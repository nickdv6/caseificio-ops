-- v0.88 (12/10/2026): Brief del mattino + Brief settimanale merged into one bot, Zio Arturo.
-- Internal key stays 'daily_brief' (Mon–Sat 06:47). On Mondays the same run also covers the
-- closed week by calling weekly_brief() (function unchanged). The Monday 07:08 weekly task is disabled.
-- Zio Orazio's portrait (avatars/daily_brief.png) goes to Zio Ciro (produzione), who had none;
-- the merged bot shows Zio Arturo's portrait (avatars/weekly_brief.png). No app files change.
-- Run once in the Supabase SQL editor (project Caseificio).

begin;

update fabula.bot_nicknames
   set nickname   = 'Zio Arturo',
       title_it   = 'Brief del mattino e settimanale',
       avatar_url = 'avatars/weekly_brief.png',
       updated_at = now()
 where agent = 'daily_brief';

update fabula.bot_nicknames
   set avatar_url = 'avatars/daily_brief.png',
       updated_at = now()
 where agent = 'produzione';

update fabula.bot_schedule
   set name_it = 'Brief del mattino e settimanale'
 where agent = 'daily_brief';

-- the 3 old weekly messages now show under the merged bot in the feed
update fabula.bot_messages set agent = 'daily_brief' where agent = 'weekly_brief';

-- remove the separate weekly card and nickname (agent_runs history is kept as is)
delete from fabula.bot_schedule  where agent = 'weekly_brief';
delete from fabula.bot_nicknames where agent = 'weekly_brief';

-- missed-run checks no longer expect a separate weekly run on Mondays
create or replace function fabula.expected_bots(p_date date)
 returns table(agent text)
 language sql
 immutable
 set search_path to 'fabula', 'public', 'extensions'
as $function$
  select a from unnest(array['daily_brief','procurement','wholesale_orders','milk_planning','sell_down','haccp_nudge','ops_health','shopify_customers','shopify_orders','shopify_inventory']) a where extract(isodow from p_date) between 1 and 6
  union all select 'compliance_calendar' where extract(isodow from p_date) = 2
  union all select 'marketing' where extract(isodow from p_date) in (1, 4)
  union all select 'sales' where extract(isodow from p_date) in (1, 3, 5)
  union all select 'monthly_review' where extract(day from p_date) = 1
  union all select 'backup_export'
$function$;

commit;

-- check: expect Zio Arturo / avatars/weekly_brief.png, Zio Ciro / avatars/daily_brief.png, 0 weekly rows
select agent, nickname, title_it, avatar_url from fabula.bot_nicknames where agent in ('daily_brief','produzione','weekly_brief');
