-- v1.06b «Perché?» (15/10/2026): the data behind a bot message written out in Italian. Spec: claude/perche-spec-v106-2026-10-15.md.
--   * fabula.message_why(id): for the people who see the message (Sistema, or the message's area: the rule of my_alarms()), the
--     reads linked to it (v1.06a), each written out by its own explainer: plan_milk, propose_purchase_orders, sell_down_signals,
--     confirm_standing_orders, haccp_evening_status, daily_brief, weekly_brief, ops_health_check, infra_checks, compliance_calendar,
--     monthly_review, and the database's auto_approve, batch_ccp, milk_reject, prod_watch. An explainer only formats values that are in
--     the data; any other read shows its labelled values (fabula.basis_labels) and never raw keys (E-14). Phone numbers and e-mails
--     are never shown. «Dati grezzi» (the JSON) only for Sistema «gestisce»; the number check for them, or for everyone with
--     bots.number_check_all = 1.
--   * The bots' prompts wrap their step-1 reads in keep_basis(): new expected versions.

-- ============================== small formatting helpers (values from the data, never computed) ==============================
create or replace function fabula._wn(p jsonb) returns numeric
language sql immutable set search_path = fabula, public as $$
  select case when jsonb_typeof(p) = 'number' then (p #>> '{}')::numeric
              when jsonb_typeof(p) = 'string' and (p #>> '{}') ~ '^-?[0-9]+(\.[0-9]+)?$' then (p #>> '{}')::numeric end
$$;
-- «1.200 kg», «20,5 %», «n/d»
create or replace function fabula._wq(p jsonb, p_unit text default 'kg') returns text
language sql stable set search_path = fabula, public as $$
  select case when fabula._wn(p) is null then 'n/d' else fabula.it_qty(fabula._wn(p)) || coalesce(' ' || nullif(p_unit, ''), '') end
$$;
-- «€ 1.440», «€ 1.440,50», with p_dec the decimals are fixed («€ 1,60»)
create or replace function fabula._we(p jsonb, p_dec integer default null) returns text
language sql stable set search_path = fabula, public as $$
  select case when fabula._wn(p) is null then 'n/d'
              else case when fabula._wn(p) < 0 then '− ' else '' end || '€ '
                   || fabula.it_num(abs(fabula._wn(p)), coalesce(p_dec, case when fabula._wn(p) = round(fabula._wn(p)) then 0 else 2 end)) end
$$;
-- a price per kg as the data has it (an average can carry 4 decimals): «€ 1,60», «€ 1,6537»
create or replace function fabula._weu(p jsonb) returns text
language sql stable set search_path = fabula, public as $$
  select case when fabula._wn(p) is null then 'n/d' when fabula._wn(p) = round(fabula._wn(p), 2) then '€ ' || fabula.it_num(fabula._wn(p), 2)
              else '€ ' || rtrim(fabula.it_num(fabula._wn(p), 4), '0') end
$$;
-- a cost line: «− € 538,04», «n/d»
create or replace function fabula._wneg(p jsonb) returns text
language sql stable set search_path = fabula, public as $$
  select case when fabula._wn(p) is null then 'n/d' else '− ' || fabula._we(p, 2) end
$$;
-- a change already computed by the database: «+12 %», «−8 %»
create or replace function fabula._wpct(p jsonb, p_unit text default '%') returns text
language sql stable set search_path = fabula, public as $$
  select case when fabula._wn(p) is null then null
              else case when fabula._wn(p) > 0 then '+' when fabula._wn(p) < 0 then '−' else '' end || fabula.it_qty(abs(fabula._wn(p))) || ' ' || p_unit end
$$;
-- «gio 15/10» from a date or a time stamp (Rome)
create or replace function fabula._wd(p jsonb) returns text
language plpgsql stable set search_path = fabula, public as $$
declare s text := p #>> '{}';
begin
  if s is null or s !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}' then return 'n/d'; end if;
  if length(s) > 10 then return fabula.it_day((s::timestamptz at time zone 'Europe/Rome')::date); end if;
  return fabula.it_day(s::date);
exception when others then return 'n/d';
end $$;
-- «18:52» (Rome) from a time stamp
create or replace function fabula._wt(p jsonb) returns text
language plpgsql stable set search_path = fabula, public as $$
begin
  return to_char((p #>> '{}')::timestamptz at time zone 'Europe/Rome', 'HH24:MI');
exception when others then return null;
end $$;
-- one line: label, value, a short note under it, flag (ko = to look at, b = the result)
create or replace function fabula._wr(p_l text, p_v text, p_n text default null, p_f text default null) returns jsonb
language sql immutable set search_path = fabula, public as $$
  select case when p_l is null then null else jsonb_strip_nulls(jsonb_build_object('l', p_l, 'v', p_v, 'n', nullif(p_n, ''), 'f', p_f)) end
$$;
-- one section: a title, its lines (empty ones dropped), a note; nothing when there is nothing to say
create or replace function fabula._wsec(p_t text, p_rows jsonb[], p_note text default null) returns jsonb
language sql immutable set search_path = fabula, public as $$
  select case when coalesce(cardinality(array_remove(p_rows, null)), 0) = 0 and p_note is null then null
              else jsonb_strip_nulls(jsonb_build_object('t', p_t, 'rows', to_jsonb(coalesce(array_remove(p_rows, null), '{}')), 'note', p_note)) end
$$;
create or replace function fabula._wout(p_title text, p_secs jsonb[]) returns jsonb
language sql immutable set search_path = fabula, public as $$
  select jsonb_build_object('title', p_title, 'sections', to_jsonb(coalesce(array_remove(p_secs, null), '{}')))
$$;
create or replace function fabula._wb(p jsonb) returns boolean
language sql immutable set search_path = fabula, public as $$
  select case when jsonb_typeof(p) = 'boolean' then (p #>> '{}')::boolean when jsonb_typeof(p) = 'string' then (p #>> '{}') in ('true', 't', '1') else false end
$$;
create or replace function fabula._wchan(p text) returns text
language sql immutable set search_path = fabula, public as $$
  select case p when 'store_pos' then 'Banco' when 'shopify' then 'Online' when 'wholesale' then 'Ingrosso' when 'market' then 'Mercati' when 'other' then 'Altro'
                when 'pos' then 'Banco' else coalesce(initcap(replace(p, '_', ' ')), 'Altro') end
$$;
create or replace function fabula._wmonth(p text) returns text
language sql immutable set search_path = fabula, public as $$
  select case when p ~ '^[0-9]{4}-[0-9]{2}' then (array['gennaio','febbraio','marzo','aprile','maggio','giugno','luglio','agosto','settembre','ottobre','novembre','dicembre'])[substr(p, 6, 2)::int]
                                                || ' ' || left(p, 4) else coalesce(p, 'n/d') end
$$;

-- ============================== the explainers ==============================
-- Piano latte (plan_milk)
create or replace function fabula._why_plan_milk(d jsonb) returns jsonb
language plpgsql stable set search_path = fabula, public as $$
declare hs text := d #>> '{demand,history_source}'; v_min boolean := fabula._wb(d->'min_run_applied'); v_cap boolean := fabula._wb(d->'capacity_hit');
        v_farm boolean := fabula._wb(d #> '{farm,exceeds_farm_supply}'); s jsonb[] := '{}';
begin
  if d ? 'skipped' then
    return fabula._wout(format('Piano latte per %s già pronto', fabula._wd(d->'date')), array[
      fabula._wsec('Il piano c''era già', array[
        fabula._wr('Latte', fabula._wq(d #> '{plan,milk_kg}')),
        fabula._wr('Stato', case d #>> '{plan,status}' when 'proposed' then 'da approvare' when 'approved' then 'approvato' else coalesce(d #>> '{plan,status}', 'n/d') end),
        fabula._wr('Mozzarella prevista', fabula._wq(d #> '{plan,planned_output_kg}'))],
        'Il calcolo non è stato rifatto: il piano di quel giorno esisteva già.')]);
  end if;
  if hs = 'none' then
    -- no sales to start from: the plan is the average milk of the last deliveries (or the vat's capacity), made into cheese at the yield
    s := s || fabula._wsec('Il calcolo', array[
      fabula._wr('Vendite', 'nessuna registrata', '⚠ non ci sono vendite da cui partire: il piano usa il latte medio accettato nelle ultime 4 settimane, o la capacità della caldaia se non ce n''è', 'ko'),
      fabula._wr('Latte di partenza', fabula._wq(d->'milk_unrounded_kg')),
      fabula._wr('Resa', fabula._wq(d->'yield_pct', '%'),
        case d->>'yield_source' when 'avg_30d' then 'media dei lotti degli ultimi 30 giorni' when 'assumption' then '⚠ ipotizzata: nessun lotto misurato negli ultimi 30 giorni' end,
        case when d->>'yield_source' = 'assumption' then 'ko' end),
      fabula._wr('Mozzarella prevista', fabula._wq(d->'planned_output_kg'), null, 'b'),
      case when v_min then fabula._wr('Lotto minimo', fabula._wq(d->'min_kg'), '⚠ piano alzato al minimo di lavorazione', 'ko') end,
      case when v_cap then fabula._wr('Capacità della caldaia', fabula._wq(d->'capacity_kg'), '⚠ piano ridotto alla capacità della caldaia', 'ko') end,
      fabula._wr('Masseria', fabula._wq(d #> '{farm,kg_available}') || ' disponibili',
        case when v_farm then format('⚠ mancano %s', fabula._wq(d #> '{farm,shortfall_kg}')) end, case when v_farm then 'ko' end),
      fabula._wr('Latte proposto', fabula._wq(d->'milk_kg'), null, 'b'),
      fabula._wr('Costo stimato', format('%s × %s/kg = %s', fabula._wq(d->'milk_kg'), fabula._weu(d->'price_eur_per_kg'), fabula._we(d->'est_cost_eur')),
        'prezzo medio del latte degli ultimi 30 giorni (o quello dei Parametri)')]);
  else
  s := s || fabula._wsec('Il calcolo', array[
    fabula._wr('Vendite al banco e online', fabula._wq(d #> '{demand,retail_kg}'),
      case hs when 'same_weekday_4w' then format('media degli stessi giorni (%s) delle ultime 4 settimane: %s giorni con vendite', coalesce(d->>'weekday', 'n/d'), coalesce(d #>> '{demand,history_days}', 'n/d'))
              when 'any_day_28d' then format('⚠ poco storico: media di tutti i giorni delle ultime 4 settimane (%s giorni con vendite)', coalesce(d #>> '{demand,history_days}', '0'))
              when 'none' then '⚠ nessuna vendita registrata: il piano parte dal latte medio delle ultime consegne' end,
      case when hs in ('any_day_28d', 'none') then 'ko' end),
    case when fabula._wn(d #> '{demand,preorder_kg}') > 0 then fabula._wr('· di cui preordini da ritirare', fabula._wq(d #> '{demand,preorder_kg}')) end,
    fabula._wr('Ingrosso', '+ ' || fabula._wq(d #> '{demand,wholesale_kg}'),
      case when fabula._wn(d #> '{demand,wholesale_confirmed_kg}') > 0 then 'ordini confermati per quel giorno' else 'media delle ultime 4 settimane: nessun ordine confermato' end),
    fabula._wr('Giacenza fresca', '− ' || fabula._wq(d->'carry_kg'),
      format('in cella %s con almeno 3 giorni di vita, contati al %s', fabula._wq(d->'carry_raw_kg'), fabula._wq(d->'carry_pct', '%'))),
    fabula._wr('Margine di sicurezza', '+ ' || fabula._wq(d->'safety_kg')),
    case when not (v_farm and fabula._wb(d #> '{farm,capped_to_farm}')) then fabula._wr('Mozzarella da fare', '= ' || fabula._wq(d->'planned_output_kg'), null, 'b') end,
    fabula._wr('Resa', fabula._wq(d->'yield_pct', '%'),
      case d->>'yield_source' when 'avg_30d' then 'media dei lotti degli ultimi 30 giorni' when 'assumption' then '⚠ ipotizzata: nessun lotto misurato negli ultimi 30 giorni' end,
      case when d->>'yield_source' = 'assumption' then 'ko' end),
    case when not (v_farm and fabula._wb(d #> '{farm,capped_to_farm}')) then fabula._wr('Latte necessario', fabula._wq(d->'milk_unrounded_kg')) end,
    case when v_min then fabula._wr('Lotto minimo', fabula._wq(d->'min_kg'), '⚠ la domanda da sola ne chiederebbe meno: il piano è alzato al minimo di lavorazione', 'ko') end,
    case when v_cap then fabula._wr('Capacità della caldaia', fabula._wq(d->'capacity_kg'), '⚠ la domanda supera la caldaia: una parte resta scoperta', 'ko') end,
    fabula._wr('Masseria', fabula._wq(d #> '{farm,kg_available}') || ' disponibili',
      case when v_farm and fabula._wb(d #> '{farm,capped_to_farm}') then format('⚠ il piano è ridotto a quello che ha la Masseria: mancano %s', fabula._wq(d #> '{farm,shortfall_kg}'))
           when v_farm then format('⚠ servono %s in più da altri fornitori', fabula._wq(d #> '{farm,shortfall_kg}')) end,
      case when v_farm then 'ko' end),
    fabula._wr('Latte proposto', fabula._wq(d->'milk_kg'),
      case when not (v_min or v_cap or v_farm) and fabula._wn(d->'milk_unrounded_kg') is distinct from fabula._wn(d->'milk_kg') then 'arrotondato per eccesso' end, 'b'),
    case when v_farm and fabula._wb(d #> '{farm,capped_to_farm}') then
      fabula._wr('Mozzarella prevista', fabula._wq(d->'planned_output_kg'), 'con il latte che la Masseria ha: meno di quella da fare') end,
    fabula._wr('Costo stimato', format('%s × %s/kg = %s', fabula._wq(d->'milk_kg'), fabula._weu(d->'price_eur_per_kg'), fabula._we(d->'est_cost_eur')),
      'prezzo medio del latte degli ultimi 30 giorni (o quello dei Parametri)')]);
  end if;
  s := s || fabula._wsec('Per confronto', array[
    case when coalesce(fabula._wn(d #> '{last_4w_same_weekday,milk_kg}'), 0) + coalesce(fabula._wn(d #> '{last_4w_same_weekday,waste_kg}'), 0) > 0 then
      fabula._wr('Stessi giorni, ultime 4 settimane', format('latte %s · scarti %s', fabula._wq(d #> '{last_4w_same_weekday,milk_kg}'), fabula._wq(d #> '{last_4w_same_weekday,waste_kg}'))) end,
    case when fabula._wn(d->'est_whey_kg') > 0 then fabula._wr('Siero e ricotta', format('%s di siero → ≈ %s di ricotta', fabula._wq(d->'est_whey_kg'), fabula._wq(d->'est_ricotta_kg'))) end]);
  if d->>'auto_approve_at' is not null then
    s := s || fabula._wsec('Se nessuno decide', array[fabula._wr('Si approva da solo', 'alle ' || (d->>'auto_approve_at'), d->>'auto_rule')]);
  end if;
  if fabula._wb(d->'is_simulation') then s := s || fabula._wsec('Simulazione', null, 'Sono dati di una simulazione, non di vendite vere.'); end if;
  return fabula._wout(format('Perché %s di latte per %s', fabula._wq(d->'milk_kg'), fabula._wd(d->'date')), s);
end $$;

-- Acquisti (propose_purchase_orders); the orders' own numbers come from their approvals (extra)
create or replace function fabula._why_purchase(d jsonb, e jsonb) returns jsonb
language plpgsql stable set search_path = fabula, public as $$
declare c jsonb; p jsonb; s jsonb[] := '{}'; n int := coalesce(fabula._wn(d->'count'), 0)::int; u text; k jsonb; sk jsonb[] := '{}';
begin
  for c in select x from jsonb_array_elements(coalesce(d->'created', '[]'::jsonb)) x loop
    p := coalesce(e #> array['orders', c->>'po_number'], '{}'::jsonb); u := coalesce(c->>'unit', p->>'unit', '');
    s := s || fabula._wsec(format('%s · %s di %s', coalesce(c->>'po_number', 'Ordine'), fabula._wq(c->'qty', u), coalesce(c->>'name', c->>'sku', 'n/d')), array[
      fabula._wr('Fornitore', coalesce(c->>'supplier', 'n/d')),
      case when p ? 'on_hand' then fabula._wr('Giacenza', fabula._wq(p->'on_hand', u)) end,
      case when p ? 'daily_use' then fabula._wr('Consumo', fabula._wq(p->'daily_use', u) || ' al giorno', 'media delle ultime 2 settimane') end,
      fabula._wr('Copertura', fabula._wq(c->'days_cover', 'giorni'), null,
                 case when fabula._wn(c->'days_cover') < fabula._wn(c->'lead_time_days') then 'ko' end),
      fabula._wr('Consegna', format('in %s · %s', fabula._wq(c->'lead_time_days', 'giorni'), fabula._wd(c->'expected_date'))),
      case when p ? 'qty_before_terms' and fabula._wn(p->'qty_before_terms') is distinct from fabula._wn(c->'qty') then
        fabula._wr('Quantità', format('%s → %s', fabula._wq(p->'qty_before_terms', u), fabula._wq(c->'qty', u)),
                   concat_ws(' · ', case when fabula._wn(p->'min_order_qty') is not null then 'minimo d''ordine ' || fabula._wq(p->'min_order_qty', u) end,
                                     case when fabula._wn(p->'order_multiple') is not null then 'multipli di ' || fabula._wq(p->'order_multiple', u) end))
      else fabula._wr('Quantità', fabula._wq(c->'qty', u), 'la quantità di riordino dell''articolo') end,
      case when fabula._wb(c->'price_missing') then fabula._wr('Prezzo', '⚠ da confermare', 'non c''è a listino: chiedilo al fornitore prima di approvare', 'ko')
           when p ? 'unit_price_eur' then fabula._wr('Prezzo', fabula._we(p->'unit_price_eur', 2) || coalesce('/' || nullif(u, ''), ''),
                                                    case p->>'price_source' when 'listino' then 'dal listino del fornitore' when 'ultimo DDT' then 'dall''ultimo DDT' end) end,
      fabula._wr('Totale', fabula._we(c->'total_eur'), 'IVA esclusa', 'b'),
      case when c->>'auto_approve_at' is not null then fabula._wr('Si approva da solo', 'alle ' || (c->>'auto_approve_at'), 'se nessuno decide prima') end]);
  end loop;
  for k in select x from jsonb_array_elements(coalesce(d->'skipped', '[]'::jsonb)) x loop
    sk := sk || fabula._wr(coalesce((select name from fabula.products where sku = k->>'sku'), k->>'sku', 'n/d'),
                           case k->>'reason' when 'open_po_exists' then 'c''è già un ordine aperto' when 'no_preferred_supplier' then '⚠ manca il fornitore' else 'saltato' end,
                           case when k->>'reason' = 'no_preferred_supplier' then format('giacenza %s, copertura %s: scegli il fornitore in Console → Anagrafiche',
                                                                                       fabula._wq(k->'on_hand', ''), fabula._wq(k->'days_cover', 'giorni')) end,
                           case when k->>'reason' = 'no_preferred_supplier' then 'ko' end);
  end loop;
  s := s || fabula._wsec('Non proposti', sk);
  s := s || fabula._wsec('Quando si propone un ordine', null,
    'Quando la giacenza scende sotto la soglia di riordino, o basta per meno di 10 giorni, o per meno della consegna più il margine (Parametri → Acquisti).');
  return fabula._wout(case when n = 0 then 'Nessun ordine ai fornitori da proporre' when n = 1 then 'Perché questo ordine al fornitore' else format('Perché %s ordini ai fornitori', n) end, s);
end $$;

-- Vendere prima (sell_down_signals); the promo's full price comes from its approval (extra)
create or replace function fabula._why_sell_down(d jsonb, e jsonb) returns jsonb
language plpgsql stable set search_path = fabula, public as $$
declare l jsonb; pr jsonb; s jsonb[] := '{}'; n int := coalesce(fabula._wn(d #> '{totals,proposals_created}'), 0)::int; risk numeric := fabula._wn(d #> '{totals,at_risk_kg}');
        dl int; n_ok int := 0;
begin
  for l in select x from jsonb_array_elements(coalesce(d->'lots', '[]'::jsonb)) x loop
    if coalesce(fabula._wn(l->'at_risk_kg'), 0) <= 0 and l->>'action' is distinct from 'ritirare' then n_ok := n_ok + 1; continue; end if;
    pr := e #> array['promos', l->>'lot']; dl := fabula._wn(l->'days_left')::int;
    s := s || fabula._wsec(format('%s · lotto %s', coalesce(l->>'name', l->>'sku', 'n/d'), coalesce(l->>'lot', 'n/d')), array[
      fabula._wr('Giacenza', fabula._wq(l->'on_hand_kg')),
      fabula._wr('Scade', fabula._wd(l->'expiry'), case when dl < 0 then 'scaduto' when dl = 0 then 'oggi' when dl = 1 then 'domani' when dl is not null then format('tra %s giorni', dl) end,
                 case when dl <= 1 then 'ko' end),
      fabula._wr('Si vende', fabula._wq(l->'old_lot_sales_rate_kg') || ' al giorno',
                 format('dai lotti non freschi, media di 14 giorni (in tutto %s al giorno)', fabula._wq(l->'total_sales_rate_kg'))),
      fabula._wr('Si venderà prima della scadenza', fabula._wq(l->'expected_to_sell_kg'), 'tenendo conto dei lotti più vecchi dello stesso prodotto'),
      fabula._wr('A rischio', fabula._wq(l->'at_risk_kg'), format('%s al prezzo pieno', fabula._we(l->'value_retail_eur')), 'ko'),
      fabula._wr('Azione', case l->>'action' when 'ritirare' then '⚠ scaduto: ritirare dalla vendita' when 'promo_banco' then 'promo al banco'
                                             when 'offerta_ingrosso_e_promo' then 'promo al banco e offerta ai clienti ingrosso' when 'spingere_al_banco' then 'spingere al banco (troppo poco per una promo)'
                                             else coalesce(l->>'action', 'n/d') end, null, case when l->>'action' = 'ritirare' then 'ko' else 'b' end),
      case when l->>'promo_price_eur_kg' is not null then
        fabula._wr('Prezzo promo', case when pr->'list_price_eur_kg' is not null then fabula._we(pr->'list_price_eur_kg', 2) || ' → ' else '' end || fabula._we(l->'promo_price_eur_kg', 2) || ' al kg',
                   'sconto ' || fabula._wq(coalesce(pr->'promo_pct', d->'promo_pct'), '%')) end,
      case when l->>'auto_approve_at' is not null then fabula._wr('Si approva da solo', 'alle ' || (l->>'auto_approve_at'), 'se nessuno decide prima') end]);
  end loop;
  s := s || fabula._wsec('In tutto', array[
    fabula._wr('A rischio', fabula._wq(d #> '{totals,at_risk_kg}'), format('%s al prezzo pieno', fabula._we(d #> '{totals,value_retail_eur}')), case when risk > 0 then 'ko' end),
    case when fabula._wn(d #> '{totals,value_milk_eur}') > 0 then fabula._wr('Valore del latte', fabula._we(d #> '{totals,value_milk_eur}'), 'quanto è costato il latte di quella mozzarella') end,
    case when n_ok > 0 then fabula._wr('Lotti che si vendono in tempo', n_ok::text) end,
    fabula._wr('Scarti degli ultimi 7 giorni', fabula._wq(d->'waste_last_7d_kg'))],
    format('Si guardano i lotti che scadono entro %s.', fabula._wq(d->'horizon_days', 'giorni')));
  return fabula._wout(case when n = 1 then 'Perché questa promo' when n > 1 then format('Perché %s promo', n)
                           when risk > 0 then format('Perché %s sono a rischio', fabula._wq(d #> '{totals,at_risk_kg}')) else 'Nessun lotto a rischio' end, s);
end $$;

-- Ordini ingrosso (confirm_standing_orders): never the customers' phones
create or replace function fabula._why_wholesale(d jsonb) returns jsonb
language plpgsql stable set search_path = fabula, public as $$
declare c jsonb; rb jsonb[] := '{}'; ru jsonb[] := '{}'; s jsonb[] := '{}'; n int := coalesce(fabula._wn(d->'booked'), 0)::int;
begin
  for c in select x from jsonb_array_elements(coalesce(d->'customers', '[]'::jsonb)) x loop
    rb := rb || case when fabula._wb(c->'already_booked') then fabula._wr(coalesce(c->>'customer', 'n/d'), 'già prenotato', c->>'order_number')
                     else fabula._wr(coalesce(c->>'customer', 'n/d'), fabula._we(c->'total_eur'),
                                     concat_ws(' · ', c->>'order_number', case when fabula._wn(c->'lines') is not null then fabula.it_n(fabula._wn(c->'lines'), 'riga', 'righe') end,
                                                       case when c->>'window' is not null then 'fascia ' || (c->>'window') end)) end;
  end loop;
  for c in select x from jsonb_array_elements(coalesce(d->'under_minimum', '[]'::jsonb)) x loop
    ru := ru || fabula._wr(coalesce(c->>'customer', 'n/d'), fabula._wq(c->'kg'), 'sotto il minimo d''ordine: la consegna non parte', 'ko');
  end loop;
  s := s || fabula._wsec('Prenotati', rb) || fabula._wsec('Non prenotati: sotto il minimo', ru);
  if jsonb_array_length(coalesce(d->'skipped_placeholder', '[]'::jsonb)) > 0 then
    s := s || fabula._wsec('Clienti di prova', array[fabula._wr('Saltati', (select string_agg(x #>> '{}', ', ') from jsonb_array_elements(d->'skipped_placeholder') x),
                                                                 coalesce(d #>> '{placeholders,line_it}', 'non sono clienti veri'))]);
  end if;
  s := s || fabula._wsec('In tutto', array[
    fabula._wr('Ingrosso confermato', fabula._wq(d->'total_kg'), 'entra nel piano latte di quel giorno', 'b'),
    case when fabula._wn(d->'queued_for_shopify') > 0 then fabula._wr('In coda per Shopify', (d->>'queued_for_shopify') || ' ordini') end]);
  return fabula._wout(case when n = 1 then format('Perché un ordine ingrosso per %s', fabula._wd(d->'date')) when n > 1 then format('Perché %s ordini ingrosso per %s', n, fabula._wd(d->'date'))
                           else format('Ordini ingrosso per %s', fabula._wd(d->'date')) end, s);
end $$;

-- Chiusura serata (haccp_evening_status): each missing item with the rule behind it
create or replace function fabula._why_evening(d jsonb) returns jsonb
language plpgsql stable set search_path = fabula, public as $$
declare m jsonb; r jsonb[] := '{}'; h jsonb[] := '{}'; s jsonb[] := '{}'; n int := coalesce(fabula._wn(d->'count'), 0)::int; c text; fs boolean;
begin
  for m in select x from jsonb_array_elements(coalesce(d->'missing', '[]'::jsonb)) x loop
    c := coalesce(m->>'code', ''); fs := c ~ '^(ccp:|abx|ph)';
    r := r || fabula._wr(coalesce(m->>'label_it', 'n/d'), case when fs then '⚠ sicurezza alimentare' else 'da registrare' end,
      case when c like 'cold:%' then 'Le celle si controllano due volte al giorno: manca la lettura della sera (dopo le 15:00).'
           when c = 'clean' then 'La sanificazione di fine turno va registrata ogni giorno di lavoro.'
           when c = 'kwh' then 'Nei giorni con produzione o vendite si legge il contatore: serve per il consumo al kg.'
           when c = 'effluent' then 'Nei giorni di produzione si registrano i reflui (scotta, acque di lavaggio).'
           when c like 'ccp:%' then 'Punto critico (CCP): va registrato per ogni lotto. Un lotto chiuso senza questa misura resta bloccato finché il responsabile HACCP non lo sblocca.'
           when c = 'abx' then 'Ogni consegna di latte va testata per gli antibiotici (CCP 1b) prima di lavorarla.'
           when c = 'ph' then 'Nei giorni di produzione il pHmetro si calibra con i tamponi 4 e 7.'
           when c = 'ship' then 'Ordini online già pagati che aspettano la spedizione.'
           when c like 'batch:%' then 'Il lotto è avviato ma non chiuso: mancano i kg prodotti.'
           when c like 'shift:%' then 'Badge di uscita non passato (la lista lo mostra dalle 19:00).' end,
      case when fs then 'ko' end);
  end loop;
  s := s || fabula._wsec('Cosa manca e perché', r, case when n > 0 then 'Sul tablet basta toccare la voce della lista per registrarla.' end);
  for m in select x from jsonb_array_elements(coalesce(d->'lots_on_hold', '[]'::jsonb)) x loop
    h := h || fabula._wr('Lotto ' || (m #>> '{}'), 'non vendere', 'bloccato per sicurezza alimentare: lo sblocca il responsabile HACCP (Autocontrollo → Lotti bloccati)', 'ko');
  end loop;
  s := s || fabula._wsec('Lotti bloccati', h);
  if fabula._wb(d->'closed_day') then s := s || fabula._wsec('Giornata chiusa', null, 'Nessuna produzione né vendita quel giorno: si controllano solo le celle frigo.'); end if;
  return fabula._wout(case when n = 0 then 'Tutto registrato' when n = 1 then 'Perché manca una registrazione' else format('Perché mancano %s registrazioni', n) end, s);
end $$;

-- Brief del mattino (daily_brief): the day's numbers next to what they are compared with (the changes are the database's)
create or replace function fabula._why_daily_brief(d jsonb) returns jsonb
language plpgsql stable set search_path = fabula, public as $$
declare s jsonb[] := '{}'; r jsonb[]; x jsonb;
begin
  r := array[
    fabula._wr('Incasso del giorno', fabula._we(d #> '{sales_trend,yesterday_eur}'), null, 'b'),
    fabula._wr('Media dello stesso giorno', fabula._we(d #> '{sales_trend,same_weekday_avg_4w_eur}'), 'ultime 4 settimane'),
    case when fabula._wpct(d #> '{changes,sales_vs_same_weekday_pct}') is not null then fabula._wr('Differenza', fabula._wpct(d #> '{changes,sales_vs_same_weekday_pct}')) end,
    fabula._wr('Settimana finora', fabula._we(d #> '{sales_trend,week_to_date_eur}'))];
  for x in select y from jsonb_array_elements(coalesce(d->'sales', '[]'::jsonb)) y loop
    r := r || fabula._wr('· ' || fabula._wchan(x->>'channel'), fabula._we(x->'revenue_eur'), case when fabula._wn(x->'orders') is not null then fabula.it_n(fabula._wn(x->'orders'), 'ordine', 'ordini') end);
  end loop;
  s := s || fabula._wsec('Vendite', r);
  r := '{}';
  for x in select y from jsonb_array_elements(coalesce(d->'production', '[]'::jsonb)) y loop
    r := r || fabula._wr(coalesce(x->>'product', 'n/d'), fabula._wq(x->'output_kg'),
                         format('%s · latte %s · resa %s', case when fabula._wn(x->'batches') is not null then fabula.it_n(fabula._wn(x->'batches'), 'lotto', 'lotti') else 'n/d lotti' end,
                                fabula._wq(x->'milk_in_kg'), fabula._wq(x->'yield_pct', '%')));
  end loop;
  if fabula._wn(d #> '{yield,yesterday}') is not null or fabula._wn(d #> '{yield,avg_30d}') is not null then
    r := r || fabula._wr('Resa della mozzarella', fabula._wq(d #> '{yield,yesterday}', '%'),
                         format('media 7 giorni %s · 30 giorni %s', fabula._wq(d #> '{yield,avg_7d}', '%'), fabula._wq(d #> '{yield,avg_30d}', '%')))
         || case when fabula._wpct(d #> '{changes,yield_vs_30d_points}', 'punti') is not null then fabula._wr('Differenza dai 30 giorni', fabula._wpct(d #> '{changes,yield_vs_30d_points}', 'punti')) end;
  end if;
  s := s || fabula._wsec('Produzione', r);
  r := '{}';
  for x in select y from jsonb_array_elements(coalesce(d->'milk', '[]'::jsonb)) y loop
    r := r || fabula._wr('Latte ' || coalesce(x->>'lot', ''), fabula._wq(x->'kg'),
                         concat_ws(' · ', case when x->>'temp_c' is not null then fabula._wq(x->'temp_c', '°C') end,
                                           case when not fabula._wb(x->'accepted') then 'respinto' || coalesce(': ' || (x->>'reason'), '') end),
                         case when not fabula._wb(x->'accepted') then 'ko' end);
  end loop;
  s := s || fabula._wsec('Latte arrivato', r);
  if fabula._wn(d #> '{energy,yesterday_kwh}') is not null then
    s := s || fabula._wsec('Energia', array[
      fabula._wr('Consumo', fabula._wq(d #> '{energy,yesterday_kwh}', 'kWh')),
      fabula._wr('Per kg prodotto', fabula._wq(d #> '{energy,yesterday_kwh_per_kg}', 'kWh/kg'),
                 concat_ws(' · ', 'media 30 giorni ' || fabula._wq(d #> '{energy,avg_30d_kwh_per_kg}', 'kWh/kg'), fabula._wpct(d #> '{changes,energy_kwh_per_kg_vs_30d_pct}')))]);
  end if;
  if coalesce(fabula._wn(d #> '{waste,last_7d_kg}'), 0) > 0 then
    s := s || fabula._wsec('Scarti', array[
      fabula._wr('Scarti del giorno', fabula._wq(d #> '{waste,yesterday_kg}')),
      fabula._wr('Ultimi 7 giorni', fabula._wq(d #> '{waste,last_7d_kg}'),
                 case when d #>> '{waste,last_7d_pct_of_output}' is not null then fabula._wq(d #> '{waste,last_7d_pct_of_output}', '%') || ' della produzione' end)]);
  end if;
  s := s || fabula._wsec('Registrazioni HACCP', array[
    fabula._wr('Registrazioni del giorno', coalesce(d #>> '{haccp,checks_logged}', 'n/d')),
    case when jsonb_array_length(coalesce(d #> '{haccp,missing_daily_checks}', '[]'::jsonb)) > 0 then
      fabula._wr('Mancanti', jsonb_array_length(d #> '{haccp,missing_daily_checks}')::text,
                 (select string_agg(coalesce((select cp.name from fabula.haccp_control_points cp where cp.code = y #>> '{}'), y #>> '{}'), ', ') from jsonb_array_elements(d #> '{haccp,missing_daily_checks}') y), 'ko') end,
    case when jsonb_array_length(coalesce(d #> '{haccp,non_conformities}', '[]'::jsonb)) > 0 then
      fabula._wr('Non conformità del giorno', jsonb_array_length(d #> '{haccp,non_conformities}')::text, null, 'ko') end]);
  r := '{}';
  for x in select y from jsonb_array_elements(coalesce(d->'pending_approvals', '[]'::jsonb)) y loop
    r := r || fabula._wr(coalesce(x->>'summary', 'Richiesta'), case when fabula._wn(x->'age_days') > 0 then 'da ' || fabula.it_n(fabula._wn(x->'age_days'), 'giorno', 'giorni') else 'del giorno' end);
  end loop;
  s := s || fabula._wsec('Da approvare', r);
  s := s || fabula._wsec('Scadenze e attività', array[
    case when jsonb_array_length(coalesce(d #> '{tasks,overdue}', '[]'::jsonb)) > 0 then fabula._wr('Attività scadute', jsonb_array_length(d #> '{tasks,overdue}')::text, null, 'ko') end,
    case when jsonb_array_length(coalesce(d #> '{tasks,calibration_due}', '[]'::jsonb)) > 0 then
      fabula._wr('Tarature in scadenza', jsonb_array_length(d #> '{tasks,calibration_due}')::text, (select string_agg(y->>'code', ', ') from jsonb_array_elements(d #> '{tasks,calibration_due}') y)) end,
    case when jsonb_array_length(coalesce(d #> '{tasks,training_expiring}', '[]'::jsonb)) > 0 then
      fabula._wr('Formazione in scadenza', jsonb_array_length(d #> '{tasks,training_expiring}')::text, (select string_agg(y->>'name', ', ') from jsonb_array_elements(d #> '{tasks,training_expiring}') y)) end,
    case when fabula._wn(d #> '{tasks,open_non_conformities}') > 0 then fabula._wr('Non conformità aperte', d #>> '{tasks,open_non_conformities}', null, 'ko') end]);
  r := '{}';
  for x in select y from jsonb_array_elements(coalesce(d->'procurement_signals', '[]'::jsonb)) y loop
    r := r || fabula._wr(coalesce(x->>'name', x->>'sku', 'n/d'), fabula._wq(x->'on_hand', ''), case when x->>'days_cover' is not null then 'copertura ' || fabula._wq(x->'days_cover', 'giorni') end);
  end loop;
  s := s || fabula._wsec('Materiali sotto scorta', r);
  if jsonb_typeof(d->'pos_close') = 'object' then
    s := s || fabula._wsec('Cassa', array[
      fabula._wr('Registratore', fabula._we(d #> '{pos_close,rt_total_eur}', 2)),
      fabula._wr('Registrato', fabula._we(d #> '{pos_close,recorded_eur}', 2)),
      fabula._wr('Differenza', fabula._we(d #> '{pos_close,variance_eur}', 2), null, case when abs(coalesce(fabula._wn(d #> '{pos_close,variance_eur}'), 0)) >= 1 then 'ko' end)]);
  end if;
  return fabula._wout(format('I numeri di %s', fabula._wd(d->'date')), s);
end $$;

-- Brief settimanale (weekly_brief, the Monday part): this week next to the previous one (the changes are the database's)
create or replace function fabula._why_weekly_brief(d jsonb) returns jsonb
language plpgsql stable set search_path = fabula, public as $$
declare s jsonb[] := '{}'; tw jsonb := coalesce(d->'this_week', '{}'::jsonb); pw jsonb := coalesce(d->'previous_week', '{}'::jsonb); ch jsonb := coalesce(d->'changes', '{}'::jsonb);
        p jsonb := coalesce(d->'pnl_estimate', '{}'::jsonb); x record; r jsonb[] := '{}';
begin
  -- this week, the previous one and the change, for one value
  s := s || fabula._wsec('Vendite', array[
    fabula._wr('Incasso', fabula._we(tw #> '{sales,revenue_eur}'), concat_ws(' · ', 'settimana prima ' || fabula._we(pw #> '{sales,revenue_eur}'), fabula._wpct(ch #> '{sales,revenue_eur}')), 'b'),
    fabula._wr('Ordini', coalesce(tw #>> '{sales,orders}', 'n/d'), concat_ws(' · ', 'settimana prima ' || coalesce(pw #>> '{sales,orders}', 'n/d'), fabula._wpct(ch #> '{sales,orders}'))),
    fabula._wr('Mozzarella venduta', fabula._wq(tw #> '{sales,mozzarella_sold_kg}'), concat_ws(' · ', 'settimana prima ' || fabula._wq(pw #> '{sales,mozzarella_sold_kg}'), fabula._wpct(ch #> '{sales,mozzarella_sold_kg}'))),
    case when fabula._wn(tw #> '{sales,ricotta_sold_kg}') > 0 or fabula._wn(pw #> '{sales,ricotta_sold_kg}') > 0 then
      fabula._wr('Ricotta venduta', fabula._wq(tw #> '{sales,ricotta_sold_kg}'), 'settimana prima ' || fabula._wq(pw #> '{sales,ricotta_sold_kg}')) end,
    case when tw #>> '{sales,avg_price_moz_eur_kg}' is not null then fabula._wr('Prezzo medio della mozzarella', fabula._we(tw #> '{sales,avg_price_moz_eur_kg}', 2) || '/kg') end]);
  for x in select k, v from jsonb_each(coalesce(tw #> '{sales,by_channel_eur}', '{}'::jsonb)) e(k, v) loop
    r := r || fabula._wr(fabula._wchan(x.k), fabula._we(x.v), 'settimana prima ' || fabula._we(pw #> array['sales', 'by_channel_eur', x.k]));
  end loop;
  s := s || fabula._wsec('Per canale', r);
  s := s || fabula._wsec('Produzione', array[
    fabula._wr('Lotti', coalesce(tw #>> '{production,batches}', 'n/d'), 'giorni di produzione ' || coalesce(tw #>> '{production,days_produced}', 'n/d')),
    fabula._wr('Mozzarella', fabula._wq(tw #> '{production,mozzarella_kg}'), concat_ws(' · ', 'settimana prima ' || fabula._wq(pw #> '{production,mozzarella_kg}'), fabula._wpct(ch #> '{production,mozzarella_kg}'))),
    case when fabula._wn(tw #> '{production,ricotta_kg}') > 0 then fabula._wr('Ricotta', fabula._wq(tw #> '{production,ricotta_kg}')) end,
    fabula._wr('Latte lavorato', fabula._wq(tw #> '{production,milk_processed_kg}'), 'ricevuto ' || fabula._wq(tw #> '{production,milk_received_kg}')),
    fabula._wr('Resa', fabula._wq(tw #> '{production,yield_pct}', '%'), 'media 30 giorni ' || fabula._wq(tw #> '{production,yield_30d_pct}', '%')),
    fabula._wr('Costo del latte', fabula._we(tw #> '{production,milk_cost_eur}')),
    case when fabula._wn(tw #> '{production,milk_rejected_deliveries}') > 0 then fabula._wr('Consegne di latte respinte', tw #>> '{production,milk_rejected_deliveries}', null, 'ko') end]);
  s := s || fabula._wsec('Scarti ed energia', array[
    fabula._wr('Scarti', fabula._wq(tw #> '{waste,total_kg}'), case when tw #>> '{waste,pct_of_mozzarella_output}' is not null then fabula._wq(tw #> '{waste,pct_of_mozzarella_output}', '%') || ' della mozzarella prodotta' end),
    fabula._wr('Energia', fabula._wq(tw #> '{energy,kwh}', 'kWh'), case when tw #>> '{energy,kwh_per_kg}' is not null then fabula._wq(tw #> '{energy,kwh_per_kg}', 'kWh/kg') end)]);
  s := s || fabula._wsec('Registrazioni', array[
    fabula._wr('Registrazioni HACCP', coalesce(tw #>> '{compliance,checks_logged}', 'n/d')),
    fabula._wr('Registrazioni mancanti', coalesce(tw #>> '{compliance,missing_checks}', 'n/d'), null, case when fabula._wn(tw #> '{compliance,missing_checks}') > 0 then 'ko' end),
    fabula._wr('Non conformità', coalesce(tw #>> '{compliance,non_conformities}', 'n/d'), null, case when fabula._wn(tw #> '{compliance,non_conformities}') > 0 then 'ko' end),
    fabula._wr('Chiusure di cassa', coalesce(tw #>> '{compliance,pos_closes}', 'n/d'),
               case when fabula._wn(tw #> '{compliance,pos_closes_with_variance}') > 0 then format('%s con differenza (in tutto %s)', tw #>> '{compliance,pos_closes_with_variance}', fabula._we(tw #> '{compliance,pos_abs_variance_eur}', 2)) end)]);
  s := s || fabula._wsec('Piani latte', array[
    fabula._wr('Approvati', coalesce(tw #>> '{milk_plans,approved}', 'n/d')), fabula._wr('Proposti', coalesce(tw #>> '{milk_plans,proposed}', 'n/d')),
    fabula._wr('Rifiutati', coalesce(tw #>> '{milk_plans,rejected}', 'n/d'))]);
  s := s || fabula._wsec('Acquisti', array[
    fabula._wr('Ordini proposti', coalesce(tw #>> '{procurement,pos_proposed}', 'n/d'), 'approvati ' || coalesce(tw #>> '{procurement,pos_approved}', 'n/d')),
    fabula._wr('Approvati', fabula._we(tw #> '{procurement,approved_eur}')),
    fabula._wr('Consumabili usati', fabula._we(tw #> '{procurement,consumables_used_eur}', 2))]);
  if p <> '{}'::jsonb then
    s := s || fabula._wsec('Conto della settimana (stima)', array[
      fabula._wr('Incasso', fabula._we(p->'revenue_eur', 2)),
      fabula._wr('Latte', fabula._wneg(p->'milk_cost_eur')),
      fabula._wr('Consumabili', fabula._wneg(p->'consumables_cost_eur')),
      fabula._wr('Lavoro', fabula._wneg(p->'labor_eur'), case p->>'labor_source' when 'benchmark' then 'stima: nessuna ora di badge' else fabula._wq(p->'labor_hours', 'ore') || ' di badge' end),
      fabula._wr('Utenze', fabula._wneg(p->'utilities_eur')), fabula._wr('Affitto', fabula._wneg(p->'lease_eur')),
      fabula._wr('Marketing', fabula._wneg(p->'marketing_eur')), fabula._wr('Internet', fabula._wneg(p->'internet_eur')),
      fabula._wr('Risultato operativo', fabula._we(p->'operating_result_eur', 2), null, case when fabula._wn(p->'operating_result_eur') < 0 then 'ko' else 'b' end),
      case when fabula._wn(p->'revenue_eur') >= 500 and p->>'margin_pct' is not null then fabula._wr('Margine', fabula._wq(p->'margin_pct', '%')) end],
      'Incasso e latte sono reali; consumabili a prezzo di listino; il lavoro dalle ore di badge quando ci sono; le altre voci sono stime (benchmark annuale diviso 52) finché non arrivano i dati veri. Il margine compare da € 500 di incasso.');
  end if;
  s := s || fabula._wsec('Ancora aperti', array[
    case when fabula._wn(d #> '{open_items,pending_approvals}') > 0 then fabula._wr('Richieste da decidere', d #>> '{open_items,pending_approvals}',
      'la più vecchia ' || case when fabula._wn(d #> '{open_items,oldest_pending_days}') > 0 then 'da ' || fabula.it_n(fabula._wn(d #> '{open_items,oldest_pending_days}'), 'giorno', 'giorni') else 'è di oggi' end) end,
    case when fabula._wn(d #> '{open_items,open_non_conformities}') > 0 then fabula._wr('Non conformità aperte', d #>> '{open_items,open_non_conformities}', null, 'ko') end,
    case when fabula._wn(d #> '{open_items,bot_errors}') > 0 then fabula._wr('Errori dei bot', d #>> '{open_items,bot_errors}', null, 'ko') end]);
  return fabula._wout(format('La settimana dal %s al %s', fabula._wd(d->'week_start'), fabula._wd(d->'week_end')), s);
end $$;

-- the system checks (infra_checks), also inside the evening check's data when the database stood in for it
create or replace function fabula._why_infra_rows(x jsonb) returns jsonb[]
language sql stable set search_path = fabula, public as $$
  select coalesce(array_agg(fabula._wr(coalesce(l.label_it, 'Altro controllo'), case when fabula._wb(v->'done') then 'in ordine' else 'da sistemare' end,
                                       v->>'detail', case when not fabula._wb(v->'done') then 'ko' end) order by coalesce(l.o, 99), k), '{}')
    from jsonb_each(case when jsonb_typeof(x) = 'object' then x else '{}'::jsonb end) e(k, v)
    left join (values (1, 'uptime', 'Sito e funzioni del server'), (2, 'cron_jobs', 'Attività programmate del database'), (3, 'vault_secret', 'Segreto del backup'),
                      (4, 'offsite_backup', 'Copia del backup fuori sede'), (5, 'outside_watcher', 'Monitor esterno (GitHub)'), (6, 'restore_tested', 'Prova di ripristino'),
                      (7, 'repo_sync', 'Migrazioni: GitHub e database'), (8, 'code_pushed', 'Codice su GitHub'), (9, 'app_deployed', 'App del tablet pubblicata'),
                      (10, 'advisors_clean', 'Sicurezza del database')) l(o, key, label_it) on l.key = e.k
   where jsonb_typeof(v) = 'object'
$$;
create or replace function fabula._why_infra(d jsonb) returns jsonb
language sql stable set search_path = fabula, public as $$
  select fabula._wout(case when (select count(*) from jsonb_each(d) e(k, v) where jsonb_typeof(v) = 'object' and not fabula._wb(v->'done')) = 0 then 'Controlli del sistema in ordine'
                           else format('Controlli del sistema: %s da sistemare', (select count(*) from jsonb_each(d) e(k, v) where jsonb_typeof(v) = 'object' and not fabula._wb(v->'done'))) end,
                      array[fabula._wsec('Sistema', fabula._why_infra_rows(d))])
$$;

-- Controllo sistema (ops_health_check)
create or replace function fabula._why_ops_health(d jsonb) returns jsonb
language plpgsql stable set search_path = fabula, public as $$
declare s jsonb[] := '{}'; r jsonb[] := '{}'; b jsonb; n_ok int := 0; n int; q jsonb;
begin
  for b in select x from jsonb_array_elements(coalesce(d->'bots', '[]'::jsonb)) x loop
    continue when b->>'agent' = 'ops_health';           -- the evening check itself: it is the one running now
    if fabula._wb(b->'ran') and coalesce(fabula._wn(b->'errors'), 0) = 0 then n_ok := n_ok + 1; continue; end if;
    r := r || fabula._wr(fabula.bot_title(b->>'agent'), case when not fabula._wb(b->'ran') then 'non partito' else fabula.it_n(fabula._wn(b->'errors'), 'errore', 'errori') end, null, 'ko');
  end loop;
  if n_ok > 0 then r := r || fabula._wr('Bot regolari', n_ok::text); end if;
  s := s || fabula._wsec('Bot di oggi', r);
  r := '{}';
  for q in select x from jsonb_array_elements(coalesce(d->'data_quality', '[]'::jsonb)) x loop
    r := r || fabula._wr(coalesce(q->>'text', 'n/d'), null, null,
                         case when q->>'key' in ('nc_critical_open', 'held_lot_sold', 'ccp_missing', 'instrument_out_of_service', 'pest_inside_7d', 'lots_on_hold') then 'ko' end);
  end loop;
  s := s || fabula._wsec('Dati e sicurezza alimentare', r);
  if d ? 'infra_checks' then s := s || fabula._wsec('Sistema', fabula._why_infra_rows(d->'infra_checks')); end if;
  n := coalesce(fabula._wn(d->'issues'), 0)::int + coalesce(fabula._wn(d->'bots_errors'), 0)::int
       + (select count(*) from jsonb_array_elements_text(coalesce(d->'bots_missing', '[]'::jsonb)) a where a <> 'ops_health')::int;
  return fabula._wout(case when n = 0 then 'Nessun problema nei bot e nei dati' when n = 1 then 'Perché una cosa da controllare' else format('Perché %s cose da controllare', n) end, s);
end $$;

-- Manutenzioni e scadenze (compliance_calendar)
create or replace function fabula._why_compliance(d jsonb) returns jsonb
language plpgsql stable set search_path = fabula, public as $$
declare s jsonb[] := '{}'; b record; r jsonb[]; i jsonb; f jsonb := coalesce(d->'food_safety', '{}'::jsonb);
begin
  for b in select * from (values ('overdue', 'Scadute', 'ko'), ('due_30', 'Entro 30 giorni', null), ('due_60', 'Entro 60 giorni', null)) v(k, t, fl) loop
    r := '{}';
    for i in select x from jsonb_array_elements(coalesce(d->b.k, '[]'::jsonb)) x limit 15 loop
      r := r || fabula._wr(coalesce(i->>'subject', 'n/d') || coalesce(' (' || (i->>'ref') || ')', ''), fabula._wd(i->'due_on'),
        concat_ws(' · ', case i->>'kind' when 'calibration' then 'taratura' when 'maintenance' then 'manutenzione' when 'training' then 'formazione'
                                         when 'campionamento' then 'analisi di laboratorio' when 'pest_control' then 'disinfestazione' when 'environment' then 'ambiente'
                                         when 'extinguishers' then 'estintori' when 'electrical_check' then 'verifica impianto elettrico' when 'water_analysis' then 'analisi dell''acqua'
                                         when 'consorzio_fee' then 'quota Consorzio' when 'haccp_plan_review' then 'revisione del piano HACCP' end,
                  case when i->>'last_done' is not null then 'ultima ' || fabula._wd(i->'last_done') end,
                  case when i->>'interval_days' is not null then 'ogni ' || (i->>'interval_days') || ' giorni' end,
                  case when i->>'responsible' is not null then 'responsabile ' || (i->>'responsible') end), b.fl);
    end loop;
    s := s || fabula._wsec(b.t, r);
  end loop;
  if fabula._wn(d #> '{counts,unknown}') > 0 then
    s := s || fabula._wsec('Senza data', array[fabula._wr('Da completare', d #>> '{counts,unknown}',
      (select string_agg(x->>'subject', ', ') from (select x from jsonb_array_elements(coalesce(d->'unknown_dates', '[]'::jsonb)) x limit 6) y)
      || case when fabula._wn(d #> '{counts,unknown}') > 6 then ' e altre' else '' end || ' — le date si inseriscono in Configurazione → Macchine e scadenze')]);
  end if;
  r := '{}';
  for i in select x from jsonb_array_elements(coalesce(f->'lab_results_pending', '[]'::jsonb)) x loop
    r := r || fabula._wr('Referto ' || coalesce(i->>'sample', '') || coalesce(' · ' || (i->>'analyte'), ''), case when fabula._wn(i->'days') is not null then 'atteso da ' || fabula.it_n(fabula._wn(i->'days'), 'giorno', 'giorni') else 'atteso' end, 'prelievo ' || fabula._wd(i->'taken_on'));
  end loop;
  r := r || case when jsonb_array_length(coalesce(f->'instruments_out_of_service', '[]'::jsonb)) > 0 then
              fabula._wr('Strumenti fuori servizio', (select string_agg(x #>> '{}', ', ') from jsonb_array_elements(f->'instruments_out_of_service') x), null, 'ko') end
        || case when jsonb_array_length(coalesce(f->'lots_on_hold', '[]'::jsonb)) > 0 then
              fabula._wr('Lotti bloccati', (select string_agg(x #>> '{}', ', ') from jsonb_array_elements(f->'lots_on_hold') x), null, 'ko') end
        || case when fabula._wn(f->'nc_open') > 0 then fabula._wr('Non conformità aperte', f->>'nc_open', case when fabula._wn(f->'nc_critical_open') > 0 then (f->>'nc_critical_open') || ' critiche' end,
                                                                  case when fabula._wn(f->'nc_critical_open') > 0 then 'ko' end) end
        || case when f ? 'pest_last_internal' or f ? 'pest_last_company' then
              fabula._wr('Ultimo controllo infestanti', fabula._wd(f->'pest_last_internal'), 'ditta: ' || fabula._wd(f->'pest_last_company')) end;
  s := s || fabula._wsec('Sicurezza alimentare', r);
  return fabula._wout(format('Scadenze: %s scadute, %s entro 30 giorni', coalesce(d #>> '{counts,overdue}', 'n/d'), coalesce(d #>> '{counts,due_30}', 'n/d')), s);
end $$;

-- Revisione mensile (monthly_review)
create or replace function fabula._why_monthly(d jsonb) returns jsonb
language plpgsql stable set search_path = fabula, public as $$
declare s jsonb[] := '{}'; u jsonb := coalesce(d->'unit_cost', '{}'::jsonb); q jsonb := coalesce(d->'milk_quality', '{}'::jsonb); h jsonb := coalesce(d->'package_headline', '{}'::jsonb);
        r jsonb[] := '{}'; c jsonb;
begin
  s := s || fabula._wsec('Costo pieno della mozzarella', array[
    fabula._wr('Mozzarella prodotta', fabula._wq(u->'mozzarella_kg')),
    fabula._wr('Latte', fabula._we(u->'milk_eur', 2)),
    fabula._wr('Consumabili', fabula._we(u->'consumables_eur', 2)),
    fabula._wr('Energia', fabula._we(u->'energy_eur', 2), fabula._wq(u->'energy_kwh', 'kWh')),
    fabula._wr('Lavoro', fabula._we(u->'labor_eur', 2), case u->>'labor_source' when 'actual' then fabula._wq(u->'labor_hours', 'ore') || ' di badge' else 'stima: nessuna ora di badge (benchmark annuale diviso 12)' end),
    fabula._wr('Costo pieno al kg', fabula._we(u->'cost_eur_per_kg', 2), null, 'b'),
    case when u->>'milk_share_pct' is not null then fabula._wr('Quota del latte', fabula._wq(u->'milk_share_pct', '%')) end,
    case when u->>'wholesale_floor_eur_kg' is not null then fabula._wr('Prezzo minimo ingrosso', fabula._we(u->'wholesale_floor_eur_kg', 2) || '/kg', 'costo pieno + 15 %') end],
    'Costo pieno = latte + consumabili + energia + lavoro; utenze diverse, affitto e marketing esclusi.');
  for c in select x from jsonb_array_elements(coalesce(u->'price_by_channel', '[]'::jsonb)) x loop
    r := r || fabula._wr(fabula._wchan(c->>'channel'), fabula._we(c->'avg_price_eur_kg', 2) || '/kg',
                         concat_ws(' · ', fabula._wq(c->'kg') || ' venduti', case when c->>'margin_eur_kg' is not null then 'margine ' || fabula._we(c->'margin_eur_kg', 2) || '/kg' end),
                         case when fabula._wn(c->'margin_eur_kg') < 0 then 'ko' end);
  end loop;
  s := s || fabula._wsec('Prezzi per canale', r);
  s := s || fabula._wsec('Qualità del latte', array[
    fabula._wr('Consegne', coalesce(q->>'deliveries', 'n/d'), case when fabula._wn(q->'rejected') > 0 then (q->>'rejected') || ' respinte' end, case when fabula._wn(q->'rejected') > 0 then 'ko' end),
    fabula._wr('Grasso', fabula._wq(q->'fat_pct', '%'), 'mese prima ' || fabula._wq(q->'fat_pct_prev', '%')),
    fabula._wr('Proteine', fabula._wq(q->'protein_pct', '%'), 'mese prima ' || fabula._wq(q->'protein_pct_prev', '%')),
    case when q->>'scc_avg' is not null then fabula._wr('Cellule somatiche (media)', fabula.it_num(fabula._wn(q->'scc_avg'), 0) || '/ml', coalesce(q->>'scc_over_400k', '0') || ' consegne sopra 400.000') end,
    case when fabula._wn(q->'temp_over_4c') > 0 then fabula._wr('Consegne sopra 4 °C', q->>'temp_over_4c', null, 'ko') end]);
  s := s || fabula._wsec('Il mese in breve', array[
    fabula._wr('Incasso', fabula._we(h->'revenue_eur', 2)), fabula._wr('Corrispettivi', fabula._we(h->'corrispettivi_eur', 2)),
    fabula._wr('Acquisti ricevuti', fabula._we(h->'purchases_eur', 2)), fabula._wr('Latte', fabula._we(h->'milk_eur', 2)),
    fabula._wr('Magazzino', fabula._we(h->'inventory_eur', 2)), fabula._wr('Scarti', fabula._wq(h->'waste_kg'))]);
  return fabula._wout('Il mese di ' || fabula._wmonth(d->>'month'), s);
end $$;

-- Approvazioni automatiche (the database's auto_approve)
create or replace function fabula._why_auto_approve(d jsonb) returns jsonb
language plpgsql stable set search_path = fabula, public as $$
declare p jsonb := coalesce(d->'payload', '{}'::jsonb); s jsonb[] := '{}';
begin
  s := s || fabula._wsec('La regola', array[
    fabula._wr('Richiesta', null, d->>'summary'),
    fabula._wr('Regola', null, d->>'rule_it', 'b'),
    fabula._wr('Nessuno ha deciso entro', coalesce('le ' || fabula._wt(d->'auto_approve_at'), 'n/d'), 'ora italiana'),
    fabula._wr('Approvato', fabula._wd(d->'decided_at') || coalesce(' ore ' || fabula._wt(d->'decided_at'), ''))],
    'Le regole si cambiano o si spengono in Configurazione → Parametri → Approvazioni automatiche. Finché si può, si annulla da Console → Oggi → Decise di recente.');
  s := s || case d->>'type'
    when 'milk_plan' then fabula._wsec('Il piano latte', array[fabula._wr('Latte', fabula._wq(p->'milk_kg')), fabula._wr('Mozzarella prevista', fabula._wq(p->'planned_output_kg')),
                                                            fabula._wr('Costo stimato', fabula._we(p->'est_cost_eur'))])
    when 'purchase_order' then fabula._wsec('L''ordine', array[fabula._wr('Ordine', coalesce(p->>'po_number', 'n/d'), p->>'supplier'),
                                                            fabula._wr('Quantità', fabula._wq(p->'qty', coalesce(p->>'unit', ''))), fabula._wr('Prezzo', fabula._we(p->'unit_price_eur', 2)),
                                                            fabula._wr('Totale', fabula._we(coalesce(p->'total_eur', d->'amount_eur')), 'IVA esclusa')])
    when 'sell_down' then fabula._wsec('La promo', array[fabula._wr('Lotto', coalesce(p->>'lot', 'n/d')), fabula._wr('A rischio', fabula._wq(p->'at_risk_kg')),
                                                       fabula._wr('Sconto', fabula._wq(p->'promo_pct', '%')), fabula._wr('Prezzo promo', fabula._we(p->'promo_price_eur_kg', 2) || ' al kg')])
    end;
  return fabula._wout('Perché si è approvato da solo', s);
end $$;

-- Sicurezza alimentare: a lot closed without its CCP (batch_ccp)
create or replace function fabula._why_batch_ccp(d jsonb) returns jsonb
language plpgsql stable set search_path = fabula, public as $$
declare r jsonb[] := '{}'; p jsonb;
begin
  for p in select x from jsonb_array_elements(coalesce(d->'points', '[]'::jsonb)) x loop
    r := r || fabula._wr(concat_ws(' ', p->>'ccp_no', p->>'name'),
                         case when p->'value' is null or jsonb_typeof(p->'value') = 'null' then '⚠ mancante' else fabula._wq(p->'value', coalesce(p->>'unit', '')) end,
                         coalesce(p->>'limit_it', case when p->>'min' is not null or p->>'max' is not null then concat_ws(' ', 'limite', fabula._wq(p->'min', ''), '–', fabula._wq(p->'max', coalesce(p->>'unit', ''))) end),
                         case when p->'value' is null or jsonb_typeof(p->'value') = 'null' then 'ko' end);
  end loop;
  return fabula._wout(format('Perché il lotto %s è bloccato', coalesce(d->>'lot', 'n/d')), array[
    fabula._wsec('Le misure del lotto alla chiusura', r),
    fabula._wsec('Cosa vuol dire', array[fabula._wr('Lotto', 'bloccato', 'Non si confeziona e non si vende finché il responsabile HACCP non lo sblocca (Autocontrollo → Lotti bloccati).', 'ko')],
                 'Se la misura è stata fatta su carta: tablet → 🛡 → Ricopia da foglio di carta, con data e ora del foglio.')]);
end $$;

-- Sicurezza alimentare: milk rejected (milk_reject)
create or replace function fabula._why_milk_reject(d jsonb) returns jsonb
language sql stable set search_path = fabula, public as $$
  select fabula._wout(format('Perché il latte %s è respinto', coalesce(d->>'milk_lot', 'n/d')), array[
    fabula._wsec('La consegna', array[
      fabula._wr('Motivo', null, d->>'reason', 'ko'),
      fabula._wr('Quantità', fabula._wq(d->'qty_kg')),
      fabula._wr('Consegna', fabula._wd(d->'intake_date'), case when d->>'ddt_number' is not null then 'DDT ' || (d->>'ddt_number') end),
      case when d->>'temperature_c' is not null then fabula._wr('Temperatura all''arrivo', fabula._wq(d->'temperature_c', '°C')) end,
      fabula._wr('Lotti bloccati', case when jsonb_array_length(coalesce(d->'lots_held', '[]'::jsonb)) = 0 then 'nessuno'
                                        else (select string_agg(x #>> '{}', ', ') from jsonb_array_elements(d->'lots_held') x) end,
                 case when jsonb_array_length(coalesce(d->'lots_held', '[]'::jsonb)) > 0 then 'fatti con questo latte: non vendere finché il responsabile HACCP non li sblocca' end,
                 case when jsonb_array_length(coalesce(d->'lots_held', '[]'::jsonb)) > 0 then 'ko' end)])])
$$;

-- Produzione della sera (prod_watch): open lots, milk close to 60 hours
create or replace function fabula._why_prod_watch(d jsonb) returns jsonb
language plpgsql stable set search_path = fabula, public as $$
declare r jsonb[] := '{}'; m jsonb[] := '{}'; x jsonb;
begin
  for x in select y from jsonb_array_elements(coalesce(d->'open_batches', '[]'::jsonb)) y loop
    r := r || fabula._wr('Lotto ' || coalesce(x->>'lot', ''), 'avviato ' || fabula._wd(x->'started') || coalesce(' ore ' || fabula._wt(x->'started'), ''),
                         'non ancora chiuso: se è finito si chiude con i kg, se è stato scartato si registra lo scarto');
  end loop;
  for x in select y from jsonb_array_elements(coalesce(d->'old_milk', '[]'::jsonb)) y loop
    m := m || fabula._wr('Latte ' || coalesce(x->>'lot', ''), fabula._wq(x->'left_kg') || ' da lavorare',
                         format('arrivato %s ore %s: %s fa', fabula._wd(x->'arrived'), coalesce(fabula._wt(x->'arrived'), 'n/d'),
                                case when fabula._wn(x->'hours') is not null then fabula.it_n(fabula._wn(x->'hours'), 'ora', 'ore') else 'n/d ore' end), 'ko');
  end loop;
  return fabula._wout('Perché questo avviso della sera', array[
    fabula._wsec('Lotti aperti', r),
    fabula._wsec('Latte vicino alle 60 ore', m, case when cardinality(m) > 0 then
      format('Il disciplinare DOP consente %s ore dalla mungitura; l''avviso parte a %s ore dall''arrivo (dalla mungitura sono di più). Lavoralo domattina per primo o non usarlo per la DOP.',
             coalesce(d->>'dop_limit_hours', '60'), coalesce(d->>'warn_hours', '48')) end)]);
end $$;

-- any other read: only the values that have an Italian label (fabula.basis_labels), never raw keys
create table if not exists fabula.basis_labels (
  key      text primary key,
  label_it text not null,
  unit     text,
  sort     integer not null default 100
);
comment on table fabula.basis_labels is 'v1.06 («Perché?»): Italian labels for the values of a read that has no explainer of its own. A key without a label is not shown.';
alter table fabula.basis_labels enable row level security;
revoke all on fabula.basis_labels from public, anon, authenticated;
insert into fabula.table_areas (table_name, area, write_level, read_open) values ('basis_labels', 'sistema', 3, false) on conflict do nothing;
insert into fabula.basis_labels (key, label_it, unit, sort) values
  ('date', 'Giorno', 'date', 1), ('month', 'Mese', null, 2), ('count', 'Quanti', null, 10), ('total', 'Totale', null, 11),
  ('total_kg', 'Totale', 'kg', 12), ('total_eur', 'Totale', '€', 13), ('revenue_eur', 'Incasso', '€', 14), ('kg', 'Quantità', 'kg', 15),
  ('milk_kg', 'Latte', 'kg', 16), ('at_risk_kg', 'A rischio', 'kg', 17), ('issues', 'Problemi', null, 18), ('booked', 'Prenotati', null, 19),
  ('created', 'Creati', null, 20), ('updated', 'Aggiornati', null, 21), ('leads', 'Contatti', null, 22), ('posts', 'Post', null, 23),
  ('drafts', 'Bozze', null, 24), ('pending', 'In attesa', null, 25), ('done', 'Fatti', null, 26), ('errors', 'Errori', null, 27)
on conflict (key) do nothing;
create or replace function fabula._why_generic(d jsonb) returns jsonb
language sql stable set search_path = fabula, public as $$
  select fabula._wout(null, array[fabula._wsec('Dati letti',
           (select array_agg(fabula._wr(l.label_it, case when l.unit = 'date' then fabula._wd(e.v) when l.unit = '€' then fabula._we(e.v)
                                                         when jsonb_typeof(e.v) = 'array' then jsonb_array_length(e.v)::text
                                                         when jsonb_typeof(e.v) in ('number', 'string') and fabula._wn(e.v) is not null then fabula._wq(e.v, coalesce(l.unit, ''))
                                                         when jsonb_typeof(e.v) = 'string' then left(e.v #>> '{}', 120) else null end) order by l.sort)
              from jsonb_each(case when jsonb_typeof(d) = 'object' then d else '{}'::jsonb end) e(k, v) join fabula.basis_labels l on l.key = e.k
             where jsonb_typeof(e.v) in ('number', 'string', 'array')),
           case when exists (select 1 from jsonb_each(case when jsonb_typeof(d) = 'object' then d else '{}'::jsonb end) e(k, v) where not exists (select 1 from fabula.basis_labels l where l.key = e.k))
                then 'Gli altri valori sono tecnici e non sono mostrati.' end)])
$$;

-- one read written out (never fails: a broken explainer falls back to the labelled values)
create or replace function fabula._why_explain(p_call text, p_data jsonb, p_extra jsonb) returns jsonb
language plpgsql stable set search_path = fabula, public as $$
begin
  return case p_call
    when 'plan_milk' then fabula._why_plan_milk(p_data)
    when 'propose_purchase_orders' then fabula._why_purchase(p_data, coalesce(p_extra, '{}'::jsonb))
    when 'sell_down_signals' then fabula._why_sell_down(p_data, coalesce(p_extra, '{}'::jsonb))
    when 'confirm_standing_orders' then fabula._why_wholesale(p_data)
    when 'haccp_evening_status' then fabula._why_evening(p_data)
    when 'daily_brief' then fabula._why_daily_brief(p_data)
    when 'weekly_brief' then fabula._why_weekly_brief(p_data)
    when 'ops_health_check' then fabula._why_ops_health(p_data)
    when 'infra_checks' then fabula._why_infra(p_data)
    when 'compliance_calendar' then fabula._why_compliance(p_data)
    when 'monthly_review' then fabula._why_monthly(p_data)
    when 'auto_approve' then fabula._why_auto_approve(p_data)
    when 'batch_ccp' then fabula._why_batch_ccp(p_data)
    when 'milk_reject' then fabula._why_milk_reject(p_data)
    when 'prod_watch' then fabula._why_prod_watch(p_data)
    else fabula._why_generic(p_data) end;
exception when others then
  raise warning '_why_explain %: %', p_call, sqlerrm;
  return fabula._why_generic(p_data) || jsonb_build_object('broken', true);
end $$;

create or replace function fabula._basis_call_it(p_call text) returns text
language sql immutable set search_path = fabula, public as $$
  select case p_call when 'plan_milk' then 'il calcolo del piano latte' when 'propose_purchase_orders' then 'il controllo delle scorte'
                     when 'sell_down_signals' then 'i lotti in scadenza' when 'confirm_standing_orders' then 'gli ordini fissi dell''ingrosso'
                     when 'haccp_evening_status' then 'le registrazioni della sera' when 'daily_brief' then 'i numeri del giorno'
                     when 'weekly_brief' then 'i numeri della settimana' when 'ops_health_check' then 'il controllo della sera'
                     when 'infra_checks' then 'i controlli del sistema' when 'compliance_calendar' then 'le scadenze'
                     when 'monthly_review' then 'i numeri del mese' when 'auto_approve' then 'la regola di approvazione'
                     when 'batch_ccp' then 'il registro HACCP del lotto' when 'milk_reject' then 'la consegna di latte respinta'
                     when 'prod_watch' then 'i lotti e il latte della sera' else 'i dati' end
$$;

-- ============================== message_why: what «Perché?» shows ==============================
create or replace function fabula.message_why(p_id bigint) returns jsonb
language plpgsql stable security definer set search_path = fabula, public as $$
declare m fabula.bot_messages; b record; parts jsonb := '[]'::jsonb; raw jsonb := '[]'::jsonb; ex jsonb; v_who text;
        v_sys3 boolean := fabula.perm_level('sistema') >= 3 or auth.uid() is null; v_ck jsonb; v_show_ck boolean; v_miss text[]; n_rows int; v_area text;
begin
  select * into m from fabula.bot_messages where id = p_id;
  if m.id is null then raise exception 'Questo messaggio non c''è più' using errcode = 'P0002'; end if;
  -- who sees the message sees its «Perché?»: the feed's readers (Sistema), and for an alarm or a decision on Telegram the people of its
  -- area (as my_alarms()); never the shared area «comune» (the briefs: sales, costs, people), which every login has
  v_area := fabula.message_area(m.agent, m.title);
  if auth.uid() is not null and not (fabula.can_table('bot_messages', false)
       or (v_area <> 'comune' and fabula.can(v_area, 1)
           and (m.severity = 'alert' or m.agent = any (string_to_array(replace(coalesce(fabula.setting_text('notify.decision_agents'), ''), ' ', ''), ','))))) then
    raise exception 'Il tuo profilo non vede questo messaggio' using errcode = '42501';
  end if;
  v_who := fabula.bot_display_name(m.agent);
  select count(*) into n_rows from fabula.message_basis where message_id = m.id;
  if m.basis_at is null or n_rows = 0 then
    return jsonb_build_object('id', m.id, 'title', m.title, 'agent_title', v_who, 'created_at', m.created_at, 'has_basis', m.basis_at is not null, 'parts', '[]'::jsonb,
      'none_it', case when m.basis_at is null then 'Questo messaggio non ha i dati salvati: è di prima del «Perché?», o il bot gira ancora con le istruzioni vecchie.'
                      else format('I dati di questo messaggio non ci sono più: si conservano %s giorni.', fabula.setting_num('bots.basis_keep_days', 90)) end);
  end if;
  -- one part per function read (the first time: a second identical call by mistake does not show twice), in the order they were read
  for b in select x.*, (select count(*) from fabula.message_basis y where y.message_id = m.id and y.call = x.call) n_same
             from (select distinct on (call) * from fabula.message_basis where message_id = m.id order by call, kept_at, id) x order by x.kept_at, x.id loop
    if b.too_big or b.data is null then
      ex := fabula._wout(null, array[fabula._wsec(null, null, format('I dati letti (%s KB) erano troppo grandi per essere conservati.', round(b.bytes / 1024.0)))]);
    else
      ex := fabula._why_explain(b.call, b.data, b.extra);
    end if;
    parts := parts || jsonb_build_array(ex || jsonb_build_object('call', b.call, 'call_it', fabula._basis_call_it(b.call), 'kept_at', b.kept_at, 'by', b.kept_by,
                                                                 'times', b.n_same,
                                                                 'read_it', format('Dati letti %s %s ore %s: %s%s', case when b.kept_by = 'database' then 'dal database' else 'da ' || v_who end,
                                                                                   fabula.it_day((b.kept_at at time zone 'Europe/Rome')::date), to_char(b.kept_at at time zone 'Europe/Rome', 'HH24:MI'),
                                                                                   fabula._basis_call_it(b.call), case when b.n_same > 1 then format(' (letti %s volte: qui la prima)', b.n_same) else '' end)));
    if v_sys3 then raw := raw || jsonb_build_array(jsonb_build_object('call', b.call, 'data', b.data, 'extra', b.extra)); end if;
  end loop;
  -- the number check: for Sistema «gestisce», or for everyone once bots.number_check_all = 1
  v_show_ck := v_sys3 or fabula.setting_num('bots.number_check_all', 0) = 1;
  if v_show_ck and m.basis_check ? 'numbers' then
    select coalesce(array_agg(x #>> '{}'), '{}') into v_miss from jsonb_array_elements(coalesce(m.basis_check -> 'missing', '[]'::jsonb)) x;
    v_ck := jsonb_build_object('numbers', m.basis_check -> 'numbers', 'found', m.basis_check -> 'found', 'dates', m.basis_check -> 'dates', 'dates_found', m.basis_check -> 'dates_found',
      'missing', m.basis_check -> 'missing', 'only_you', not (fabula.setting_num('bots.number_check_all', 0) = 1),
      'line_it', case when cardinality(v_miss) = 0 then format('Numeri controllati: %s e %s del messaggio sono nei dati letti.',
                                                               fabula.it_n(coalesce(fabula._wn(m.basis_check -> 'numbers'), 0), 'numero', 'numeri'),
                                                               fabula.it_n(coalesce(fabula._wn(m.basis_check -> 'dates'), 0), 'data', 'date'))
                      when cardinality(v_miss) = 1 then format('⚠ Nel messaggio c''è un numero che non si trova nei dati letti: %s. Controllalo con i dati qui sotto.', v_miss[1])
                      else format('⚠ Nel messaggio ci sono numeri che non si trovano nei dati letti: %s. Controllali con i dati qui sotto.', array_to_string(v_miss, ', ')) end);
  end if;
  return jsonb_build_object('id', m.id, 'title', m.title, 'agent_title', v_who, 'created_at', m.created_at, 'has_basis', true,
    'parts', parts, 'check', v_ck, 'raw', case when v_sys3 then raw end);
end $$;
revoke all on function fabula.message_why(bigint) from public, anon;
grant execute on function fabula.message_why(bigint) to authenticated, service_role;
comment on function fabula.message_why(bigint) is 'v1.06 («Perché?»): the data behind a bot message, written out in Italian, for the people who see the message: Sistema (the feed''s readers), or for an alarm or a Telegram decision the message''s area, never «comune». «Dati grezzi» and the number check: Sistema «gestisce» (the check for everyone with bots.number_check_all = 1).';

insert into fabula.security_accepted (key, reason) values
  ('authenticated_security_definer_function_executable:fabula.message_why(p_id bigint)', 'by design (v1.06b, «Perché?»): the data behind a bot message, only for whoever sees the message (Sistema; for an alarm or a Telegram decision its area, never «comune»); raw data and the number check only for Sistema «gestisce»'),
  ('rls_enabled_no_policy:fabula.message_basis', 'by design (v1.06a, «Perché?»): reached only through keep_basis / post_bot_message / message_why'),
  ('rls_enabled_no_policy:fabula.basis_labels', 'by design (v1.06b, «Perché?»): read only by message_why')
on conflict (key) do nothing;

-- ============================== the prompts: step-1 reads wrapped in keep_basis (tools/bots/sync_rules.py --versions) ==============================
insert into fabula.bot_prompt_versions (agent, version) values
  ('compliance_calendar', 'a4795a1a60'),
  ('daily_brief', 'e8f4648a27'),
  ('haccp_nudge', 'aa815c9982'),
  ('milk_planning', '211b385515'),
  ('monthly_review', 'f764e615dc'),
  ('ops_health', '8f00c8f547'),
  ('procurement', 'f8f4c2f497'),
  ('sell_down', '16da87dc49'),
  ('wholesale_orders', '55e0f06098')
on conflict (agent) do update set version = excluded.version, updated_at = now();
