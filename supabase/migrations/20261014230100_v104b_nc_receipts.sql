-- v1.04b · Audit 12/10/2026, D-26 (rest): non-conformities and arrival checks can no longer be quietly rewritten.
--   (Since v0.96 an NC cannot be deleted and every change is in the Registro; since v0.99 closing needs the corrective action.)
--   * An NC's origin (when and by whom it was opened, its record, lot, batch and machine) never changes from a login; a missing lot,
--     batch or machine can be filled in once.
--   * Severity and description change only with the HACCP manager's level (haccp 3): a floor or office profile adds cause and
--     actions, it cannot turn «critica» into «minore».
--   * A closed NC is frozen (texts, links and the closing date): to change it, the HACCP manager reopens it first (that stays in the
--     Registro). A login's new NC is opened now and open (opening date and closure are not written by hand).
--   * Arrival check (MOD-15): a delivery checked «NON conforme» cannot be re-checked «conforme»; the NC decides what happens to the
--     goods. A delivery checked «conforme» can still be found non-conforming later (new NC). Each check keeps its time and NC.
--   * Goods found non-conforming stay isolated while their NC is open: dosing refuses a lot of that delivery, and asks for the lot
--     when the ingredient has one isolated.

-- ============================== NC edits ==============================
create or replace function fabula.trg_nc_edit_guard() returns trigger
language plpgsql set search_path = fabula, public as $$
-- invoker: the database's own functions (definer) and the bots pass; a login (Autocontrollo page, API) is checked
begin
  if current_user not in ('authenticated', 'anon') or coalesce(current_setting('fabula.correct_ctx', true), '') = 'on' then return new; end if;
  if new.opened_at is distinct from old.opened_at or new.opened_by_id is distinct from old.opened_by_id
     or new.haccp_log_id is distinct from old.haccp_log_id then
    raise exception using errcode = '42501', message = 'Quando e da chi è stata aperta una non conformità, e la registrazione da cui nasce, non si cambiano';
  end if;
  if (old.lot_number is not null and new.lot_number is distinct from old.lot_number)
     or (old.batch_id is not null and new.batch_id is distinct from old.batch_id)
     or (old.equipment_id is not null and new.equipment_id is distinct from old.equipment_id) then
    if fabula.perm_level('haccp') < 3 then
      raise exception using errcode = '42501', message = 'Il lotto o la macchina di una non conformità li cambia solo il responsabile HACCP (si può aggiungere se manca)';
    end if;
  end if;
  -- a closed NC is frozen until the HACCP manager reopens it (the reopening is itself checked by nc_close_guard)
  if old.status = 'closed' and new.status = 'closed'
     and (new.severity, new.description, new.corrective_action, new.root_cause, new.preventive_action, new.lot_number, new.batch_id, new.equipment_id, new.document_id, new.closed_at)
         is distinct from (old.severity, old.description, old.corrective_action, old.root_cause, old.preventive_action, old.lot_number, old.batch_id, old.equipment_id, old.document_id, old.closed_at) then
    raise exception using errcode = '42501', message = format('La non conformità è chiusa%s: per cambiarla il responsabile HACCP la riapre, così resta traccia.', coalesce(' (' || to_char(old.closed_at at time zone 'Europe/Rome', 'DD/MM/YYYY') || ')', ''));
  end if;
  if (new.severity is distinct from old.severity or new.description is distinct from old.description) and fabula.perm_level('haccp') < 3 then
    raise exception using errcode = '42501', message = 'Gravità e descrizione di una non conformità le cambia solo il responsabile HACCP: scrivi quello che serve in «Causa» o «Azione correttiva».';
  end if;
  return new;
end $$;
drop trigger if exists nc_edit_guard on fabula.non_conformities;
create trigger nc_edit_guard before update on fabula.non_conformities for each row execute function fabula.trg_nc_edit_guard();

-- a login's new NC (the API; the tablet's NCs come from the database's own functions) is opened now and open
create or replace function fabula.trg_nc_insert_guard() returns trigger
language plpgsql set search_path = fabula, public as $$
begin
  if current_user not in ('authenticated', 'anon') then return new; end if;
  new.opened_at := now(); new.status := 'open'; new.closed_at := null; new.closed_by_id := null;
  return new;
end $$;
drop trigger if exists nc_insert_guard on fabula.non_conformities;
create trigger nc_insert_guard before insert on fabula.non_conformities for each row execute function fabula.trg_nc_insert_guard();

-- ============================== arrival checks ==============================
alter table fabula.goods_receipts add column if not exists inspected_at timestamptz;
alter table fabula.goods_receipts add column if not exists inspection_nc_id uuid references fabula.non_conformities(id);
comment on column fabula.goods_receipts.inspection_nc_id is 'v1.04 (audit D-26): the NC opened by a «NON conforme» arrival check; while it is open the goods of this receipt are isolated (dosing refuses them).';

create or replace function fabula.record_receipt_check(p_po_number text, p_ok boolean, p_note text default null::text, p_staff_id uuid default null::uuid, p_ddt text default null::text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'fabula', 'public'
as $function$
declare g record; v_nc uuid; v_sup text;
begin
  perform fabula.require_perm('magazzino', 2);
  if p_ok is null then raise exception 'Esito del controllo all''arrivo mancante'; end if;
  if not p_ok and coalesce(trim(p_note), '') = '' then raise exception 'Merce non conforme: scrivi cosa non va (es. confezione rotta, temperatura, etichetta)'; end if;
  select gr.id, gr.inspection_ok, gr.inspection_note, gr.inspected_at, gr.inspection_nc_id, p.legal_name as supplier into g
  from fabula.goods_receipts gr join fabula.purchase_orders po on po.id = gr.purchase_order_id left join fabula.parties p on p.id = po.supplier_id
  where po.po_number = p_po_number and (p_ddt is null or gr.ddt_number is not distinct from p_ddt)
  order by gr.received_at desc limit 1
  for update of gr;
  if g.id is null then raise exception 'Ricevimento non trovato per l''ordine %', p_po_number; end if;
  v_sup := g.supplier;
  -- v1.04 (audit D-26): a «NON conforme» check is not turned into «conforme» by checking again; the NC decides (reso, distruzione…)
  if g.inspection_ok is false then
    if p_ok then
      raise exception using errcode = '22023', message = format('Il ricevimento di %s è già registrato NON conforme%s: «%s». Non si rifà il controllo: la merce resta isolata finché il responsabile HACCP chiude la non conformità.',
        p_po_number, coalesce(' il ' || to_char(g.inspected_at at time zone 'Europe/Rome', 'DD/MM HH24:MI'), ''), coalesce(g.inspection_note, '—'));
    end if;
    return jsonb_build_object('receipt_id', g.id, 'nc_id', g.inspection_nc_id, 'already', true);   -- the same «non conforme» again: nothing new
  end if;
  if g.inspection_ok is true and p_ok then
    return jsonb_build_object('receipt_id', g.id, 'nc_id', null, 'already', true);
  end if;
  -- first check, or a «conforme» delivery found non-conforming later (the earlier check stays in the Registro)
  if not p_ok then
    insert into fabula.non_conformities (severity, description, corrective_action, opened_by_id)
    values ('major', format('MOD-15 · Merce non conforme all''arrivo: ordine %s%s — %s', p_po_number, coalesce(' (' || v_sup || ')', ''), trim(p_note)),
            'Merce isolata con cartello, fornitore avvisato · decidere reso o distruzione', p_staff_id)
    returning id into v_nc;
  end if;
  update fabula.goods_receipts set inspection_ok = p_ok, inspection_note = nullif(trim(p_note), ''), inspected_by_id = p_staff_id, inspected_at = now(),
         inspection_nc_id = coalesce(v_nc, inspection_nc_id)
   where id = g.id;
  return jsonb_build_object('receipt_id', g.id, 'nc_id', v_nc);
end $function$;

-- the isolated goods: a supplier lot received on a «NON conforme» delivery whose NC is still open
create or replace function fabula._lot_quarantine(p_product_id uuid, p_lot text) returns text
language sql stable security definer set search_path = fabula, public as $$
  select format('lotto %s, ordine %s%s', coalesce(l.supplier_lot, '—'), po.po_number, coalesce(': ' || g.inspection_note, ''))
    from fabula.goods_receipt_lines l join fabula.goods_receipts g on g.id = l.receipt_id join fabula.purchase_orders po on po.id = g.purchase_order_id
    join fabula.non_conformities n on n.id = g.inspection_nc_id
   where l.product_id = p_product_id and g.inspection_ok is false and n.status::text <> 'closed'
     and (p_lot is null or upper(btrim(l.supplier_lot)) = upper(btrim(p_lot)))
   order by g.received_at desc limit 1
$$;
revoke all on function fabula._lot_quarantine(uuid, text) from public, anon;
grant execute on function fabula._lot_quarantine(uuid, text) to authenticated;
insert into fabula.security_accepted (key, reason) values
  ('authenticated_security_definer_function_executable:fabula._lot_quarantine(p_product_id uuid, p_lot text)', 'by design (v1.04b, audit D-26): dosing (record_batch_consumable, invoker) asks whether an ingredient lot is isolated; returns only lot, order number and the check note')
on conflict (key) do nothing;

create or replace function fabula.record_batch_consumable(p_batch_lot text, p_sku text, p_qty numeric, p_qty_standard numeric, p_staff_id uuid default null::uuid, p_lot text default null::text, p_confirm boolean default false)
 returns text
 language plpgsql
 set search_path to 'fabula', 'public', 'extensions'
as $function$
declare b record; v_comp uuid; v_name text; v_unit text; v_rec uuid; v_lot text := nullif(upper(trim(coalesce(p_lot, ''))), ''); v_q text;
begin
  select * into b from fabula.production_batches where batch_lot = p_batch_lot;
  select id, name, unit into v_comp, v_name, v_unit from fabula.products where sku = p_sku;
  if b is null or v_comp is null then raise exception 'Lotto o SKU sconosciuto: % / %', p_batch_lot, p_sku using errcode = '22023'; end if;
  -- v0.98 (audit D-19)
  if b.output_kg is not null then
    raise exception 'Il lotto % è già chiuso: i dosaggi si registrano prima della chiusura', p_batch_lot using errcode = '22023';
  end if;
  if p_qty is null or p_qty < 0 then raise exception 'Quantità di % non valida: scrivi la quantità usata (0 se non l''hai messo)', v_name using errcode = '22023'; end if;
  -- v1.04 (audit D-26): goods found non-conforming at arrival stay isolated while their NC is open
  if p_qty > 0 then
    v_q := fabula._lot_quarantine(v_comp, v_lot);
    if v_q is not null and v_lot is not null then
      raise exception using errcode = '22023', message = format('%s, %s: merce NON conforme all''arrivo, è isolata. Usa un''altra confezione o chiama il responsabile HACCP.', v_name, v_q);
    elsif v_q is not null then
      raise exception using errcode = '22023', message = format('%s: c''è merce NON conforme all''arrivo e isolata (%s). Scrivi il lotto della confezione che usi.', v_name, v_q);
    end if;
  end if;
  if coalesce(p_qty_standard, 0) > 0 and not coalesce(p_confirm, false) and (p_qty > p_qty_standard * 3 or p_qty < p_qty_standard / 3) then
    raise exception using errcode = '22023', hint = 'confirm', message = format('%s: %s %s contro %s previsti dalla ricetta. Controlla la virgola; se è giusto conferma.',
      v_name, fabula._it_num(round(p_qty, 4)), v_unit, fabula._it_num(round(p_qty_standard, 4)));
  end if;
  if exists (select 1 from fabula.batch_consumables where batch_id = b.id and product_id = v_comp) then
    perform fabula.correct_batch_consumable(p_batch_lot, p_sku, p_qty, 'riconferma da tablet');
    update fabula.batch_consumables set confirmed_at = now(), confirmed_by_id = coalesce(p_staff_id, confirmed_by_id),
           qty_standard = coalesce(qty_standard, p_qty_standard), lot_number = coalesce(v_lot, lot_number)
     where batch_id = b.id and product_id = v_comp;
    return 'corrected';
  end if;
  select id into v_rec from fabula.recipes
   where finished_product_id = b.product_id and component_product_id = v_comp
     and valid_from <= b.batch_date and (valid_to is null or valid_to >= b.batch_date)
   order by valid_from desc limit 1;
  insert into fabula.batch_consumables (batch_id, product_id, qty, recipe_id, qty_standard, entry, confirmed_at, confirmed_by_id, lot_number)
  values (b.id, v_comp, p_qty, v_rec, p_qty_standard, case when p_qty = p_qty_standard then 'confirmed' else 'corrected' end, now(), p_staff_id, v_lot);
  insert into fabula.stock_moves (product_id, lot_number, qty, move_type, batch_id, source, reason)
  values (v_comp, v_lot, -p_qty, 'production_in', b.id, 'tablet',
          format('Lotto %s: dosato e confermato %s (ricetta %s)', p_batch_lot, p_qty, p_qty_standard));
  return 'recorded';
end $function$;
