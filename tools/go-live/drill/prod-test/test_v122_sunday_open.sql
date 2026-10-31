-- v1.22 · Sunday open all year, written into the migrations as on live (v122a) · run on a fresh replay:
--   tools/go-live/drill/infra-test/replay.sh h_test
--   su postgres -c "psql -d h_test -f tools/go-live/drill/prod-test/test_v122_sunday_open.sql" | grep -E "PASS|FAIL"
-- Sections: 1 the replay has live's two values · 2 what they mean (Sunday a delivery day, not a closed day) · 3 the migration's two
-- statements (copied here: a suite cannot read the migration file) run again on a database that already has the values, as live does,
-- change nothing · 4 the settings keep their kind and description.
\set ON_ERROR_STOP 0
create or replace function pg_temp.ck(p_name text, p_ok boolean, p_info text default '') returns text language sql as
$$ select case when coalesce(p_ok, false) then 'PASS ' else 'FAIL ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end $$;

-- ---------------------------------------------------------------- 1. the replay equals live (read on live 31/10/2026)
select pg_temp.ck('trade.delivery_days is every day of the week, as on live since 30/10',
  (select value from fabula.settings where key = 'trade.delivery_days') = '1,2,3,4,5,6,7', (select value from fabula.settings where key = 'trade.delivery_days'));
select pg_temp.ck('prod.closed_weekdays is empty (no weekly closing day), as on live since 30/10',
  (select value from fabula.settings where key = 'prod.closed_weekdays') = '', (select value from fabula.settings where key = 'prod.closed_weekdays'));

-- ---------------------------------------------------------------- 2. what that means
select (date_trunc('week', (now() at time zone 'Europe/Rome')::date + 7) + interval '6 days')::date sun \gset
select pg_temp.ck('a Sunday is a wholesale delivery day', fabula.trade_is_delivery_day(:'sun'::date), :'sun');
select pg_temp.ck('…and not a closed day for production (the full daily task list)', not fabula.is_closed_day(:'sun'::date), :'sun');
select pg_temp.ck('every day of the next week is a delivery day',
  (select bool_and(fabula.trade_is_delivery_day(g::date)) from generate_series(:'sun'::date - 6, :'sun'::date, interval '1 day') g));

-- ---------------------------------------------------------------- 3. on a database that already has the values (live): nothing changes
-- the whole settings table and the Bot feed (where a changed setting leaves its notice), before and after
select md5(string_agg(s::text, '|' order by s.key)) fp0 from fabula.settings s \gset
select count(*) bm0 from fabula.bot_messages \gset
create temp table v122_n (n int);
with u as (update fabula.settings set value = '1,2,3,4,5,6,7' where key = 'trade.delivery_days' and value is distinct from '1,2,3,4,5,6,7' returning 1),
     v as (update fabula.settings set value = '' where key = 'prod.closed_weekdays' and value is distinct from '' returning 1)
insert into v122_n select (select count(*) from u) + (select count(*) from v);
select pg_temp.ck('the migration''s statements run again update no row (on live it is a no-op)', (select n from v122_n) = 0, (select n::text from v122_n));
select pg_temp.ck('…every setting is exactly as before (value, kind, description, updated_at)',
  (select md5(string_agg(s::text, '|' order by s.key)) from fabula.settings s) = :'fp0');
select pg_temp.ck('…and no notice reached the Bot feed', (select count(*) from fabula.bot_messages) = :bm0, (select count(*) from fabula.bot_messages)::text);

-- ---------------------------------------------------------------- 4. the two settings keep their kind and their description
select pg_temp.ck('both settings keep kind «weekdays»',
  (select count(*) from fabula.settings where key in ('trade.delivery_days', 'prod.closed_weekdays') and kind = 'weekdays') = 2,
  (select string_agg(key || '=' || coalesce(kind, '∅'), ', ') from fabula.settings where key in ('trade.delivery_days', 'prod.closed_weekdays')));
select pg_temp.ck('…and their descriptions, which name Sunday',
  (select description from fabula.settings where key = 'prod.closed_weekdays') like 'Giorni di chiusura:%domenica%'
  and (select description from fabula.settings where key = 'trade.delivery_days') like 'Giorni di consegna:%domenica%');
