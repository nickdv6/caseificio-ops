-- v0.47 Bot avatars — display only. Files live in the tablet app: fabula-tablet/avatars/<agent>.png (192 px).
-- Each avatar's gender matches the bot's title: Zio = male avatar, Zia = female avatar (checked below).
-- Source set: nonni-avatars/ (28 portraits, zio-NN / zia-NN). shopify_inventory (inactive) keeps the placeholder: only 15 male portraits for 16 Zio bots.
-- Portrait per bot: daily_brief zio-09 · weekly_brief zio-13 · monthly_review zio-02 · milk_planning zio-06 · procurement zio-15 ·
-- sell_down zio-05 · ops_health zio-11 · bot_watchdog zio-12 · bot_heartbeat zio-01 · backup_export zio-07 · shopify_customers zio-04 ·
-- shopify_orders zio-14 · wholesale_orders zio-03 · sales zio-10 · marketing zio-08 · haccp_nudge zia-06 · compliance_calendar zia-07 ·
-- predis zia-11 · invite_user zia-03
do $$
declare r record; n int;
begin
  for r in select * from (values
    ('daily_brief','zio'),('weekly_brief','zio'),('monthly_review','zio'),('milk_planning','zio'),
    ('procurement','zio'),('sell_down','zio'),('ops_health','zio'),('bot_watchdog','zio'),
    ('bot_heartbeat','zio'),('backup_export','zio'),('shopify_customers','zio'),('shopify_orders','zio'),
    ('wholesale_orders','zio'),('sales','zio'),('marketing','zio'),
    ('haccp_nudge','zia'),('compliance_calendar','zia'),('predis','zia'),('invite_user','zia')
  ) x(agent, g)
  loop
    update fabula.bot_nicknames
       set avatar_url = 'avatars/' || r.agent || '.png', updated_at = now()
     where agent = r.agent and lower(split_part(nickname, ' ', 1)) = r.g;
    get diagnostics n = row_count;
    if n <> 1 then
      raise exception 'v047: % — no row or title does not match % avatar', r.agent, r.g;
    end if;
  end loop;
end $$;
