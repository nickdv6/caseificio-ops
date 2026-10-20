-- v1.10 «Sicurezza e salvataggi» (quality test 20/10/2026, claude/quality-test-2026-10-20.md) · run on a fresh replay:
--   tools/go-live/drill/infra-test/replay.sh p110
--   su postgres -c "psql -d p110 -f tools/go-live/drill/prod-test/test_v110_security_saves.sql" | grep -E "PASS|FAIL"
-- (the tablet's saves, the welcome page and the server functions are tested in the browser: tools/go-live/drill/tablet-test/v110_e2e.py)
\set ON_ERROR_STOP 0
create or replace function pg_temp.ck(p_name text, p_ok boolean, p_info text default '') returns text language sql as
$$ select case when coalesce(p_ok, false) then 'PASS ' else 'FAIL ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end $$;
create or replace function pg_temp.err(p_sql text) returns text language plpgsql as
$$ begin execute p_sql; return ''; exception when others then return sqlerrm; end $$;
create or replace function pg_temp.h(t text) returns text language sql as $$ select encode(sha256(convert_to(t, 'UTF8')), 'hex') $$;
create or replace function pg_temp.as_user(p uuid) returns void language sql as
$$ select set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, false) $$;

-- people: a titolare (T), a socio (S), someone on the floor with Telegram (F)
insert into auth.users (id, email, email_confirmed_at, encrypted_password, last_sign_in_at) values
  ('00000000-0000-4000-a000-0000000110a1', 'tit110@example.it', now(), 'x', now()),
  ('00000000-0000-4000-a000-0000000110b1', 'socio110@example.it', now(), 'x', now()),
  ('00000000-0000-4000-a000-0000000110c1', 'floor110@example.it', now(), 'x', now()),
  ('00000000-0000-4000-a000-0000000110e1', 'spare110@example.it', now(), 'x', now());
insert into fabula.staff (id, full_name, role, app_role, email, active, auth_user_id) values
  ('00000000-0000-4000-b000-0000000110a0', 'Tito Titolare', 'owner', 'titolare', 'tit110@example.it', true, '00000000-0000-4000-a000-0000000110a1'),
  ('00000000-0000-4000-b000-0000000110b0', 'Sara Socia', 'partner', 'socio', 'socio110@example.it', true, '00000000-0000-4000-a000-0000000110b1'),
  ('00000000-0000-4000-b000-0000000110c0', 'Franco Floor', 'operaio', 'produzione', 'floor110@example.it', true, '00000000-0000-4000-a000-0000000110c1');

-- ---------------------------------------------------------------- 1. protected settings (item 1)
select pg_temp.ck('protected: the app address, access links, the addresses the database calls, the Telegram bot',
  fabula.setting_protected('infra.site_url') and fabula.setting_protected('auth.link_days') and fabula.setting_protected('trade.edge_url')
  and fabula.setting_protected('shopify.sync_url') and fabula.setting_protected('notify.function_url') and fabula.setting_protected('notify.telegram_bot'));
select pg_temp.ck('…not the marketing links, the Manuale link (review L3) nor ordinary settings',
  not fabula.setting_protected('mkt.local_site_url') and not fabula.setting_protected('food.manuale_url') and not fabula.setting_protected('milk.price_eur_kg') and not fabula.setting_protected('trade.min_order_kg'));
select value site_before from fabula.settings where key = 'infra.site_url' \gset
select pg_temp.as_user('00000000-0000-4000-a000-0000000110b1');
set role authenticated;
select pg_temp.err($$update fabula.settings set value = 'https://app.bubalina.it.evil.example' where key = 'infra.site_url'$$) s1 \gset
select pg_temp.err($$update fabula.settings set value = 'https://evil.example/functions/v1/trade-portal' where key = 'trade.edge_url'$$) s2 \gset
select pg_temp.err($$update fabula.settings set value = '30' where key = 'auth.link_days'$$) s3 \gset
select pg_temp.err($$insert into fabula.settings (key, value, description, data_type) values ('infra.extra_url', 'https://evil.example', 'x', 'text')$$) s4 \gset
select pg_temp.err($$delete from fabula.settings where key = 'shopify.sync_url'$$) s5 \gset
select pg_temp.err($$update fabula.settings set value = '13' where key = 'trade.min_order_kg'$$) s6 \gset
reset role;
select pg_temp.ck('a socio cannot change the app address (the next access link would go to that site)', :'s1' ilike '%solo chi gestisce utenti%', :'s1');
select pg_temp.ck('…nor where the database sends the trade job key', :'s2' ilike '%solo chi gestisce utenti%', :'s2');
select pg_temp.ck('…nor how long access links last', :'s3' ilike '%solo chi gestisce utenti%', :'s3');
select pg_temp.ck('…nor add or delete such a setting (a delete is not even reached: no delete rule for the API)', :'s4' ilike '%solo chi gestisce utenti%'
  and exists (select 1 from fabula.settings where key = 'shopify.sync_url') and not exists (select 1 from fabula.settings where key = 'infra.extra_url'), :'s4' || ' / ' || :'s5');
select pg_temp.ck('…the value is unchanged', (select value from fabula.settings where key = 'infra.site_url') = :'site_before');
select pg_temp.ck('an ordinary setting still saves for the socio', :'s6' = '' and (select value from fabula.settings where key = 'trade.min_order_kg') = '13', :'s6');
select pg_temp.as_user('00000000-0000-4000-a000-0000000110a1');
set role authenticated;
select pg_temp.err($$update fabula.settings set value = 'https://app.bubalina.it' where key = 'infra.site_url'$$) s7 \gset
reset role;
select pg_temp.ck('the titolare can change the app address', :'s7' = '', :'s7');
-- the database's own functions (e.g. the version watcher) still write their settings when a socio's tablet calls them
create function pg_temp.sys_write() returns void language sql security definer as $$ update fabula.settings set value = 'perla-v99|x' where key = 'infra.sw_seen' $$;
insert into fabula.settings (key, value, description, data_type) values ('infra.sw_seen', '', 'test', 'text') on conflict (key) do nothing;
grant execute on function pg_temp.sys_write() to authenticated;
select pg_temp.as_user('00000000-0000-4000-a000-0000000110b1');
set role authenticated;
select pg_temp.err($$select pg_temp.sys_write()$$) s8 \gset
reset role;
select pg_temp.ck('a database function writing a protected setting on a socio''s behalf is not refused', :'s8' = '' and (select value from fabula.settings where key = 'infra.sw_seen') = 'perla-v99|x', :'s8');

-- ---------------------------------------------------------------- 2. adding staff (item 2)
select pg_temp.as_user('00000000-0000-4000-a000-0000000110b1');
set role authenticated;
select pg_temp.err($$insert into fabula.staff (full_name, role, app_role, active) values ('Finto Titolare', 'owner', 'titolare', true)$$) i1 \gset
select pg_temp.err($$insert into fabula.staff (full_name, role, app_role, email, active) values ('Con Email', 'operaio', 'produzione', 'spare110@example.it', true)$$) i2 \gset
select pg_temp.err($$insert into fabula.staff (full_name, role, app_role, active, auth_user_id) values ('Con Login', 'operaio', 'produzione', true, '00000000-0000-4000-a000-0000000110e1')$$) i3 \gset
select pg_temp.err($$insert into fabula.staff (full_name, role, app_role, active) values ('Solo Badge', 'operaio', 'produzione', true)$$) i4 \gset
reset role;
select pg_temp.ck('a socio cannot add a Titolare (review: the insert went round the staff guard)', :'i1' ilike '%solo chi gestisce utenti%', :'i1');
select pg_temp.ck('…nor a person with an e-mail (a sign-up with it would claim the row)', :'i2' ilike '%solo chi gestisce utenti%', :'i2');
select pg_temp.ck('…nor one linked to a login', :'i3' ilike '%solo chi gestisce utenti%', :'i3');
select pg_temp.ck('…a row with no login and no e-mail still saves', :'i4' = '', :'i4');
select pg_temp.ck('…and no Titolare row was made', not exists (select 1 from fabula.staff where full_name in ('Finto Titolare', 'Con Email', 'Con Login')));
select pg_temp.as_user('00000000-0000-4000-a000-0000000110a1');
set role authenticated;
select pg_temp.err($$insert into fabula.staff (full_name, role, app_role, email, active) values ('Dal Titolare', 'operaio', 'produzione', 'nuova110@example.it', true)$$) i5 \gset
reset role;
select pg_temp.ck('the titolare can add a person with an e-mail', :'i5' = '', :'i5');
select pg_temp.ck('the server functions (service role) are not affected', pg_temp.err($$insert into fabula.staff (full_name, role, app_role, email, active) values ('Da Funzione', 'operaio', 'produzione', 'fn110@example.it', true)$$) = '');
select pg_temp.as_user('00000000-0000-4000-a000-0000000110b1');
set role authenticated;
select pg_temp.err($$update fabula.staff set app_role = 'titolare' where id = '00000000-0000-4000-b000-0000000110c0'$$) i6 \gset
reset role;
select pg_temp.ck('the update rule of v1.09 still holds (a socio cannot change a profile)', :'i6' ilike '%solo chi gestisce utenti%', :'i6');
select set_config('request.jwt.claims', '', false);

-- ---------------------------------------------------------------- 3. Telegram of someone else
insert into fabula.notify_targets (staff_id, topics, chat_id, active, linked_at) values ('00000000-0000-4000-b000-0000000110c0', '{food_safety}', 110110, true, now())
on conflict (staff_id) do update set chat_id = 110110, active = true;
select pg_temp.as_user('00000000-0000-4000-a000-0000000110b1');
set role authenticated;
select pg_temp.err($$select fabula.notify_link_code('00000000-0000-4000-b000-0000000110c0')$$) t1 \gset
select pg_temp.err($$select fabula.notify_link_code()$$) t2 \gset
reset role;
select pg_temp.ck('a socio cannot replace the Telegram of someone already linked', :'t1' ilike '%già collegato%', :'t1');
select pg_temp.ck('…the chat is untouched', (select chat_id from fabula.notify_targets where staff_id = '00000000-0000-4000-b000-0000000110c0') = 110110);
select pg_temp.ck('…the socio can still link their own', :'t2' = '', :'t2');
select pg_temp.as_user('00000000-0000-4000-a000-0000000110a1');
set role authenticated;
select pg_temp.err($$select fabula.notify_link_code('00000000-0000-4000-b000-0000000110c0')$$) t3 \gset
reset role;
select pg_temp.ck('the titolare can make a new one for that person', :'t3' = '', :'t3');
select set_config('request.jwt.claims', '', false);

-- ---------------------------------------------------------------- 4. access links: the others stop when the password is saved (item 9)
insert into fabula.staff (id, full_name, role, app_role, email, active) values ('00000000-0000-4000-b000-0000000110d0', 'Dora Link', 'operaio', 'produzione', 'dora110@example.it', true);
insert into auth.users (id, email, email_confirmed_at, encrypted_password) values ('00000000-0000-4000-a000-0000000110d1', 'dora110@example.it', now(), 'x');
select fabula.access_link_new('00000000-0000-4000-b000-0000000110d0', pg_temp.h('dora1'), null) is not null x \gset
select fabula.access_link_claim(pg_temp.h('dora1')) as c1 \gset
select fabula.access_link_new('00000000-0000-4000-b000-0000000110d0', pg_temp.h('dora2'), null) is not null x \gset
update fabula.staff_access_links set revoked_at = null, revoked_why = null where token_hash = pg_temp.h('dora1');   -- as if made just before L2
select fabula.access_link_bind((:'c1'::jsonb ->> 'link_id')::uuid, '00000000-0000-4000-a000-0000000110d1') b1 \gset
select pg_temp.ck('bind no longer stops the other links (a password that then fails left both dead)',
  (fabula.access_link_check(pg_temp.h('dora2')) ->> 'ok')::boolean, fabula.access_link_check(pg_temp.h('dora2'))::text);
select fabula.access_link_done((:'c1'::jsonb ->> 'link_id')::uuid) d1 \gset
select pg_temp.ck('once the password is saved (access_link_done) the other links stop: «password già scelta»',
  :'d1'::int = 1 and fabula.access_link_check(pg_temp.h('dora2')) ->> 'reason' = 'revoked'
  and (select revoked_why from fabula.staff_access_links where token_hash = pg_temp.h('dora2')) = 'password già scelta', :'d1');
select pg_temp.ck('access_link_done is for the server function only', not has_function_privilege('authenticated', 'fabula.access_link_done(uuid)', 'execute')
  and not has_function_privilege('anon', 'fabula.access_link_done(uuid)', 'execute'));

-- ---------------------------------------------------------------- 5. a late badge-out after the automatic close (item 8)
insert into fabula.shifts (staff_id, clock_in, source) values ('00000000-0000-4000-b000-0000000110c0', now() - interval '13 hours', 'tablet');
select pg_temp.as_user('00000000-0000-4000-a000-0000000110c1');
set role authenticated;
select fabula.badge_in(null, '00000000-0000-4000-b000-0000000110c0', now()) bi \gset
select fabula.badge_out(null, '00000000-0000-4000-b000-0000000110c0', now() - interval '4 hours') bo \gset
reset role;
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('a badge-out queued 4 hours ago corrects the shift closed by itself (9 h, not 12 h + 0 h)',
  (:'bo'::jsonb ->> 'corrected')::boolean and (select hours from fabula.shifts where staff_id = '00000000-0000-4000-b000-0000000110c0' order by clock_in limit 1) = 9.00, :'bo');
select pg_temp.ck('…and the new shift stays open',
  exists (select 1 from fabula.shifts where staff_id = '00000000-0000-4000-b000-0000000110c0' and clock_out is null and clock_in > now() - interval '1 minute'));
select pg_temp.ck('…the corrected shift says so', (select notes from fabula.shifts where staff_id = '00000000-0000-4000-b000-0000000110c0' order by clock_in limit 1) ilike '%uscita corretta%');
select pg_temp.as_user('00000000-0000-4000-a000-0000000110c1');
set role authenticated;
select fabula.badge_out(null, '00000000-0000-4000-b000-0000000110c0', now()) bo2 \gset
reset role;
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('a badge-out now still closes the open shift', :'bo2'::jsonb ->> 'action' = 'out' and not coalesce((:'bo2'::jsonb ->> 'corrected')::boolean, false), :'bo2');

-- review H1: a late badge-out with no shift open never stretches an old automatic close from days before (it became 119 h)
insert into fabula.staff (id, full_name, role, app_role, active) values ('00000000-0000-4000-b000-0000000110f0', 'Gino Turni', 'operaio', 'produzione', true);
insert into fabula.shifts (staff_id, clock_in, clock_out, source, notes) values
  ('00000000-0000-4000-b000-0000000110f0', now() - interval '5 days', now() - interval '5 days' + interval '12 hours', 'tablet', 'chiuso automaticamente (badge dimenticato)'),
  ('00000000-0000-4000-b000-0000000110f0', now() - interval '8 hours', now() - interval '30 minutes', 'tablet', null);
select fabula.badge_out(null, '00000000-0000-4000-b000-0000000110f0', now() - interval '1 hour') h1 \gset
select pg_temp.ck('review H1: a late badge-out after a normal badge-out on another tablet changes nothing (the old automatic close stays 12 h)',
  :'h1'::jsonb ->> 'action' = 'none' and (select max(hours) from fabula.shifts where staff_id = '00000000-0000-4000-b000-0000000110f0') = 12.00, :'h1');
-- review M1a: a split shift: morning closed normally, afternoon open; the morning's late scan from the other tablet leaves the afternoon open
insert into fabula.shifts (staff_id, clock_in, clock_out, source) values ('00000000-0000-4000-b000-0000000110f0', now() - interval '7 hours', now() - interval '3 hours', 'tablet');
insert into fabula.shifts (staff_id, clock_in, source) values ('00000000-0000-4000-b000-0000000110f0', now() - interval '2 hours', 'tablet');
delete from fabula.shifts where staff_id = '00000000-0000-4000-b000-0000000110f0' and clock_in > now() - interval '9 hours' and clock_in < now() - interval '7 hours 30 minutes';
select fabula.badge_out(null, '00000000-0000-4000-b000-0000000110f0', now() - interval '3 hours 2 minutes') m1 \gset
select pg_temp.ck('review M1: a late badge-out older than the open shift never closes it at 0 hours',
  :'m1'::jsonb ->> 'action' = 'none' and exists (select 1 from fabula.shifts where staff_id = '00000000-0000-4000-b000-0000000110f0' and clock_out is null), :'m1');
-- review M1b: a tablet offline overnight: its badge-out is 16 hours old
insert into fabula.staff (id, full_name, role, app_role, active) values ('00000000-0000-4000-b000-0000000110f1', 'Nina Notte', 'operaio', 'produzione', true);
insert into fabula.shifts (staff_id, clock_in, clock_out, source, notes) values
  ('00000000-0000-4000-b000-0000000110f1', now() - interval '24 hours', now() - interval '12 hours', 'tablet', 'chiuso automaticamente (badge dimenticato)');
insert into fabula.shifts (staff_id, clock_in, source) values ('00000000-0000-4000-b000-0000000110f1', now() - interval '1 hour', 'tablet');
select fabula.badge_out(null, '00000000-0000-4000-b000-0000000110f1', now() - interval '16 hours') m2 \gset
select pg_temp.ck('review M1: a badge-out 16 hours old (tablet offline overnight) corrects yesterday''s shift (8 h) and today''s stays open',
  (:'m2'::jsonb ->> 'corrected')::boolean and (:'m2'::jsonb ->> 'hours')::numeric = 8.00
  and exists (select 1 from fabula.shifts where staff_id = '00000000-0000-4000-b000-0000000110f1' and clock_out is null), :'m2');

-- ---------------------------------------------------------------- 6. save_ops: calibration, pest round, lab sample with the save id (item 3)
select pg_temp.ck('save_ops accepts the three records', (select prosrc from pg_proc where oid = 'fabula.save_ops(jsonb,uuid,timestamp with time zone,timestamp with time zone)'::regprocedure)
  ~ 'record_calibration_check.*record_pest_inspection.*record_sample_taken');
select count(*) pest0 from fabula.pest_inspections \gset
select pg_temp.as_user('00000000-0000-4000-a000-0000000110a1');
set role authenticated;
select pg_temp.err($$select fabula.save_ops('[{"rpc":"record_pest_inspection","args":{"p_by":"interno","p_findings":[],"p_staff_id":"00000000-0000-4000-b000-0000000110a0","p_actions":"giro v110"}}]'::jsonb, '11000000-0000-4000-a000-000000000110'::uuid)$$) p1 \gset
select pg_temp.err($$select fabula.save_ops('[{"rpc":"record_pest_inspection","args":{"p_by":"interno","p_findings":[],"p_staff_id":"00000000-0000-4000-b000-0000000110a0","p_actions":"giro v110"}}]'::jsonb, '11000000-0000-4000-a000-000000000110'::uuid)$$) p2 \gset
reset role;
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('a pest round sent twice with the same save id is written once (a lost reply wrote it twice)',
  :'p1' = '' and :'p2' = '' and (select count(*) from fabula.pest_inspections) = :pest0 + 1, :'p1' || ' / ' || :'p2');

-- ---------------------------------------------------------------- 7. farm: cancelled loads do not use up the day (item 13)
update fabula.settings set value = '0123456789abcdef0123456789abcd10' where key = 'milk.farm_token';
insert into fabula.settings (key, value, description, data_type) select 'milk.farm_token', '0123456789abcdef0123456789abcd10', 'test', 'text'
 where not exists (select 1 from fabula.settings where key = 'milk.farm_token');
do $$ declare i int; r jsonb; begin
  for i in 1..8 loop
    r := fabula.farm_milk_ship('0123456789abcdef0123456789abcd10', 300 + i, 4, null, null, true, 'Test');
    perform fabula.farm_milk_amend('0123456789abcdef0123456789abcd10', r ->> 'milk_lot', null, true, 'prova v110', 'Test');
  end loop; end $$;
select pg_temp.err($$select fabula.farm_milk_ship('0123456789abcdef0123456789abcd10', 1050, 4, null, null, true, 'Test')$$) f1 \gset
select pg_temp.ck('after 8 cancelled loads the real one is still recorded', :'f1' = '' and exists (select 1 from fabula.milk_shipments where kg = 1050 and status = 'shipped'), :'f1');
select pg_temp.ck('…with a lot number of its own', (select count(distinct milk_lot) = count(*) from fabula.milk_shipments where ship_date = (now() at time zone 'Europe/Rome')::date));
do $$ declare i int; begin
  for i in 1..7 loop perform fabula.farm_milk_ship('0123456789abcdef0123456789abcd10', 400 + i, 4, null, null, true, 'Test'); end loop; end $$;
select pg_temp.err($$select fabula.farm_milk_ship('0123456789abcdef0123456789abcd10', 999, 4, null, null, true, 'Test')$$) f2 \gset
select pg_temp.ck('8 loads that stand still stop a 9th', :'f2' ilike '%Troppe spedizioni oggi (8)%', :'f2');

-- ---------------------------------------------------------------- 8. trade: an application cannot take over a customer (item 5)
insert into fabula.parties (id, type, legal_name, trade_name, piva, sdi_code, pec_email, email, phone, active, source)
values ('50000000-0000-4000-a000-000000000110', 'customer', 'Pizzeria Vera', 'Pizzeria Vera', '01234567890', 'VERA123', 'vera@pec.it', 'vera110@example.it', '3331110000', true, 'shopify');
select fabula.trade_apply('{"business_name":"Evil Srl","contact_name":"Eve","email":"VERA110@example.it","piva":"09999999999","sdi_code":"EVIL999","pec_email":"evil@pec.it","phone":"3330000000","shopify_customer_id":"424242"}'::jsonb) ->> 'id' app \gset
select pg_temp.as_user('00000000-0000-4000-a000-0000000110a1');
set role authenticated;
select fabula.trade_approve(:'app'::uuid, null) ta \gset
reset role;
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('approving a request with an existing customer''s e-mail leaves their name, P.IVA, SDI, PEC and phone as they were',
  (select legal_name = 'Pizzeria Vera' and piva = '01234567890' and sdi_code = 'VERA123' and pec_email = 'vera@pec.it' and phone = '3331110000'
     from fabula.parties where id = '50000000-0000-4000-a000-000000000110'));
select pg_temp.ck('…the differences are listed for the office', jsonb_array_length(:'ta'::jsonb -> 'differences') >= 4
  and (:'ta'::jsonb -> 'differences') @> '[{"field":"piva","current":"01234567890","request":"09999999999"}]', :'ta');
select pg_temp.ck('…and noted on the request', (select decision_note from fabula.trade_applications where id = :'app'::uuid) ilike '%dati non cambiati%');
select pg_temp.ck('…the Shopify id typed in the form is not taken', (select shopify_customer_id is distinct from '424242' from fabula.parties where id = '50000000-0000-4000-a000-000000000110'));
select fabula.trade_apply('{"business_name":"Nuova Trattoria","contact_name":"Nino","email":"nuova110@trattoria.it","piva":"07777777777","shopify_customer_id":"515151"}'::jsonb) ->> 'id' app2 \gset
select pg_temp.as_user('00000000-0000-4000-a000-0000000110a1');
set role authenticated;
select fabula.trade_approve(:'app2'::uuid, null) ta2 \gset
reset role;
select set_config('request.jwt.claims', '', false);
select pg_temp.ck('a new customer is created from the request, without the Shopify id of the form',
  (select legal_name = 'Nuova Trattoria' and piva = '07777777777' and shopify_customer_id is null from fabula.parties where id = (:'ta2'::jsonb ->> 'party_id')::uuid)
  and jsonb_array_length(:'ta2'::jsonb -> 'differences') = 0, :'ta2');

-- ---------------------------------------------------------------- 9. the Shopify order queue: one run per row (item 6)
insert into fabula.sales_orders (id, order_number, customer_id, channel, order_date, source) values ('51000000-0000-4000-a000-000000000110', 'T110', '50000000-0000-4000-a000-000000000110', 'wholesale', current_date + 3, 'trade');
insert into fabula.trade_order_queue (id, sales_order_id, customer_id, delivery_date, payload) values
  ('52000000-0000-4000-a000-000000000110', '51000000-0000-4000-a000-000000000110', '50000000-0000-4000-a000-000000000110', current_date + 3, '{"order_number":"T110","lines":[]}');
select fabula.trade_queue_claim() q1 \gset
select fabula.trade_queue_claim() q2 \gset
select pg_temp.ck('the first run takes the row', :'q1'::jsonb @> '[{"id":"52000000-0000-4000-a000-000000000110"}]', left(:'q1', 120));
select pg_temp.ck('…a second run at the same time («Invia ora» during the 18:25 run) does not get it', not (:'q2'::jsonb @> '[{"id":"52000000-0000-4000-a000-000000000110"}]'), left(:'q2', 120));
update fabula.trade_order_queue set claimed_at = now() - interval '11 minutes' where id = '52000000-0000-4000-a000-000000000110';
select pg_temp.ck('…a claim left by a run that stopped is taken again after 10 minutes', fabula.trade_queue_claim() @> '[{"id":"52000000-0000-4000-a000-000000000110"}]');
select fabula.trade_queue_result('52000000-0000-4000-a000-000000000110', false, null, null, null, 'prova') x \gset
select pg_temp.ck('…a failed attempt frees it for the next run', (select claimed_at is null and status = 'pending' from fabula.trade_order_queue where id = '52000000-0000-4000-a000-000000000110'));
select pg_temp.ck('trade_queue_claim is for the server function only', not has_function_privilege('authenticated', 'fabula.trade_queue_claim()', 'execute')
  and not has_function_privilege('anon', 'fabula.trade_queue_claim()', 'execute'));

-- ---------------------------------------------------------------- 10. the weekly plan: confirmed deliveries, windows (item 7)
select id moz from fabula.products where sku = 'MOZ-DOP-KG' \gset
insert into fabula.trade_products (variant_id, product_id, title, variant_title, kg_per_unit, unit_label, trade_price_eur, min_qty, step_qty)
values ('gid://v110/1', :'moz', 'Mozzarella', 'v110', 1, 'kg', 11.5, 1, 1) on conflict do nothing;
insert into fabula.parties (id, type, legal_name, active, trade_status) values ('50000000-0000-4000-a000-000000000111', 'customer', 'Pizzeria Piano', true, 'approved');
insert into fabula.trade_schedules (customer_id, status, start_date) values ('50000000-0000-4000-a000-000000000111', 'active', current_date - 7);
insert into fabula.trade_schedule_days (customer_id, weekday, active) select '50000000-0000-4000-a000-000000000111', w, true from generate_series(1, 6) w;
insert into fabula.trade_schedule_lines (customer_id, weekday, variant_id, qty) select '50000000-0000-4000-a000-000000000111', w, 'gid://v110/1', 20 from generate_series(1, 6) w;
-- the cut-off moved to midnight: tomorrow is already confirmed, the day after can still change
update fabula.settings set value = '00:00' where key = 'trade.cutoff_time';
select d tom from (select g::date d from generate_series(fabula.trade_now_rome()::date + 1, fabula.trade_now_rome()::date + 8, interval '1 day') g
                    where fabula.trade_is_delivery_day(g::date) and not fabula.trade_can_change(g::date) order by g limit 1) x \gset
select extract(isodow from :'tom'::date)::int wd \gset
select pg_temp.err(format($q$select fabula.trade_save_schedule('50000000-0000-4000-a000-000000000111', '{"start_date":"%s","days":{"%s":{"lines":{"gid://v110/1":140}}}}'::jsonb, 'customer')$q$, :'tom', :'wd')) w1 \gset
select pg_temp.ck('a customer''s new plan cannot change a delivery already confirmed (20 → 140 kg after the cut-off)', :'w1' ilike '%già chiusi%fai partire il piano dal%', :'w1');
select pg_temp.ck('…the plan is untouched', (select qty from fabula.trade_schedule_lines where customer_id = '50000000-0000-4000-a000-000000000111' and weekday = :wd) = 20);
select pg_temp.err(format($q$select fabula.trade_save_schedule('50000000-0000-4000-a000-000000000111', '{"start_date":"%s","days":{"%s":{"lines":{"gid://v110/1":20}},"%s":{"lines":{"gid://v110/1":30}}}}'::jsonb, 'customer')$q$,
  :'tom', :'wd', case when :wd = 6 then 1 else :wd + 1 end)) w2 \gset
select pg_temp.ck('…a plan that keeps the confirmed day as it is still saves', :'w2' = '', :'w2');
update fabula.trade_schedules set status = 'paused' where customer_id = '50000000-0000-4000-a000-000000000111';
select pg_temp.err(format($q$select fabula.trade_save_schedule('50000000-0000-4000-a000-000000000111', '{"start_date":"%s","days":{"%s":{"lines":{"gid://v110/1":90}}}}'::jsonb, 'customer')$q$, :'tom', :'wd')) w2b \gset
select pg_temp.ck('review L1: a paused plan saved after the cut-off is not refused (it stays paused, no delivery changes)', :'w2b' = '', :'w2b');
update fabula.trade_schedules set status = 'active' where customer_id = '50000000-0000-4000-a000-000000000111';
select pg_temp.err(format($q$select fabula.trade_save_schedule('50000000-0000-4000-a000-000000000111', '{"window":"05:00-06:00","days":{"%s":{"lines":{"gid://v110/1":20}}}}'::jsonb, 'staff')$q$, :'wd')) w3 \gset
select pg_temp.err(format($q$select fabula.trade_save_schedule('50000000-0000-4000-a000-000000000111', '{"days":{"%s":{"window":"23:00-24:00","lines":{"gid://v110/1":20}}}}'::jsonb, 'staff')$q$, :'wd')) w4 \gset
select pg_temp.ck('a delivery window that is not offered is refused (plan and day)', :'w3' ilike '%Fascia oraria non prevista: 05:00-06:00%' and :'w4' ilike '%Fascia oraria non prevista: 23:00-24:00%', :'w3' || ' / ' || :'w4');
select pg_temp.err(format($q$select fabula.trade_save_schedule('50000000-0000-4000-a000-000000000111', '{"window":"07:00-09:00","days":{"%s":{"window":"09:00-11:00","lines":{"gid://v110/1":20}}}}'::jsonb, 'staff')$q$, :'wd')) w5 \gset
select pg_temp.ck('…the windows offered still save', :'w5' = '', :'w5');
update fabula.settings set value = '18:00' where key = 'trade.cutoff_time';

-- ---------------------------------------------------------------- 11. Telegram text
select pg_temp.ck('«Se ne occupa» escapes the name with tg_esc («&» too)',
  (select prosrc from pg_proc where oid = 'fabula.notify_ack(bigint,uuid,text)'::regprocedure) like '%fabula.tg_esc(v_name)%');

-- ---------------------------------------------------------------- 12. security scan
select pg_temp.ck('no new finding without a reason', not exists (select 1 from fabula.security_findings() f where not exists (select 1 from fabula.security_accepted a where a.key = f.key)),
  (select string_agg(f.key, ', ') from fabula.security_findings() f where not exists (select 1 from fabula.security_accepted a where a.key = f.key)));
