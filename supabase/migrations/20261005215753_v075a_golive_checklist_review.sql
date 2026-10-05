-- v0.75a (05/10/2026) · Go-live checklist review. The checklist covered the software and the data but skipped the
-- gates that decide whether the dairy can legally open and sell DOP, and the dry run. Added (auto = computed live):
--   gates      deal_signed, lease_signed (manual) · ce_approval (auto: food.ce_approval_no) · dop_control (manual) ·
--              haccp_training (auto: no required course missing or expired in v_training_matrix) · einvoicing (manual)
--   setup      opening_date (auto: mkt.store_opening_date) · vat_capacity, labels (manual)
--   dry run    tablet_checkin (auto: a device on the live app in the last 2 days) · first_milk, moisture_test (MOZ-DOP
--              sample conforme), first_shipment (auto) · paper_fallback (manual)
-- Reordered: open gates first, then setup, dry run, and the system checks (all green) last. Area next steps refreshed.
create or replace function fabula.ops_dashboard()
 returns jsonb
 language plpgsql
 stable
 set search_path = fabula, public, extensions
as $$
declare
  v_today date := (now() at time zone 'Europe/Rome')::date;
  v_moz uuid := (select id from fabula.products where sku = 'MOZ-DOP-KG');
  v_auto jsonb;
  v_checks jsonb;
  v_bots jsonb;
  v_health jsonb;
  v_ops jsonb;
  v_areas jsonb;
  v_first date;
  v_manuale text := coalesce((select value from fabula.settings where key = 'food.manuale_stato'), 'bozza');
begin
  -- live go-live checks
  v_auto := jsonb_build_object(
    'sim_purged', jsonb_build_object(
        'done', not exists (select 1 from fabula.stock_moves where source = 'simulation')
            and not exists (select 1 from fabula.production_batches where source = 'simulation')
            and not exists (select 1 from fabula.milk_intake where source = 'simulation')
            and not exists (select 1 from fabula.simulation_runs),
        'detail', null),
    'second_login', (select jsonb_build_object('done', count(*) >= 2,
        'detail', count(*) || ' of ' || (select count(*) from fabula.staff where active) || ' staff can log in')
        from fabula.staff where active and auth_user_id is not null),
    'stock_count', (select jsonb_build_object('done', count(*) > 0,
        'detail', case when count(*) = 0 then 'No count posted yet' else 'Last count ' || to_char(max(counted_at) at time zone 'Europe/Rome', 'DD/MM HH24:MI') end)
        from fabula.stock_counts where status = 'posted'),
    'placeholders', (select jsonb_build_object('done', count(*) = 0,
        'detail', case when count(*) = 0 then null else count(*) || ' placeholder names left' end)
        from fabula.parties where active and (notes = 'placeholder' or source = 'placeholder')),
    'recipes', (select jsonb_build_object('done', count(*) = 0,
        'detail', case when count(*) = 0 then null else count(*) || ' placeholder doses' end)
        from fabula.recipes where source = 'placeholder' and (valid_to is null or valid_to >= v_today)),
    'compliance_dates', (select jsonb_build_object('done', count(*) = 0,
        'detail', case when count(*) = 0 then null else count(*) || ' deadlines without a date' end)
        from fabula.compliance_deadlines where due_on is null and done_on is null),
    'equipment_dates', (select jsonb_build_object('done', count(*) = 0,
        'detail', case when count(*) = 0 then null else count(*) || ' machines without a calibration date' end)
        from fabula.equipment where active and calibration_interval_days is not null and last_calibrated_on is null),
    'manuale_signed', jsonb_build_object('done', lower(v_manuale) not in ('bozza', 'draft', ''),
        'detail', 'Rev ' || coalesce((select value from fabula.settings where key = 'food.manuale_rev'), '?')
               || ' · ' || v_manuale || case when lower(v_manuale) in ('bozza', 'draft', '') then ' · needs the HACCP consultant''s signature' else '' end),
    'first_batch', (select jsonb_build_object('done', count(*) > 0,
        'detail', case when count(*) = 0 then 'Waiting for the first batch' else count(*) || ' real batches' end)
        from fabula.production_batches where coalesce(source, '') <> 'simulation'),
    'pitr', (select jsonb_build_object('done', count(*) > 0,
        'detail', case when count(*) = 0 then 'No successful backup in the last 26 h'
                       else 'Last backup ' || to_char(max(finished_at) at time zone 'Europe/Rome', 'DD/MM HH24:MI') || ' Agropoli · documents/backups' end)
        from fabula.agent_runs where agent = 'backup_export' and status = 'ok' and started_at > now() - interval '26 hours'),
    'bots_clean', (select jsonb_build_object('done', count(*) = 0,
        'detail', case when count(*) = 0 then null else count(*) || ' failed runs: ' || string_agg(distinct agent, ', ') end)
        from fabula.agent_runs where status = 'error' and started_at > now() - interval '24 hours'),
    -- v0.75: gates to open, dry run
    'ce_approval', jsonb_build_object('done', coalesce((select value from fabula.settings where key = 'food.ce_approval_no'), '') <> '',
        'detail', coalesce('CE n. ' || nullif((select value from fabula.settings where key = 'food.ce_approval_no'), ''),
                  'No CE approval number in Masseria''s name yet: subingresso or new approval (Reg. 853/2004), SCIA and the Agropoli local unit, then enter it in Configurazione → Parametri (food.ce_approval_no)')),
    'haccp_training', (select jsonb_build_object('done', count(*) > 0 and count(*) filter (where m.status in ('mancante', 'scaduto')) = 0,
        'detail', case when count(*) = 0 then 'No staff in the training matrix'
                       when count(*) filter (where m.status in ('mancante', 'scaduto')) = 0 then 'All ' || count(*) || ' required courses valid'
                       else count(*) filter (where m.status in ('mancante', 'scaduto')) || ' of ' || count(*) || ' required courses missing or expired ('
                            || string_agg(distinct m.full_name, ', ') filter (where m.status in ('mancante', 'scaduto')) || ') · Manuale → Formazione (MOD-10)' end)
        from fabula.v_training_matrix m join fabula.staff s on s.id = m.staff_id and s.active),
    'opening_date', jsonb_build_object('done', coalesce((select value from fabula.settings where key = 'mkt.store_opening_date'), '') <> '',
        'detail', coalesce('Opening ' || nullif((select value from fabula.settings where key = 'mkt.store_opening_date'), ''),
                  'Not set: Configurazione → Parametri · mkt.store_opening_date (marketing countdown, plus sales.plan_start and food.sampling_start)')),
    'tablet_checkin', (select jsonb_build_object('done', count(*) filter (where app_version = fabula.live_app_version() and last_seen_at > now() - interval '2 days') > 0,
        'detail', case when count(*) = 0 then 'No tablet has checked in yet: open the app once on each tablet with Wi-Fi'
                       else count(*) || ' device(s) · ' || count(*) filter (where app_version = fabula.live_app_version()) || ' on the latest app · last seen '
                            || to_char(max(last_seen_at) at time zone 'Europe/Rome', 'DD/MM HH24:MI') end)
        from fabula.devices),
    'first_milk', (select jsonb_build_object('done', count(*) > 0,
        'detail', case when count(*) = 0 then 'Waiting for the first load from the farm (shipment QR)' else count(*) || ' real deliveries · ' || trim_scale(sum(qty_kg)) || ' kg' end)
        from fabula.milk_intake where accepted and coalesce(source, '') <> 'simulation'),
    'moisture_test', (select jsonb_build_object('done', coalesce(bool_or(s.outcome = 'conforme'), false),
        'detail', case when count(*) = 0 then 'No MOZ-DOP sample yet (moisture ≤ 65 %, fat on dry matter ≥ 52 %); the trial cheese was at the limit'
                       else count(*) || ' sample(s) · latest: ' || (array_agg(s.outcome order by s.taken_on desc nulls last, s.created_at desc))[1] end)
        from fabula.lab_samples s join fabula.lab_tests t on t.id = s.test_id and t.code = 'MOZ-DOP' where s.outcome <> 'annullato'),
    'first_shipment', (select jsonb_build_object('done', count(*) > 0,
        'detail', case when count(*) = 0 then 'Pack one real order from Da spedire and print its DDT' else count(*) || ' packed · last DDT ' || coalesce(max(ddt_number), '?') end)
        from fabula.shipments where packed_at is not null)
  );

  v_auto := v_auto || fabula.infra_checks();   -- v0.68: code_pushed, repo_sync, app_deployed, restore_tested, advisors_clean, uptime

  select jsonb_agg(jsonb_build_object(
           'key', c.key, 'label', c.label, 'kind', c.kind,
           'done', case when c.kind = 'auto' then coalesce((v_auto -> c.key ->> 'done')::boolean, false) else c.done end,
           'detail', case when c.kind = 'auto' then v_auto -> c.key ->> 'detail' else c.note end,
           'updated_at', case when c.kind = 'manual' then c.updated_at end)
         order by c.sort)
    into v_checks
    from fabula.dash_checks c;

  -- bots: last run per scheduled bot
  select jsonb_agg(jsonb_build_object(
           'agent', s.agent, 'name', fabula.bot_display_name(s.agent), 'active', s.active,
           'due_times', s.due_times, 'weekdays', s.weekdays, 'month_day', s.month_day,
           'last_at', r.started_at, 'last_status', r.status,
           'last_summary', left(coalesce(r.error, r.summary), 160),
           'runs_7d', coalesce(w.runs, 0), 'errors_7d', coalesce(w.errs, 0))
         order by s.due_times[1])
    into v_bots
    from fabula.bot_schedule s
    left join lateral (select started_at, status, summary, error from fabula.agent_runs a
                        where a.agent = s.agent order by started_at desc limit 1) r on true
    left join lateral (select count(*) runs, count(*) filter (where status = 'error') errs from fabula.agent_runs a
                        where a.agent = s.agent and a.started_at > now() - interval '7 days') w on true;

  -- bot health: expected runs vs successful runs on completed days, each bot from the day it first ran.
  -- A bot that has never run is left out here (the board shows it as "Not run yet" / "Missed today").
  v_first := greatest(v_today - 7, (select min((started_at at time zone 'Europe/Rome')::date) from fabula.agent_runs));
  select jsonb_build_object(
           'expected', count(*),
           'ok', count(*) filter (where ok),
           'missed', coalesce(jsonb_agg(jsonb_build_object('day', d, 'agent', agent)) filter (where not ok), '[]'::jsonb),
           'from', v_first, 'to', v_today - 1,
           'not_started', (select coalesce(jsonb_agg(s.agent), '[]'::jsonb) from fabula.bot_schedule s
                            where s.active and not exists (select 1 from fabula.agent_runs a where a.agent = s.agent)))
    into v_health
    from (
      select d::date as d, e.agent,
             exists (select 1 from fabula.agent_runs a
                      where a.agent = e.agent and a.status = 'ok'
                        and (a.started_at at time zone 'Europe/Rome')::date = d::date) as ok
        from generate_series(v_first, v_today - 1, interval '1 day') d
        cross join lateral fabula.expected_bots(d::date) e
        join lateral (select min((a.started_at at time zone 'Europe/Rome')::date) as first_run
                        from fabula.agent_runs a where a.agent = e.agent) fr on true
       where e.agent in (select agent from fabula.bot_schedule where active)
         and fr.first_run is not null
         and d::date >= fr.first_run
    ) x;

  -- today on the floor
  v_ops := jsonb_build_object(
    'milk_kg_today', (select coalesce(sum(qty_kg), 0) from fabula.milk_intake where intake_date = v_today and accepted),
    'batches_today', (select count(*) from fabula.production_batches where batch_date = v_today),
    'output_kg_today', (select coalesce(sum(output_kg), 0) from fabula.production_batches where batch_date = v_today),
    'moz_on_hand_kg', (select coalesce(sum(qty), 0) from fabula.stock_moves where product_id = v_moz and (expiry_date is null or expiry_date >= v_today)),
    'orders_to_ship', (select count(*) from fabula.v_orders_to_ship),
    'approvals_pending', (select count(*) from fabula.approvals where status = 'pending'),
    'haccp_checks_today', (select count(*) from fabula.haccp_log where (logged_at at time zone 'Europe/Rome')::date = v_today),
    'notices_open', (select count(*) from fabula.notices where resolved_at is null and (expires_at is null or expires_at > now())),
    'alerts', (select coalesce(jsonb_agg(jsonb_build_object('severity', severity, 'title', title_it) order by created_at desc), '[]'::jsonb)
                 from fabula.notices where resolved_at is null and (expires_at is null or expires_at > now())),
    'bot_messages_unread', (select count(*) from fabula.bot_messages where read_at is null)
  );

  select jsonb_agg(to_jsonb(a) - 'sort' order by a.sort) into v_areas from fabula.dash_areas a;

  return jsonb_build_object(
    'generated_at', now(),
    'today', v_today,
    'company', fabula.company_name(),
    'scores', (select jsonb_build_object(
                 'built', round(avg(built)), 'reliable', round(avg(reliable)), 'automated', round(avg(automated)),
                 'areas', count(*),
                 'areas_updated_at', max(updated_at),
                 'prev', case when count(prev) > 0 then jsonb_build_object(
                           'built', round(avg((prev->>'built')::numeric)),
                           'reliable', round(avg((prev->>'reliable')::numeric)),
                           'automated', round(avg((prev->>'automated')::numeric)),
                           'areas', count(prev),
                           'at', max((prev->>'at')::timestamptz)) end)
               from fabula.dash_areas),
    'areas', v_areas,
    'checks', v_checks,
    'bots', v_bots,
    'bot_health', v_health,
    'ops', v_ops
  );
end $$;
revoke execute on function fabula.ops_dashboard() from public, anon, authenticated;
grant execute on function fabula.ops_dashboard() to service_role;

insert into fabula.dash_checks (key, sort, label, kind, done, note, updated_at) values
 -- 1. gates to open
 ('deal_signed', 1, 'Purchase deed signed after due diligence', 'manual', false, 'Handshake €55,000 (03/10), nothing in writing. Open: equipment inspection, DURC/lien/subsidy clearance, 2 years of sales and tax records; going concern or asset sale (commercialista); preliminare and deed in Masseria''s name.', now()),
 ('lease_signed', 2, 'Lease signed and registered in Masseria''s name', 'manual', false, '€1,050/month in 2027, €1,100 from 2028, from 1/1/2027 (agreed 05/10, not in writing). Step-up and ISTAT in the contract; access terms for work before January; permitted use covers production and retail.', now()),
 ('ce_approval', 3, 'Food business registered in Masseria''s name (CE approval, SCIA)', 'auto', false, null, now()),
 ('dop_control', 4, 'DOP: in the RINA control system, Consorzio marks ordered', 'manual', false, 'RINA adhesion as caseificio (€490) and the farm as allevatore (€80); Consorzio contrassegni for every pack; buffalo traceability platform; read the statute non-compete first. The Manuale §2 still names DQA: RINA replaced it (D.M. 30/12/2025).', now()),
 ('haccp_training', 5, 'HACCP training valid for everyone on the floor', 'auto', false, null, now()),
 ('manuale_signed', 6, 'Manuale di Autocontrollo signed off', 'auto', false, null, now()),
 ('einvoicing', 7, 'E-invoicing ready (Fatture in Cloud, PEC, SDI code)', 'manual', false, 'Commercialista answers on IVA regime and invoice numbering; Fatture in Cloud account in Masseria''s name; PEC and SDI code still empty in Configurazione → Azienda. Required for every B2B sale.', now()),
 ('rt_printer', 8, 'RT fiscal printer installed', 'manual', false, null, now()),
 -- 2. set up with real data
 ('opening_date', 10, 'Opening date set', 'auto', false, null, now()),
 ('stock_count', 11, 'Opening stock count posted', 'auto', false, null, now()),
 ('placeholders', 12, 'Real supplier and customer names', 'auto', false, null, now()),
 ('recipes', 13, 'Recipe doses confirmed by the casaro', 'auto', false, null, now()),
 ('vat_capacity', 14, 'Fortino vat capacity confirmed (prod.vat_kg)', 'manual', false, '800 kg is provisional: read the TINO plate or ask Fortino. The production plan splits each day''s milk by this number.', now()),
 ('compliance_dates', 15, 'Every compliance deadline has a date', 'auto', false, null, now()),
 ('equipment_dates', 16, 'Calibration date set on every machine', 'auto', false, null, now()),
 ('shopify_catalog', 17, 'Shopify catalog decisions made', 'manual', false, null, now()),
 ('labels', 18, 'Sales labels approved (final brand, DOP mark, shelf-life)', 'manual', false, '"La Bianca" is a placeholder: trademark check, no geographic qualifier next to DOP; producer name, allergens and nutrition (Reg. 1169/2011); shelf-life from the MOZ-SHELF study; activate MOD-23. Print nothing before the brand is final.', now()),
 -- 3. dry run
 ('tablet_checkin', 20, 'Floor tablet checked in on the latest app', 'auto', false, null, now()),
 ('first_milk', 21, 'First real milk delivery received', 'auto', false, null, now()),
 ('first_batch', 22, 'First real batch recorded', 'auto', false, null, now()),
 ('moisture_test', 23, 'DOP lab test passed (moisture ≤ 65 %)', 'auto', false, null, now()),
 ('first_shipment', 24, 'First real order packed with its DDT', 'auto', false, null, now()),
 ('paper_fallback', 25, 'Paper sheets ready for tablet or Wi-Fi outages', 'manual', false, 'Print the blank MOD sheets (Manuale → Registri → Modulo vuoto: 01, 02, 03, 05, 06) and keep them by the line; type them in afterwards.', now()),
 -- 4. system (green)
 ('sim_purged', 30, 'Simulated data purged', 'auto', false, null, now()),
 ('code_pushed', 31, 'Latest code pushed to GitHub', 'auto', false, null, now()),
 ('app_deployed', 32, 'Tablet app live = latest on GitHub', 'auto', false, null, now()),
 ('repo_sync', 33, 'Repo migrations match the live database', 'auto', false, null, now()),
 ('leaked_pw', 34, 'Leaked-password protection on', 'manual', false, null, now()),
 ('fix_first', 35, 'Fix-first bugs closed', 'manual', false, null, now()),
 ('second_login', 36, 'A second person can log in', 'auto', false, null, now()),
 ('pitr', 37, 'Off-database backup in the last 26 h', 'auto', false, null, now()),
 ('restore_tested', 38, 'Backup restore tested (last 100 days)', 'auto', false, null, now()),
 ('bots_clean', 39, 'No bot errors in the last 24 h', 'auto', false, null, now()),
 ('advisors_clean', 40, 'No new database security warnings', 'auto', false, null, now()),
 ('uptime', 41, 'Tablet site and server functions up', 'auto', false, null, now())
on conflict (key) do update set sort = excluded.sort;

-- area next steps (same-day: scores and `prev` untouched)
insert into fabula.dash_areas (area, sort, built, reliable, automated, next_step, evidence, updated_at) values
 ('Compliance & HACCP', 7, 0, 0, 0, 'CE approval and SCIA moved to Masseria (record food.ce_approval_no); RINA adhesion (caseificio + farm) and Consorzio marks; HACCP training for everyone (Manuale → Formazione); consultant signs the Manuale (and fixes DQA → RINA); calibrate the pasteuriser, 2 scales and reference thermometer; MOZ-DOP moisture test; confirm the provisional deadline dates', '', now()),
 ('Finance & e-invoicing', 11, 0, 0, 0, 'Commercialista answers the IVA regime and numbering questions; PEC and SDI code; Fatture in Cloud in Masseria''s name, then build the invoicing bot; bank feed', '', now()),
 ('Staff & rota', 10, 0, 0, 0, 'Emilio Celso logs in (2 of 3 can); HACCP training records for all three (Manuale → Formazione); contracts and CCNL/INPS for the 2 shop staff', '', now()),
 ('Sales & orders', 2, 0, 0, 0, 'Post the opening stock count (stock sync then starts by itself); Shopify catalog decisions; order the Epson RT printer in Masseria''s name (P.IVA final)', '', now()),
 ('Reports & briefs', 1, 0, 0, 0, 'First weekly brief ran 05/10 on empty data; it becomes meaningful after the first real week (benchmark ≈ €2,869/week)', '', now()),
 ('B2B sales pipeline', 3, 0, 0, 0, 'Vendite bot ran 05/10; set sales.plan_start with the opening date; start working the 45 leads (all still nuovo)', '', now()),
 ('Production floor', 12, 0, 0, 0, 'Fortino capacity → prod.vat_kg (800 is a placeholder); casaro confirms the 6 doses and presets; open the app on the floor tablet once; first real batch from the Home card', '', now())
on conflict (area) do update set next_step = excluded.next_step, updated_at = excluded.updated_at;
