-- v0.99 audit office decisions and undo (D-24, E-12, E-11, B-12, B-09, B-11, E-10, B-13, B-18, B-19, B-15, B-06, B-22/23) · run on a fresh replay:
--   tools/go-live/drill/infra-test/replay.sh o_test
--   su postgres -c "psql -d o_test -f tools/go-live/drill/prod-test/test_audit_office.sql" | grep -E "PASS|FAIL"
\set ON_ERROR_STOP 0
create or replace function pg_temp.ck(p_name text, p_ok boolean, p_info text default '') returns text language sql as
$$ select case when coalesce(p_ok, false) then 'PASS ' else 'FAIL ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end $$;
create or replace function pg_temp.err(p_sql text) returns text language plpgsql as
$$ declare h text; begin execute p_sql; return ''; exception when others then get stacked diagnostics h = pg_exception_hint; return sqlerrm || case when coalesce(h, '') <> '' then ' || hint: ' || h else '' end; end $$;
create or replace function pg_temp.st(p_sql text) returns text language plpgsql as
$$ begin execute p_sql; return ''; exception when others then return sqlstate; end $$;
create or replace function pg_temp.as_user(p_sub text) returns void language sql as
$$ select set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', p_sub), false) $$;
create or replace function pg_temp.rome() returns date language sql as $$ select (now() at time zone 'Europe/Rome')::date $$;
-- the n-th working day (not Sunday) from tomorrow
create or replace function pg_temp.wday(n int) returns date language sql as
$$ select g::date from generate_series(pg_temp.rome() + 1, pg_temp.rome() + 30, interval '1 day') g where extract(isodow from g) <> 7 order by g offset n - 1 limit 1 $$;
select id moz from fabula.products where sku = 'MOZ-DOP-KG' \gset
select id rennet from fabula.products where sku = 'CON-RENNET' \gset
insert into fabula.app_roles (code, name_it, home) values ('acq2_test', 'Acquisti (registra)', 'console') on conflict do nothing;
insert into fabula.role_permissions (role_code, area, level) values ('acq2_test', 'acquisti', 2) on conflict do nothing;
insert into fabula.staff (id, full_name, role, app_role, active, auth_user_id) values
  ('10000000-0000-4000-a000-0000000099a1', 'Titolare O', 'owner', 'titolare', true, '00000000-0000-4000-a000-0000000099a1'),
  ('10000000-0000-4000-a000-0000000099a2', 'Casaro O', 'casaro', 'produzione', true, '00000000-0000-4000-a000-0000000099a2'),
  ('10000000-0000-4000-a000-0000000099a3', 'Marketing O', 'operaio', 'marketing', true, '00000000-0000-4000-a000-0000000099a3'),
  ('10000000-0000-4000-a000-0000000099a4', 'Acquisti O', 'operaio', 'acq2_test', true, '00000000-0000-4000-a000-0000000099a4')
on conflict do nothing;
update fabula.settings set value = '1200' where key = 'milk.capacity_kg';
update fabula.settings set value = '150' where key = 'approve.auto_po_max_eur';
delete from fabula.milk_plans where plan_date between pg_temp.rome() and pg_temp.rome() + 30;
select pg_temp.wday(1) d1, pg_temp.wday(2) d2, pg_temp.wday(3) d3, pg_temp.wday(4) d4 \gset

-- ============================== B-09 / FIX · a milk plan decided in the Console reaches the farm ==============================
select (fabula.plan_milk(:'d1'::date)) ->> 'approval_id' a1 \gset
select fabula.plan_milk(:'d2'::date) pm2 \gset
select :'pm2'::jsonb ->> 'approval_id' a2 \gset
select pg_temp.ck('B-09 the milk proposal carries its warnings for the card', (select payload ? 'capacity_hit' and payload ? 'exceeds_farm_supply' and payload ? 'min_run_applied' and payload ? 'farm_kg_available' from fabula.approvals where id = :'a1'));
select pg_temp.ck('E-10 plan_milk says when it approves itself (field present, null when no rule applies)', :'pm2'::jsonb ? 'auto_approve_at', :'pm2');
-- a browser no longer updates approvals itself (review 13/10: it could skip the notes and sign as someone else) …
select pg_temp.as_user('00000000-0000-4000-a000-0000000099a1');
set role authenticated;
select pg_temp.err(format($q$update fabula.approvals set status = 'approved', decided_by = 'Titolare O', decided_at = now() where id = '%s'$q$, :'a2')) e_f0 \gset
reset role;
select pg_temp.ck('D-24 a logged-in browser cannot update an approval directly (only through decide/revoke)', :'e_f0' like 'permission denied for table approvals%', :'e_f0');
-- … and any update that still happens (bots, service role) reaches the milk plan: the sync trigger no longer runs with the caller's rights
select set_config('request.jwt.claims', '', false);
set role service_role;
select pg_temp.err(format($q$update fabula.approvals set status = 'approved', decided_by = 'Bot', decided_at = now() where id = '%s'$q$, :'a2')) e_f1 \gset
reset role;
select pg_temp.ck('FIX an approval reaches milk_plans whoever updates it (it stayed «proposed»: the trigger ran as the user)',
  :'e_f1' = '' and (select status from fabula.milk_plans where approval_id = :'a2') = 'approved', :'e_f1' || ' ' || coalesce((select status from fabula.milk_plans where approval_id = :'a2'), '?'));
-- decide_approval: the profile, «Approva con … kg», the capacity, the farm
select pg_temp.as_user('00000000-0000-4000-a000-0000000099a2');
set role authenticated;
select pg_temp.err(format($q$select fabula.decide_approval('%s', 'approved')$q$, :'a1')) e_m1 \gset
reset role;
select pg_temp.ck('B-12 a profile that only «registra» in Produzione cannot decide a milk plan', :'e_m1' like 'Il tuo profilo vede questa richiesta ma non la decide: serve «gestisce» in produzione%', :'e_m1');
select pg_temp.as_user('00000000-0000-4000-a000-0000000099a1');
set role authenticated;
select pg_temp.err(format($q$select fabula.decide_approval('%s', 'approved', null, 99999)$q$, :'a1')) e_m2 \gset
select pg_temp.err(format($q$select fabula.decide_approval('%s', 'rejected', null, 700)$q$, :'a1')) e_m3 \gset
select pg_temp.err(format($q$select fabula.decide_approval('%s', 'approved', 'meno latte', 700)$q$, :'a1')) e_m4 \gset
reset role;
select pg_temp.ck('B-09 99999 kg is refused: more than the dairy can take', :'e_m2' like '99999 kg sono più della capacità del caseificio (1200 kg al giorno)%', :'e_m2');
select pg_temp.ck('B-09 kg are changed only when approving', :'e_m3' like 'I kg si cambiano solo approvando%', :'e_m3');
select pg_temp.ck('B-09 «Approva con 700 kg»: the plan, its output and cost follow, and the note says it',
  :'e_m4' = '' and (select status = 'approved' and milk_kg = 700 and planned_output_kg = round(700 * yield_pct_used / 100, 1) and details ? 'original_milk_kg' from fabula.milk_plans where approval_id = :'a1')
  and (select (payload->>'milk_kg')::numeric = 700 and amount_eur = (select est_cost_eur from fabula.milk_plans where approval_id = :'a1') and decision_note like 'approvato con 700 kg invece di%' and decided_by = 'Titolare O' from fabula.approvals where id = :'a1'), :'e_m4');
select pg_temp.ck('B-12 every decision is in the history, signed by the login', (select jsonb_array_length(history) = 1 and history->0->>'to' = 'approved' and history->0->>'by' = 'Titolare O' from fabula.approvals where id = :'a1'));
-- D-24: decided stays decided
set role service_role;
select pg_temp.err(format($q$update fabula.approvals set status = 'rejected' where id = '%s'$q$, :'a1')) e_d1 \gset
select pg_temp.err(format($q$update fabula.approvals set decided_by = 'Consulente finto', decision_note = 'ok' where id = '%s'$q$, :'a1')) e_d3 \gset
select pg_temp.err(format($q$update fabula.approvals set history = '[]', summary = summary where id = '%s'$q$, :'a1')) e_d4 \gset
reset role;
select pg_temp.as_user('00000000-0000-4000-a000-0000000099a1');
set role authenticated;
select pg_temp.err(format($q$select fabula.decide_approval('%s', 'rejected', 'ripensato')$q$, :'a1')) e_d2 \gset
reset role;
select pg_temp.ck('D-24 a decided request cannot be decided again, not even by a plain update (service role)', :'e_d1' like 'Richiesta già decisa il % da Titolare O: per cambiare idea usa «Annulla»%', :'e_d1');
select pg_temp.ck('D-24 …nor re-signed: who decided and why stay as recorded', :'e_d3' like 'Una decisione registrata non si riscrive%'
  and (select decided_by from fabula.approvals where id = :'a1') = 'Titolare O', :'e_d3');
select pg_temp.ck('D-24 …and the history cannot be wiped', :'e_d4' = '' and (select jsonb_array_length(history) from fabula.approvals where id = :'a1') = 1, :'e_d4');
select pg_temp.ck('D-24 …and decide_approval says so', :'e_d2' like 'Richiesta già approvata da Titolare O%', :'e_d2');
-- «Annulla» while the Masseria has not seen it
select pg_temp.ck('B-12 v_approvals_recent lists it, undoable', (select undo_block is null and milk->>'status' = 'approved' from fabula.v_approvals_recent where id = :'a1'));
select pg_temp.as_user('00000000-0000-4000-a000-0000000099a1');
set role authenticated;
select pg_temp.err(format($q$select fabula.revoke_approval('%s', 'sbagliato giorno')$q$, :'a1')) e_u1 \gset
reset role;
select pg_temp.ck('E-10/B-12 «Annulla»: back to «da decidere», the plan back to proposed (off the farm page), no automatic approval any more',
  :'e_u1' = '' and (select status = 'pending' and decided_at is null and auto_approve_at is null and auto_rule like 'decisione annullata da Titolare O%' and jsonb_array_length(history) = 2
                      and history->1->>'to' = 'pending' and history->1->>'note' like 'annullata: sbagliato giorno' from fabula.approvals where id = :'a1')
  and (select status from fabula.milk_plans where approval_id = :'a1') = 'proposed', :'e_u1');
-- after the Masseria has seen it, no undo
select pg_temp.as_user('00000000-0000-4000-a000-0000000099a1');
set role authenticated;
select pg_temp.err(format($q$select fabula.decide_approval('%s', 'approved')$q$, :'a1')) e_u2 \gset
reset role;
update fabula.milk_plans set farm_seen_at = now() where approval_id = :'a1';
select pg_temp.as_user('00000000-0000-4000-a000-0000000099a1');
set role authenticated;
select pg_temp.err(format($q$select fabula.revoke_approval('%s')$q$, :'a1')) e_u3 \gset
reset role;
select pg_temp.ck('B-12 once the Masseria has seen the order, «Annulla» says to call her', :'e_u2' = '' and :'e_u3' like 'Non si annulla: la Masseria l''ha già visto % alle %: per cambiarlo chiamala', :'e_u2' || ' / ' || :'e_u3');
-- more than the farm has: asked
insert into fabula.farm_supply (supply_date, kg_available) values (:'d3', 500) on conflict (supply_date) do update set kg_available = 500;
select (fabula.plan_milk(:'d3'::date)) ->> 'approval_id' a3 \gset
select pg_temp.as_user('00000000-0000-4000-a000-0000000099a1');
set role authenticated;
select pg_temp.err(format($q$select fabula.decide_approval('%s', 'approved', null, 800)$q$, :'a3')) e_f2 \gset
select pg_temp.err(format($q$select fabula.decide_approval('%s', 'approved', null, 800, true)$q$, :'a3')) e_f3 \gset
reset role;
select pg_temp.ck('B-09 more milk than the Masseria has asks first (HINT confirm), then goes through', :'e_f2' like 'La Masseria ha 500 kg disponibili per % ne chiedi 800%Confermi? || hint: confirm' and :'e_f3' = ''
  and (select milk_kg from fabula.milk_plans where approval_id = :'a3') = 800, :'e_f2' || ' / ' || :'e_f3');

-- ============================== E-12 / E-11 · deadlines every 10 minutes, and what they mean ==============================
select (fabula.plan_milk(:'d4'::date)) ->> 'approval_id' a4 \gset
update fabula.approvals set expires_at = now() - interval '1 minute', auto_approve_at = null where id = :'a4';
select pg_temp.as_user('00000000-0000-4000-a000-0000000099a1');
set role authenticated;
select pg_temp.err(format($q$select fabula.decide_approval('%s', 'approved')$q$, :'a4')) e_e1 \gset
reset role;
select pg_temp.ck('E-12 past its deadline it can no longer be approved', :'e_e1' like 'Richiesta scaduta % alle %: non si può più approvare. Se serve latte usa «Ordina di nuovo»%', :'e_e1');
select (fabula.auto_approve_due()) ->> 'expired' n_exp \gset
select pg_temp.ck('E-12 the 10-minute job expires it (not only the evening check)', :'n_exp'::int >= 1
  and (select status = 'expired' and decided_by = 'Scadenza' and decided_at is not null from fabula.approvals where id = :'a4')
  and (select status from fabula.milk_plans where approval_id = :'a4') = 'rejected', :'n_exp');
select pg_temp.ck('E-11 «Scaduta senza decisione» says no milk is ordered, and it is pushed as a decision',
  exists (select 1 from fabula.bot_messages where agent = 'auto_approve' and severity = 'warn' and title like 'Scaduta senza decisione%' and body like '%Nessun ordine di latte per%')
  and exists (select 1 from fabula.notify_outbox where topic = 'decisions' and dedupe_key = 'exp:' || :'a4'));
select pg_temp.ck('E-11 …and ops_health_check still runs (it uses the same expiry)', pg_temp.err($q$select fabula.ops_health_check()$q$) = '');
-- order again after the expiry
select pg_temp.as_user('00000000-0000-4000-a000-0000000099a1');
set role authenticated;
select pg_temp.err(format($q$select fabula.milk_order_again('%s', 600, 'ordinato al telefono')$q$, :'d4')) e_o1 \gset
select pg_temp.err(format($q$select fabula.milk_order_again('%s', 600)$q$, :'d4')) e_o2 \gset
select pg_temp.err(format($q$select fabula.milk_order_again('%s')$q$, pg_temp.rome() - 1)) e_o3 \gset
select pg_temp.err(format($q$select fabula.milk_order_again('%s')$q$, (select g::date from generate_series(pg_temp.rome() + 1, pg_temp.rome() + 8, interval '1 day') g where extract(isodow from g) = 7 limit 1))) e_o4 \gset
reset role;
select pg_temp.ck('B-09 after an expiry «Ordina 600 kg» makes the plan and approves it at once', :'e_o1' = ''
  and exists (select 1 from fabula.milk_plans where plan_date = :'d4' and status = 'approved' and milk_kg = 600), :'e_o1');
select pg_temp.ck('B-09 …a second order for the same day is refused; yesterday and Sunday too',
  :'e_o2' like 'C''è già un piano latte per%' and :'e_o3' like 'Per % è tardi%' and :'e_o4' = 'La domenica non si lavora', :'e_o2' || ' / ' || :'e_o3' || ' / ' || :'e_o4');
select pg_temp.ck('B-09 the expired one now says another plan exists (no second «Ordina»)', (select (milk->>'other_active')::boolean from fabula.v_approvals_recent where id = :'a4'));

-- ============================== E-10 · an automatic approval is pushed, undoable; its posts wait for a person ==============================
insert into fabula.approvals (kind, requested_by, summary, payload, related_table, amount_eur, expires_at)
values ('price_change', 'agent:sell_down', 'Promo -30% su Mozzarella lotto L-PROMO', jsonb_build_object('type', 'sell_down', 'sku', 'MOZ-DOP-KG', 'lot', 'L-PROMO', 'at_risk_kg', 8,
        'on_hand_kg', 10, 'expiry', pg_temp.rome() + 1, 'promo_pct', 30, 'list_price_eur_kg', 16.8, 'promo_price_eur_kg', 11.76, 'action', 'promo_banco'),
        'stock_moves', 40, ((pg_temp.rome()::timestamp + time '23:59') at time zone 'Europe/Rome')) returning id ap \gset
update fabula.approvals set auto_approve_at = now() - interval '1 minute' where id = :'ap';
select fabula.auto_approve_due() aad \gset
select pg_temp.ck('E-10 the promo approves itself after its delay', (select status = 'approved' and decided_by = 'Approvazione automatica' from fabula.approvals where id = :'ap'), :'aad');
select pg_temp.ck('E-10 …a «warn» line pushed on Telegram (decisions, nothing to take charge of) with how to undo it',
  exists (select 1 from fabula.bot_messages where agent = 'auto_approve' and severity = 'warn' and title like 'Approvato da solo · Promo%' and body like '%Decise di recente%' and body like '%Configurazione → Parametri → Approvazioni automatiche%' and body not like '%approve.*%')
  and exists (select 1 from fabula.notify_outbox where topic = 'decisions' and dedupe_key = 'aa:' || :'ap' and escalate_at is null));
select pg_temp.ck('E-10 the two posts of an auto-approved promo wait for a person (review, with their own card)',
  (select count(*) = 2 from fabula.mkt_content where brief_it like 'Promo scorte lotto L-PROMO, approvata automaticamente%' and status = 'review' and approved_by is null and scheduled_at > now())
  and (select count(*) = 2 from fabula.approvals where payload->>'type' = 'content_post' and status = 'pending'
         and payload->>'content_id' in (select jsonb_array_elements_text(payload->'posts') from fabula.approvals where id = :'ap')));
select pg_temp.as_user('00000000-0000-4000-a000-0000000099a1');
set role authenticated;
select pg_temp.err(format($q$select fabula.revoke_approval('%s')$q$, :'ap')) e_p1 \gset
reset role;
select pg_temp.ck('E-10 «Annulla» on the promo: pending again, its posts and their cards withdrawn',
  :'e_p1' = '' and (select status = 'pending' and not payload ? 'posts' from fabula.approvals where id = :'ap')
  and not exists (select 1 from fabula.mkt_content where brief_it like 'Promo scorte lotto L-PROMO%' and status <> 'rejected')
  and not exists (select 1 from fabula.approvals a join fabula.mkt_content c on c.id::text = a.payload->>'content_id' where c.brief_it like 'Promo scorte lotto L-PROMO%' and a.status = 'pending'), :'e_p1');
select pg_temp.as_user('00000000-0000-4000-a000-0000000099a1');
set role authenticated;
select pg_temp.err(format($q$select fabula.decide_approval('%s', 'approved')$q$, :'ap')) e_p2 \gset
reset role;
select pg_temp.ck('E-10 approved by a person, the posts are written again, approved and signed',
  :'e_p2' = '' and (select count(*) = 2 from fabula.mkt_content where brief_it like 'Promo scorte lotto L-PROMO, approvata da Titolare O%' and status = 'approved' and approved_by = 'Titolare O'), :'e_p2');

-- ============================== B-13 · a post edited while it waits refreshes its card; «Annulla» never doubles it ==============================
insert into fabula.mkt_content (platform, format, pillar, status, scheduled_at, brief_it, caption_it) values ('instagram', 'post', 'origine', 'review', now() + interval '2 days', 'test B-13', 'Testo vecchio') returning id as mc, approval_id as mca \gset
update fabula.mkt_content set caption_it = 'Testo nuovo con prezzo 12 €', hashtags = '#bufala' where id = :'mc';
select pg_temp.ck('B-13 the card shows the text as it is now (caption, hashtags, edited mark)',
  (select payload->>'caption_it' = 'Testo nuovo con prezzo 12 €' and payload->>'hashtags' = '#bufala' and payload ? 'edited_at' and summary like '%Testo nuovo%' from fabula.approvals where id = :'mca'));
select pg_temp.as_user('00000000-0000-4000-a000-0000000099a3');
set role authenticated;
select pg_temp.err(format($q$select fabula.decide_approval('%s', 'approved')$q$, :'mca')) e_c1 \gset
select pg_temp.err(format($q$select fabula.revoke_approval('%s')$q$, :'mca')) e_c2 \gset
reset role;
select pg_temp.ck('B-13 approved, then undone: the post is back in review with the same card (no second one)',
  :'e_c1' = '' and :'e_c2' = '' and (select status from fabula.mkt_content where id = :'mc') = 'review'
  and (select count(*) from fabula.approvals where payload->>'content_id' = :'mc') = 1 and (select status from fabula.approvals where id = :'mca') = 'pending', :'e_c1' || ' / ' || :'e_c2');

-- ============================== B-11 · DOP: approve the figures, then mark it sent ==============================
insert into fabula.approvals (kind, requested_by, summary, payload, related_table)
values ('dop_declaration', 'agent:monthly_review', 'Dichiarazione Consorzio test',
        jsonb_build_object('month', to_char(date_trunc('month', pg_temp.rome()) - interval '1 month', 'YYYY-MM'), 'mozzarella_dop_kg', 100,
                           'issues', jsonb_build_array(jsonb_build_object('check', 'latte_60h', 'it', 'Latte oltre 60 h', 'n', 1))), 'consorzio') returning id dop \gset
insert into fabula.task_instances (schedule_id, due_at, status)
select id, (date_trunc('month', pg_temp.rome())::date::timestamp + time '10:00') at time zone 'Europe/Rome', 'due' from fabula.task_schedules where code = 'T-DOP' returning id tdop \gset
select pg_temp.as_user('00000000-0000-4000-a000-0000000099a1');
set role authenticated;
select pg_temp.err(format($q$select fabula.decide_approval('%s', 'approved')$q$, :'dop')) e_g1 \gset
select pg_temp.err(format($q$select fabula.decide_approval('%s', 'approved', 'Visti: Latte oltre 60 h · lotto rifatto')$q$, :'dop')) e_g2 \gset
reset role;
select pg_temp.ck('B-11 with a check to look at, approving needs the note', :'e_g1' like 'Ci sono 1 controlli del disciplinare da vedere%', :'e_g1');
select pg_temp.ck('B-11 approving the figures does not close the monthly task', :'e_g2' = '' and (select status::text from fabula.task_instances where id = :'tdop') = 'due', :'e_g2');
select pg_temp.ck('B-11 an approved declaration not yet sent stays in sight', exists (select 1 from fabula.v_approvals_recent where id = :'dop' and undo_block is null));
select pg_temp.as_user('00000000-0000-4000-a000-0000000099a1');
set role authenticated;
select pg_temp.err(format($q$select fabula.dop_declaration_sent('%s', '%s')$q$, :'dop', pg_temp.rome() + 1)) e_g3 \gset
select pg_temp.err(format($q$select fabula.dop_declaration_sent('%s', '%s', null, 'PEC')$q$, :'dop', date_trunc('month', pg_temp.rome())::date - 3)) e_g4 \gset
select pg_temp.err(format($q$select fabula.dop_declaration_sent('%s', '%s')$q$, :'dop', pg_temp.rome())) e_g5 \gset
select pg_temp.err(format($q$select fabula.dop_declaration_sent('%s', '%s', '2026/77')$q$, :'dop', pg_temp.rome())) e_g6 \gset
select pg_temp.err(format($q$select fabula.revoke_approval('%s')$q$, :'dop')) e_g7 \gset
reset role;
select pg_temp.ck('B-11 a send date in the future, or inside the month itself, is refused; protocol or how it was sent is required',
  :'e_g3' = 'Data di invio: oggi o un giorno passato' and :'e_g4' like 'La dichiarazione di % si invia dal %' and :'e_g5' like 'Scrivi il numero di protocollo%', :'e_g3' || ' / ' || :'e_g4' || ' / ' || :'e_g5');
select pg_temp.ck('B-11 «Segna inviata» records it and closes the monthly task', :'e_g6' = ''
  and (select payload->>'protocol' = '2026/77' and payload->>'sent_by' = 'Titolare O' from fabula.approvals where id = :'dop')
  and (select status::text from fabula.task_instances where id = :'tdop') = 'done', :'e_g6');
select pg_temp.ck('B-11 once sent it no longer undoes, and leaves the «to send» list', :'e_g7' like 'Non si annulla: già segnata come inviata%'
  and not exists (select 1 from fabula.v_approvals_recent where id = :'dop' and status = 'approved' and not (payload ? 'sent_at')), :'e_g7');

-- ============================== B-18 · catalogue orders ==============================
insert into fabula.parties (id, type, legal_name, email, active) values ('50000000-0000-4000-a000-0000000099f1', 'supplier', 'Fornitore O', 'f@o.it', true) on conflict do nothing;
insert into fabula.supplier_prices (supplier_id, product_id, price_eur, valid_from) values ('50000000-0000-4000-a000-0000000099f1', :'rennet', 25, pg_temp.rome() - 10);
select id salt from fabula.products where sku = 'CON-SALT' \gset
select pg_temp.as_user('00000000-0000-4000-a000-0000000099a1');
set role authenticated;
select pg_temp.err(format($q$select fabula.create_manual_po('50000000-0000-4000-a000-0000000099f1', '[{"product_id":"%s","qty":2}]')$q$, :'rennet')) e_b1 \gset
select fabula.create_manual_po('50000000-0000-4000-a000-0000000099f1', format('[{"product_id":"%s","qty":2}]', :'rennet')::jsonb) po1 \gset
select fabula.create_manual_po('50000000-0000-4000-a000-0000000099f1', format('[{"product_id":"%s","qty":40}]', :'rennet')::jsonb) po2 \gset
select pg_temp.err(format($q$select fabula.create_manual_po('50000000-0000-4000-a000-0000000099f1', '[{"product_id":"%s","qty":5}]')$q$, :'salt')) e_b3 \gset
select fabula.create_manual_po('50000000-0000-4000-a000-0000000099f1', format('[{"product_id":"%s","qty":5,"price_tbc":true}]', :'salt')::jsonb) po3 \gset
reset role;
select pg_temp.ck('B-18 under the limit, from «gestisce»: approved, with its creator', :'po1'::jsonb->>'status' = 'approved'
  and (select created_by_id = '10000000-0000-4000-a000-0000000099a1' from fabula.purchase_orders where po_number = :'po1'::jsonb->>'po_number'), :'po1');
select pg_temp.ck('B-18 above the limit (€ 1.000 > € 150): waits for approval, one card with every line, never automatic',
  :'po2'::jsonb->>'status' = 'pending_approval' and (select status::text from fabula.purchase_orders where po_number = :'po2'::jsonb->>'po_number') = 'pending_approval'
  and (select jsonb_array_length(payload->'lines') = 1 and (payload->>'over_limit')::boolean and requested_by = 'Titolare O' and auto_approve_at is null
         and fabula.auto_approve_rule(a) is null from fabula.approvals a where id = (:'po2'::jsonb->>'approval_id')::uuid), :'po2');
select pg_temp.ck('B-18 a line without a price is refused unless «prezzo da confermare»', :'e_b3' like '%manca il prezzo di Fornitore O%prezzo da confermare%'
  and (:'po3'::jsonb->>'price_missing')::int = 1, :'e_b3');
select pg_temp.ck('B-18 (review) an order with a price to confirm always waits for a person: its real total is unknown',
  :'po3'::jsonb->>'status' = 'pending_approval' and (select (payload->>'price_missing')::boolean from fabula.approvals where id = (:'po3'::jsonb->>'approval_id')::uuid), :'po3');
select pg_temp.as_user('00000000-0000-4000-a000-0000000099a1');
set role authenticated;
select fabula.create_manual_po('50000000-0000-4000-a000-0000000099f1', format('[{"product_id":"%s","qty":2,"price_eur":-1900}]', :'rennet')::jsonb) po6 \gset
reset role;
select pg_temp.ck('B-18 (review) a price sent by the browser is ignored: the supplier list decides (€ 25 × 2)', :'po6'::jsonb->>'status' = 'approved'
  and (select subtotal_eur = 50 from fabula.purchase_orders where po_number = :'po6'::jsonb->>'po_number'), :'po6');
update fabula.purchase_orders set status = 'cancelled', cancel_reason = 'test' where po_number = :'po6'::jsonb->>'po_number';
select pg_temp.as_user('00000000-0000-4000-a000-0000000099a4');
set role authenticated;
select fabula.create_manual_po('50000000-0000-4000-a000-0000000099f1', format('[{"product_id":"%s","qty":1}]', :'rennet')::jsonb) po4 \gset
reset role;
select pg_temp.ck('B-18 a «registra» profile places it, a person with «gestisce» approves it (even € 25)', :'po4'::jsonb->>'status' = 'pending_approval', :'po4');
-- approve, undo, reject through the card
select pg_temp.as_user('00000000-0000-4000-a000-0000000099a1');
set role authenticated;
select pg_temp.err(format($q$select fabula.decide_approval('%s', 'approved')$q$, :'po2'::jsonb->>'approval_id')) e_b4 \gset
select status::text s_b4 from fabula.purchase_orders where po_number = :'po2'::jsonb->>'po_number' \gset
select pg_temp.err(format($q$select fabula.revoke_approval('%s')$q$, :'po2'::jsonb->>'approval_id')) e_b5 \gset
select status::text s_b5 from fabula.purchase_orders where po_number = :'po2'::jsonb->>'po_number' \gset
select pg_temp.err(format($q$select fabula.decide_approval('%s', 'rejected')$q$, :'po2'::jsonb->>'approval_id')) e_b6 \gset
reset role;
select pg_temp.ck('B-12 an order approved, undone (back to waiting), rejected (cancelled)', :'e_b4' = '' and :'s_b4' = 'approved' and :'e_b5' = '' and :'s_b5' = 'pending_approval'
  and :'e_b6' = '' and (select status::text from fabula.purchase_orders where po_number = :'po2'::jsonb->>'po_number') = 'cancelled', concat_ws(' / ', :'e_b4', :'s_b4', :'e_b5', :'s_b5', :'e_b6'));
select undo_block ub2 from fabula.v_approvals_recent where id = (:'po2'::jsonb->>'approval_id')::uuid \gset
select pg_temp.ck('B-12 (review) a rejected order is not brought back when a newer order for the same items exists (no double order)',
  :'ub2' like 'c''è già un ordine più recente per gli stessi articoli (' || (:'po4'::jsonb->>'po_number') || ')%', :'ub2');
-- cancel_po
update fabula.purchase_orders set status = 'sent', sent_at = now() where po_number = :'po3'::jsonb->>'po_number';
select pg_temp.as_user('00000000-0000-4000-a000-0000000099a4');
set role authenticated;
select pg_temp.err(format($q$select fabula.cancel_po('%s', 'x')$q$, :'po1'::jsonb->>'po_number')) e_x1 \gset
select fabula.cancel_po(:'po1'::jsonb->>'po_number', 'quantità sbagliata') x2 \gset
select fabula.cancel_po(:'po3'::jsonb->>'po_number', 'rifatto con un altro fornitore') x3 \gset
select pg_temp.err(format($q$select fabula.cancel_po('%s', 'ancora')$q$, :'po4'::jsonb->>'po_number')) e_x4 \gset
reset role;
select undo_block ub4 from fabula.v_approvals_recent where id = (:'po4'::jsonb->>'approval_id')::uuid \gset
update fabula.purchase_orders set status = 'received' where po_number = :'po4'::jsonb->>'po_number';
select pg_temp.as_user('00000000-0000-4000-a000-0000000099a4');
set role authenticated;
select pg_temp.err(format($q$select fabula.cancel_po('%s', 'ancora')$q$, :'po4'::jsonb->>'po_number')) e_x5 \gset
reset role;
select pg_temp.ck('B-18 «Annulla ordine» needs a reason; an approved order is cancelled with who and why', :'e_x1' like 'Scrivi perché annulli%'
  and (select status = 'cancelled' and cancel_reason = 'quantità sbagliata' and cancelled_by_id = '10000000-0000-4000-a000-0000000099a4' from fabula.purchase_orders where po_number = :'po1'::jsonb->>'po_number'), :'e_x1');
select pg_temp.ck('B-18 a sent order is cancelled too, with the message for the supplier', (:'x3'::jsonb->>'was_sent')::boolean and :'x3'::jsonb->>'message_it' like 'Buongiorno, vi chiediamo di annullare il nostro ordine PO-%', :'x3');
select pg_temp.ck('B-18 cancelling an order waiting for approval rejects its card; a received order is never cancelled',
  :'e_x4' = '' and (select status::text from fabula.approvals where id = (:'po4'::jsonb->>'approval_id')::uuid) = 'rejected' and :'e_x5' like '%già stato ricevuto%', :'e_x4' || ' / ' || :'e_x5');
select pg_temp.ck('B-18 an order cancelled by hand is not reopened by «Annulla» on its card',
  :'ub4' = 'ordine annullato a mano', :'ub4');

-- ============================== B-19 · the milk forecast reads the Ingrosso plans ==============================
-- a delivery day Monday to Saturday: the 7-day milk forecast (demand_7d) has no Sunday row, so B-19 reads a weekday (v1.22a: since
-- Sunday is a delivery day too, a delivery day alone could be a Sunday)
create or replace function pg_temp.dday(n int) returns date language sql as
$$ select g::date from generate_series(fabula.trade_now_rome()::date + 3, fabula.trade_now_rome()::date + 20, interval '1 day') g
   where fabula.trade_is_delivery_day(g::date) and extract(isodow from g) <> 7 order by g offset n - 1 limit 1 $$;
insert into fabula.trade_products (variant_id, product_id, title, variant_title, kg_per_unit, unit_label, base_price_eur, trade_price_eur, min_qty, step_qty)
values ('gid://office/1', :'moz', 'Mozzarella', 'O', 1, 'kg', 14, 11.5, 1, 1) on conflict do nothing;
insert into fabula.parties (id, type, legal_name, active, trade_status) values ('50000000-0000-4000-a000-0000000099e1', 'customer', 'Pizzeria O', true, 'approved') on conflict do nothing;
select pg_temp.dday(1) dd1, extract(isodow from pg_temp.dday(1))::int ww1 \gset
select fabula.trade_save_schedule('50000000-0000-4000-a000-0000000099e1', format('{"days":{"%s":{"lines":{"gid://office/1":12}}}}', :'ww1')::jsonb) is not null s_tr \gset
delete from fabula.standing_orders where weekday = :ww1;
insert into fabula.standing_orders (customer_id, product_id, weekday, qty_kg, active) values ('50000000-0000-4000-a000-0000000099e1', :'moz', :ww1, 40, true);
select wholesale_kg wk, wholesale_source ws from fabula.demand_7d(:'dd1'::date, 1) \gset
select pg_temp.ck('B-19 wholesale in the 7-day forecast = the Ingrosso plan (12 kg), not the old grid (40 kg)', :'wk'::numeric >= 12 and :'wk'::numeric < 40 and :'ws' in ('piani ingrosso', 'ordini confermati'), :'wk' || ' ' || :'ws');
select fabula.sales_status(pg_temp.rome()) -> 'accounts' ->> 'standing_kg_week' skw1 \gset
insert into fabula.standing_orders (customer_id, product_id, weekday, qty_kg, active) values ('50000000-0000-4000-a000-0000000099e1', :'moz', 1 + (:ww1 % 6), 55, true);
select fabula.sales_status(pg_temp.rome()) -> 'accounts' ->> 'standing_kg_week' skw2 \gset
select pg_temp.ck('B-19 (review) the Vendite «kg a settimana» come from the Ingrosso plans, not the frozen grid', :'skw1' = :'skw2' and :'skw1'::numeric >= 12, :'skw1' || ' / ' || :'skw2');

-- ============================== TRADE-06 · a customer stopping the plan from the portal: the office sees it ==============================
select fabula.trade_set_status('50000000-0000-4000-a000-0000000099e1', 'paused', null, 'customer') ts1 \gset
select pg_temp.ck('TRADE-06 «Pausa senza data» from the portal puts a line on the dashboard for the office',
  exists (select 1 from fabula.bot_messages where agent = 'wholesale_orders' and severity = 'warn' and title like 'Pizzeria O ha messo in pausa il piano senza data%' and created_at > now() - interval '1 minute'), :'ts1');
select fabula.trade_set_status('50000000-0000-4000-a000-0000000099e1', 'active', null, 'staff') ts2 \gset

-- ============================== B-15 · «Togli» from tomorrow, «Rimetti» the same day ==============================
select r.id rcp from fabula.recipes r where r.valid_to is null and r.valid_from <= current_date limit 1 \gset
select pg_temp.as_user('00000000-0000-4000-a000-0000000099a2');
set role authenticated;
select pg_temp.err(format($q$select fabula.end_recipe_component('%s')$q$, :'rcp')) e_r1 \gset
reset role;
select pg_temp.as_user('00000000-0000-4000-a000-0000000099a1');
set role authenticated;
select pg_temp.err(format($q$select fabula.end_recipe_component('%s')$q$, :'rcp')) e_r2 \gset
select exists (select 1 from fabula.v_recipe_active where recipe_id = :'rcp') r_still \gset
select pg_temp.err(format($q$select fabula.restore_recipe_component('%s')$q$, :'rcp')) e_r3 \gset
reset role;
select pg_temp.ck('B-15 a «registra» profile cannot take a component out', :'e_r1' like 'Non tolto: il tuo profilo non può modificare le ricette%', :'e_r1');
select pg_temp.ck('B-15 «Togli» ends it from tomorrow: today''s lots still dose it', :'e_r2' = '' and :'r_still'::boolean, :'e_r2');
select pg_temp.ck('B-15 «Rimetti» the same day undoes it', :'e_r3' = '' and (select valid_to is null from fabula.recipes where id = :'rcp'), :'e_r3');
update fabula.recipes set valid_to = current_date - 1 where id = :'rcp';
select pg_temp.as_user('00000000-0000-4000-a000-0000000099a1');
set role authenticated;
select pg_temp.err(format($q$select fabula.restore_recipe_component('%s')$q$, :'rcp')) e_r4 \gset
reset role;
select pg_temp.ck('B-15 …not another day', :'e_r4' like 'Si rimette solo il giorno in cui è stato tolto%', :'e_r4');
-- a component put in today and taken out today stops at once; a removed row can't be «saved» back
select pg_temp.as_user('00000000-0000-4000-a000-0000000099a1');
set role authenticated;
select fabula.add_recipe_component('MOZ-DOP-KG', 'CON-CITRIC', 'per_kg_milk', 0.001) rnew \gset
select fabula.end_recipe_component(:'rnew') rend \gset
select exists (select 1 from fabula.v_recipe_active where recipe_id = :'rnew') r_new_still \gset
select pg_temp.err(format($q$select fabula.update_recipe_dose('%s', 0.002)$q$, :'rnew')) e_r5 \gset
select fabula.add_recipe_component('MOZ-DOP-KG', 'CON-CITRIC', 'per_kg_milk', 0.001) rnew2 \gset
reset role;
select pg_temp.ck('B-15 (review) put in today and taken out today: it stops at once, not tomorrow', (:'rend'::jsonb->>'now')::boolean and not :'r_new_still'::boolean, :'rend');
select pg_temp.ck('B-15 (review) a dose saved on a removed row is refused (it would silently put it back)', :'e_r5' like 'Componente tolto dalla ricetta%', :'e_r5');
select pg_temp.ck('B-15 (review) …and adding it again from the bottom row works the same day', exists (select 1 from fabula.v_recipe_active where recipe_id = :'rnew2'));

-- ============================== B-06 · lot release with a named analysis; NC closing ==============================
insert into fabula.production_batches (batch_date, batch_lot, product_id, milk_in_kg, input_kind, started_at, output_kg, source, food_safety_hold, hold_reason, hold_at)
values (current_date, 'L99-H', :'moz', 300, 'milk', now(), 90, 'tablet', true, 'test', now());
insert into fabula.lab_samples (test_id, sample_code, lot_number, outcome) select id, 'C-TEST-OK', 'L99-H', 'conforme' from fabula.lab_tests limit 1;
insert into fabula.lab_samples (test_id, sample_code, lot_number, outcome) select id, 'C-TEST-KO', 'L99-H', 'non_conforme' from fabula.lab_tests limit 1;
select pg_temp.as_user('00000000-0000-4000-a000-0000000099a1');
set role authenticated;
select pg_temp.err($q$select fabula.release_lot_hold('L99-H', null, 'ok')$q$) e_h1 \gset
select pg_temp.err($q$select fabula.release_lot_hold('L99-H', null, 'rianalisi', 'C-TEST-KO')$q$) e_h2 \gset
select pg_temp.err($q$select fabula.release_lot_hold('l99-h', null, 'rianalisi del lotto', 'c-test-ok')$q$) e_h3 \gset
reset role;
select pg_temp.ck('B-06 «ok» is not a reason; a non-conforming sample does not release', :'e_h1' like 'Serve una motivazione%' and :'e_h2' like 'Il campione C-TEST-KO non è un''analisi conforme del lotto L99-H%', :'e_h1' || ' / ' || :'e_h2');
select pg_temp.ck('B-06 the conforming analysis of the lot releases it, named in the register', :'e_h3' = ''
  and (select not food_safety_hold and notes like '%sblocco: analisi conforme C-TEST-OK%' from fabula.production_batches where batch_lot = 'L99-H'), :'e_h3');
-- a recall decided for the lot keeps it held; a later assessment saying «no recall» lets it go
insert into fabula.production_batches (batch_date, batch_lot, product_id, milk_in_kg, input_kind, started_at, output_kg, source, food_safety_hold, hold_reason, hold_at)
values (current_date, 'L99-R', :'moz', 300, 'milk', now(), 90, 'tablet', true, 'test', now());
insert into fabula.lab_samples (test_id, sample_code, lot_number, outcome) select id, 'C-TEST-R', 'L99-R', 'conforme' from fabula.lab_tests limit 1;
insert into fabula.approvals (kind, requested_by, summary, payload, status, decided_by, decided_at, decision_note, requested_at)
values ('other', 'agent:food_safety', 'Valutare ritiro L99-R', jsonb_build_object('type', 'recall_assessment', 'lot', 'L99-R'), 'approved', 'Consulente R', now(), 'ritiro deciso', now() - interval '2 hours');
select pg_temp.as_user('00000000-0000-4000-a000-0000000099a1');
set role authenticated;
select pg_temp.err($q$select fabula.release_lot_hold('L99-R', null, 'rianalisi del lotto', 'C-TEST-R')$q$) e_h4 \gset
reset role;
select food_safety_hold h4_held from fabula.production_batches where batch_lot = 'L99-R' \gset
insert into fabula.approvals (kind, requested_by, summary, payload, status, decided_by, decided_at, decision_note, requested_at)
values ('other', 'agent:food_safety', 'Rivalutare ritiro L99-R', jsonb_build_object('type', 'recall_assessment', 'lot', 'L99-R'), 'rejected', 'Consulente R', now(), 'riesame: nessun ritiro', now() - interval '1 hour');
select pg_temp.as_user('00000000-0000-4000-a000-0000000099a1');
set role authenticated;
select pg_temp.err($q$select fabula.release_lot_hold('L99-R', null, 'rianalisi del lotto', 'C-TEST-R')$q$) e_h5 \gset
reset role;
select pg_temp.ck('B-06 (review) after a recall was decided the lot is never released', :'e_h4' like 'Per il lotto L99-R è stato deciso il ritiro/richiamo (Consulente R,%non si sblocca%'
  and :'h4_held'::boolean, :'e_h4');
select pg_temp.ck('B-06 (review) …the latest assessment decides: a later «no recall» lets it go', :'e_h5' = '', :'e_h5');
insert into fabula.non_conformities (severity, status, description) values ('minor', 'open', 'test B-06') returning id nc \gset
select pg_temp.as_user('00000000-0000-4000-a000-0000000099a1');
set role authenticated;
select pg_temp.err(format($q$update fabula.non_conformities set status = 'closed' where id = '%s'$q$, :'nc')) e_n1 \gset
select pg_temp.err(format($q$update fabula.non_conformities set status = 'closed', corrective_action = 'sonda sostituita' where id = '%s'$q$, :'nc')) e_n2 \gset
select pg_temp.err(format($q$update fabula.non_conformities set status = 'investigating' where id = '%s'$q$, :'nc')) e_n3 \gset
reset role;
select pg_temp.ck('B-06 an NC closes only with its corrective action, and can be reopened', :'e_n1' like 'Scrivi l''azione correttiva prima di chiudere%' and :'e_n2' = '' and :'e_n3' = ''
  and (select status::text = 'investigating' and closed_at is null from fabula.non_conformities where id = :'nc'), :'e_n1');

-- ============================== B-22 / B-23 · what Shopify has ==============================
select pg_temp.err($q$insert into fabula.trade_price_tiers (variant_id, min_qty, price_eur, discount_pct) values ('gid://office/1', 30, 10, 5)$q$) e_t1 \gset
insert into fabula.trade_price_tiers (variant_id, min_qty, price_eur) values ('gid://office/1', 30, 10) returning id as tid, changed_at as tch \gset
update fabula.trade_price_tiers set synced_at = now() + interval '1 second' where id = :'tid';
select pg_sleep(0.01);
update fabula.trade_price_tiers set active = false where id = :'tid';
select pg_temp.err($q$insert into fabula.trade_price_tiers (variant_id, min_qty, price_eur) values ('gid://office/1', 50, 0)$q$) e_t2 \gset
select pg_temp.ck('B-23 a tier is a price or a discount, not both; never € 0', :'e_t1' like '%trade_price_tiers_one_kind%' and (:'e_t2' like '%trade_price_tiers_price_pos%' or :'e_t2' like 'Prezzo dello scaglione%'), :'e_t1' || ' / ' || :'e_t2');
select pg_temp.ck('B-23 switching a tier off is a change still to send', (select changed_at > :'tch'::timestamptz from fabula.trade_price_tiers where id = :'tid'));
select pg_temp.ck('B-22 the price list keeps what was last sent', (select count(*) = 4 from information_schema.columns where table_schema = 'fabula' and table_name = 'trade_products'
  and column_name in ('synced_price_eur', 'synced_min_qty', 'synced_step_qty', 'synced_active')));

-- ============================== security ==============================
select coalesce(string_agg(f.key, ' · '), '') sec_new from fabula.security_findings() f where f.key not in (select key from fabula.security_accepted) \gset
select pg_temp.ck('the evening security check finds nothing new (every new definer function is accepted with its reason)', :'sec_new' = '', :'sec_new');
select pg_temp.ck('…and the old release key is gone', not exists (select 1 from fabula.security_accepted where key like '%release_lot_hold(p_lot text, p_staff_id uuid, p_note text)'));
select pg_temp.ck('anonymous callers cannot decide, undo, order milk or cancel orders',
  not has_function_privilege('anon', 'fabula.decide_approval(uuid, text, text, numeric, boolean)', 'execute')
  and not has_function_privilege('anon', 'fabula.revoke_approval(uuid, text)', 'execute')
  and not has_function_privilege('anon', 'fabula.milk_order_again(date, numeric, text, boolean)', 'execute')
  and not has_function_privilege('anon', 'fabula.cancel_po(text, text)', 'execute')
  and not has_function_privilege('authenticated', 'fabula.expire_approvals(timestamptz)', 'execute'));
