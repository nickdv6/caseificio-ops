-- v1.07b (15/10/2026): the Shopify stock message follows the decision that the website and the till sell at zero stock, and the
-- milk planning prompt's new version (it handles the plan's new «pre_opening» answer, v1.07a).
--   * shopify.sell_at_zero (default Sì, as decided on 02/10, v0.39): the website and the till keep selling at zero stock, production
--     follows the orders. The stock check no longer asks to turn off «Continua a vendere quando esaurito» (it did on 15/10, against
--     that decision); it lists instead the tracked products that stop at zero. With «No» it behaves as before. The setting is part
--     of the message's fingerprint, so changing it gives a full message rather than «(invariato)».

insert into fabula.settings (key, value, description, data_type, kind, sort, impact_it, min_value, max_value, unit) values
  ('shopify.sell_at_zero', '1',
   'Sito e cassa vendono anche a scorte zero (la produzione segue gli ordini). Sì = il controllo giacenze segnala i prodotti che si fermano a zero; No = segnala quelli che vendono a zero.',
   'number', 'flag', 56,
   'Con «No» il controllo giacenze chiede di togliere «Continua a vendere quando esaurito» su Shopify.', null, null, null)
on conflict (key) do nothing;

do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.shopify_sync_finish'::regproc);
  n := replace(d, $s$      if jsonb_array_length(coalesce(res->'selling_at_zero', '[]')) > 0 then
        todo := todo || format('%s anche a scorte zero: in Shopify togli «Continua a vendere quando esaurito» (%s)', fabula.it_n(jsonb_array_length(res->'selling_at_zero'), 'prodotto si vende', 'prodotti si vendono'),
                               (select string_agg(e #>> '{}', ', ') from jsonb_array_elements(res->'selling_at_zero') e));
$s$, $s$      if coalesce(fabula.setting_num('shopify.sell_at_zero', 1), 1) = 1 then
        -- v1.07b: selling at zero stock is the decision (shopify.sell_at_zero): only a tracked product that stops at zero is a problem
        if exists (select 1 from jsonb_array_elements(coalesce(res->'variants', '[]')) v
                    where v->>'policy' = 'DENY' and coalesce((v->>'tracked')::boolean, false)) then
          todo := todo || format('%s a scorte zero: in Shopify attiva «Continua a vendere quando esaurito» (%s)',
                                 fabula.it_n((select count(*)::int from jsonb_array_elements(res->'variants') v where v->>'policy' = 'DENY' and coalesce((v->>'tracked')::boolean, false)),
                                             'prodotto si ferma', 'prodotti si fermano'),
                                 (select string_agg(v->>'label', ', ' order by v->>'label') from jsonb_array_elements(res->'variants') v
                                   where v->>'policy' = 'DENY' and coalesce((v->>'tracked')::boolean, false)));
        end if;
      elsif jsonb_array_length(coalesce(res->'selling_at_zero', '[]')) > 0 then
        todo := todo || format('%s anche a scorte zero: in Shopify togli «Continua a vendere quando esaurito» (%s)', fabula.it_n(jsonb_array_length(res->'selling_at_zero'), 'prodotto si vende', 'prodotti si vendono'),
                               (select string_agg(e #>> '{}', ', ') from jsonb_array_elements(res->'selling_at_zero') e));
$s$);
  if n = d then raise exception 'v107b: shopify_sync_finish selling_at_zero pattern not found'; end if;
  d := n;
  -- the decision is part of what makes the message «the same as last time»: changing it gives a full message, not «(invariato)»
  n := replace(d, $s$      fp := md5(coalesce(res->>'push', '') || '|' || coalesce((select string_agg(concat_ws(':', v->>'variant_id', v->>'available_units', v->>'shopify_qty', v->>'tracked', v->>'policy'), ',' order by v->>'variant_id')
$s$, $s$      fp := md5(coalesce(fabula.setting_text('shopify.sell_at_zero'), '1') || '|' || coalesce(res->>'push', '') || '|' || coalesce((select string_agg(concat_ws(':', v->>'variant_id', v->>'available_units', v->>'shopify_qty', v->>'tracked', v->>'policy'), ',' order by v->>'variant_id')
$s$);
  if n = d then raise exception 'v107b: shopify_sync_finish fingerprint pattern not found'; end if;
  execute n;
end $mig$;

-- ============================== the prompt (tools/bots/sync_rules.py --versions) ==============================
insert into fabula.bot_prompt_versions (agent, version) values
  ('milk_planning', '581ad88a3f')
on conflict (agent) do update set version = excluded.version, updated_at = now();
