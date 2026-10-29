-- v1.20a (29/10/2026) · MILK-1 · the house rule «latte del giorno»: every kg of milk delivered to the caseificio goes into a vat the day it
-- arrives, and only that day (claude/milk-same-day-pre-change-review-2026-10-29.md; rule: claude/milk-freshness-rule-2026-10-29.md).
-- Decided by Nick on 29/10/2026:
--   * the farm delivers every morning of cheesemaking; each delivery holds only last evening's (15:30) and that morning's (05:00) milkings;
--   * everything delivered to the caseificio is transformed that day: no scrap, no leftovers; milk not needed stays at the farm and is
--     sold there;
--   * the rule covers every product made from milk (DOP or not); there is no setting to switch it off.
-- Until now the database enforced only the DOP limit (60 h, v0.97b, DOP products only), the plan proposed milk up to milk.raw_shelf_days
-- + 1 days old, and the evening watch spoke only of milk 48 h old.
-- Now:
--   1. batch_milk_same_day: a milk input is refused when its vat's day (Rome date of started_at, else batch_date) differs from the day the
--      milk arrived, or when the load left the Masseria on an earlier day. An offline or paper start keeps its own start time, so a vat
--      started on the delivery day and sent later passes. The 60 h DOP guard stays as the legal backstop (it fires first: name order).
--   2. prod_watch (19:xx Rome): a delivery of the day, or of the last 5 days, with more than 1 kg not in a vat is an alarm («Regola del
--      caseificio»), with one non-conformity per delivery (severity minor, marked as not food safety): closing it needs HACCP level 3 and
--      the corrective action, so an exception is always documented. It replaces «latte vicino alle 60 ore» (48 h).
--   3. production_plan: only the day's deliveries are proposed, all of their kg; older milk with kg left is listed apart («stale»).
--   4. «Prima di chiudere» (_haccp_evening_items): from 15:00 the deliveries of the day not yet all in a vat.
--   5. consorzio_declaration: checks latte_altro_giorno and latte_non_lavorato (expected 0) and the month's longest arrival-to-vat time.
--   6. milk.raw_shelf_days = 0 (minimum lowered to 0): a raw-milk lot expires the day it arrives (information: the expiring and
--      sell-down views read finished goods only).
--   7. The message rule «latte_60_ore» becomes «latte_non_lavorato»; the «Perché?» of the evening watch explains the house rule.
-- Not changed: plan_milk / demand_7d (they never counted raw milk), milk_reject, correct_batch_milk (kg only, same delivery), the D-1
-- guard, grants, the farm page (release B).
-- Rollback: tools/go-live/rollback/20261029200000_v120a_down.sql.

-- ============================================================================================================================
-- 1. The vat is filled on the day the milk arrives
-- ============================================================================================================================
create or replace function fabula.trg_batch_milk_same_day()
returns trigger language plpgsql security definer set search_path = fabula, public as $$
declare v_day date; mi record;
begin
  select coalesce((b.started_at at time zone 'Europe/Rome')::date, b.batch_date) into v_day
    from fabula.production_batches b where b.id = new.batch_id;
  select m.milk_lot, m.intake_date, (s.shipped_at at time zone 'Europe/Rome')::date ship_day into mi
    from fabula.milk_intake m left join fabula.milk_shipments s on s.id = m.shipment_id where m.id = new.milk_intake_id;
  if v_day is null or mi.intake_date is null then return new; end if;     -- a missing lot or delivery: the foreign keys say so
  if mi.intake_date <> v_day then
    raise exception 'Il latte % è arrivato il %: si lavora solo il giorno in cui arriva (regola del caseificio: tutto il latte consegnato va in caldaia lo stesso giorno). Chiama il responsabile.',
      coalesce(mi.milk_lot, '?'), fabula._it_d(mi.intake_date) using errcode = '23514';
  end if;
  if mi.ship_day is not null and mi.ship_day < v_day then
    raise exception 'Il latte % è partito dalla Masseria il %: si lavora solo latte consegnato la mattina stessa (regola del caseificio). Chiama il responsabile.',
      coalesce(mi.milk_lot, '?'), fabula._it_d(mi.ship_day) using errcode = '23514';
  end if;
  return new;
end $$;
comment on function fabula.trg_batch_milk_same_day() is
  'v1.20 (MILK-1): regola del caseificio — il latte va in caldaia il giorno in cui arriva (e in cui è partito dalla Masseria), per ogni prodotto';
revoke all on function fabula.trg_batch_milk_same_day() from public, anon, authenticated;
drop trigger if exists batch_milk_same_day on fabula.batch_milk_inputs;
create trigger batch_milk_same_day before insert or update of milk_intake_id, batch_id on fabula.batch_milk_inputs
  for each row execute function fabula.trg_batch_milk_same_day();

-- ============================================================================================================================
-- 2. The evening watch (19:xx Rome): milk not all in a vat on its day → alarm + one non-conformity per delivery
-- ============================================================================================================================
create or replace function fabula.prod_watch(p_now timestamp with time zone default now())
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'fabula', 'public'
as $function$
declare v_day date := (p_now at time zone 'Europe/Rome')::date; v_open text; v_milk text; n_open int; n_milk int; n_nc int := 0; v_title text; d record;
begin
  if extract(hour from p_now at time zone 'Europe/Rome') <> 19 then return jsonb_build_object('skipped', 'not 19:xx in Rome'); end if;
  select count(*), string_agg(batch_lot || ' (' || to_char(coalesce(started_at, batch_date::timestamptz) at time zone 'Europe/Rome', 'DD/MM HH24:MI') || ')', ', ' order by batch_lot)
    into n_open, v_open
    from fabula.production_batches where output_kg is null and batch_date <= v_day and coalesce(source, '') not in ('simulation', 'test');
  -- v1.20 (MILK-1, house rule): every kg delivered goes into a vat the day it arrives; at 19:xx a delivery of today, or of the last
  -- 5 days, that still has more than 1 kg not in a vat breaks the rule (was: milk 48 h old, before the DOP 60 h)
  select count(*), string_agg(format('%s: %s kg, arrivato %s', m.milk_lot, trim_scale(m.left_kg), to_char(m.arrived at time zone 'Europe/Rome', 'DD/MM HH24:MI')), E'\n• ' order by m.arrived)
    into n_milk, v_milk
    from (select mi.milk_lot, ((mi.intake_date + coalesce(mi.intake_time, time '07:00')) at time zone 'Europe/Rome') arrived,
                 mi.qty_kg - coalesce((select sum(bmi.qty_kg) from fabula.batch_milk_inputs bmi where bmi.milk_intake_id = mi.id), 0) left_kg
            from fabula.milk_intake mi where mi.accepted and coalesce(mi.source, '') <> 'simulation' and mi.intake_date between v_day - 5 and v_day) m
   where m.left_kg > 1 and m.arrived <= p_now;
  if n_open = 0 and n_milk = 0 then return jsonb_build_object('open_batches', 0, 'old_milk', 0); end if;
  -- one non-conformity per delivery, once: the responsible closes it with what was done (trg_nc_close_guard asks for the action)
  for d in select mi.milk_lot, mi.intake_date,
                  mi.qty_kg - coalesce((select sum(bmi.qty_kg) from fabula.batch_milk_inputs bmi where bmi.milk_intake_id = mi.id), 0) left_kg
             from fabula.milk_intake mi
            where mi.accepted and coalesce(mi.source, '') <> 'simulation' and mi.intake_date between v_day - 5 and v_day
              and ((mi.intake_date + coalesce(mi.intake_time, time '07:00')) at time zone 'Europe/Rome') <= p_now
            order by mi.intake_date, mi.milk_lot loop
    continue when d.left_kg <= 1;
    continue when exists (select 1 from fabula.non_conformities n where n.lot_number = d.milk_lot and n.description like 'Regola del caseificio%');
    insert into fabula.non_conformities (severity, status, description, lot_number)
    values ('minor', 'open',
            format('Regola del caseificio (non di sicurezza alimentare): latte %s arrivato il %s, %s kg non lavorati il giorno di arrivo. Non va in caldaia nei giorni seguenti: scrivi cosa è stato fatto.',
                   d.milk_lot, fabula._it_d(d.intake_date), fabula._it_num(round(d.left_kg, 1))),
            d.milk_lot);
    n_nc := n_nc + 1;
  end loop;
  v_title := format('Produzione %s: %s', to_char(v_day, 'DD/MM'), concat_ws(' · ', case when n_open > 0 then n_open || ' lott' || case when n_open = 1 then 'o aperto' else 'i aperti' end end,
                                                                     case when n_milk > 0 then n_milk || case when n_milk = 1 then ' consegna di latte non lavorata' else ' consegne di latte non lavorate' end || ' in giornata' end));
  if exists (select 1 from fabula.bot_messages where agent in ('produzione', 'sicurezza') and title = v_title) then
    return jsonb_build_object('skipped', 'already posted', 'nc_opened', n_nc);
  end if;
  perform fabula.keep_basis(case when n_milk > 0 then 'sicurezza' else 'produzione' end, 'prod_watch', jsonb_build_object('date', v_day, 'checked_at', p_now,
      'rule', 'same_day', 'dop_limit_hours', 60,
      'open_batches', (select coalesce(jsonb_agg(jsonb_build_object('lot', batch_lot, 'started', coalesce(started_at, batch_date::timestamptz)) order by batch_lot), '[]'::jsonb)
                         from fabula.production_batches where output_kg is null and batch_date <= v_day and coalesce(source, '') not in ('simulation', 'test')),
      'old_milk', (select coalesce(jsonb_agg(jsonb_build_object('lot', m.milk_lot, 'left_kg', m.left_kg, 'arrived', m.arrived,
                                                               'hours', round(extract(epoch from p_now - m.arrived) / 3600)) order by m.arrived), '[]'::jsonb)
                     from (select mi.milk_lot, ((mi.intake_date + coalesce(mi.intake_time, time '07:00')) at time zone 'Europe/Rome') arrived,
                                  mi.qty_kg - coalesce((select sum(bmi.qty_kg) from fabula.batch_milk_inputs bmi where bmi.milk_intake_id = mi.id), 0) left_kg
                             from fabula.milk_intake mi where mi.accepted and coalesce(mi.source, '') <> 'simulation' and mi.intake_date between v_day - 5 and v_day) m
                    where m.left_kg > 1 and m.arrived <= p_now)), 'database');   -- v1.06 («Perché?»)
  perform fabula.post_bot_message(case when n_milk > 0 then 'sicurezza' else 'produzione' end, 'warn', v_title,
    concat_ws(E'\n\n',
      case when n_open > 0 then format(E'Lotti avviati e non chiusi:\n• %s\nSe sono finiti, scansiona l''etichetta sul tank e chiudili con i kg; se sono stati scartati, registra lo scarto.', replace(v_open, ', ', E'\n• ')) end,
      case when n_milk > 0 then format(E'Regola del caseificio: tutto il latte consegnato va in caldaia il giorno in cui arriva. Latte non ancora lavorato:\n• %s\nNon può andare in caldaia nei giorni seguenti. Per ogni consegna c''è una non conformità (Autocontrollo → Non conformità): il responsabile la chiude scrivendo cosa è stato fatto.', v_milk) end));
  return jsonb_build_object('open_batches', n_open, 'old_milk', n_milk, 'nc_opened', n_nc);
end $function$;

-- «Perché?» of the evening watch: the open lots and the milk not worked on its day
create or replace function fabula._why_prod_watch(d jsonb) returns jsonb
language plpgsql stable set search_path = fabula, public as $$
declare r jsonb[] := '{}'; m jsonb[] := '{}'; x jsonb;
begin
  for x in select y from jsonb_array_elements(coalesce(d->'open_batches', '[]'::jsonb)) y loop
    r := r || fabula._wr('Lotto ' || coalesce(x->>'lot', ''), 'avviato ' || fabula._wd(x->'started') || coalesce(' ore ' || fabula._wt(x->'started'), ''),
                         'non ancora chiuso: se è finito si chiude con i kg, se è stato scartato si registra lo scarto');
  end loop;
  for x in select y from jsonb_array_elements(coalesce(d->'old_milk', '[]'::jsonb)) y loop
    m := m || fabula._wr('Latte ' || coalesce(x->>'lot', ''), fabula._wq(x->'left_kg') || ' non lavorati',
                         format('arrivato %s ore %s: %s fa', fabula._wd(x->'arrived'), coalesce(fabula._wt(x->'arrived'), 'n/d'),
                                case when fabula._wn(x->'hours') is not null then fabula.it_n(fabula._wn(x->'hours'), 'ora', 'ore') else 'n/d ore' end), 'ko');
  end loop;
  return fabula._wout('Perché questo avviso della sera', array[
    fabula._wsec('Lotti aperti', r),
    fabula._wsec('Latte non lavorato il giorno di arrivo', m, case when cardinality(m) > 0 then
      format('Regola del caseificio: tutto il latte consegnato va in caldaia il giorno in cui arriva (il disciplinare DOP consente fino a %s ore dalla mungitura). Questo latte non può andare in caldaia nei giorni seguenti: il responsabile chiude la non conformità scrivendo cosa è stato fatto.',
             coalesce(d->>'dop_limit_hours', '60')) end)]);
end $$;

-- ============================================================================================================================
-- 3. Settings, message rule, scheduled-job description
-- ============================================================================================================================
update fabula.settings
   set min_value = 0, value = '0',
       description = 'Giorni entro cui il latte conferito va lavorato: 0 = il giorno di arrivo (regola del caseificio, v1.20). Il lotto di latte in magazzino scade quel giorno'
 where key = 'milk.raw_shelf_days';

update fabula.message_rules
   set kind = 'latte_non_lavorato', title_regex = 'latte non lavorat',
       meaning_it = 'Latte consegnato e non messo tutto in caldaia il giorno di arrivo (regola del caseificio): non va in caldaia nei giorni seguenti; il responsabile chiude la non conformità.'
 where kind = 'latte_60_ore';

update fabula.cron_jobs_expected set purpose_it = 'Lotti aperti e latte non lavorato in giornata (sera)' where jobname = 'fabula_prod_watch';

-- ============================================================================================================================
-- 4. production_plan: only the day's milk is proposed; older milk with kg left is listed apart («stale»)
-- ============================================================================================================================
CREATE OR REPLACE FUNCTION fabula.production_plan(p_date date DEFAULT ((now() AT TIME ZONE 'Europe/Rome'::text))::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'fabula', 'public'
AS $function$
declare v_vat numeric := greatest(fabula.setting_num('prod.vat_kg', 800), 50); v_min numeric := fabula.setting_num('milk.min_run_kg', 300);
        v_whey_pct numeric := fabula.setting_num('effluent.whey_pct_of_milk', 62);
        v_prod record; v_preset record; v_y jsonb; v_ric jsonb; m record; v_n int; v_kg numeric; v_rest numeric; v_seq int := 0;
        milk jsonb := '[]'; props jsonb := '[]'; v_doses jsonb; i int;
begin
  perform fabula.require_perm('produzione', 1);
  -- main product: the active finished good that is not a by-product (mozzarella), with its default preset
  select p.id, p.name, p.byproduct_product_id into v_prod from fabula.products p
   where p.kind = 'finished_good' and p.active and not exists (select 1 from fabula.products q where q.byproduct_product_id = p.id)
   order by (p.sku = 'MOZ-DOP-KG') desc, p.name limit 1;
  select pp.id, pp.name into v_preset from fabula.process_presets pp where pp.product_id = v_prod.id and pp.active order by pp.is_default desc, pp.created_at limit 1;
  v_y := fabula.expected_yield(v_prod.id, v_preset.id);
  if v_prod.byproduct_product_id is not null then v_ric := fabula.expected_yield(v_prod.byproduct_product_id); end if;

  for m in
    select mi.id, mi.milk_lot, mi.qty_kg, mi.intake_date, mi.intake_time, pa.legal_name supplier,
           least(coalesce(s.shipped_at, 'infinity'::timestamptz), (mi.intake_date + coalesce(mi.intake_time, '06:00')) at time zone 'Europe/Rome') + interval '60 hours' use_by,
           coalesce((select sum(bm.qty_kg) from fabula.batch_milk_inputs bm where bm.milk_intake_id = mi.id), 0) used
      from fabula.milk_intake mi
      left join fabula.parties pa on pa.id = mi.supplier_id
      left join fabula.milk_shipments s on s.id = mi.shipment_id
     where mi.accepted is not false and mi.intake_date = p_date and coalesce(mi.source, '') <> 'simulation'
     order by mi.intake_date, mi.intake_time nulls first, mi.created_at
  loop
    v_rest := round(m.qty_kg - m.used, 1);
    continue when v_rest < 1;
    milk := milk || jsonb_build_object('milk_intake_id', m.id, 'milk_lot', m.milk_lot, 'supplier', m.supplier, 'intake_date', m.intake_date,
              'kg', m.qty_kg, 'used_kg', m.used, 'left_kg', v_rest, 'use_by', m.use_by,
              'hours_left', round(extract(epoch from (m.use_by - now())) / 3600, 1));
    -- equal vat loads: 1,150 kg with an 800 kg vat → 2 × 575 kg
    v_n := ceil(v_rest / v_vat)::int;
    for i in 1..v_n loop
      v_kg := case when i < v_n then round(v_rest / v_n, 1) else v_rest - round(v_rest / v_n, 1) * (v_n - 1) end;
      v_seq := v_seq + 1;
      select coalesce(jsonb_agg(jsonb_build_object('sku', r.sku, 'name', r.name, 'unit', r.unit,
                       'qty', case when r.round_up then ceil(r.qty_per_unit * v_kg) else round(r.qty_per_unit * v_kg, 3) end) order by r.step_order), '[]')
        into v_doses from fabula.v_recipe_active r where r.finished_product_id = v_prod.id and r.phase = 'start' and r.basis = 'per_kg_milk';
      props := props || jsonb_build_object('seq', v_seq, 'milk_intake_id', m.id, 'milk_lot', m.milk_lot, 'left_kg', v_rest, 'milk_kg', v_kg,
                 'product_id', v_prod.id, 'product', v_prod.name, 'preset_id', v_preset.id, 'preset', v_preset.name,
                 'yield_pct', v_y->'pct', 'yield_source', v_y->'source', 'expected_kg', round(v_kg * (v_y->>'pct')::numeric / 100, 1),
                 'whey_kg', round(v_kg * v_whey_pct / 100, 0),
                 'ricotta_kg', case when v_ric is not null then round(v_kg * v_whey_pct / 100 * (v_ric->>'pct')::numeric / 100, 1) end,
                 'doses', v_doses, 'use_by', m.use_by, 'small', v_rest < v_min);
    end loop;
  end loop;

  return jsonb_build_object(
    'date', p_date, 'vat_kg', v_vat, 'min_run_kg', v_min, 'tolerance_pts', v_y->'tolerance_pts',
    'yield', v_y, 'product', v_prod.name,
    'target', (select jsonb_build_object('milk_kg', mp.milk_kg, 'planned_output_kg', mp.planned_output_kg, 'status', mp.status)
                 from fabula.milk_plans mp where mp.plan_date = p_date and mp.status in ('approved', 'proposed') order by (mp.status = 'approved') desc limit 1),
    'milk', milk, 'proposals', props,
    'open', (select coalesce(jsonb_agg(jsonb_build_object('batch_id', b.id, 'batch_lot', b.batch_lot, 'product', p.name, 'input_kind', b.input_kind,
                       'milk_in_kg', b.milk_in_kg, 'started_at', b.started_at, 'batch_date', b.batch_date,
                       'expected_kg', round(b.milk_in_kg * (fabula.expected_yield(b.product_id, b.preset_id)->>'pct')::numeric / 100, 1)) order by b.started_at), '[]')
               from fabula.production_batches b join fabula.products p on p.id = b.product_id
              where b.output_kg is null and b.batch_date >= p_date - 3 and b.source is distinct from 'simulation'),
    'done', (select jsonb_build_object('batches', count(*), 'output_kg', coalesce(sum(b.output_kg), 0), 'milk_kg', coalesce(sum(b.milk_in_kg), 0),
                       'yield_pct', case when sum(b.milk_in_kg) > 0 then round(sum(b.output_kg) / sum(b.milk_in_kg) * 100, 1) end,
                       'flags', count(*) filter (where b.yield_flag is not null))
               from fabula.production_batches b
              where b.batch_date = p_date and b.output_kg is not null and b.product_id = v_prod.id and b.source is distinct from 'simulation'),
    'expected_kg', (select coalesce(sum((x->>'expected_kg')::numeric), 0) from jsonb_array_elements(props) x),
    -- v1.20 (MILK-1, house rule): only the milk that arrived on the day is proposed; milk of an earlier day that still has kg left is
    -- listed here, never proposed (it can no longer go into a vat: batch_milk_same_day refuses it)
    'same_day', true,
    'stale', (select coalesce(jsonb_agg(jsonb_build_object('milk_intake_id', x.id, 'milk_lot', x.milk_lot, 'intake_date', x.intake_date, 'left_kg', x.left_kg)
                                order by x.intake_date, x.milk_lot), '[]')
                from (select mi.id, mi.milk_lot, mi.intake_date,
                             round(mi.qty_kg - coalesce((select sum(bm.qty_kg) from fabula.batch_milk_inputs bm where bm.milk_intake_id = mi.id), 0), 1) left_kg
                        from fabula.milk_intake mi
                       where mi.accepted is not false and mi.intake_date between p_date - 7 and p_date - 1 and coalesce(mi.source, '') <> 'simulation') x
               where x.left_kg >= 1));
end $function$;

-- ============================================================================================================================
-- 5. «Prima di chiudere»: from 15:00 the milk of the day not yet in a vat
-- ============================================================================================================================
CREATE OR REPLACE FUNCTION fabula._haccp_evening_items(p_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'fabula', 'public', 'extensions'
AS $function$
declare items jsonb := '[]'; n_ship int; n_milk int; n_abx int; v_real_prod boolean; v_start date := fabula.tasks_start_date();
begin
  v_real_prod := exists (select 1 from fabula.production_batches where batch_date = p_date and source <> 'simulation');
  -- v1.05 (audit E-32): nothing is asked before the tasks start, unless milk or a lot was really worked that day (food safety first)
  if v_start is not null and p_date < v_start and not v_real_prod
     and not fabula._real_activity(p_date) then   -- v1.07: nor real product in stock or worked in the last days
    return items;
  end if;
  -- the Rome day (v1.05: logged_at::date was the UTC date)
  select coalesce(jsonb_agg(jsonb_build_object('code', 'cold:' || cp.code, 'label_it', 'Temperatura serale ' || coalesce(e.code, cp.name), 'scan', 'EQ:' || e.code) order by cp.code), '[]') into items
  from fabula.haccp_control_points cp left join fabula.equipment e on e.id = cp.equipment_id
  where cp.active and cp.frequency = 'twice_daily'
    and not exists (select 1 from fabula.haccp_log l where l.control_point_id = cp.id and (l.logged_at at time zone 'Europe/Rome')::date = p_date
                                                         and (l.logged_at at time zone 'Europe/Rome')::time >= time '15:00');
  -- the end-of-shift cleaning, not on a closed day with no production (only the cold rooms are checked then)
  if not (fabula.is_closed_day(p_date) and not v_real_prod)
     and not exists (select 1 from fabula.haccp_log l join fabula.haccp_control_points cp on cp.id = l.control_point_id
                  where cp.code = 'PRP-CLEAN' and (l.logged_at at time zone 'Europe/Rome')::date = p_date) then
    items := items || jsonb_build_object('code', 'clean', 'label_it', 'Sanificazione fine turno', 'scan', 'CLEAN:');
  end if;
  if exists (select 1 from fabula.production_batches where batch_date = p_date) or exists (select 1 from fabula.sales_orders where order_date = p_date) then
    if not exists (select 1 from fabula.meter_readings where meter = 'elec_main' and (read_at at time zone 'Europe/Rome')::date = p_date) then
      items := items || jsonb_build_object('code', 'kwh', 'label_it', 'Lettura contatore', 'scan', 'METER:elec_main'); end if;
  end if;
  if v_real_prod and not exists (select 1 from fabula.effluent_log where log_date = p_date) then
    items := items || jsonb_build_object('code', 'effluent', 'label_it', 'Reflui del giorno (scotta, acque di lavaggio)', 'scan', 'EFFL:');
  end if;
  -- food safety: CCP per real batch (filatura for mozzarella, affioramento for ricotta, pasteurisation when the milk is pasteurised)
  select items || coalesce(jsonb_agg(jsonb_build_object('code', 'ccp:' || cp.code || ':' || b.batch_lot,
                                                        'label_it', cp.ccp_no || ' ' || cp.name || ' · lotto ' || b.batch_lot,
                                                        'scan', 'CCP:' || cp.code || ':' || b.batch_lot) order by b.batch_lot, cp.sort), '[]') into items
  from fabula.production_batches b
  join fabula.haccp_control_points cp on cp.active and (
         cp.code = case when b.input_kind = 'whey' then 'CCP-RIC' else 'CCP-STRETCH' end
      or (cp.code = 'CCP-PAST' and b.input_kind <> 'whey' and fabula.setting_text('food.milk_process', 'crudo') = 'pastorizzato'))
  where b.batch_date = p_date and b.source <> 'simulation'
    and not exists (select 1 from fabula.haccp_log l where l.batch_id = b.id and l.control_point_id = cp.id);
  select count(*) into n_milk from fabula.milk_intake where intake_date = p_date and source <> 'simulation';
  select count(*) into n_abx from fabula.haccp_log l join fabula.haccp_control_points cp on cp.id = l.control_point_id
   where cp.code = 'CCP-MILK-ABX' and (l.logged_at at time zone 'Europe/Rome')::date = p_date;
  if n_milk > n_abx then
    items := items || jsonb_build_object('code', 'abx', 'label_it', format('CCP 1b test antibiotici: %s conferimenti di latte senza esito', n_milk - n_abx), 'scan', 'CCP:CCP-MILK-ABX');
  end if;
  -- v1.20 (MILK-1, house rule): every kg delivered goes into a vat on the day it arrives. From 15:00 Rome (any time, for an earlier
  -- day) a delivery of the day with more than 1 kg not yet in a vat is on the list; its label opens the milk (batch start).
  if p_date < (now() at time zone 'Europe/Rome')::date or (now() at time zone 'Europe/Rome')::time >= time '15:00' then
    select items || coalesce(jsonb_agg(jsonb_build_object('code', 'milkleft:' || x.milk_lot,
             'label_it', case when p_date < (now() at time zone 'Europe/Rome')::date
                              then format('Latte %s: %s kg non lavorati il giorno di arrivo (regola del caseificio): chiama il responsabile', x.milk_lot, fabula._it_num(x.left_kg))
                              else format('Latte %s: %s kg non ancora in caldaia: va lavorato oggi', x.milk_lot, fabula._it_num(x.left_kg)) end,
             'scan', 'LOT:' || x.milk_lot) order by x.milk_lot), '[]') into items
      from (select mi.milk_lot, mi.qty_kg - coalesce((select sum(bm.qty_kg) from fabula.batch_milk_inputs bm where bm.milk_intake_id = mi.id), 0) left_kg
              from fabula.milk_intake mi where mi.intake_date = p_date and mi.accepted and coalesce(mi.source, '') <> 'simulation') x
     where x.left_kg > 1;
  end if;
  if v_real_prod and not exists (select 1 from fabula.calibration_checks c join fabula.equipment e on e.id = c.equipment_id
                                 where e.code = 'PH-01' and (c.checked_at at time zone 'Europe/Rome')::date = p_date) then
    items := items || jsonb_build_object('code', 'ph', 'label_it', 'Calibrazione pH-metro (tamponi 4 e 7)', 'scan', 'CAL:PH-01');
  end if;
  select count(*) into n_ship from fabula.v_orders_to_ship where channel = 'shopify';
  if n_ship > 0 then
    items := items || jsonb_build_object('code', 'ship', 'label_it', n_ship || ' ordini online pagati da spedire', 'scan', 'SHIP:');
  end if;
  select items || coalesce(jsonb_agg(jsonb_build_object('code', 'batch:' || batch_lot, 'label_it', 'Lotto ' || batch_lot || ' non chiuso (kg prodotto)', 'scan', 'LOT:' || batch_lot)), '[]') into items
  from fabula.production_batches where batch_date = p_date and output_kg is null and source <> 'simulation';
  select items || coalesce(jsonb_agg(jsonb_build_object('code', 'shift:' || st.badge_code, 'label_it', st.full_name || ': badge di uscita non passato', 'scan', st.badge_code)), '[]') into items
  from fabula.shifts s join fabula.staff st on st.id = s.staff_id where s.clock_out is null and (s.clock_in at time zone 'Europe/Rome')::date = p_date;
  return items;
end $function$;

-- ============================================================================================================================
-- 6. Monthly Consorzio declaration: the house rule's two checks and the longest arrival-to-vat time
-- ============================================================================================================================
CREATE OR REPLACE FUNCTION fabula.consorzio_declaration(p_month date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'fabula', 'public', 'extensions'
AS $function$
declare m0 date; m1 date; j jsonb; v_appr uuid; v_kg numeric; v_issues jsonb; v_batches int; v_code text;
begin
  m0 := date_trunc('month', coalesce(p_month, (date_trunc('month', (now() at time zone 'Europe/Rome')::date) - interval '1 month')::date))::date;
  m1 := (m0 + interval '1 month')::date - 1;
  v_code := fabula.setting_text('dop.rina_code');
  select coalesce(sum(b.output_kg), 0), count(*) into v_kg, v_batches
    from fabula.production_batches b join fabula.products p on p.id = b.product_id
   where p.is_dop and b.batch_date between m0 and m1 and b.output_kg is not null;

  -- disciplinare checks (each item: what, how many, detail)
  select coalesce(jsonb_agg(i) filter (where (i->>'n')::int > 0), '[]') into v_issues from (
    select jsonb_build_object('check', 'codice_rina', 'it', 'Lotti DOP senza il codice RINA del caseificio: prima del codice non si possono vendere né dichiarare come DOP (Configurazione → Sicurezza alimentare e DOP)',
             'n', case when v_code is null then v_batches else 0 end, 'detail', '[]'::jsonb) i
    union all
    select jsonb_build_object('check', 'latte_60h', 'it', 'Latte lavorato oltre 60 h dall''arrivo (limite: 60 h dalla prima mungitura)',
             'n', count(*), 'detail', coalesce(jsonb_agg(jsonb_build_object('lot', x.batch_lot, 'milk_lot', x.milk_lot, 'hours', round(x.h, 1))), '[]'))
      from (select b.batch_lot, mi.milk_lot,
                   extract(epoch from (b.started_at - ((mi.intake_date + coalesce(mi.intake_time, '06:00')) at time zone 'Europe/Rome'))) / 3600 h
              from fabula.production_batches b join fabula.products p on p.id = b.product_id
              join fabula.batch_milk_inputs bmi on bmi.batch_id = b.id join fabula.milk_intake mi on mi.id = bmi.milk_intake_id
             where p.is_dop and b.batch_date between m0 and m1 and b.started_at is not null) x
     where x.h > 60
    union all
    select jsonb_build_object('check', 'grasso_proteine', 'it', 'Consegne sotto grasso 7,23 % o proteine 4,2 % (art. 3 disciplinare)',
             'n', count(*), 'detail', coalesce(jsonb_agg(jsonb_build_object('milk_lot', milk_lot, 'date', intake_date, 'fat_pct', fat_pct, 'protein_pct', protein_pct)), '[]'))
      from fabula.milk_intake where accepted and intake_date between m0 and m1 and (fat_pct < 7.23 or protein_pct < 4.2)
    union all
    select jsonb_build_object('check', 'fornitori_non_dop', 'it', 'Latte da fornitori non segnati come iscritti DOP (anagrafica)',
             'n', count(distinct mi.supplier_id), 'detail', coalesce(jsonb_agg(distinct p.legal_name), '[]'))
      from fabula.milk_intake mi join fabula.parties p on p.id = mi.supplier_id
     where mi.accepted and mi.intake_date between m0 and m1 and not p.is_dop_certified
    union all
    select jsonb_build_object('check', 'lotti_senza_latte', 'it', 'Lotti DOP senza latte collegato (tracciabilità)',
             'n', count(*), 'detail', coalesce(jsonb_agg(b.batch_lot), '[]'))
      from fabula.production_batches b join fabula.products p on p.id = b.product_id
     where p.is_dop and b.batch_date between m0 and m1 and b.output_kg is not null and coalesce(b.input_kind, 'milk') <> 'whey'
       and not exists (select 1 from fabula.batch_milk_inputs bmi where bmi.batch_id = b.id)
    -- v1.20 (MILK-1, house rule, every product made from milk): the milk goes into a vat on the day it arrives, all of it
    union all
    select jsonb_build_object('check', 'latte_altro_giorno', 'it', 'Lotti fatti con latte arrivato in un altro giorno (regola del caseificio: il latte va in caldaia il giorno in cui arriva)',
             'n', count(*), 'detail', coalesce(jsonb_agg(jsonb_build_object('lot', x.batch_lot, 'milk_lot', x.milk_lot, 'arrived', x.intake_date, 'vat_day', x.vat_day)), '[]'))
      from (select b.batch_lot, mi.milk_lot, mi.intake_date, coalesce((b.started_at at time zone 'Europe/Rome')::date, b.batch_date) vat_day
              from fabula.production_batches b join fabula.batch_milk_inputs bmi on bmi.batch_id = b.id join fabula.milk_intake mi on mi.id = bmi.milk_intake_id
             where b.batch_date between m0 and m1) x
     where x.intake_date <> x.vat_day
    union all
    select jsonb_build_object('check', 'latte_non_lavorato', 'it', 'Consegne di latte non lavorate per intero il giorno di arrivo (regola del caseificio)',
             'n', count(*), 'detail', coalesce(jsonb_agg(jsonb_build_object('milk_lot', x.milk_lot, 'date', x.intake_date, 'kg_left', x.left_kg)), '[]'))
      from (select mi.milk_lot, mi.intake_date,
                   round(mi.qty_kg - coalesce((select sum(bmi.qty_kg) from fabula.batch_milk_inputs bmi join fabula.production_batches b on b.id = bmi.batch_id
                                                where bmi.milk_intake_id = mi.id
                                                  and coalesce((b.started_at at time zone 'Europe/Rome')::date, b.batch_date) = mi.intake_date), 0), 1) left_kg
              from fabula.milk_intake mi where mi.accepted and mi.intake_date between m0 and m1) x
     where x.left_kg > 1
  ) s;

  select jsonb_build_object('month', to_char(m0, 'YYYY-MM'), 'from', m0, 'to', m1,
    'milk_in_kg', (select coalesce(sum(qty_kg), 0) from fabula.milk_intake where accepted and intake_date between m0 and m1),
    'milk_rejected_kg', (select coalesce(sum(qty_kg), 0) from fabula.milk_intake where accepted = false and intake_date between m0 and m1),
    'milk_suppliers', (select coalesce(jsonb_agg(jsonb_build_object('supplier', p.legal_name, 'kg', kg, 'dop_certified', p.is_dop_certified)), '[]')
                       from (select supplier_id, round(sum(qty_kg), 1) kg from fabula.milk_intake where accepted and intake_date between m0 and m1 group by supplier_id) x join fabula.parties p on p.id = x.supplier_id),
    'milk_processed_kg', (select coalesce(sum(b.milk_in_kg), 0) from fabula.production_batches b join fabula.products p on p.id = b.product_id where p.is_dop and b.batch_date between m0 and m1 and b.output_kg is not null),
    'mozzarella_dop_kg', v_kg,
    'by_product', (select coalesce(jsonb_agg(jsonb_build_object('product', name, 'kg', kg, 'batches', n)), '[]')
                     from (select p.name, sum(b.output_kg) kg, count(*) n from fabula.production_batches b join fabula.products p on p.id = b.product_id
                            where p.is_dop and b.batch_date between m0 and m1 and b.output_kg is not null group by p.name) y),
    'batches', v_batches,
    -- v1.20 (MILK-1): the longest time from the milk's arrival to the start of its vat this month (every product from milk)
    'arrival_to_vat_max_h', (select round(max(extract(epoch from (b.started_at - ((mi.intake_date + coalesce(mi.intake_time, '06:00')) at time zone 'Europe/Rome'))) / 3600)::numeric, 1)
                               from fabula.production_batches b join fabula.batch_milk_inputs bmi on bmi.batch_id = b.id join fabula.milk_intake mi on mi.id = bmi.milk_intake_id
                              where b.batch_date between m0 and m1 and b.started_at is not null),
    'labels_printed', (select coalesce(sum(qty_printed), 0) from fabula.labels l where l.kind in ('batch_lot','retail_pack','wholesale_case') and (l.printed_at at time zone 'Europe/Rome')::date between m0 and m1),
    'lots', (select coalesce(jsonb_agg(b.batch_lot order by b.batch_date, b.batch_lot), '[]') from fabula.production_batches b join fabula.products p on p.id = b.product_id where p.is_dop and b.batch_date between m0 and m1 and b.output_kg is not null),
    'sold_kg', (select coalesce(-sum(sm.qty), 0) from fabula.stock_moves sm join fabula.products p on p.id = sm.product_id where p.is_dop and sm.move_type = 'sale' and (sm.moved_at at time zone 'Europe/Rome')::date between m0 and m1),
    'fees_estimate_eur', jsonb_build_object(
        'consorzio', round(v_kg * fabula.setting_num('dop.consorzio_eur_kg', 0.044), 2),
        'rina_variable', round(v_kg * fabula.setting_num('dop.rina_eur_kg', 0.002), 2),
        'note', 'Contributo Consorzio stimato: confermare la tariffa €/kg con il Consorzio'),
    'issues', v_issues,
    'rina_code', v_code,
    'consorzio', jsonb_build_object('name', 'Consorzio per la Tutela del Formaggio Mozzarella di Bufala Campana', 'address', 'Via Gasparri 1, 81100 Caserta',
                                    'cf', '03497570634', 'piva', '02236840613', 'sdi', 'USAL8PV'),
    'company', fabula.company_name(),
    'note', 'Preparata in automatico dai dati di produzione. Invio al Consorzio a mano finché non c''è il modulo/portale ufficiale.') into j;

  -- R-01: not under DOP control yet and nothing DOP made this month → nothing to declare, nothing to decide
  if v_code is null and v_batches = 0 then
    return j || jsonb_build_object('approval_created', false, 'skipped', true,
      'skip_it', format('Nessuna dichiarazione per %s: il caseificio non ha ancora il codice RINA (dop.rina_code) e nel mese non ci sono lotti DOP', to_char(m0, 'MM/YYYY')));
  end if;

  if not exists (select 1 from fabula.approvals where kind = 'dop_declaration' and payload->>'month' = to_char(m0, 'YYYY-MM') and status in ('pending','approved')) then
    insert into fabula.approvals (kind, requested_by, summary, payload, related_table)
    values ('dop_declaration', 'agent:monthly_review',
            format('Dichiarazione Consorzio %s: latte %s kg → mozzarella DOP %s kg in %s lotti, %s etichette%s', to_char(m0, 'MM/YYYY'),
                   round((j->>'milk_processed_kg')::numeric), round(v_kg), j->>'batches', j->>'labels_printed',
                   case when jsonb_array_length(v_issues) > 0 then format(' · %s controlli da vedere', jsonb_array_length(v_issues)) else '' end),
            j, 'consorzio') returning id into v_appr;
    j := j || jsonb_build_object('approval_id', v_appr, 'approval_created', true);
  else
    j := j || jsonb_build_object('approval_created', false);
  end if;
  return j;
end $function$;

-- (end of v1.20a)
