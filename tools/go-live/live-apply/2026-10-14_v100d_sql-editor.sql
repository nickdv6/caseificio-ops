-- v1.00d for the Supabase dashboard SQL Editor (14/10/2026): closes the 16 alarms left open from before v1.00.
-- Same file as supabase/migrations/20261014050000_v100d_close_old_alarms.sql. One transaction; refuses a second run.
-- Paste everything, Run; the last result shows how many alarms are still open (0 expected right after).
begin;
do $chk$ begin
  if exists (select 1 from supabase_migrations.schema_migrations where version = '20261014050000') then
    raise exception 'STOP: v1.00d is already in the migration history — nothing to do';
  end if;
  if (select max(version) from supabase_migrations.schema_migrations) <> '20261014043100' then
    raise exception 'STOP: the live history does not end at 20261014043100 (v100c_notices_incidents_runnow) — tell Claude before applying';
  end if;
end $chk$;

-- v1.00d · one-off (14/10/2026): the alarms left open from before v1.00.
-- Before v1.00 «Segna come letta» closed a message for everyone, so nobody resolved bot alarms; since v1.00 an alarm stays open
-- until «Risolto» with a note, and the bell started at 16. They were all written by scheduled bots between 02/10 and 13/10
-- (brief del mattino, chiusura serata, piano latte for days gone, one Shopify stock error), and each bot restates the situation
-- at every run. Closed here once, saying why; their Telegram reminders stop with them (trigger bot_messages_closed).
-- Not touched: notice copies (they close with their notice), and anything not from a scheduled bot (Sicurezza alimentare,
-- Resa e lotti aperti, Tablet, Masseria…), which still needs a person.
update fabula.bot_messages m
   set read_at = now(), resolved_at = now(),
       resolution = 'chiuso all''avvio della v1.00: allarme di un bot programmato precedente al 14/10, ogni nuova esecuzione rifà il punto'
 where m.read_at is null and m.severity = 'alert' and m.notice_key is null
   and m.created_at < timestamp '2026-10-14 00:00' at time zone 'Europe/Rome'
   and m.agent in (select agent from fabula.bot_schedule);

insert into supabase_migrations.schema_migrations (version, name) values ('20261014050000', 'v100d_close_old_alarms');
commit;

select (select count(*) from fabula.bot_messages where read_at is null and severity = 'alert') as open_alarms,
       (select count(*) from fabula.bot_messages where resolution like 'chiuso all''avvio della v1.00%') as closed_now;
