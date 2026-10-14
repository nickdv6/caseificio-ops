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
