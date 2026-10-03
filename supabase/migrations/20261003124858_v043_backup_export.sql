-- v0.43 (03/10/2026): free off-database backup instead of PITR
-- edge function backup-export (supabase/functions/backup-export) writes a gzipped JSON of every fabula table to
-- the private documents bucket: backups/latest.json.gz every 2 h on working days, backups/daily/YYYY-MM-DD.json.gz nightly (90 days).
-- pg_cron -> fabula.backup_export_call(mode) -> pg_net POST with the token from the Vault secret 'backup_export_token'
-- (secret added by Nick in the Supabase dashboard; until it exists the function answers 403 and the board shows the check open).
-- Runs logged as agent 'backup_export'.

create extension if not exists pg_net with schema extensions;

create or replace function fabula.backup_check_token(p_token text)
 returns boolean
 language sql
 stable
 security definer
 set search_path = fabula, public, extensions
as $$
  select coalesce(p_token <> '' and p_token = (select decrypted_secret from vault.decrypted_secrets where name = 'backup_export_token'), false)
$$;

create or replace function fabula.backup_table_list()
 returns text[]
 language sql
 stable
 set search_path = fabula, public, extensions
as $$
  select array_agg(table_name::text order by table_name)
    from information_schema.tables
   where table_schema = 'fabula' and table_type = 'BASE TABLE'
$$;

create or replace function fabula.backup_export_call(p_mode text default 'latest')
 returns bigint
 language plpgsql
 security definer
 set search_path = fabula, public, extensions
as $$
declare v_id bigint; v_token text;
begin
  select decrypted_secret into v_token from vault.decrypted_secrets where name = 'backup_export_token';
  if v_token is null then
    insert into fabula.agent_runs(agent, status, finished_at, summary, error)
    values ('backup_export', 'error', now(), 'backup ' || p_mode || ' non partito',
            'Vault secret backup_export_token missing: add it in Supabase → Project Settings → Vault');
    return null;
  end if;
  select net.http_post(
           url := 'https://ojkquhzaeypsphncjqwy.supabase.co/functions/v1/backup-export',
           body := jsonb_build_object('mode', case when p_mode = 'nightly' then 'nightly' else 'latest' end),
           headers := jsonb_build_object('Content-Type', 'application/json', 'x-backup-token', v_token),
           timeout_milliseconds := 120000)
    into v_id;
  return v_id;
end $$;

revoke execute on function fabula.backup_check_token(text) from public, anon, authenticated;
revoke execute on function fabula.backup_table_list() from public, anon, authenticated;
revoke execute on function fabula.backup_export_call(text) from public, anon, authenticated;
grant execute on function fabula.backup_check_token(text) to service_role;
grant execute on function fabula.backup_table_list() to service_role;
grant execute on function fabula.backup_export_call(text) to service_role;

-- schedules (pg_cron runs in UTC): every 2 h 07:05-21:05 Rome summer time on Mon-Sat; nightly 21:15 Rome summer time (20:15 in winter)
select cron.schedule('fabula_backup_latest', '5 5-19/2 * * 1-6', $c$select fabula.backup_export_call('latest')$c$);
select cron.schedule('fabula_backup_nightly', '15 19 * * *', $c$select fabula.backup_export_call('nightly')$c$);

-- monitored like a bot: heartbeat/watchdog via bot_schedule, bot health via expected_bots
insert into fabula.bot_schedule(agent, name_it, due_times, weekdays, month_day, grace_min, active)
values ('backup_export', 'Backup notturno', array['21:15'::time], array[1,2,3,4,5,6,7], null, 45, true)
on conflict (agent) do nothing;

create or replace function fabula.expected_bots(p_date date)
 returns table(agent text)
 language sql
 immutable
 set search_path = fabula, public, extensions
as $function$
  select a from unnest(array['daily_brief','procurement','wholesale_orders','milk_planning','sell_down','haccp_nudge','shopify_customers','shopify_orders','shopify_inventory']) a where extract(isodow from p_date) between 1 and 6
  union all select 'weekly_brief' where extract(isodow from p_date) = 1
  union all select 'compliance_calendar' where extract(isodow from p_date) = 2
  union all select 'marketing' where extract(isodow from p_date) in (1, 4)
  union all select 'monthly_review' where extract(day from p_date) = 1
  union all select 'backup_export'
$function$;

-- go-live board: the PITR item becomes a live check on the backup runs
insert into fabula.dash_checks(key, sort, label, kind, done, note)
values ('pitr', 5, 'Off-database backup in the last 26 h', 'auto', false, null)
on conflict (key) do update set label = excluded.label, kind = 'auto', note = null, updated_at = now();

insert into fabula.dash_areas(area, sort, built, reliable, automated, next_step)
values ('Infra & security', 12, 90, 78, 88, 'Add the backup Vault secret; logins for the Celsos (second titolare); test a restore')
on conflict (area) do update set built = excluded.built, reliable = excluded.reliable, automated = excluded.automated,
  next_step = excluded.next_step, updated_at = now();

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
         -- a bot counts only from the day it first ran (bots were rolled out 1-2 Oct)
         and d::date >= coalesce((select min((a.started_at at time zone 'Europe/Rome')::date) from fabula.agent_runs a where a.agent = e.agent), v_first)
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

