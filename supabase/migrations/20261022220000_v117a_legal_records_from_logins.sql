-- v1.17a (22/10/2026) · rows a login writes itself into the legal registers are checked by the database (audit D-1,
-- claude/production-readiness-audit-2026-10-22.md).
-- A login with level 2 in an area could INSERT straight into haccp_log, production_batches, stock_moves, lab_samples and milk_intake (the tablet's
-- save_ops steps, the API, and the functions that run as the login all land there as role «authenticated»). Reproduced as produzione:
-- a CCP-PAST of 60 °C saved «ok», signed by the titolare, dated 30 days back, source «sensor» (no NC, no hold); a lot with source
-- «test» closed without CCPs and not held; +1000 kg of finished goods added with a stock adjustment.
-- One guard, BEFORE each write by a login (current_user authenticated/anon, the same test as trg_record_lock). The database's own
-- functions (log_ccp, log_milk_check, record_lab_result, pack_order, post_stock_count, receive_purchase_order, correct_record, …), cron,
-- the bots, their stand-ins and the service role run as the owner and are not touched. What a login can still write is exactly what the
-- tablet and the login-run functions write today:
--   haccp_log    · only non-critical points (the end-of-shift cleaning, the pest round): a CCP reading goes through log_ccp, which
--                  computes the result and places the hold. Result recomputed from the limits when there is a value; time within
--                  the last 7 days (an offline save keeps its time, as save_ops already allows); no «sensor»/«simulation»/«test»;
--                  entered_by_id = the login's own staff id.
--   production_batches · insert: no «sensor»/«simulation»/«test» source, not already closed (output_kg/finished_at come only from
--                  the close, which is what triggers the CCP check and the hold); entered_by_id = the login. Update: the source and
--                  entered_by_id do not change.
--   stock_moves  · production_in (raw milk, consumables, packaging into a lot: out of stock), sale (out of stock), production_out
--                  (into stock, only for a closed lot, its product and lot, up to the kg the close recorded), adjustment (only the
--                  consumable/packaging correction of a lot, as correct_batch_consumable does). Anything else, or any other sign,
--                  is refused: stock is corrected with the count (post_stock_count) or by the system.
--   lab_samples  · a sample is created «in attesa» with no result: the result comes only from record_lab_result.
--   milk_intake  · (added with Nick's approval, same direct-write gap) no «sensor»/«simulation»/«test»; the delivery's date and time
--                  within the last 7 days and not in the future for every source; a live «tablet» entry may be up to 15 minutes
--                  ahead, a DEVICE-CLOCK tolerance only (the time is the tablet's own clock), every other source 5 minutes (the
--                  paper rule, trg_milk_paper_date, already says so for «paper»). The longer-term fix is server time / clock-skew
--                  validation (audit R-11), not trusting the tablet clock: out of scope here. The temperature is required (without it the CCP 1a acceptance rule cannot run); who received it is
--                  a person the tablet can pick (floor_operators; a name, when given, is that person's own), or «firma non leggibile» on a paper
--                  copy; entered_by_id = the login. A delivery copied from paper keeps its own date (nothing is moved).
-- Delayed entries and corrections keep their controlled routes, untouched here: the paper copy (log_ccp/log_milk_check with source
-- «paper», milk and lot paper copies) up to 7 days back, and correct_record (with a reason, the original kept; after 15 minutes only the
-- HACCP or production manager). No timestamp is rewritten: a time outside the window is refused.
-- Not changed: grants, policies, existing triggers and functions; the signer of a reading (operator/operator_id) is D-3.
-- Rollback: tools/go-live/rollback/20261022220000_v117a_down.sql (drops the five triggers and the function).

create or replace function fabula.trg_login_record_guard()
 returns trigger
 language plpgsql
 set search_path to 'fabula', 'public'
as $function$
declare cp record; b record; v_kind fabula.product_kind; v_out numeric; v_today date;
begin
  if current_user not in ('authenticated', 'anon') then return new; end if;   -- the database's own functions, cron, bots, service role

  if tg_table_name = 'haccp_log' then
    select id, code, name, ccp_no, is_ccp, min_value, max_value, warn_min, warn_max into cp
      from fabula.haccp_control_points where id = new.control_point_id;
    if cp.id is null or cp.is_ccp then
      raise exception '%: un punto critico si registra solo dal controllo HACCP del tablet, con il valore misurato (non direttamente nel registro)',
        coalesce(coalesce(cp.ccp_no || ' · ', '') || cp.name, 'Punto di controllo sconosciuto') using errcode = '42501';
    end if;
    if coalesce(new.source, '') in ('sensor', 'simulation', 'test') then
      raise exception 'Registro HACCP: l''origine «%» non si scrive da un utente', new.source using errcode = '42501';
    end if;
    if new.logged_at is null or new.logged_at > now() + interval '5 minutes' or new.logged_at < now() - interval '7 days' then
      raise exception 'Registro HACCP: data e ora non valide (al massimo 7 giorni fa, non nel futuro)' using errcode = '22023';
    end if;
    if new.measured_value is not null then
      new.result := fabula.ccp_eval(cp.min_value, cp.max_value, cp.warn_min, cp.warn_max, new.measured_value);
    end if;
    new.entered_by_id := fabula.my_staff_id();
    return new;

  elsif tg_table_name = 'production_batches' then
    if tg_op = 'INSERT' then
      if coalesce(new.source, '') in ('sensor', 'simulation', 'test') then
        raise exception 'Lotto %: l''origine «%» non si scrive da un utente', new.batch_lot, new.source using errcode = '42501';
      end if;
      if new.output_kg is not null or new.finished_at is not null then
        raise exception 'Lotto %: un lotto si chiude solo con «Chiudi lotto» dopo l''avvio (lì si controllano i CCP)', new.batch_lot using errcode = '42501';
      end if;
      new.entered_by_id := fabula.my_staff_id();
    else
      if new.source is distinct from old.source then
        raise exception 'Lotto %: l''origine di un lotto non si cambia', old.batch_lot using errcode = '42501';
      end if;
      new.entered_by_id := old.entered_by_id;
    end if;
    return new;

  elsif tg_table_name = 'stock_moves' then
    select kind into v_kind from fabula.products where id = new.product_id;
    if new.move_type = 'production_in' then
      if new.qty is null or new.qty > 0 or new.batch_id is null or v_kind is null or v_kind not in ('raw_material', 'consumable', 'packaging') then
        raise exception 'Magazzino: un consumo di produzione è latte, ingredienti o confezioni in uscita verso un lotto' using errcode = '42501';
      end if;
    elsif new.move_type = 'sale' then
      if new.qty is null or new.qty > 0 then
        raise exception 'Magazzino: una vendita è una quantità in uscita' using errcode = '42501';
      end if;
    elsif new.move_type = 'production_out' then
      select id, batch_lot, product_id, output_kg into b from fabula.production_batches where id = new.batch_id;
      if b.id is null or b.output_kg is null or new.lot_number is distinct from b.batch_lot or new.product_id is distinct from b.product_id then
        raise exception 'Magazzino: un carico di produzione nasce solo dalla chiusura del suo lotto' using errcode = '42501';
      end if;
      select coalesce(sum(qty), 0) into v_out from fabula.stock_moves where batch_id = b.id and move_type = 'production_out';
      if new.qty is null or new.qty < 0 or v_out + new.qty > b.output_kg then
        raise exception 'Magazzino: il carico del lotto % supererebbe i % kg registrati alla chiusura', b.batch_lot, fabula._it_num(b.output_kg) using errcode = '42501';
      end if;
    elsif new.move_type = 'adjustment' then
      if new.batch_id is null or v_kind is null or v_kind not in ('consumable', 'packaging') then
        raise exception 'Magazzino: le rettifiche si fanno con l''inventario (Console → Magazzino), non da un utente' using errcode = '42501';
      end if;
    else
      raise exception 'Magazzino: il movimento «%» non si scrive da un utente (lo registra il sistema)', new.move_type using errcode = '42501';
    end if;
    return new;

  elsif tg_table_name = 'lab_samples' then
    if coalesce(new.outcome, 'in_attesa') <> 'in_attesa' or new.result_value is not null or new.result_it is not null or new.report_no is not null
       or new.report_date is not null or new.document_id is not null or new.nc_id is not null then
      raise exception 'Campione %: l''esito dell''analisi si registra solo quando arriva il referto del laboratorio (Autocontrollo → Analisi)',
        coalesce(new.sample_code, '') using errcode = '42501';
    end if;
    return new;

  elsif tg_table_name = 'milk_intake' then
    if coalesce(new.source, '') in ('sensor', 'simulation', 'test') then
      raise exception 'Arrivo latte: l''origine «%» non si scrive da un utente', new.source using errcode = '42501';
    end if;
    v_today := (now() at time zone 'Europe/Rome')::date;
    -- the time of a live delivery is the tablet's own clock (unlike haccp_log, where save_ops corrects it): 15 minutes ahead are a
    -- device-clock tolerance for source «tablet» only, so a tablet clock a little fast never blocks a delivery; any other source (a paper
    -- copy: the time typed from the sheet) keeps 5 minutes, as trg_milk_paper_date. Not a business rule for dating deliveries.
    if new.intake_date is null or new.intake_date < v_today - 7
       or new.intake_date + coalesce(new.intake_time, time '00:00') > (now() at time zone 'Europe/Rome')
          + (case when new.source = 'tablet' then interval '15 minutes' else interval '5 minutes' end) then
      raise exception 'Arrivo latte: data e ora non valide (al massimo 7 giorni fa, non nel futuro)' using errcode = '22023';
    end if;
    if new.temperature_c is null then
      raise exception 'Arrivo latte: scrivi la temperatura del latte (CCP 1a)' using errcode = '23502';
    end if;
    if new.received_by_id is not null then
      if not exists (select 1 from fabula.floor_operators() o where o.id = new.received_by_id and (new.received_by is null or o.full_name = new.received_by)) then
        raise exception 'Arrivo latte: chi ha ricevuto il latte va scelto dall''elenco del personale, con il suo nome' using errcode = '42501';
      end if;
    elsif new.received_by is not null and not (new.source = 'paper' and new.received_by = 'firma non leggibile') then
      raise exception 'Arrivo latte: chi ha ricevuto il latte va scelto dall''elenco del personale' using errcode = '42501';
    end if;
    new.entered_by_id := fabula.my_staff_id();
    return new;
  end if;
  return new;
end $function$;

-- «a0»: before the tables' other BEFORE triggers (they fire in name order), so nothing works on a row that is refused here
create trigger haccp_log_a0_login_guard before insert on fabula.haccp_log for each row execute function fabula.trg_login_record_guard();
create trigger batch_a0_login_guard before insert or update on fabula.production_batches for each row execute function fabula.trg_login_record_guard();
create trigger stock_moves_a0_login_guard before insert on fabula.stock_moves for each row execute function fabula.trg_login_record_guard();
create trigger lab_samples_a0_login_guard before insert on fabula.lab_samples for each row execute function fabula.trg_login_record_guard();
create trigger milk_intake_a0_login_guard before insert on fabula.milk_intake for each row execute function fabula.trg_login_record_guard();
