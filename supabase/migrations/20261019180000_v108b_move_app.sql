-- v1.08b (19/10/2026): the app moves to https://app.bubalina.it (project doc claude/audit-fixes-v108-2026-10-15.md, «v1.08b»).
-- Since v1.08 every release publishes fabula-tablet/ on GitHub Pages at app.bubalina.it (free, no credits); the Netlify address kept
-- serving the same app. From here:
--   * infra.site_url = https://app.bubalina.it: every link the database builds (Telegram and Bot feed links, invites, the Masseria
--     and trade links, QR codes printed from now on) and the hourly check of the site («Sito del tablet», «App pubblicata = GitHub»)
--     use the new address. The drift texts switch to «approva il rilascio su GitHub» by themselves (v1.08a: they follow this setting).
--   * The old address forwards: fabula-tablet/config.js sends every page opened on *.netlify.app to the same page on
--     app.bubalina.it; the tablet first waits until nothing is waiting to be sent and carries its name and id (?device=,
--     ?device_uid=), so the office keeps seeing the same tablet. Netlify builds once more for that, then no more (netlify.toml).
--   * The two system texts that still said Netlify (the drift notice, the uptime alert) and the system-check bot's prompt.

update fabula.settings
   set value = 'https://app.bubalina.it',
       description = 'Indirizzo dell''app (tablet e Console), pubblicata da ogni rilascio su GitHub Pages: i link nei messaggi, negli inviti e nei QR lo usano; il controllo orario verifica che risponda e che la versione sia quella su GitHub'
 where key = 'infra.site_url';
do $mig$ begin
  if (select value from fabula.settings where key = 'infra.site_url') is distinct from 'https://app.bubalina.it' then
    raise exception 'v108b: setting infra.site_url not found';
  end if;
end $mig$;

do $mig$
declare d text; n text;
begin
  -- the drift notice (more than 6 h out of step): the app is published by the release, not by Netlify
  d := pg_get_functiondef('fabula.trg_notice_message()'::regprocedure);
  n := replace(d, $s$when 'app_deployed' then 'Il tablet non ha l''ultima versione dell''app: controlla il deploy su Netlify'$s$,
                  $s$when 'app_deployed' then 'Il tablet non ha l''ultima versione dell''app: approva il rilascio su GitHub (Actions → Release)'$s$);
  if n = d then raise exception 'v108b: trg_notice_message app_deployed pattern not found'; end if;
  execute n;

  -- the uptime alert: the app's host is GitHub Pages now
  d := pg_get_functiondef('fabula.infra_collect()'::regprocedure);
  n := replace(d, $s$'Sistema non raggiungibile: sito del tablet o funzioni del server non rispondono (Netlify / Supabase)'$s$,
                  $s$'Sistema non raggiungibile: sito del tablet o funzioni del server non rispondono (GitHub Pages / Supabase)'$s$);
  if n = d then raise exception 'v108b: infra_collect uptime title pattern not found'; end if;
  d := n;
  n := replace(d, $s$  -- drift: GitHub / Netlify / live database out of step for more than 6 h$s$,
                  $s$  -- drift: GitHub / the app's site / live database out of step for more than 6 h$s$);
  if n = d then raise exception 'v108b: infra_collect drift comment pattern not found'; end if;
  execute n;
end $mig$;

-- ============================== the prompt (tools/bots/sync_rules.py --versions) ==============================
insert into fabula.bot_prompt_versions (agent, version) values
  ('ops_health', '2422561503')
on conflict (agent) do update set version = excluded.version, updated_at = now();
