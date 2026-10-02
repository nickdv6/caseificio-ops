-- v0.38 · Deliveroo as a third delivery marketplace (with Glovo and Just Eat).
-- Same flow: orders arrive on the Deliveroo tablet, are rung on Shopify POS with a custom payment type "Deliveroo",
-- and mkt_derive_order() tags them marketplace = 'deliveroo' (fulfilment_kind = 'marketplace').
-- Commission 25 % / markup 34 % are placeholders like Glovo's; coverage of Agropoli to be confirmed with Deliveroo.
insert into fabula.mkt_channels (code, name, kind, status, commission_pct, markup_pct, utm_source, notes, sort)
values ('deliveroo', 'Deliveroo · consegna Agropoli', 'marketplace', 'planned', 25, 34, 'deliveroo',
  'Copertura di Agropoli da verificare con Deliveroo prima di attivare. Ordini sul tablet Deliveroo → battuti su Shopify POS con pagamento "Deliveroo". Commissione e ricarico da confermare nel contratto.', 55)
on conflict (code) do nothing;
do $$ declare d text; begin
  d := pg_get_functiondef('fabula.mkt_derive_order()'::regprocedure);
  if position('deliveroo' in d) = 0 then
    d := replace(d, $q$when gw ~ 'just.?eat' or src ~ 'just.?eat' then 'justeat'$q$,
                    $q$when gw ~ 'just.?eat' or src ~ 'just.?eat' then 'justeat' when gw ~ 'deliveroo' or src ~ 'deliveroo' then 'deliveroo'$q$);
    if position('deliveroo' in d) = 0 then raise exception 'patch point not found'; end if;
    execute d;
  end if; end $$;
