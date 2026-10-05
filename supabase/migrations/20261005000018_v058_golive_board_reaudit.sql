-- v0.58 (05/10/2026): go-live board re-audit after v0.44–v0.57 and the 04/10 bug test
-- * dash_areas: evidence (why the score) + prev (scores before this audit) columns; scores re-estimated;
--   new area "B2B sales pipeline" (v0.44 module)
-- * dash_checks: 4 new checks (tablet redeployed, fix-first bugs closed, repo migrations match live,
--   Manuale di Autocontrollo signed off) and a new order
-- * ops_dashboard(): company name, manuale_signed auto check, previous headline scores,
--   bot health no longer counts a bot that has never run (Vendite showed a false miss on 02/10)

alter table fabula.dash_areas add column if not exists evidence text;
alter table fabula.dash_areas add column if not exists prev jsonb;

insert into fabula.dash_areas(area, sort, built, reliable, automated, next_step, evidence, updated_at) values
 ('Reports & briefs', 1, 92, 70, 90,
  'Fix monthly_review closing the running month (1 Oct it closed October, not September); read the first weekly brief Mon 5 Oct',
  'Daily, weekly and monthly briefs run on schedule. Monthly review closed the wrong month; the accountant pack always shows SIMULAZIONE; weekly benchmark still €2,990/wk.', now()),
 ('Sales & orders', 2, 82, 70, 80,
  'Shopify catalog decisions; RT printer once the P.IVA is final',
  'Shopify customers/orders sync daily without errors; held and expired lots no longer sold online (v055). Open: XSS via Shopify customer name on Da spedire.', now()),
 ('B2B sales pipeline', 3, 85, 55, 50,
  'Vendite bot first run Mon 5 Oct 08:04; set sales.plan_start; start working the 45 leads (all still nuovo)',
  'v0.44: 5-channel targets, Vendite page, 45 seeded prospects, Vendite bot scheduled Mon/Wed/Fri but never run. Bugs: new leads ignore stage, WhatsApp prefix, XSS in lead notes. Calls and tastings stay human.', now()),
 ('Inventory & lots', 4, 88, 72, 70,
  'Fix stock-count save (step 0.1 rejects 96.64), then post the opening count',
  'Printable lot labels, lot codes typed without LOT:, lot guard and hold filter live. The stock-count form refuses some quantities; lot dates use UTC between 00:00 and 02:00.', now()),
 ('Milk plan & intake', 5, 92, 70, 60,
  'First real intake from the station QR; fix the reused tank id (T1) intake error; confirm Masseria daily kg',
  'Station QR + DDT number (v0.53), rejected milk refused at scan and in the DB (v055), milk price now €1.60. Piano latte runs nightly. A reused milk lot id breaks intake and can double-save.', now()),
 ('Procurement', 6, 86, 58, 55,
  'Replace the 3 placeholder suppliers with real ones, prices and reorder points',
  'Arrival check on goods receipt (v0.57). Acquisti bot runs but proposes nothing: suppliers and prices are still placeholders; receive_purchase_order can run twice on a re-send.', now()),
 ('Compliance & HACCP', 7, 90, 62, 60,
  'Consultant signs the Manuale (rev 0 bozza); date 8 deadlines; calibrate pasteuriser, 2 scales, reference thermometer',
  'v0.57 Manuale di Autocontrollo: 23 MOD forms, printable registers, weekly verification, pasteuriser/innesto/brine checks; calibration and lab NC fixes (v055). Manual still a draft; pest-visit save fails for HACCP level 2.', now()),
 ('Marketing', 8, 72, 45, 55,
  'Opening date, Predis keys, BENVENUTO10; let the Marketing profile save mkt.* settings',
  'Module and bot built; nothing live yet. Marketing profile cannot save its own settings; an edited post stays approved; any staff can spend Predis credits.', now()),
 ('Fulfilment & shipping', 9, 86, 60, 45,
  'Pack one order end to end on the tablet and print the DDT (4 wholesale orders from placeholder customers are queued)',
  'Pack, scale, DDT and Shopify fulfilment built; no shipment yet. Multi-step saves are not atomic; a weight override stays on for later saves.', now()),
 ('Staff & rota', 10, 88, 55, 45,
  'Invite the Celsos and floor staff (1 of 3 can log in); fix In turno for floor profiles',
  'Badge printing (v0.53), rota, hours, certificates. Floor profiles see an empty In turno list, so a second badge scan clocks them out; the only titolare can demote himself.', now()),
 ('Finance & e-invoicing', 11, 40, 40, 35,
  'Commercialista answers the IVA and numbering questions, then build the Fatture in Cloud bot; bank feed',
  'Spec written, nothing built: 0 invoices, no SDI link, no payout reconciliation. Depends on the entity decision.', now()),
 ('Production floor', 12, 88, 52, 25,
  'Casaro confirms the 6 placeholder doses and presets; fix offline start and Enter-reload before the first batch',
  'Plain-language tablet messages, ricotta tino label, rejected-milk stop, resume keeps its preset. Bug test: offline start locks the user out, Enter reloads single-field forms, last dosing step can freeze. 0 real batches.', now()),
 ('Infra & security', 13, 90, 68, 88,
  'Fix the 3 XSS spots; repair migration history (v044/v044b, v044c/d) and add the live-only objects; redeploy fabula-tablet',
  'Backups locked to the backup job (v054), leaked-password protection on, nightly + 2-hourly backups clean. Repo cannot rebuild the DB, 3 stored-XSS spots, 5 functions with mutable search_path, restore never tested.', now())
on conflict (area) do update
   set prev = jsonb_build_object('built', fabula.dash_areas.built, 'reliable', fabula.dash_areas.reliable,
                                 'automated', fabula.dash_areas.automated, 'at', fabula.dash_areas.updated_at),
       sort = excluded.sort, built = excluded.built, reliable = excluded.reliable, automated = excluded.automated,
       next_step = excluded.next_step, evidence = excluded.evidence, updated_at = excluded.updated_at;

-- go-live checklist: 4 new checks, new order, refreshed code_pushed note (upsert only; done flags untouched)
insert into fabula.dash_checks(key, sort, label, kind, done, note) values
 ('sim_purged',       1, 'Simulated data purged',                     'auto',   false, null),
 ('code_pushed',      2, 'Latest code pushed to GitHub',              'manual', false, 'v0.57 (51259e6) on GitHub, 04/10; v0.58 board re-audit saved locally'),
 ('app_deployed',     3, 'Tablet app redeployed (sw perla-v32)',      'manual', false, 'Netlify: redeploy fabula-tablet so the v0.55–v0.57 fixes and HACCP forms reach the tablet'),
 ('leaked_pw',        4, 'Leaked-password protection on',             'manual', false, null),
 ('fix_first',        5, 'Fix-first bugs closed',                     'manual', false, 'Open: stored XSS (3 places), offline start lockout, form step / Enter reload, accountant pack badge'),
 ('repo_sync',        6, 'Repo migrations match the live database',   'manual', false, 'v044/v044b not in live history; v044c/d versions differ; bot_messages, demand_7d, documents bucket and pg_cron jobs have no migration'),
 ('pitr',             7, 'Off-database backup in the last 26 h',      'auto',   false, null),
 ('second_login',     8, 'A second person can log in',                'auto',   false, null),
 ('stock_count',      9, 'Opening stock count posted',                'auto',   false, null),
 ('placeholders',    10, 'Real supplier and customer names',          'auto',   false, null),
 ('recipes',         11, 'Recipe doses confirmed by the casaro',      'auto',   false, null),
 ('compliance_dates',12, 'Every compliance deadline has a date',      'auto',   false, null),
 ('equipment_dates', 13, 'Calibration date set on every machine',     'auto',   false, null),
 ('manuale_signed',  14, 'Manuale di Autocontrollo signed off',       'auto',   false, null),
 ('shopify_catalog', 15, 'Shopify catalog decisions made',            'manual', false, null),
 ('rt_printer',      16, 'RT fiscal printer installed',               'manual', false, null),
 ('first_batch',     17, 'First real batch recorded',                 'auto',   false, null),
 ('bots_clean',      18, 'No bot errors in the last 24 h',            'auto',   false, null)
on conflict (key) do update
   set sort = excluded.sort,
       note = coalesce(excluded.note, fabula.dash_checks.note),
       updated_at = case when excluded.key = 'code_pushed' then now() else fabula.dash_checks.updated_at end;

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
        from fabula.agent_runs where status = 'error' and started_at > now() - interval '24 hours')
  );

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
