-- v0.99b · Audit 12/10/2026, office decisions and undo (2/2): orders, wholesale forecast, recipes, holds and NCs, B2B prices.
--   B-18   Catalogue orders: a line without a price is refused unless «prezzo da confermare» is ticked; the creator is stored;
--          above approve.auto_po_max_eur, with a price to confirm, or from a «registra» profile, the order waits for approval in Console → Oggi
--          (one card with every line); cancel_po() («Annulla ordine», with a reason) for orders not yet received, with the
--          message for the supplier when it had already been sent.
--   B-19   The 7-day milk forecast takes wholesale from the Ingrosso plans (trade_effective_lines), no longer from the old
--          «Ordini fissi» grid, which books nothing (the Console grid is gone).
--   B-15   «Togli» on a recipe component ends it from tomorrow (today's lots still dose it), as the button always said, or at once
--          when it was put in today; restore_recipe_component() undoes it the same day; a removed row can't be «saved» back.
--   B-06   A held lot is not released while its recall assessment is undecided, nor after a recall was decided; a release can name the conforming analysis
--          (checked against the lot); an NC closes only with its corrective action.
--   B-22/23 B2B price list: what was last sent to Shopify is kept per product and per tier, so Ingrosso shows «da inviare»
--          after a change; a tier is a price or a discount, never both.

-- ============================================================================================================================
-- 1. B-18 · catalogue orders
-- ============================================================================================================================
create or replace function fabula.create_manual_po(p_supplier_id uuid, p_lines jsonb, p_notes text default null)
returns jsonb language plpgsql security definer set search_path = fabula, public, extensions as $$
declare v_date date := (now() at time zone 'Europe/Rome')::date; v_po uuid; v_no text; v_seq int; v_lead int; l jsonb;
        v_price numeric; v_iva numeric; v_sub numeric := 0; v_ivat numeric := 0; v_n int := 0; v_sup text; v_email text; v_missing int := 0;
        v_name text; v_sku text; v_unit text; v_lines jsonb := '[]'; v_who text; v_max numeric; v_needs boolean; v_appr uuid;
begin
  perform fabula.require_perm('acquisti', 2);
  select legal_name, email into v_sup, v_email from fabula.parties where id = p_supplier_id and active;
  if v_sup is null then raise exception using errcode = '22023', message = 'Fornitore non trovato'; end if;
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then raise exception using errcode = '22023', message = 'Nessuna riga da ordinare'; end if;
  v_who := coalesce((select full_name from fabula.staff where id = fabula.my_staff_id()), 'console');
  select coalesce(max(t.lead_time_days), fabula.setting_num('purchasing.default_lead_days', 5)::int) into v_lead
    from fabula.supplier_products t where t.supplier_id = p_supplier_id and t.product_id in (select (x->>'product_id')::uuid from jsonb_array_elements(p_lines) x);
  select count(*) + 1 into v_seq from fabula.purchase_orders where order_date = v_date;
  loop
    v_no := 'PO-' || to_char(v_date, 'YYYYMMDD') || '-' || lpad(v_seq::text, 2, '0');
    exit when not exists (select 1 from fabula.purchase_orders where po_number = v_no);
    v_seq := v_seq + 1;
  end loop;
  insert into fabula.purchase_orders (po_number, supplier_id, status, order_date, expected_date, drafted_by, rationale, notes, source, created_by_id)
  values (v_no, p_supplier_id, 'draft', v_date, v_date + v_lead, 'human', 'Ordine manuale dal catalogo forniture', nullif(trim(p_notes), ''), 'console:catalogo', fabula.my_staff_id())
  returning id into v_po;
  for l in select * from jsonb_array_elements(p_lines) loop
    if coalesce((l->>'qty')::numeric, 0) <= 0 then continue; end if;
    select name, sku, unit, coalesce(iva_rate, 22) into v_name, v_sku, v_unit, v_iva from fabula.products where id = (l->>'product_id')::uuid;
    v_price := null;              -- review 13/10: never a price from the browser (a −€ line could pull the total under the limit)
    if v_price is null then
      select price_eur into v_price from fabula.supplier_prices where supplier_id = p_supplier_id and product_id = (l->>'product_id')::uuid and valid_from <= v_date order by valid_from desc, created_at desc limit 1;
    end if;
    if v_price is null then
      select price_eur into v_price from fabula.v_supplier_price_history where supplier_id = p_supplier_id and product_id = (l->>'product_id')::uuid and source = 'DDT' order by price_date desc limit 1;
    end if;
    if v_price <= 0 then v_price := null; end if;
    -- v0.99 (audit B-18): no silent €0 lines
    if v_price is null and not coalesce((l->>'price_tbc')::boolean, false) then
      raise exception using errcode = '22023',
        message = format('%s: manca il prezzo di %s. Scrivilo toccando il fornitore, oppure spunta «prezzo da confermare»', coalesce(v_name, 'articolo'), v_sup);
    end if;
    if v_price is null then v_missing := v_missing + 1; end if;
    insert into fabula.purchase_order_lines (purchase_order_id, product_id, qty_ordered, unit_price_eur, iva_rate)
    values (v_po, (l->>'product_id')::uuid, (l->>'qty')::numeric, coalesce(v_price, 0), v_iva);
    insert into fabula.supplier_products (supplier_id, product_id) values (p_supplier_id, (l->>'product_id')::uuid) on conflict do nothing;
    v_sub := v_sub + round((l->>'qty')::numeric * coalesce(v_price, 0), 2);
    v_ivat := v_ivat + round((l->>'qty')::numeric * coalesce(v_price, 0) * v_iva / 100, 2);
    v_lines := v_lines || jsonb_build_object('sku', v_sku, 'name', v_name, 'qty', (l->>'qty')::numeric, 'unit', v_unit, 'unit_price_eur', v_price,
                                             'total_eur', round((l->>'qty')::numeric * coalesce(v_price, 0), 2));
    v_n := v_n + 1;
  end loop;
  if v_n = 0 then raise exception using errcode = '22023', message = 'Nessuna quantità maggiore di zero'; end if;
  -- above the automatic limit, or from a profile that only «registra», a person approves it in Console → Oggi
  v_max := fabula.setting_num('approve.auto_po_max_eur', 150);
  -- a line «prezzo da confermare» counts € 0, so the real total is unknown: a person approves it whatever the profile
  v_needs := v_sub > v_max or v_missing > 0 or (auth.uid() is not null and not fabula.can('acquisti', 3));
  update fabula.purchase_orders set subtotal_eur = v_sub, iva_eur = v_ivat, total_eur = v_sub + v_ivat,
         status = case when v_needs then 'pending_approval'::fabula.po_status else 'approved'::fabula.po_status end
   where id = v_po;
  if v_needs then
    insert into fabula.approvals (kind, requested_by, summary, payload, related_table, related_id, amount_eur, expires_at)
    values ('purchase_order', v_who,
            format('Ordine %s: %s %s a %s, € %s (creato da %s dal catalogo)', v_no, v_n, case when v_n = 1 then 'riga' else 'righe' end, v_sup,
                   replace(to_char(v_sub, 'FM9999990.00'), '.', ','), v_who),
            jsonb_build_object('po_number', v_no, 'supplier', v_sup, 'supplier_email', v_email, 'lines', v_lines, 'total_eur', v_sub,
                               'created_by', v_who, 'manual', true, 'expected_date', v_date + v_lead, 'price_missing', v_missing > 0,
                               'over_limit', v_sub > v_max, 'limit_eur', v_max),
            'purchase_orders', v_po, v_sub, now() + interval '7 days')
    returning id into v_appr;
  end if;
  return jsonb_build_object('po_number', v_no, 'supplier', v_sup, 'lines', v_n, 'subtotal_eur', v_sub, 'expected_date', v_date + v_lead,
                            'price_missing', v_missing, 'status', case when v_needs then 'pending_approval' else 'approved' end,
                            'needs_approval', v_needs, 'approval_id', v_appr, 'limit_eur', v_max);
end $$;
revoke all on function fabula.create_manual_po(uuid, jsonb, text) from public, anon;
grant execute on function fabula.create_manual_po(uuid, jsonb, text) to authenticated, service_role;

create or replace function fabula.cancel_po(p_po_number text, p_reason text) returns jsonb
language plpgsql security definer set search_path = fabula, public as $$
declare po fabula.purchase_orders; v_who text; s record;
begin
  perform fabula.require_perm('acquisti', 2);
  if length(coalesce(trim(p_reason), '')) < 3 then raise exception using errcode = '22023', message = 'Scrivi perché annulli l''ordine'; end if;
  select * into po from fabula.purchase_orders where po_number = upper(trim(p_po_number)) for update;
  if not found then raise exception using errcode = '22023', message = format('Ordine %s non trovato', p_po_number); end if;
  if po.status = 'cancelled' then raise exception using errcode = '22023', message = format('L''ordine %s è già annullato', po.po_number); end if;
  if po.status in ('received', 'partially_received') or exists (select 1 from fabula.goods_receipts g where g.purchase_order_id = po.id) then
    raise exception using errcode = '22023', message = format('L''ordine %s è già stato ricevuto (anche in parte): non si annulla. Registra un reso al fornitore', po.po_number);
  end if;
  v_who := coalesce((select full_name from fabula.staff where id = fabula.my_staff_id()), 'sistema');
  update fabula.purchase_orders set status = 'cancelled', cancelled_at = now(), cancelled_by_id = fabula.my_staff_id(), cancel_reason = trim(p_reason), updated_at = now(),
         notes = concat_ws(E'\n', notes, format('[%s] annullato da %s: %s', to_char(now() at time zone 'Europe/Rome', 'DD/MM HH24:MI'), v_who, trim(p_reason)))
   where id = po.id;
  update fabula.approvals set status = 'rejected', decided_by = v_who, decided_at = now(), decision_note = 'ordine annullato: ' || trim(p_reason)
   where related_table = 'purchase_orders' and related_id = po.id and status = 'pending';
  select legal_name, email, phone into s from fabula.parties where id = po.supplier_id;
  return jsonb_build_object('po_number', po.po_number, 'was_status', po.status, 'was_sent', po.status = 'sent', 'supplier', s.legal_name,
    'email', s.email, 'phone', s.phone,
    'message_it', case when po.status = 'sent' then format('Buongiorno, vi chiediamo di annullare il nostro ordine %s del %s. Ci scusiamo per il disturbo. Grazie, %s',
                                                           po.po_number, to_char(po.order_date, 'DD/MM/YYYY'), fabula.company_name()) end);
end $$;
revoke all on function fabula.cancel_po(text, text) from public, anon;
grant execute on function fabula.cancel_po(text, text) to authenticated, service_role;

-- ============================================================================================================================
-- 2. B-19 · the 7-day milk forecast reads the Ingrosso plans
-- ============================================================================================================================
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.demand_7d'::regproc);
  n := replace(d, $s$select coalesce(sum(so.qty_kg), 0) into v_stand from fabula.standing_orders so where so.active and so.product_id = v_moz and so.weekday = extract(isodow from d);$s$,
                  $s$select coalesce(sum(t.kg), 0) into v_stand from fabula.trade_effective_lines(d) t where t.product_id = v_moz;   -- v0.99 (audit B-19): the Ingrosso plans, not the old grid$s$);
  if n = d then raise exception 'v099b: demand_7d standing pattern not found'; end if;
  d := n;
  n := replace(d, $s$when v_stand > 0 then 'ordini fissi'$s$, $s$when v_stand > 0 then 'piani ingrosso'$s$);
  if n = d then raise exception 'v099b: demand_7d label pattern not found'; end if;
  execute n;
end $mig$;

-- ============================================================================================================================
-- 3. B-15 · «Togli» ends a component from tomorrow; the same day it can be put back
-- ============================================================================================================================
drop function if exists fabula.end_recipe_component(uuid);
create function fabula.end_recipe_component(p_recipe_id uuid) returns jsonb
language plpgsql set search_path = fabula, public, extensions as $$
declare r fabula.recipes; v_today date := (now() at time zone 'Europe/Rome')::date; v_who text; v_now boolean;
begin
  select * into r from fabula.recipes where id = p_recipe_id;
  if not found then raise exception using errcode = '22023', message = 'Componente non trovato: aggiorna la pagina'; end if;
  if r.valid_to is not null then raise exception using errcode = '22023', message = 'Componente già tolto dalla ricetta'; end if;
  v_who := coalesce((select full_name from fabula.staff where id = fabula.my_staff_id()), 'sistema');
  -- added (or changed) today: it stops at once, also for today's lots not yet dosed (review 13/10); otherwise from tomorrow
  v_now := r.valid_from >= v_today;
  update fabula.recipes set valid_to = case when v_now then v_today - 1 else v_today end,
         notes = concat_ws(E'\n', notes, format('[%s] tolto da %s: %s', to_char(now() at time zone 'Europe/Rome', 'DD/MM HH24:MI'), v_who,
                                                 case when v_now then 'non si dosa più già da ora (era stato inserito oggi)' else 'da domani non si dosa più' end))
   where id = p_recipe_id and valid_to is null;
  if not found then raise exception using errcode = '42501', message = 'Non tolto: il tuo profilo non può modificare le ricette'; end if;
  return jsonb_build_object('recipe_id', p_recipe_id, 'valid_to', case when v_now then v_today - 1 else v_today end, 'now', v_now);
end $$;
grant execute on function fabula.end_recipe_component(uuid) to authenticated, service_role;

create or replace function fabula.restore_recipe_component(p_recipe_id uuid) returns jsonb
language plpgsql set search_path = fabula, public, extensions as $$
declare r fabula.recipes; v_today date := (now() at time zone 'Europe/Rome')::date;
begin
  select * into r from fabula.recipes where id = p_recipe_id;
  if not found then raise exception using errcode = '22023', message = 'Componente non trovato: aggiorna la pagina'; end if;
  if r.valid_to is distinct from v_today then
    raise exception using errcode = '22023', message = 'Si rimette solo il giorno in cui è stato tolto: aggiungilo di nuovo dalla riga in fondo';
  end if;
  if exists (select 1 from fabula.recipes x where x.finished_product_id = r.finished_product_id and x.component_product_id = r.component_product_id
              and x.id <> r.id and (x.valid_to is null or x.valid_to > v_today)) then
    raise exception using errcode = '22023', message = 'Il componente è già di nuovo nella ricetta';
  end if;
  update fabula.recipes set valid_to = null,
         notes = concat_ws(E'\n', notes, format('[%s] rimesso nella ricetta', to_char(now() at time zone 'Europe/Rome', 'DD/MM HH24:MI')))
   where id = p_recipe_id;
  if not found then raise exception using errcode = '42501', message = 'Non rimesso: il tuo profilo non può modificare le ricette'; end if;
  return jsonb_build_object('recipe_id', p_recipe_id, 'valid_to', null);
end $$;
grant execute on function fabula.restore_recipe_component(uuid) to authenticated, service_role;

-- a dose saved on a removed row would put the component back from today without saying so
do $mig$
declare d text := pg_get_functiondef('fabula.update_recipe_dose(uuid, numeric, boolean, text, integer, text, boolean)'::regprocedure); n text;
begin
  n := replace(d, $o$  select name, unit into v_comp, v_unit from fabula.products where id = r.component_product_id;$o$,
               $n$  select name, unit into v_comp, v_unit from fabula.products where id = r.component_product_id;
  if r.valid_to is not null then   -- v0.99b (review 13/10)
    raise exception 'Componente tolto dalla ricetta: per rimetterlo usa «Rimetti» (oggi) o aggiungilo di nuovo dalla riga in fondo' using errcode = '22023';
  end if;$n$);
  if n = d then raise exception 'v099b: update_recipe_dose pattern not found'; end if;
  execute n;
end $mig$;

-- the editor shows the end date (a component taken out today is still dosed today: «tolto da domani · Rimetti»)
create or replace view fabula.v_recipe_editor with (security_invoker = true) as
 SELECT r.id AS recipe_id,
    f.sku AS finished_sku,
    f.name AS finished_name,
    c.id AS component_id,
    c.sku AS component_sku,
    c.name AS component_name,
    c.unit,
    (r.basis)::text AS basis,
    r.qty_per_unit,
    r.round_up,
    r.phase,
    r.step_order,
    r.instruction_it,
    r.valid_from,
    r.source,
    r.notes,
    r.valid_to
   FROM ((fabula.recipes r
     JOIN fabula.products f ON ((f.id = r.finished_product_id)))
     JOIN fabula.products c ON ((c.id = r.component_product_id)))
  WHERE ((r.valid_from <= ((now() AT TIME ZONE 'Europe/Rome'::text))::date) AND ((r.valid_to IS NULL) OR (r.valid_to >= ((now() AT TIME ZONE 'Europe/Rome'::text))::date)))
  ORDER BY f.sku, r.phase DESC, r.step_order, c.name;

-- ============================================================================================================================
-- 4. B-06 · lot release and NC closing
-- ============================================================================================================================
drop function if exists fabula.release_lot_hold(text, uuid, text);
create function fabula.release_lot_hold(p_lot text, p_staff_id uuid, p_note text, p_sample_code text default null) returns text
language plpgsql security definer set search_path = fabula, public, extensions as $$
declare v_lot text := upper(trim(coalesce(p_lot, ''))); v_s record; v_r record;
begin
  perform fabula.require_perm('haccp', 3);   -- v0.60: only HACCP managers release a lot, also through the API
  if length(coalesce(trim(p_note), '')) < 5 then raise exception using errcode = '22023', message = 'Serve una motivazione (es. esito analisi conforme, valutazione del consulente)'; end if;
  -- v0.99 (audit B-06): an open recall decision keeps the lot held
  -- and a decided recall keeps it held for good: the latest assessment of the lot decides (review 13/10)
  select status, decided_by, decided_at into v_r from fabula.approvals
   where payload->>'type' = 'recall_assessment' and upper(payload->>'lot') = v_lot order by requested_at desc limit 1;
  if v_r.status = 'pending' then
    raise exception using errcode = '22023',
      message = format('Prima decidi la valutazione di ritiro/richiamo del lotto %s (Console → Oggi): finché è aperta il lotto resta bloccato', v_lot);
  elsif v_r.status = 'approved' then
    raise exception using errcode = '22023',
      message = format('Per il lotto %s è stato deciso il ritiro/richiamo (%s, %s): non si sblocca. Il prodotto in giacenza va smaltito o reso come da procedura di ritiro',
                       v_lot, coalesce(v_r.decided_by, '?'), coalesce(to_char(v_r.decided_at at time zone 'Europe/Rome', 'DD/MM/YYYY'), ''));
  end if;
  if nullif(trim(p_sample_code), '') is not null then
    select s.sample_code, s.report_no, s.report_date into v_s from fabula.lab_samples s
     where s.sample_code = upper(trim(p_sample_code)) and upper(s.lot_number) = v_lot and s.outcome = 'conforme';
    if not found then
      raise exception using errcode = '22023', message = format('Il campione %s non è un''analisi conforme del lotto %s', upper(trim(p_sample_code)), v_lot);
    end if;
    p_note := format('analisi conforme %s%s · %s', v_s.sample_code, coalesce(' (referto ' || v_s.report_no || coalesce(' del ' || to_char(v_s.report_date, 'DD/MM/YYYY'), '') || ')', ''), trim(p_note));
  end if;
  perform set_config('fabula.hold_ctx', 'on', true);   -- v0.95a: the hold guard lets this update through
  update fabula.production_batches set food_safety_hold = false, hold_released_at = now(),
         hold_released_by_id = case when auth.uid() is not null then fabula.my_staff_id() else p_staff_id end,   -- a user can't sign as someone else
         notes = concat_ws(E'\n', notes, format('[%s] sblocco: %s', to_char(now() at time zone 'Europe/Rome', 'DD/MM HH24:MI'), trim(p_note)))
   where batch_lot = v_lot and food_safety_hold;
  if not found then raise exception using errcode = '22023', message = format('Lotto %s non bloccato', v_lot); end if;
  return 'released';
end $$;
revoke all on function fabula.release_lot_hold(text, uuid, text, text) from public, anon;
grant execute on function fabula.release_lot_hold(text, uuid, text, text) to authenticated, service_role;

create or replace function fabula.trg_nc_close_guard() returns trigger
language plpgsql security definer set search_path = fabula, public as $$
begin
  if auth.uid() is null then return new; end if;                 -- bots / SQL
  if (new.status = 'closed') is distinct from (old.status = 'closed') then
    perform fabula.require_perm('haccp', 3);
    if new.status = 'closed' then
      if coalesce(trim(new.corrective_action), '') = '' then      -- v0.99 (audit B-06): the browser asked; now the database does too
        raise exception using errcode = '22023', message = 'Scrivi l''azione correttiva prima di chiudere la non conformità';
      end if;
      new.closed_by_id := fabula.my_staff_id(); new.closed_at := now();
    else new.closed_by_id := null; new.closed_at := null; end if;
  elsif new.closed_by_id is distinct from old.closed_by_id then
    new.closed_by_id := old.closed_by_id;
  end if;
  return new;
end $$;

-- ============================================================================================================================
-- 5. B-22 / B-23 · what Shopify has, per product and per tier
-- ============================================================================================================================
alter table fabula.trade_products add column if not exists synced_price_eur numeric,
                                  add column if not exists synced_min_qty numeric,
                                  add column if not exists synced_step_qty numeric,
                                  add column if not exists synced_active boolean;
comment on column fabula.trade_products.synced_price_eur is 'v0.99 (audit B-22): reserved price last sent to Shopify (with synced_min_qty, synced_step_qty, synced_active): a difference = «da inviare»';
update fabula.trade_products set synced_price_eur = trade_price_eur, synced_min_qty = min_qty, synced_step_qty = step_qty, synced_active = active
 where synced_at is not null and synced_at >= updated_at and synced_active is null;
alter table fabula.trade_price_tiers add column if not exists changed_at timestamptz not null default now(),
                                     add column if not exists synced_at timestamptz;
comment on column fabula.trade_price_tiers.synced_at is 'v0.99 (audit B-23): last «Invia a Shopify» after which this tier was in the price list (or removed from it)';
update fabula.trade_price_tiers set synced_at = changed_at where synced_at is null;
create or replace function fabula.trg_trade_tier_changed() returns trigger language plpgsql set search_path = fabula, public as $$
begin
  if tg_op = 'INSERT' or (new.variant_id, new.min_qty, new.price_eur, new.discount_pct, new.active) is distinct from (old.variant_id, old.min_qty, old.price_eur, old.discount_pct, old.active) then
    new.changed_at := now();
  end if;
  return new;
end $$;
drop trigger if exists trade_price_tiers_changed on fabula.trade_price_tiers;
create trigger trade_price_tiers_changed before insert or update on fabula.trade_price_tiers for each row execute function fabula.trg_trade_tier_changed();
update fabula.trade_price_tiers set discount_pct = null where price_eur is not null and discount_pct is not null;   -- the old sync used the price
alter table fabula.trade_price_tiers drop constraint if exists trade_price_tiers_one_kind;
alter table fabula.trade_price_tiers add constraint trade_price_tiers_one_kind check (price_eur is null or discount_pct is null);
comment on constraint trade_price_tiers_one_kind on fabula.trade_price_tiers is 'Uno scaglione è un prezzo €/kg oppure uno sconto %, non tutti e due';
-- audit B-23: a € 0 tier would give the product away (the browser already refuses it; now the database does too)
update fabula.trade_price_tiers set active = false, price_eur = null, discount_pct = 0, note = concat_ws(' ', note, '[v0.99: prezzo 0 € tolto]')
 where price_eur is not null and price_eur <= 0;
alter table fabula.trade_price_tiers drop constraint if exists trade_price_tiers_price_pos;
alter table fabula.trade_price_tiers add constraint trade_price_tiers_price_pos check (price_eur is null or price_eur > 0);

-- ============================================================================================================================
-- 5b. TRADE-06 · a customer who stops the plan from the portal: the office sees it on the dashboard the same minute
--     (customer e-mail/WhatsApp confirmations need a customer messaging channel: backlog)
-- ============================================================================================================================
do $mig$
declare d text := pg_get_functiondef('fabula.trade_set_status(uuid, text, date, text)'::regprocedure); n text;
begin
  n := replace(d, $o$  perform fabula.trade_log(p_customer, p_actor, 'status_' || p_status, jsonb_build_object('until', p_until), msg);$o$,
               $n$  perform fabula.trade_log(p_customer, p_actor, 'status_' || p_status, jsonb_build_object('until', p_until), msg);
  if p_actor = 'customer' and (p_status = 'cancelled' or (p_status = 'paused' and p_until is null)) then   -- v0.99b (audit TRADE-06)
    begin
      perform fabula.post_bot_message('wholesale_orders', 'warn',
        left(format('%s ha %s dal portale', coalesce((select coalesce(trade_name, legal_name) from fabula.parties where id = p_customer), 'Un cliente'),
                    case when p_status = 'cancelled' then 'annullato il piano consegne' else 'messo in pausa il piano senza data' end), 120),
        msg || E'

' || coalesce('Se non era voluto chiamalo: ' || nullif((select phone from fabula.parties where id = p_customer), '') || '. ', '')
            || 'Ingrosso → Clienti e piani.');
    exception when others then raise warning 'trade_set_status message: %', sqlerrm;
    end;
  end if;$n$);
  if n = d then raise exception 'v099b: trade_set_status pattern not found'; end if;
  execute n;
end $mig$;

-- ============================================================================================================================
-- 5c. B-19 · the Vendite numbers read the Ingrosso plans too (the old grid is frozen)
-- ============================================================================================================================
do $mig$
declare d text := pg_get_functiondef('fabula.sales_status(date)'::regprocedure); n text;
begin
  n := replace(d, $o$'standing_kg_week', (select round(coalesce(sum(qty_kg), 0), 1) from fabula.standing_orders where active),$o$,
               $n$'standing_kg_week', (select round(coalesce(sum(e.kg), 0), 1) from generate_series(d + 1, d + 7, interval '1 day') g
                                      cross join lateral fabula.trade_effective_lines(g::date) e),   -- v0.99b (audit B-19): next 7 days of plans$n$);
  n := replace(n, $o$and not exists (select 1 from fabula.standing_orders s where s.customer_id = x.customer_id and s.active))),$o$,
                  $n$and not exists (select 1 from fabula.trade_schedules s where s.customer_id = x.customer_id and s.status = 'active'))),$n$);
  if n = d or n !~ 'trade_schedules s where' or n ~ 'standing_orders' then raise exception 'v099b: sales_status patterns not found'; end if;
  execute n;
end $mig$;

-- ============================================================================================================================
-- 6. Security check
-- ============================================================================================================================
insert into fabula.security_accepted (key, reason, accepted_at) values
 ('authenticated_security_definer_function_executable:fabula.create_manual_po(p_supplier_id uuid, p_lines jsonb, p_notes text)',
  'by design (v0.89a, v0.99b audit B-18): require_perm(acquisti, 2) first; above the automatic limit or from level 2 the order waits for approval', now()),
 ('authenticated_security_definer_function_executable:fabula.cancel_po(p_po_number text, p_reason text)',
  'by design (v0.99b, audit B-18): require_perm(acquisti, 2) first; never a received order', now()),
 ('authenticated_security_definer_function_executable:fabula.release_lot_hold(p_lot text, p_staff_id uuid, p_note text, p_sample_code text)',
  'by design (v0.60, v0.99b audit B-06): require_perm(haccp, 3) first; signer from the login; blocked while a recall decision is open or after a recall', now())
on conflict (key) do update set reason = excluded.reason, accepted_at = excluded.accepted_at;
delete from fabula.security_accepted
 where key = 'authenticated_security_definer_function_executable:fabula.release_lot_hold(p_lot text, p_staff_id uuid, p_note text)';
