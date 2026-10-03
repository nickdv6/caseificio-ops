-- v0.42 (03/10/2026): go-live dashboard backbone
-- dash_areas  = per-area estimates (built / reliable / automated), maintained by Claude/Nick
-- dash_checks = go-live checklist; 'auto' rows are computed live by ops_dashboard(),
--               'manual' rows are ticked by Nick (dashboard or SQL: select fabula.dash_set_check(key, true))
-- ops_dashboard() = one read-only JSON for the live dashboard artifact (and any bot)

create table if not exists fabula.dash_areas (
  area text primary key,
  sort int not null default 0,
  built int not null check (built between 0 and 100),
  reliable int not null check (reliable between 0 and 100),
  automated int not null check (automated between 0 and 100),
  next_step text,
  updated_at timestamptz not null default now()
);

create table if not exists fabula.dash_checks (
  key text primary key,
  sort int not null default 0,
  label text not null,
  kind text not null check (kind in ('auto','manual')),
  done boolean not null default false,
  note text,
  updated_at timestamptz not null default now()
);

alter table fabula.dash_areas enable row level security;
alter table fabula.dash_checks enable row level security;

insert into fabula.table_areas(table_name, area, write_level, read_open)
values ('dash_areas','sistema',3,true), ('dash_checks','sistema',3,true)
on conflict (table_name) do nothing;

do $$
declare t text;
begin
  foreach t in array array['dash_areas','dash_checks'] loop
    if not exists (select 1 from pg_policies where schemaname='fabula' and tablename=t and policyname=t||'_read') then
      execute format('create policy %I on fabula.%I for select to authenticated using (true)', t||'_read', t);
      -- no remove policy on purpose: dashboard rows are only inserted and updated
      execute format('create policy %I on fabula.%I for insert to authenticated with check (true)', t||'_insert', t);
      execute format('create policy %I on fabula.%I for update to authenticated using (true)', t||'_update', t);
      execute format('create policy %I on fabula.%I as restrictive for select to authenticated using ((select fabula.can_table(%L, false)))', t||'_role_select', t, t);
      execute format('create policy %I on fabula.%I as restrictive for insert to authenticated with check ((select fabula.can_table(%L, true)))', t||'_role_insert', t, t);
      execute format('create policy %I on fabula.%I as restrictive for update to authenticated using ((select fabula.can_table(%L, true)))', t||'_role_update', t, t);
    end if;
  end loop;
end $$;

insert into fabula.dash_areas(area, sort, built, reliable, automated, next_step) values
 ('Reports & briefs',       1, 90, 75, 90, 'Read the first real weekly brief (Mon) and tune tone/content'),
 ('Sales & orders',         2, 80, 70, 80, 'Shopify catalog decisions; RT printer once the P.IVA is final'),
 ('Inventory & lots',       3, 85, 78, 70, 'Opening stock count on the tablet'),
 ('Milk plan & intake',     4, 90, 68, 60, 'First real milk intakes; confirm Masseria daily kg'),
 ('Procurement',            5, 85, 60, 55, 'Real suppliers, prices and reorder points'),
 ('Compliance & HACCP',     6, 75, 50, 55, 'Date the 14 compliance deadlines and machine calibrations'),
 ('Marketing',              7, 70, 45, 55, 'Opening date, Predis keys, BENVENUTO10 code'),
 ('Fulfilment & shipping',  8, 85, 65, 45, 'Test a packed order end to end on the tablet'),
 ('Staff & rota',           9, 85, 60, 45, 'Invite staff and partners; set contract hours'),
 ('Finance & e-invoicing', 10, 40, 40, 35, 'Build the Fatture in Cloud bot; bank feed'),
 ('Production floor',      11, 85, 55, 25, 'Casaro confirms doses and machine presets'),
 ('Infra & security',      12, 88, 75, 85, 'Leaked-password toggle; PITR decision; second titolare')
on conflict (area) do nothing;

insert into fabula.dash_checks(key, sort, label, kind, done, note) values
 ('sim_purged',        1, 'Simulated data purged',                  'auto',   false, null),
 ('code_pushed',       2, 'Latest code pushed to GitHub',           'manual', false, 'v0.41 commit 29864f2 is local'),
 ('leaked_pw',         3, 'Leaked-password protection on',          'manual', false, 'Supabase → Authentication → Attack Protection'),
 ('second_login',      4, 'A second person can log in',             'auto',   false, null),
 ('pitr',              5, 'Point-in-time recovery decided',         'manual', false, 'PITR add-on or nightly export'),
 ('stock_count',       6, 'Opening stock count posted',             'auto',   false, null),
 ('placeholders',      7, 'Real supplier and customer names',       'auto',   false, null),
 ('recipes',           8, 'Recipe doses confirmed by the casaro',   'auto',   false, null),
 ('compliance_dates',  9, 'Every compliance deadline has a date',   'auto',   false, null),
 ('equipment_dates',  10, 'Calibration date set on every machine',  'auto',   false, null),
 ('shopify_catalog',  11, 'Shopify catalog decisions made',         'manual', false, 'Classica variants, Ricotta price, bundle copy'),
 ('rt_printer',       12, 'RT fiscal printer installed',            'manual', false, 'Epson FP-81 II RT, after the P.IVA is final'),
 ('first_batch',      13, 'First real batch recorded',              'auto',   false, null),
 ('bots_clean',       14, 'No bot errors in the last 24 h',         'auto',   false, null)
on conflict (key) do nothing;

create or replace function fabula.dash_set_check(p_key text, p_done boolean, p_note text default null)
 returns jsonb
 language plpgsql
 set search_path = fabula, public, extensions
as $$
declare r fabula.dash_checks;
begin
  update fabula.dash_checks
     set done = p_done, note = coalesce(p_note, note), updated_at = now()
   where key = p_key and kind = 'manual'
  returning * into r;
  if r.key is null then
    raise exception 'dash_set_check: % is not a manual check', p_key;
  end if;
  return to_jsonb(r);
end $$;

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
    'first_batch', (select jsonb_build_object('done', count(*) > 0,
        'detail', case when count(*) = 0 then 'Waiting for the first batch' else count(*) || ' real batches' end)
        from fabula.production_batches where coalesce(source, '') <> 'simulation'),
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
           'agent', s.agent, 'name', s.name_it, 'active', s.active,
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

  -- bot health: expected runs vs successful runs on completed days since the bots started
  v_first := greatest(v_today - 7, (select min((started_at at time zone 'Europe/Rome')::date) from fabula.agent_runs));
  select jsonb_build_object(
           'expected', count(*),
           'ok', count(*) filter (where ok),
           'missed', coalesce(jsonb_agg(jsonb_build_object('day', d, 'agent', agent)) filter (where not ok), '[]'::jsonb),
           'from', v_first, 'to', v_today - 1)
    into v_health
    from (
      select d::date as d, e.agent,
             exists (select 1 from fabula.agent_runs a
                      where a.agent = e.agent and a.status = 'ok'
                        and (a.started_at at time zone 'Europe/Rome')::date = d::date) as ok
        from generate_series(v_first, v_today - 1, interval '1 day') d
        cross join lateral fabula.expected_bots(d::date) e
       where e.agent in (select agent from fabula.bot_schedule where active)
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
    'scores', (select jsonb_build_object(
                 'built', round(avg(built)), 'reliable', round(avg(reliable)), 'automated', round(avg(automated)),
                 'areas_updated_at', max(updated_at)) from fabula.dash_areas),
    'areas', v_areas,
    'checks', v_checks,
    'bots', v_bots,
    'bot_health', v_health,
    'ops', v_ops
  );
end $$;

revoke execute on function fabula.ops_dashboard() from public, anon;
revoke execute on function fabula.dash_set_check(text, boolean, text) from public, anon;
grant execute on function fabula.ops_dashboard() to authenticated, service_role;
grant execute on function fabula.dash_set_check(text, boolean, text) to authenticated, service_role;
