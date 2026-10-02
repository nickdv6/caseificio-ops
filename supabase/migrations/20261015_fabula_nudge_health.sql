-- =============================================================================
-- v0.15: HACCP evening nudge + bot health / data quality.
--   fabula.notices: short banners the tablet shows on the home screen until they
--     expire or the thing gets done (red = compliance, grey = info).
--   haccp_evening_status(): what is still missing tonight (evening cold checks,
--     sanitation, Z close, meter reading, open batches) → upserts one notice.
--   ops_health_check(): did every bot run today, errors, data-quality issues
--     (open batches, lots without labels, negative stock, milk intakes without
--     DDT photo, sales on unknown lots, stale pending approvals → expired,
--     stock count overdue). Read-mostly; the only write is expiring approvals.
-- Written without destructive keywords (connector rule).
-- =============================================================================
set search_path = fabula, public;

create table if not exists fabula.notices (
  id          uuid primary key default gen_random_uuid(),
  key         text not null,                  -- 'haccp_evening:2026-10-02' — one per subject per day
  severity    text not null default 'warn' check (severity in ('info','warn','alert')),
  title_it    text not null,
  items       jsonb not null default '[]',    -- [{code, label_it, scan}] – scan = code to open on tap
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null,
  resolved_at timestamptz,
  unique (key)
);
grant all on fabula.notices to authenticated, service_role;
alter table fabula.notices enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname='fabula' and tablename='notices' and policyname='notices_authenticated_all') then
    create policy notices_authenticated_all on fabula.notices for all to authenticated using (true) with check (true);
  end if;
end $$;
create or replace view fabula.v_active_notices as
select * from fabula.notices where resolved_at is null and expires_at > now() order by severity desc, created_at desc;
grant select on fabula.v_active_notices to authenticated, service_role;

-- What is still missing tonight. Called by the 19:00 bot; also safe to call any time.
create or replace function fabula.haccp_evening_status(p_date date default (now() at time zone 'Europe/Rome')::date)
returns jsonb language plpgsql as $$
declare items jsonb := '[]'; v_key text := 'haccp_evening:' || p_date; n int;
begin
  -- evening cold-room checks (after 15:00)
  select coalesce(jsonb_agg(jsonb_build_object('code', 'cold:' || cp.code, 'label_it', 'Temperatura serale ' || coalesce(e.code, cp.name), 'scan', 'EQ:' || e.code) order by cp.code), '[]') into items
  from fabula.haccp_control_points cp left join fabula.equipment e on e.id = cp.equipment_id
  where cp.active and cp.frequency = 'twice_daily'
    and not exists (select 1 from fabula.haccp_log l where l.control_point_id = cp.id and l.logged_at::date = p_date and (l.logged_at at time zone 'Europe/Rome')::time >= time '15:00');
  -- sanitation
  if not exists (select 1 from fabula.haccp_log l join fabula.haccp_control_points cp on cp.id = l.control_point_id where cp.code = 'PRP-CLEAN' and l.logged_at::date = p_date) then
    items := items || jsonb_build_object('code', 'clean', 'label_it', 'Sanificazione fine turno', 'scan', 'CLEAN:');
  end if;
  -- till close and meter (only if there were sales/production today — otherwise the day was closed)
  if exists (select 1 from fabula.production_batches where batch_date = p_date) or exists (select 1 from fabula.sales_orders where order_date = p_date) then
    if not exists (select 1 from fabula.pos_daily_closings where closing_date = p_date) then
      items := items || jsonb_build_object('code', 'z', 'label_it', 'Chiusura cassa (scontrino Z)', 'scan', 'EQ:RT-01'); end if;
    if not exists (select 1 from fabula.meter_readings where meter = 'elec_main' and read_at::date = p_date) then
      items := items || jsonb_build_object('code', 'kwh', 'label_it', 'Lettura contatore', 'scan', 'METER:elec_main'); end if;
  end if;
  -- batches started today and never closed
  select items || coalesce(jsonb_agg(jsonb_build_object('code', 'batch:' || batch_lot, 'label_it', 'Lotto ' || batch_lot || ' non chiuso (kg prodotto)', 'scan', 'LOT:' || batch_lot)), '[]') into items
  from fabula.production_batches where batch_date = p_date and output_kg is null and source <> 'simulation';

  n := jsonb_array_length(items);
  if n > 0 then
    insert into fabula.notices (key, severity, title_it, items, expires_at)
    values (v_key, 'alert', format('Prima di chiudere: %s cose da registrare', n), items, ((p_date + 1)::timestamp + time '05:00') at time zone 'Europe/Rome')
    on conflict (key) do update set items = excluded.items, title_it = excluded.title_it, resolved_at = null;
  else
    update fabula.notices set resolved_at = now() where key = v_key and resolved_at is null;
  end if;
  return jsonb_build_object('date', p_date, 'missing', items, 'count', n,
    'is_simulation', exists (select 1 from fabula.simulation_runs where p_date between from_date and to_date),
    'closed_day', not (exists (select 1 from fabula.production_batches where batch_date = p_date) or exists (select 1 from fabula.sales_orders where order_date = p_date)));
end $$;
grant execute on function fabula.haccp_evening_status(date) to authenticated, service_role;

-- Expected bot runs by weekday (Europe/Rome day). Edit here when a bot is added.
create or replace function fabula.expected_bots(p_date date) returns table (agent text) language sql immutable as $$
  select a from unnest(array['daily_brief','procurement','milk_planning','sell_down']) a where extract(isodow from p_date) between 1 and 6
  union all select 'weekly_brief' where extract(isodow from p_date) = 1
  union all select 'compliance_calendar' where extract(isodow from p_date) = 2
$$;

create or replace function fabula.ops_health_check(p_date date default (now() at time zone 'Europe/Rome')::date)
returns jsonb language plpgsql as $$
declare bots jsonb; dq jsonb := '[]'; n_exp int;
begin
  -- 1. bots: expected today vs ran (any status) + errors
  select jsonb_agg(jsonb_build_object('agent', e.agent, 'ran', r.n > 0, 'runs', coalesce(r.n, 0), 'errors', coalesce(r.err, 0), 'last_error', r.last_error) order by e.agent) into bots
  from fabula.expected_bots(p_date) e
  left join lateral (select count(*) n, count(*) filter (where status = 'error') err, max(error) filter (where status = 'error') last_error
                     from fabula.agent_runs ar where ar.agent = e.agent and (ar.started_at at time zone 'Europe/Rome')::date = p_date) r on true;

  -- 2. data quality
  update fabula.approvals set status = 'expired' where status = 'pending' and expires_at < now();
  with issues as (
    select 'open_batches' k, 'Lotti aperti da più di un giorno: ' || string_agg(batch_lot, ', ') t, count(*) c
      from fabula.production_batches where output_kg is null and batch_date < p_date and source <> 'simulation' having count(*) > 0
    union all
    select 'negative_stock', 'Giacenza negativa: ' || string_agg(sku || ' ' || round(qty_on_hand,1), ', '), count(*)
      from (select sku, sum(qty_on_hand) qty_on_hand from fabula.v_stock_on_hand group by sku having sum(qty_on_hand) < -0.01) x having count(*) > 0
    union all
    select 'unlabelled_lots', 'Lotti chiusi senza etichetta stampata: ' || string_agg(b.batch_lot, ', '), count(*)
      from fabula.production_batches b where b.output_kg is not null and b.batch_date between p_date - 7 and p_date and b.source <> 'simulation'
       and not exists (select 1 from fabula.labels l where l.batch_id = b.id) having count(*) > 0
    union all
    select 'milk_no_ddt_photo', 'Arrivi latte senza foto DDT (7 gg): ' || count(*), count(*)
      from fabula.milk_intake m where m.intake_date between p_date - 7 and p_date and m.source <> 'simulation'
       and not exists (select 1 from fabula.documents d where d.kind = 'ddt_in' and d.document_date = m.intake_date) having count(*) > 0
    union all
    select 'unknown_lot_sales', 'Vendite su lotti sconosciuti (7 gg): ' || string_agg(distinct sm.lot_number, ', '), count(*)
      from fabula.stock_moves sm where sm.move_type = 'sale' and sm.moved_at::date between p_date - 7 and p_date and sm.source <> 'simulation'
       and sm.lot_number is not null and not exists (select 1 from fabula.production_batches b where b.batch_lot = sm.lot_number) having count(*) > 0
    union all
    select 'stock_count_overdue', 'Conta magazzino non fatta da ' || (p_date - max(counted_at::date)) || ' giorni', 1
      from fabula.stock_counts where status = 'posted' having max(counted_at::date) < p_date - 9
    union all
    select 'stock_count_never', 'Nessuna conta magazzino registrata', 1 where not exists (select 1 from fabula.stock_counts where status = 'posted')
    union all
    select 'approvals_stale', 'Approvazioni in attesa da oltre 3 giorni: ' || count(*), count(*)
      from fabula.approvals where status = 'pending' and requested_at < now() - interval '3 days' having count(*) > 0
    union all
    select 'tablet_silent', 'Nessuna scansione dal tablet oggi (giorno lavorativo)', 1
      where extract(isodow from p_date) between 1 and 6 and not exists (select 1 from fabula.scan_events where scanned_at::date = p_date)
        and not exists (select 1 from fabula.simulation_runs where p_date between from_date and to_date)
  )
  select coalesce(jsonb_agg(jsonb_build_object('key', k, 'text', t, 'count', c)), '[]') into dq from issues;

  return jsonb_build_object('date', p_date, 'bots', coalesce(bots, '[]'),
    'bots_missing', (select coalesce(jsonb_agg(b->>'agent'), '[]') from jsonb_array_elements(coalesce(bots,'[]')) b where not (b->>'ran')::boolean),
    'bots_errors', (select coalesce(sum((b->>'errors')::int), 0) from jsonb_array_elements(coalesce(bots,'[]')) b),
    'data_quality', dq, 'issues', jsonb_array_length(dq),
    'is_simulation', exists (select 1 from fabula.simulation_runs where p_date - 1 between from_date and to_date));
end $$;
grant execute on function fabula.ops_health_check(date) to authenticated, service_role;
