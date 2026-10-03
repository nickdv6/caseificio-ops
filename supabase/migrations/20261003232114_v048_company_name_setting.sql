-- v0.48: the company name in operational documents and messages comes from settings company.name
-- (Configurazione → Azienda) instead of being hardcoded. Fallback 'La Perla del Cilento' when the setting is empty.
-- Marketing / sales outreach copy (mkt_ai_brief, mkt_outreach_draft, sales_lead_message) is brand copy and is left as is.
-- Applied via Supabase MCP on 2026-10-03 (version 20261003232114). The DO block rewrites the live function bodies by exact
-- fragment and is a no-op when run again.
create or replace function fabula.company_name(p_for_format boolean default false)
returns text language sql stable security definer set search_path = fabula, pg_temp as $$
  select case when p_for_format then replace(n, '%', '%%') else n end
  from (select coalesce(nullif(btrim((select value from fabula.settings where key = 'company.name')), ''), 'La Perla del Cilento') as n) x
$$;
comment on function fabula.company_name(boolean) is 'Company name from settings company.name (fallback La Perla del Cilento). p_for_format = true doubles any % for use inside format().';
grant execute on function fabula.company_name(boolean) to authenticated, service_role;

do $do$
declare
  r record; d text; nd text;
  reps text[][] := array[
    -- compliance_calendar: supplier/lab requests
    array['format(''Buongiorno, per La Perla del Cilento (Agropoli)', 'format(''Buongiorno, per '' || fabula.company_name(true) || '' (Agropoli)'],
    array['''Richiesta campionamenti — La Perla del Cilento, Agropoli''', '''Richiesta campionamenti — '' || fabula.company_name() || '', Agropoli'''],
    -- confirm_standing_orders: WhatsApp confirmation to wholesale customers
    array['format(''Buongiorno, La Perla del Cilento conferma per', 'format(''Buongiorno, '' || fabula.company_name(true) || '' conferma per'],
    -- monthly_package: header of the accountant pack
    array['''name'', ''La Perla del Cilento'',', '''name'', fabula.company_name(),'],
    -- po_send_package: purchase order e-mail / WhatsApp to suppliers
    array['''Ordine %s — La Perla del Cilento''', '''Ordine %s — '' || fabula.company_name(true)'],
    array['presso La Perla del Cilento, Agropoli (SA).', 'presso '' || fabula.company_name(true) || E'', Agropoli (SA).'],
    array['saluti,\nLa Perla del Cilento''', 'saluti,\n'' || fabula.company_name(true)'],
    array['format(''Buongiorno, La Perla del Cilento ordina:', 'format(''Buongiorno, '' || fabula.company_name(true) || '' ordina:']
  ];
  i int;
begin
  for r in select p.oid, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'fabula' and p.proname in ('compliance_calendar', 'confirm_standing_orders', 'monthly_package', 'po_send_package') loop
    d := pg_get_functiondef(r.oid); nd := d;
    for i in 1 .. array_length(reps, 1) loop nd := replace(nd, reps[i][1], reps[i][2]); end loop;
    if nd like '%La Perla del Cilento%' then raise exception 'v048: % still has a hardcoded company name', r.proname; end if;
    if nd <> d then execute nd; end if;
  end loop;
end $do$;
