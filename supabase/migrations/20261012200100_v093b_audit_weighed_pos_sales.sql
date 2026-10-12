-- v0.93b · Audit 12/10/2026, phase 0 — bug 3 (POS-06): a weighed counter sale no longer stops the Shopify order sync.
-- A line added from the «Pesa» tile is a Shopify POS custom sale: it has no variant. upsert_shopify_orders then tried to insert a
-- NULL variant id into shopify_variant_map (primary key) → not-null violation → the whole batch failed, and kept failing for the
-- bot's 3-day window (web orders, POS day closings and stock moves all stopped). Now such a line is booked from its line properties
-- (sku + peso_kg, written by the Pesa tile; the Ordini Shopify bot passes them as "properties"), so weighed sales reach stock and
-- lots like any other sale; without usable properties it is listed in shopify_unmapped_lines ("vendita libera") and the rest of the
-- order and of the batch is saved.
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.upsert_shopify_orders(jsonb)'::regprocedure);
  n := replace(d,
    E'        select * into v_map from fabula.shopify_variant_map where variant_id = l->>''variant_id'';\n',
    E'        -- v0.93b (audit POS-06): weighed counter sale = custom sale with no variant: book it from sku + peso_kg\n'
    '        if nullif(l->>''variant_id'', '''') is null then\n'
    '          v_prod := (select id from fabula.products where sku = coalesce(nullif(l->''properties''->>''sku'', ''''), nullif(l->>''sku'', '''')) limit 1);\n'
    '          v_line_kg := nullif(coalesce(l->''properties''->>''peso_kg'', l->>''peso_kg''), '''')::numeric * coalesce((l->>''quantity'')::numeric, 1);\n'
    '          if v_prod is null or v_line_kg is null or v_line_kg <= 0 then\n'
    '            insert into fabula.shopify_unmapped_lines (sales_order_id, variant_id, title, variant_title, qty, unit_price_eur)\n'
    '            values (v_id, ''vendita libera'', coalesce(l->>''title'', ''?''), l->>''variant_title'', (l->>''quantity'')::numeric, (l->>''price'')::numeric)\n'
    '            on conflict (sales_order_id, variant_id, title) do update set qty = excluded.qty, seen_at = now();\n'
    '            n_unm := n_unm + 1; continue;\n'
    '          end if;\n'
    '          agg := jsonb_set(agg, array[v_prod::text], jsonb_build_object(\n'
    '            ''kg'',  coalesce((agg->v_prod::text->>''kg'')::numeric, 0) + v_line_kg,\n'
    '            ''eur'', coalesce((agg->v_prod::text->>''eur'')::numeric, 0) + (l->>''quantity'')::numeric * (l->>''price'')::numeric,\n'
    '            ''iva'', coalesce((l->>''tax_rate'')::numeric, nullif(l->''properties''->>''iva'', '''')::numeric, 4)));\n'
    '          continue;\n'
    '        end if;\n'
    '        select * into v_map from fabula.shopify_variant_map where variant_id = l->>''variant_id'';\n');
  if n = d or position('audit POS-06' in n) = 0 then raise exception 'v093b: line loop of upsert_shopify_orders not found'; end if;
  execute n;
end $mig$;
