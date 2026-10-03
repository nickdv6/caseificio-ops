-- v0.49: company.name everywhere — marketing and sales copy now use fabula.company_name() too (v0.48 covered
-- operational documents). Wording changed from "Nick de La Perla del Cilento" to "Nick di <nome>" so any name reads right.
-- Kept on purpose: the Instagram handle @laperladelcilento and the domain perladelcilento.it (real accounts, not the name).
-- The DO block rewrites the live function bodies by exact fragment and is a no-op when run again.
do $do$
declare
  r record; d text; nd text; i int;
  reps text[][] := array[
    -- mkt_ai_brief (Predis.ai brief)
    array['''Post per La Perla del Cilento''', '''Post per '' || fabula.company_name()'],
    array['''— Marca: La Perla del Cilento, caseificio', '''— Marca: '' || fabula.company_name() || '', caseificio'],
    -- mkt_outreach_draft (creator e-mail + DM)
    array['sono Nick de La Perla del Cilento, il caseificio di Agropoli', 'sono Nick di '' || fabula.company_name(true) || E'', il caseificio di Agropoli'],
    array['\nNick\nLa Perla del Cilento · perladelcilento.it''', '\nNick\n'' || fabula.company_name(true) || E'' · perladelcilento.it'''],
    array['E''Ciao %s! Siamo La Perla del Cilento, caseificio', 'E''Ciao %s! Siamo '' || fabula.company_name(true) || E'', caseificio'],
    -- sales_lead_message (Vendite pipeline)
    array['Sono Nick de La Perla del Cilento, il nuovo', 'Sono Nick di '' || fabula.company_name(true) || '', il nuovo'],
    array['sono Nick de La Perla del Cilento. Vi avevo', 'sono Nick di '' || fabula.company_name(true) || ''. Vi avevo'],
    array['la proposta de La Perla del Cilento:', 'la proposta di '' || fabula.company_name(true) || '':'],
    -- mkt_seed_launch (campaign name)
    array['''Pre-lancio · Arriva La Perla''', '''Pre-lancio · Apriamo ad Agropoli''']
  ];
begin
  for r in select p.oid, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'fabula' and p.proname in ('mkt_ai_brief', 'mkt_outreach_draft', 'sales_lead_message', 'mkt_seed_launch') loop
    d := pg_get_functiondef(r.oid); nd := d;
    for i in 1 .. array_length(reps, 1) loop nd := replace(nd, reps[i][1], reps[i][2]); end loop;
    if nd ~ 'La Perla del Cilento|Arriva La Perla' then raise exception 'v049: % still has a hardcoded company name', r.proname; end if;
    if nd <> d then execute nd; end if;
  end loop;
end $do$;

-- shop sign in the local campaign checklist (data, written once with the current name)
update fabula.mkt_local_items
   set title_it = replace(title_it, 'La Perla del Cilento', fabula.company_name()),
       spec_it  = replace(spec_it,  'La Perla del Cilento', fabula.company_name())
 where title_it like '%La Perla del Cilento%' or spec_it like '%La Perla del Cilento%';
