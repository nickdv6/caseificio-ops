-- v0.42b: bot health counts each bot from its first run
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

