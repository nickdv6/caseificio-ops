-- Fabula v0.83e — one console notice per key (notices.key is unique): the trade_applications notice is recomputed from the pending
-- applications; "all products" tiers on the weekly basis read the whole plan's kg, product tiers the product's kg.
set search_path = fabula, public, extensions;

create or replace function fabula.trade_notice_refresh() returns void language plpgsql security definer set search_path = fabula, public as $$
declare it jsonb;
begin
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'business', business_name, 'type', business_type, 'email', email, 'city', city, 'kg_week', expected_kg_week, 'at', created_at) order by created_at), '[]')
    into it from fabula.trade_applications where status = 'pending';
  insert into fabula.notices (key, severity, title_it, items, expires_at, resolved_at)
  values ('trade_applications', 'info', 'Richieste professionisti da valutare', it, now() + interval '30 days', case when jsonb_array_length(it) = 0 then now() end)
  on conflict (key) do update set items = excluded.items, expires_at = excluded.expires_at, resolved_at = excluded.resolved_at,
    created_at = case when fabula.notices.resolved_at is not null and excluded.resolved_at is null then now() else fabula.notices.created_at end;
end $$;
revoke all on function fabula.trade_notice_refresh() from public, anon;
grant execute on function fabula.trade_notice_refresh() to authenticated, service_role;

create or replace function fabula.trade_apply(p jsonb) returns jsonb language plpgsql security definer set search_path = fabula, public as $$
declare v uuid; v_email text := lower(trim(p->>'email'));
begin
  if not (fabula.trade_settings()->>'enabled')::boolean then raise exception 'Sezione non attiva' using errcode = '22023'; end if;
  if coalesce(trim(p->>'business_name'), '') = '' or coalesce(trim(p->>'contact_name'), '') = '' or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'Compila nome attività, referente ed email' using errcode = '22023';
  end if;
  if exists (select 1 from fabula.trade_applications where lower(email) = v_email and status = 'pending') then
    return jsonb_build_object('ok', true, 'duplicate', true, 'message_it', 'Abbiamo già ricevuto la tua richiesta: ti rispondiamo entro un giorno lavorativo.');
  end if;
  insert into fabula.trade_applications (business_name, business_type, piva, codice_fiscale, sdi_code, pec_email, contact_name, email, phone, address, city, province, postcode, expected_kg_week, preferred_days, notes, shopify_customer_id, source)
  values (trim(p->>'business_name'), coalesce(nullif(lower(trim(p->>'business_type')), ''), 'altro'), nullif(upper(regexp_replace(coalesce(p->>'piva', ''), '\s', '', 'g')), ''), nullif(trim(p->>'codice_fiscale'), ''), nullif(trim(p->>'sdi_code'), ''), nullif(trim(p->>'pec_email'), ''),
          trim(p->>'contact_name'), v_email, nullif(trim(p->>'phone'), ''), nullif(trim(p->>'address'), ''), nullif(trim(p->>'city'), ''), nullif(upper(trim(p->>'province')), ''), nullif(trim(p->>'postcode'), ''),
          nullif(replace(regexp_replace(coalesce(p->>'expected_kg_week', ''), '[^0-9.,]', '', 'g'), ',', '.'), '')::numeric, nullif(trim(p->>'preferred_days'), ''), nullif(trim(p->>'notes'), ''), nullif(trim(p->>'shopify_customer_id'), ''), coalesce(nullif(p->>'source', ''), 'web'))
  returning id into v;
  perform fabula.trade_notice_refresh();
  return jsonb_build_object('ok', true, 'id', v, 'message_it', 'Richiesta ricevuta. Ti rispondiamo entro un giorno lavorativo e ti scriviamo quando l''accesso è attivo.');
end $$;

create or replace function fabula.trade_approve(p_app uuid, p_note text default null) returns jsonb
language plpgsql security definer set search_path = fabula, public as $$
declare a fabula.trade_applications%rowtype; v_party uuid; v_tok text; v_terms int := (fabula.trade_settings()->>'payment_terms_days')::int; v_seg text;
begin
  perform fabula.require_perm('vendite', 3);
  select * into a from fabula.trade_applications where id = p_app;
  if a.id is null then raise exception 'Richiesta non trovata' using errcode = '22023'; end if;
  if a.status = 'approved' and a.party_id is not null then
    return jsonb_build_object('ok', true, 'already', true, 'party_id', a.party_id, 'token', (select portal_token from fabula.parties where id = a.party_id));
  end if;
  v_seg := case a.business_type when 'pizzeria' then 'pizzeria' when 'ristorante' then 'ristorante' when 'hotel' then 'hotel' when 'bnb' then 'bnb' when 'agriturismo' then 'agriturismo' when 'lido' then 'lido' else 'altro' end;
  select id into v_party from fabula.parties where a.shopify_customer_id is not null and shopify_customer_id = a.shopify_customer_id;
  if v_party is null then select id into v_party from fabula.parties where type = 'customer' and lower(email) = lower(a.email) and active order by (source = 'shopify') desc limit 1; end if;
  v_tok := encode(extensions.gen_random_bytes(16), 'hex');
  if v_party is null then
    insert into fabula.parties (type, legal_name, trade_name, piva, codice_fiscale, sdi_code, pec_email, email, phone, address, city, province, postcode, country, payment_terms_days, source, is_wholesale, trade_status, portal_token, segment, business_type, shopify_customer_id, active)
    values ('customer', a.business_name, a.business_name, a.piva, a.codice_fiscale, a.sdi_code, a.pec_email, a.email, a.phone, a.address, a.city, a.province, a.postcode, 'IT', v_terms, 'trade', true, 'approved', v_tok, v_seg, a.business_type, a.shopify_customer_id, true)
    returning id into v_party;
  else
    update fabula.parties set legal_name = coalesce(nullif(a.business_name, ''), legal_name), trade_name = a.business_name, piva = coalesce(a.piva, piva), codice_fiscale = coalesce(a.codice_fiscale, codice_fiscale), sdi_code = coalesce(a.sdi_code, sdi_code), pec_email = coalesce(a.pec_email, pec_email),
      phone = coalesce(a.phone, phone), address = coalesce(a.address, address), city = coalesce(a.city, city), province = coalesce(a.province, province), postcode = coalesce(a.postcode, postcode),
      payment_terms_days = coalesce(nullif(payment_terms_days, 0), v_terms), is_wholesale = true, trade_status = 'approved', portal_token = coalesce(portal_token, v_tok), segment = coalesce(segment, v_seg), business_type = a.business_type,
      tags = (select array_agg(distinct t) from unnest(tags || array['ingrosso']) t), notes = case when notes = 'placeholder' then null else notes end, active = true, updated_at = now()
    where id = v_party;
    select portal_token into v_tok from fabula.parties where id = v_party;
  end if;
  update fabula.trade_applications set status = 'approved', party_id = v_party, decided_by = coalesce((select full_name from fabula.staff where auth_user_id = auth.uid()), 'staff'), decided_at = now(), decision_note = p_note where id = p_app;
  perform fabula.trade_notice_refresh();
  perform fabula.trade_log(v_party, 'staff', 'approved', jsonb_build_object('application', p_app), 'Accesso professionisti attivato. Accedi al sito con la tua email per vedere il listino e impostare le consegne.');
  return jsonb_build_object('ok', true, 'party_id', v_party, 'token', v_tok, 'application', to_jsonb(a) || jsonb_build_object('party_id', v_party), 'payment_terms_days', v_terms);
end $$;

create or replace function fabula.trade_reject(p_app uuid, p_note text default null) returns boolean language plpgsql security definer set search_path = fabula, public as $$
declare n int;
begin
  perform fabula.require_perm('vendite', 3);
  update fabula.trade_applications set status = 'rejected', decided_by = coalesce((select full_name from fabula.staff where auth_user_id = auth.uid()), 'staff'), decided_at = now(), decision_note = p_note where id = p_app and status = 'pending';
  get diagnostics n = row_count;
  perform fabula.trade_notice_refresh();
  return n > 0;
end $$;

-- tiers: "all products" on the weekly basis = whole plan kg; product tiers = that product's kg
create or replace function fabula.trade_price(p_customer uuid, p_variant text, p_qty numeric, p_recurring boolean default true)
returns jsonb language plpgsql stable set search_path = fabula, public as $$
declare s jsonb := fabula.trade_settings(); tp fabula.trade_products%rowtype; v_list numeric; v_basis numeric; v_basis_all numeric; t record; v_tier numeric; v_tier_min numeric; v_tier_src text;
        v_rec numeric := 0; v_final numeric; v_combine boolean := (s->>'discounts_combine')::boolean; v_week boolean := (s->>'tier_basis' = 'week');
begin
  select * into tp from fabula.trade_products where variant_id = p_variant;
  if tp.variant_id is null or tp.trade_price_eur is null then return jsonb_build_object('error', 'prodotto non in listino'); end if;
  v_list := tp.trade_price_eur;
  v_basis := case when v_week then fabula.trade_week_qty(p_customer, p_variant) else coalesce(p_qty, 0) * tp.kg_per_unit end;
  v_basis_all := case when v_week then fabula.trade_week_qty(p_customer, null) else v_basis end;
  v_tier := v_list;
  for t in select * from fabula.trade_price_tiers where active and (variant_id = p_variant or variant_id is null)
             and min_qty <= case when variant_id is null then v_basis_all else v_basis end
           order by (variant_id is not null) desc, min_qty desc loop
    v_tier := case when t.price_eur is not null then t.price_eur else round(v_list * (1 - t.discount_pct / 100), 2) end;
    v_tier_min := t.min_qty; v_tier_src := case when t.variant_id is null then 'tutti i prodotti' else 'prodotto' end;
    exit;
  end loop;
  if p_recurring then v_rec := coalesce((s->>'recurring_discount_pct')::numeric, 0); end if;
  if v_combine then v_final := round(v_tier * (1 - v_rec / 100), 2);
  else v_final := least(v_tier, round(v_list * (1 - v_rec / 100), 2)); end if;
  return jsonb_build_object('variant_id', p_variant, 'unit', tp.unit_label, 'list_price', v_list, 'tier_price', v_tier, 'tier_min_qty', v_tier_min, 'tier_source', v_tier_src,
                            'recurring_pct', v_rec, 'combine', v_combine, 'basis', s->>'tier_basis', 'basis_qty', v_basis, 'basis_qty_all', v_basis_all,
                            'final_price', v_final, 'saving_eur', round(v_list - v_final, 2),
                            'saving_pct', case when v_list > 0 then round((v_list - v_final) / v_list * 100, 1) else 0 end,
                            'line_total', round(v_final * coalesce(p_qty, 0), 2));
end $$;

select fabula.trade_notice_refresh();
