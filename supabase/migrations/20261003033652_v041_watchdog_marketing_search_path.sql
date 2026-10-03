-- v0.41 quick wins (02/10/2026)
-- 1. Watchdog coverage: the Marketing bot (Mon + Thu) is now an expected bot,
--    so ops_health_check() flags it when it doesn't run.
create or replace function fabula.expected_bots(p_date date)
 returns table(agent text)
 language sql
 immutable
as $function$
  select a from unnest(array['daily_brief','procurement','wholesale_orders','milk_planning','sell_down','haccp_nudge','shopify_customers','shopify_orders','shopify_inventory']) a where extract(isodow from p_date) between 1 and 6
  union all select 'weekly_brief' where extract(isodow from p_date) = 1
  union all select 'compliance_calendar' where extract(isodow from p_date) = 2
  union all select 'marketing' where extract(isodow from p_date) in (1, 4)
  union all select 'monthly_review' where extract(day from p_date) = 1
$function$;

-- 2. Security advisor "function_search_path_mutable": pin search_path on every
--    fabula function that doesn't have one (89 at the time). Same resolution as the
--    Data API (fabula first, then public, extensions), so behaviour is unchanged.
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'fabula' and p.prokind = 'f'
      and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
      and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%')
  loop
    execute format('alter function %s set search_path = fabula, public, extensions', f.sig);
  end loop;
end $$;
