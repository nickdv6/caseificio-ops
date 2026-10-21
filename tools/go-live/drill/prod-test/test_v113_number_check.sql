-- v1.13 · the number check without false alarms (R-03) · run on a fresh replay:
--   tools/go-live/drill/infra-test/replay.sh n_test
--   su postgres -c "psql -d n_test -f tools/go-live/drill/prod-test/test_v113_number_check.sql" | grep -E "PASS|FAIL"
-- The two messages it flagged wrongly in its first week (Controllo sistema 19/10, Manutenzioni e scadenze 20/10), rebuilt on the replay,
-- and the cases around them that must still be flagged.
\set ON_ERROR_STOP 0
create or replace function pg_temp.ck(p_name text, p_ok boolean, p_info text default '') returns text language sql as
$$ select case when coalesce(p_ok, false) then 'PASS ' else 'FAIL ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end $$;
create or replace function pg_temp.toks(p text) returns text language sql as
$$ select coalesce(string_agg(tok, ' | ' order by ord), '') from fabula._basis_tokens(p, true) with ordinality t(tok, kind, vals, decs, pct, signed, ord) $$;

-- ============================== what the tokenizer leaves out ==============================
select pg_temp.ck('«invariati dal 16/10» outside brackets is a note, not data (the 19/10 title)',
  pg_temp.toks('Approvazione in attesa e nomi provvisori: invariati dal 16/10') = '', pg_temp.toks('Approvazione in attesa e nomi provvisori: invariati dal 16/10'));
select pg_temp.ck('…in every gender and number, with «dall''» and «da»',
  pg_temp.toks('scorte invariate dall''08/10; lista invariata da 12/10; dato invariato al 3/10') = '', pg_temp.toks('scorte invariate dall''08/10; lista invariata da 12/10; dato invariato al 3/10'));
select pg_temp.ck('«(erano 3 il 17/10)», a comparison with the previous message, is left out',
  pg_temp.toks('Bot con istruzioni non aggiornate: solo Manutenzioni e scadenze (erano 3 il 17/10).') = '',
  pg_temp.toks('Bot con istruzioni non aggiornate: solo Manutenzioni e scadenze (erano 3 il 17/10).'));
select pg_temp.ck('…the number of today stays: «2 (era 1 il 16/10)» and «erano 3 il 17/10, ora 2» keep the 2',
  pg_temp.toks('Bot non partiti: 2 (era 1 il 16/10)') = '2' and pg_temp.toks('erano 3 il 17/10, ora 2') = '2',
  pg_temp.toks('Bot non partiti: 2 (era 1 il 16/10)') || ' / ' || pg_temp.toks('erano 3 il 17/10, ora 2'));
select pg_temp.ck('a real date next to the note is still checked: «Scade il 21/10 (invariata dal 16/10)» → 21/10',
  pg_temp.toks('Scade il 21/10 (invariata dal 16/10)') = '21/10', pg_temp.toks('Scade il 21/10 (invariata dal 16/10)'));
select pg_temp.ck('«erano» without a date is data and stays: «erano previsti 1.200 kg»',
  pg_temp.toks('erano previsti 1.200 kg') = '1.200', pg_temp.toks('erano previsti 1.200 kg'));
select pg_temp.ck('the counts of a list stay: «28 date da impostare: 4 tarature»',
  pg_temp.toks('28 date da impostare: 4 tarature') = '28 | 4', pg_temp.toks('28 date da impostare: 4 tarature'));
select pg_temp.ck('inside the data nothing changes: «invariato dal 16/10» in a data text still gives its date',
  exists (select 1 from fabula._basis_tokens('invariato dal 16/10', false) where tok = '16/10'));

-- ============================== the Controllo sistema message of 19/10 ==============================
select fabula.keep_basis('ops_health', 'ops_health_check', '{"pending_approvals_over_3d": 1, "placeholders": 4, "bots_missing": [], "bots_errors": 0}'::jsonb, 'bot') is not null kept \gset
select fabula.post_bot_message('ops_health', 'warn', 'Approvazione in attesa e nomi provvisori: invariati dal 16/10',
  E'**Da fare**\n1. Decidi le approvazioni in attesa (Console → Da approvare): 1 da oltre 3 giorni (invariato dal 16/10)\n2. 4 nomi provvisori da sostituire (Console → Anagrafiche) (invariato dal 16/10)\n\n**In breve**\n• Tutti i bot hanno girato oggi, nessun errore; sicurezza del database, backup, sito del tablet e GitHub in ordine.\n• Bot con istruzioni non aggiornate: solo Manutenzioni e scadenze (erano 3 il 17/10). Le attività programmate vanno aggiornate dal repo: chiedi a Claude.\n\nEN — All bots ran clean and the infrastructure is in order; the stale approval and 4 placeholder names are unchanged since 16/10.') m1 \gset
select pg_temp.ck('the 19/10 message is clean now: 1 and 4 found, no date asked of the data',
  (select basis_check->'missing' = '[]'::jsonb and (basis_check->>'numbers')::int = 2 and (basis_check->>'found')::int = 2 and (basis_check->>'dates')::int = 0
     from fabula.bot_messages where id = :m1), (select basis_check::text from fabula.bot_messages where id = :m1));
select fabula.keep_basis('ops_health', 'ops_health_check', '{"pending_approvals_over_3d": 1, "placeholders": 4}'::jsonb, 'bot') is not null kept \gset
select fabula.post_bot_message('ops_health', 'warn', 'Nomi provvisori da sostituire', E'• 5 nomi provvisori da sostituire (era 4 il 16/10)') m2 \gset
select pg_temp.ck('a wrong number is still caught: «5 nomi provvisori» when the data says 4',
  (select basis_check->'missing' = '["5"]'::jsonb from fabula.bot_messages where id = :m2), (select basis_check::text from fabula.bot_messages where id = :m2));

-- ============================== the Manutenzioni e scadenze message of 20/10 ==============================
select fabula.compliance_calendar() cc \gset
select pg_temp.ck('compliance_calendar gives the counts by kind, which add up to the totals',
  (select coalesce(sum(v::int), 0) from jsonb_each_text(:'cc'::jsonb #> '{counts,by_kind,unknown}') e(k, v)) = (:'cc'::jsonb #>> '{counts,unknown}')::int
  and (:'cc'::jsonb #>> '{counts,unknown}')::int > 0
  and (select count(*) from jsonb_array_elements(:'cc'::jsonb -> 'unknown_dates') u where u->>'kind' = 'calibration') = coalesce((:'cc'::jsonb #>> '{counts,by_kind,unknown,calibration}')::int, 0),
  :'cc'::jsonb #>> '{counts,by_kind}');
select coalesce((:'cc'::jsonb #>> '{counts,by_kind,unknown,calibration}')::int, 0) n_cal, coalesce((:'cc'::jsonb #>> '{counts,by_kind,unknown,maintenance}')::int, 0) n_man,
       coalesce((:'cc'::jsonb #>> '{counts,by_kind,unknown,verifica}')::int, 0) n_ver, (:'cc'::jsonb #>> '{counts,unknown}')::int n_all \gset
select fabula.keep_basis('compliance_calendar', 'compliance_calendar', fabula.compliance_calendar(), 'bot') is not null kept \gset
select fabula.post_bot_message('compliance_calendar', 'info', format('Nessuna scadenza entro 30 giorni · %s date ancora da impostare', :n_all),
  format(E'- %s date da impostare: %s tarature, %s manutenzioni, %s verifiche senza data; il calendario non può avvisare finché mancano (invariato dal 06/10).\n\nEN — The same %s items still have no date.',
         :n_all, :n_cal, :n_man, :n_ver, :n_all)) m3 \gset
select pg_temp.ck('the 20/10 message is clean now: the counts by kind are in the data',
  (select basis_check->'missing' = '[]'::jsonb and (basis_check->>'found')::int = (basis_check->>'numbers')::int from fabula.bot_messages where id = :m3),
  (select basis_check::text from fabula.bot_messages where id = :m3));
select fabula.keep_basis('compliance_calendar', 'compliance_calendar', fabula.compliance_calendar(), 'bot') is not null kept \gset
select fabula.post_bot_message('compliance_calendar', 'info', 'Date da impostare', format('- %s date da impostare: 97 tarature', :n_all)) m4 \gset
select pg_temp.ck('a wrong count by kind is still caught («97 tarature»)',
  (select basis_check->'missing' = '["97"]'::jsonb from fabula.bot_messages where id = :m4), (select basis_check::text from fabula.bot_messages where id = :m4));
select pg_temp.ck('the calendar and the tokenizer keep their grants (no anon; the tokenizer only for the database)',
  not has_function_privilege('anon', 'fabula.compliance_calendar(date)', 'execute')
  and not has_function_privilege('authenticated', 'fabula._basis_tokens(text, boolean)', 'execute')
  and not has_function_privilege('anon', 'fabula._basis_tokens(text, boolean)', 'execute'));
