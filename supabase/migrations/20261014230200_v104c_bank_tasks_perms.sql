-- v1.04c · Audit 12/10/2026, D-28, D-31, D-33.
--   * D-28 Incassi, manual matching: an outgoing payment cannot settle a customer invoice, a wholesale order or a Shopify payout,
--     and an incoming one cannot pay a supplier invoice; an invoice or order already matched to another bank movement (or an invoice
--     already paid) is refused with where it is (an instalment: the other movement is classified «Altro» with a note); a different
--     amount (more than € 0,50) is written in the note, after the note typed by hand.
--   * D-31 A task tied to a control point (cold rooms, valve, chlorine, cleaning, brine…) is closed only when a reading of that point
--     exists for it (from 3 hours before it is due, or that day when it is the only one): a cold-room display check («CAL:CF-01»)
--     no longer ticks «Temperatura cella 1».
--   * D-33 A login inserts an approval request only as «in attesa» (it cannot write one already approved or set to approve itself);
--     a purchase order is created only as draft or awaiting approval and reaches «approvato / inviato / ricevuto» only through the
--     database's own functions (approval, «Invia», receipt); a PO line cannot have a negative price.
--     (create_manual_po already asks for approval below acquisti 3 since v0.99; hold_lot and record_lab_result are definer since v0.93.)

-- ============================== D-28 bank matching ==============================
create or replace function fabula.recon_set_bank(p_bank_tx uuid, p_kind text, p_ref text default null::text, p_note text default null::text)
 returns jsonb
 language plpgsql
 set search_path to 'fabula', 'public'
as $function$
declare b fabula.bank_transactions; v_who uuid := fabula.my_staff_id(); v_kind text := lower(btrim(coalesce(p_kind, ''))); v_note text := nullif(btrim(coalesce(p_note, '')), '');
        p fabula.payment_payouts; v_inv fabula.invoices; v_so fabula.sales_orders; x record;
begin
  if not fabula.can('finanza', 2) then raise exception 'Il tuo profilo non può abbinare gli incassi' using errcode = '42501'; end if;
  select * into b from fabula.bank_transactions where id = p_bank_tx for update;
  if b.id is null then raise exception 'Movimento non trovato'; end if;
  -- undo whatever was there
  update fabula.payment_payouts set bank_tx_id = null, matched_at = null, matched_by = null, match_note = null, updated_at = now() where bank_tx_id = b.id;
  if b.matched_invoice_id is not null then
    update fabula.invoices set status = 'approved', paid_at = null, payment_ref = null, updated_at = now() where id = b.matched_invoice_id and payment_ref = b.external_id and status = 'paid';
  end if;
  update fabula.bank_transactions set match_kind = null, matched_payout_id = null, matched_invoice_id = null, matched_order_id = null, reconciled = false,
         match_note = null, matched_at = null, matched_by = null where id = b.id;
  if v_kind = 'clear' then return jsonb_build_object('id', b.id, 'kind', null); end if;

  if v_kind = 'payout' then
    select * into p from fabula.payment_payouts where id = p_ref;
    if p.id is null then raise exception 'Versamento non trovato'; end if;
    if p.bank_tx_id is not null then raise exception 'Questo versamento è già abbinato a un altro movimento'; end if;
    -- v1.04 (audit D-28): a payout and its bank movement go the same way
    if sign(coalesce(p.net_eur, 0)) <> sign(b.amount_eur) then
      raise exception using errcode = '22023', message = format('Un''%s (%s €) non può essere il versamento Shopify del %s (%s €): scegli un movimento nella stessa direzione.',
        case when b.amount_eur < 0 then 'uscita' else 'entrata' end, fabula._it_num(b.amount_eur), to_char(p.payout_date, 'DD/MM/YYYY'), fabula._it_num(p.net_eur));
    end if;
    update fabula.bank_transactions set match_kind = 'payout', matched_payout_id = p.id, reconciled = true, matched_at = now(), matched_by = v_who,
           match_note = coalesce(v_note, case when p.net_eur <> b.amount_eur then 'Abbinato a mano: importi diversi (' || p.net_eur || ' / ' || b.amount_eur || ')' end) where id = b.id;
    update fabula.payment_payouts set bank_tx_id = b.id, matched_at = now(), matched_by = v_who, match_note = v_note, updated_at = now() where id = p.id;
  elsif v_kind = 'invoice' then
    select * into v_inv from fabula.invoices where id = p_ref::uuid for update;
    if v_inv.id is null then raise exception 'Fattura non trovata'; end if;
    -- v1.04 (audit D-28): the direction must match, and an invoice is settled once
    if v_inv.direction = 'out' and b.amount_eur <= 0 then
      raise exception using errcode = '22023', message = format('Un''uscita (%s €) non può incassare la fattura cliente %s: scegli un''entrata, oppure abbina l''uscita come fornitore o spesa.', fabula._it_num(b.amount_eur), v_inv.invoice_number);
    elsif v_inv.direction = 'in' and b.amount_eur >= 0 then
      raise exception using errcode = '22023', message = format('Un''entrata (%s €) non paga la fattura fornitore %s: scegli un''uscita.', fabula._it_num(b.amount_eur), v_inv.invoice_number);
    end if;
    if v_inv.status::text = 'void' then raise exception using errcode = '22023', message = format('La fattura %s è annullata', v_inv.invoice_number); end if;
    select bt.value_date, bt.amount_eur into x from fabula.bank_transactions bt where bt.matched_invoice_id = v_inv.id and bt.id <> b.id limit 1;
    if found then
      raise exception using errcode = '22023', message = format('La fattura %s è già abbinata al movimento del %s (%s €): togli prima quell''abbinamento. Se è una rata, classifica questo movimento come «Altro» con una nota.', v_inv.invoice_number, to_char(x.value_date, 'DD/MM/YYYY'), fabula._it_num(x.amount_eur));
    end if;
    if v_inv.status::text = 'paid' then
      raise exception using errcode = '22023', message = format('La fattura %s risulta già pagata%s%s.', v_inv.invoice_number, coalesce(' il ' || to_char(v_inv.paid_at, 'DD/MM/YYYY'), ''), coalesce(' (' || nullif(v_inv.payment_ref, '') || ')', ''));
    end if;
    update fabula.bank_transactions set match_kind = 'invoice', matched_invoice_id = v_inv.id, reconciled = true, matched_at = now(), matched_by = v_who,
           match_note = nullif(concat_ws(' · ', v_note, case when abs(abs(b.amount_eur) - coalesce(v_inv.total_eur, 0)) > 0.5
                                              then format('Abbinato a mano: importi diversi (fattura %s €, movimento %s €)', fabula._it_num(v_inv.total_eur), fabula._it_num(b.amount_eur)) end), '')
     where id = b.id;
    update fabula.invoices set status = 'paid', paid_at = b.value_date, payment_ref = b.external_id, updated_at = now() where id = v_inv.id;
  elsif v_kind = 'order' then
    select * into v_so from fabula.sales_orders where id = p_ref::uuid for update;
    if v_so.id is null then raise exception 'Ordine non trovato'; end if;
    if b.amount_eur <= 0 then
      raise exception using errcode = '22023', message = format('Un''uscita (%s €) non può incassare l''ordine %s: scegli un''entrata.', fabula._it_num(b.amount_eur), v_so.order_number);
    end if;
    if v_so.status::text in ('cancelled', 'draft') then raise exception using errcode = '22023', message = format('L''ordine %s è %s: non si incassa', v_so.order_number, case when v_so.status::text = 'draft' then 'una bozza' else 'annullato' end); end if;
    select bt.value_date, bt.amount_eur into x from fabula.bank_transactions bt where bt.matched_order_id = v_so.id and bt.id <> b.id limit 1;
    if found then
      raise exception using errcode = '22023', message = format('L''ordine %s è già abbinato al movimento del %s (%s €): togli prima quell''abbinamento. Se è una rata, classifica questo movimento come «Altro» con una nota.', v_so.order_number, to_char(x.value_date, 'DD/MM/YYYY'), fabula._it_num(x.amount_eur));
    end if;
    update fabula.bank_transactions set match_kind = 'order', matched_order_id = v_so.id, reconciled = true, matched_at = now(), matched_by = v_who,
           match_note = nullif(concat_ws(' · ', v_note, case when abs(b.amount_eur - coalesce(v_so.total_eur, 0)) > 0.5
                                              then format('Abbinato a mano: importi diversi (ordine %s €, movimento %s €)', fabula._it_num(v_so.total_eur), fabula._it_num(b.amount_eur)) end), '')
     where id = b.id;
  elsif v_kind in ('bank_fee', 'cash_deposit', 'transfer', 'expense', 'supplier', 'salary', 'tax', 'other', 'ignore') then
    if v_kind in ('other', 'ignore') and v_note is null then raise exception 'Scrivi una nota: cosa è questo movimento?'; end if;
    update fabula.bank_transactions set match_kind = v_kind, reconciled = true, matched_at = now(), matched_by = v_who, match_note = v_note where id = b.id;
  else
    raise exception 'Tipo di abbinamento sconosciuto: %', p_kind;
  end if;
  return jsonb_build_object('id', b.id, 'kind', v_kind);
end $function$;

-- ============================== D-31 a task needs its record ==============================
create or replace function fabula.close_open_task(p_day date, p_code text default null::text, p_equipment_id uuid default null::uuid, p_control_point_id uuid default null::uuid, p_staff_id uuid default null::uuid, p_scan_event_id uuid default null::uuid, p_at timestamp with time zone default null::timestamp with time zone)
 returns uuid
 language plpgsql
 set search_path to 'fabula', 'public'
as $function$
declare v_id uuid; v_at timestamptz := coalesce(p_at, now()); v_from timestamptz;
begin
  if p_code is null and p_equipment_id is null and p_control_point_id is null then return null; end if;
  if v_at > now() + interval '5 minutes' or v_at < now() - interval '7 days' then v_at := now(); end if;   -- a wrong tablet clock
  v_from := coalesce(p_day, (v_at at time zone 'Europe/Rome')::date)::timestamp at time zone 'Europe/Rome';
  select ti.id into v_id from fabula.task_instances ti join fabula.task_schedules ts on ts.id = ti.schedule_id
   cross join lateral (select count(*) = 1 as single from fabula.task_instances t2 where t2.schedule_id = ti.schedule_id and t2.followup_kind is null
                         and t2.due_at >= v_from and t2.due_at < v_from + interval '1 day') s
   where ti.status in ('due', 'overdue') and ti.followup_kind is null and ti.due_at >= v_from and ti.due_at < v_from + interval '1 day'
     and (p_code is null or ts.code = p_code) and (p_equipment_id is null or ts.equipment_id = p_equipment_id)
     and (p_control_point_id is null or ts.control_point_id = p_control_point_id)
     -- v0.97 (audit A-05): with more than one task of that kind in the day (cold rooms morning and evening) a check closes only one
     -- whose time has come (from 3 hours before it): an extra re-check at 10:00 leaves the evening reading on the list
     and (ti.due_at - interval '3 hours' <= v_at or s.single)
     -- v1.04 (audit D-31): a task tied to a control point is done only if a reading of that point exists for it — not because a
     -- calibration of the same machine (CAL:CF-01) or another scan of it came by
     and (ts.control_point_id is null or exists (
           select 1 from fabula.haccp_log h
            where h.control_point_id = ts.control_point_id
              and h.logged_at >= case when s.single then v_from else greatest(v_from, ti.due_at - interval '3 hours') end
              and h.logged_at < least(v_from + interval '1 day', v_at + interval '5 minutes')))
   order by (v_at between ti.due_at - interval '3 hours' and ti.due_at + interval '6 hours') desc, ti.due_at
   limit 1;
  if v_id is null then return null; end if;
  update fabula.task_instances set status = 'done', completed_at = v_at, completed_by_id = coalesce(p_staff_id, fabula.my_staff_id()),
         scan_event_id = coalesce(p_scan_event_id, scan_event_id)
   where id = v_id;
  return v_id;
end $function$;

-- ============================== D-33 permission levels ==============================
-- approvals: a login writes a request only as «in attesa»; the auto-approval window is set by the database (approvals_auto_rule,
-- which fires after this one: triggers run in name order)
create or replace function fabula.trg_approvals_insert_guard() returns trigger
language plpgsql set search_path = fabula, public as $$
begin
  if current_user not in ('authenticated', 'anon') then return new; end if;
  if new.status::text <> 'pending' then
    raise exception using errcode = '42501', message = 'Una richiesta di approvazione nasce «in attesa»: la decide chi ne ha il livello, da Console → Oggi';
  end if;
  new.decided_by := null; new.decided_at := null; new.decision_note := null; new.auto_approve_at := null; new.auto_rule := null;
  return new;
end $$;
drop trigger if exists approvals_a0_insert_guard on fabula.approvals;
create trigger approvals_a0_insert_guard before insert on fabula.approvals for each row execute function fabula.trg_approvals_insert_guard();

-- purchase orders: created by a login only as draft or awaiting approval; approved / sent / received only through the database's
-- own functions (the approval in Console → Oggi, «Invia», the goods receipt), which run as definer and pass
create or replace function fabula.trg_po_status_guard() returns trigger
language plpgsql set search_path = fabula, public as $$
begin
  if current_user not in ('authenticated', 'anon') then return new; end if;
  if tg_op = 'INSERT' and new.status::text not in ('draft', 'pending_approval') then
    raise exception using errcode = '42501', message = 'Un ordine d''acquisto nasce in bozza o in attesa di approvazione: si approva da Console → Oggi';
  end if;
  if tg_op = 'UPDATE' and new.status is distinct from old.status and new.status::text in ('approved', 'sent', 'partially_received', 'received') then
    raise exception using errcode = '42501', message = format('L''ordine %s diventa «%s» solo dalla sua approvazione, da «Invia al fornitore» o dal ricevimento merce', new.po_number,
      case new.status::text when 'approved' then 'approvato' when 'sent' then 'inviato' else 'ricevuto' end);
  end if;
  return new;
end $$;
drop trigger if exists purchase_orders_status_guard on fabula.purchase_orders;
create trigger purchase_orders_status_guard before insert or update of status on fabula.purchase_orders for each row execute function fabula.trg_po_status_guard();

alter table fabula.purchase_order_lines drop constraint if exists purchase_order_lines_unit_price_check;
alter table fabula.purchase_order_lines add constraint purchase_order_lines_unit_price_check check (unit_price_eur is null or unit_price_eur >= 0) not valid;
alter table fabula.purchase_order_lines validate constraint purchase_order_lines_unit_price_check;
comment on constraint purchase_order_lines_unit_price_check on fabula.purchase_order_lines is 'Il prezzo di una riga d''ordine non può essere negativo';
