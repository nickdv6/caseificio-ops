-- v0.39 · 2026-10-02 · database heartbeat independent of the Claude scheduler · simulation tools and mkt_ai_complete not callable by users
-- (part of the v0.39 integrity pass; see 20261002172859 for the overview)

-- ---------------------------------------------------------------- 7. reliability
-- heartbeat in the database itself: if the Claude scheduler or a connector stops, the console still shows it
create or replace function fabula.bot_heartbeat(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = fabula, public as $$
declare v_local timestamp := p_now at time zone 'Europe/Rome'; v_day date := (p_now at time zone 'Europe/Rome')::date; r record; a jsonb := '[]'::jsonb;
begin
  for r in select bs.agent, bs.name_it, t.due from fabula.bot_schedule bs cross join unnest(bs.due_times) t(due)
           where bs.active and extract(isodow from v_day) = any (bs.weekdays) and (bs.month_day is null or extract(day from v_day) = bs.month_day)
             and v_day + t.due + make_interval(mins => bs.grace_min + 60) <= v_local loop
    if not exists (select 1 from fabula.agent_runs ar where ar.agent = r.agent
                   and ar.started_at >= ((v_day + r.due) at time zone 'Europe/Rome') - interval '30 minutes') then
      a := a || jsonb_build_object('agent', r.agent, 'name', r.name_it, 'due', to_char(r.due, 'HH24:MI'));
    end if;
  end loop;
  if jsonb_array_length(a) > 0 then
    insert into fabula.notices (key, severity, title_it, items, expires_at)
    values ('bot_heartbeat', 'alert', format('%s bot non partiti oggi: controllare le attività programmate e i connettori Supabase/Shopify', jsonb_array_length(a)), a, p_now + interval '12 hours')
    on conflict (key) do update set severity = 'alert', title_it = excluded.title_it, items = excluded.items, created_at = p_now, expires_at = excluded.expires_at, resolved_at = null;
  else
    update fabula.notices set resolved_at = p_now where key = 'bot_heartbeat' and resolved_at is null;
  end if;
  return jsonb_build_object('checked_at', p_now, 'missed', a);
end $$;
revoke execute on function fabula.bot_heartbeat(timestamptz) from public, anon, authenticated;
grant execute on function fabula.bot_heartbeat(timestamptz) to service_role;
select cron.schedule('fabula_bot_heartbeat', '25 * * * *', $cron$select fabula.bot_heartbeat()$cron$);

-- simulation tools and the Predis completion hook are not for users
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p where p.pronamespace = 'fabula'::regnamespace
             and p.proname in ('simulate_days', 'purge_simulation', 'seed_simulation_suppliers', 'purge_milk_plan_simulation', 'mkt_ai_complete') loop
    execute format('revoke execute on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
