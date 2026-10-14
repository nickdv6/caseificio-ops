-- v1.03c · Audit 12/10/2026, PRINT-08: lot labels are reprinted from the database, never typed by hand.
--   * Tablet → «🖨 Ristampa etichette»: the lots of the last 14 days (and every lot still being worked), searchable; the label is
--     built from the database (product, lot, expiry or arrival date), as at batch close or milk arrival. Each reprint is counted on
--     the lot's label row (labels.reprinted_count, who and when).
--   * labels.html checks every LOT: line against the database: name and expiry come from the database (a wrong one typed is
--     corrected on screen), a lot typed by hand that does not exist is shown in red and not printed. A lot the tablet has just saved
--     offline (not yet in the database) is printed with an amber note; without network or login the page says the lots were not
--     checked.

alter table fabula.labels add column if not exists reprinted_count int not null default 0;
alter table fabula.labels add column if not exists last_reprinted_at timestamptz;
alter table fabula.labels add column if not exists last_reprinted_by_id uuid references fabula.staff(id);

-- the label of one lot, as the tablet prints it at milk arrival, batch start or close (null = no such lot)
create or replace function fabula._lot_label(p_lot text) returns jsonb
language plpgsql stable security definer set search_path = fabula, public as $$
declare v text := upper(btrim(regexp_replace(coalesce(p_lot, ''), '^\s*LOT:', '', 'i'))); b record; m record; v_exp date; v_copies int;
begin
  if v = '' then return null; end if;
  select pb.id, pb.batch_lot, pb.batch_date, pb.started_at, pb.finished_at, pb.output_kg, pb.input_kind, pb.food_safety_hold, pb.hold_reason,
         p.name as product, p.shelf_life_days
    into b from fabula.production_batches pb left join fabula.products p on p.id = pb.product_id
   where upper(pb.batch_lot) = v order by pb.created_at desc limit 1;
  if found then
    select qty_printed into v_copies from fabula.labels where upper(code) = 'LOT:' || v;
    if b.output_kg is null then   -- still being worked: the vat (or the ricotta tino) label
      return jsonb_build_object('lot', b.batch_lot, 'kind', case when b.input_kind = 'whey' then 'ricotta_open' else 'batch_open' end,
        'name', case when b.input_kind = 'whey' then 'Ricotta in lavorazione' else coalesce(b.product, 'Lotto') || ' · in lavorazione' end,
        'sub', case when b.input_kind = 'whey' then 'tino · ' || to_char(coalesce((b.started_at at time zone 'Europe/Rome')::date, b.batch_date), 'DD/MM/YYYY')
                    else 'avviato ' || to_char(coalesce((b.started_at at time zone 'Europe/Rome')::date, b.batch_date), 'DD/MM/YYYY')
                         || coalesce(' alle ' || to_char(b.started_at at time zone 'Europe/Rome', 'HH24:MI'), '') end,
        'copies', 1, 'on_hold', coalesce(b.food_safety_hold, false), 'hold_reason', b.hold_reason, 'open', true,
        'date', coalesce((b.started_at at time zone 'Europe/Rome')::date, b.batch_date));
    end if;
    select max(expiry_date) into v_exp from fabula.stock_moves where upper(lot_number) = v and expiry_date is not null;
    v_exp := coalesce(v_exp, coalesce((b.finished_at at time zone 'Europe/Rome')::date, b.batch_date) + coalesce(b.shelf_life_days, 5));
    return jsonb_build_object('lot', b.batch_lot, 'kind', case when b.input_kind = 'whey' then 'ricotta' else 'batch' end,
      'name', coalesce(b.product, 'Lotto'), 'sub', 'scad. ' || to_char(v_exp, 'DD/MM/YYYY'), 'expiry', v_exp,
      'copies', greatest(coalesce(v_copies, 1), 1), 'on_hold', coalesce(b.food_safety_hold, false), 'hold_reason', b.hold_reason, 'open', false,
      'date', coalesce((b.finished_at at time zone 'Europe/Rome')::date, b.batch_date));
  end if;
  select mi.milk_lot, mi.intake_date, mi.accepted, mi.rejection_reason, pa.legal_name as supplier
    into m from fabula.milk_intake mi left join fabula.parties pa on pa.id = mi.supplier_id
   where upper(mi.milk_lot) = v order by mi.intake_date desc, mi.created_at desc limit 1;
  if found then
    return jsonb_build_object('lot', m.milk_lot, 'kind', 'milk',
      'name', 'Latte di bufala · ' || coalesce(m.supplier, 'fornitore'), 'sub', 'arrivo ' || to_char(m.intake_date, 'DD/MM/YYYY'),
      'copies', 1, 'on_hold', false, 'rejected', m.accepted is false, 'rejection_reason', m.rejection_reason, 'open', false, 'date', m.intake_date);
  end if;
  return null;
end $$;
revoke all on function fabula._lot_label(text) from public, anon, authenticated;

create or replace function fabula._lot_label_reader() returns boolean
language sql stable security definer set search_path = fabula, public as $$
  select greatest(fabula.perm_level('produzione'), fabula.perm_level('magazzino'), fabula.perm_level('spedizioni'), fabula.perm_level('haccp')) >= 1
$$;
revoke all on function fabula._lot_label_reader() from public, anon, authenticated;

-- labels.html: { "<code as written>": {found, lot, name, sub, …} } for every LOT: code on the page
create or replace function fabula.lot_label_info(p_codes text[]) returns jsonb
language plpgsql stable security definer set search_path = fabula, public as $$
declare c text; res jsonb := '{}'::jsonb; l jsonb;
begin
  if not fabula._lot_label_reader() then raise exception 'Il tuo profilo non vede i lotti' using errcode = '42501'; end if;
  foreach c in array coalesce(p_codes[1:120], '{}'::text[]) loop
    if c is null or c !~* '^\s*LOT:' then continue; end if;
    l := fabula._lot_label(c);
    res := res || jsonb_build_object(c, coalesce(l || '{"found": true}'::jsonb, '{"found": false}'::jsonb));
  end loop;
  return res;
end $$;

-- the tablet's «Ristampa etichette»: lots still being worked, then the last p_days days (newest first), optionally searched
create or replace function fabula.lot_labels(p_q text default null, p_days int default 14) returns jsonb
language plpgsql stable security definer set search_path = fabula, public as $$
declare v_q text := nullif(upper(btrim(regexp_replace(coalesce(p_q, ''), '^\s*LOT:', '', 'i'))), ''); v_from date := (now() at time zone 'Europe/Rome')::date - greatest(least(coalesce(p_days, 14), 60), 1);
begin
  if not fabula._lot_label_reader() then raise exception 'Il tuo profilo non vede i lotti' using errcode = '42501'; end if;
  -- every lot of the period is labelled, then sorted (being worked first, newest next), then the first 80 kept
  return (select coalesce(jsonb_agg(l order by k_open desc, k_date desc nulls last, k_lot desc), '[]'::jsonb)
    from (select l, (l ->> 'open')::boolean as k_open, (l ->> 'date')::date as k_date, l ->> 'lot' as k_lot
            from (select fabula._lot_label(x.lot) as l
                    from (select batch_lot as lot from fabula.production_batches
                           where (output_kg is null and batch_date >= v_from - 46) or batch_date >= v_from or finished_at >= v_from
                          union
                          select milk_lot from fabula.milk_intake where intake_date >= v_from and milk_lot is not null) x
                   where v_q is null or upper(x.lot) like '%' || replace(replace(v_q, '%', ''), '_', '\_') || '%') y
           where l is not null
           order by k_open desc, k_date desc nulls last, k_lot desc
           limit 80) z);
end $$;

-- a reprint: checks the lot, counts it on the lot's label row (a closed batch or a milk lot without one gets it now; a batch still
-- being worked does not, because closing it creates that row), and returns the label to print
create or replace function fabula.lot_label_reprint(p_lot text, p_copies int default 1, p_staff_id uuid default null) returns jsonb
language plpgsql security definer set search_path = fabula, public as $$
declare l jsonb := fabula._lot_label(p_lot); v_staff uuid := coalesce(p_staff_id, fabula.my_staff_id()); n int := greatest(least(coalesce(p_copies, 1), 60), 1);
        v_code text; b record; m record;
begin
  if greatest(fabula.perm_level('produzione'), fabula.perm_level('magazzino'), fabula.perm_level('spedizioni')) < 2 then
    raise exception 'Il tuo profilo non può stampare etichette di lotto' using errcode = '42501';
  end if;
  if l is null then raise exception 'Lotto sconosciuto: %', coalesce(nullif(btrim(p_lot), ''), '(vuoto)') using errcode = '22023'; end if;
  if p_staff_id is not null and not exists (select 1 from fabula.staff where id = p_staff_id and active) then v_staff := fabula.my_staff_id(); end if;
  v_code := 'LOT:' || (l ->> 'lot');
  update fabula.labels set reprinted_count = reprinted_count + 1, last_reprinted_at = now(), last_reprinted_by_id = v_staff
   where upper(code) = upper(v_code);
  if not found and not (l ->> 'open')::boolean then
    if l ->> 'kind' = 'milk' then
      select id into m from fabula.milk_intake where upper(milk_lot) = upper(l ->> 'lot') order by intake_date desc, created_at desc limit 1;
      insert into fabula.labels (kind, code, lot_number, milk_intake_id, qty_printed, printed_by_id, reprinted_count, last_reprinted_at, last_reprinted_by_id)
      values ('milk_lot', v_code, l ->> 'lot', m.id, n, v_staff, 1, now(), v_staff) on conflict (code) do nothing;
    else
      select id, product_id into b from fabula.production_batches where upper(batch_lot) = upper(l ->> 'lot') order by created_at desc limit 1;
      insert into fabula.labels (kind, code, lot_number, product_id, batch_id, qty_printed, printed_by_id, reprinted_count, last_reprinted_at, last_reprinted_by_id)
      values ('batch_lot', v_code, l ->> 'lot', b.product_id, b.id, n, v_staff, 1, now(), v_staff) on conflict (code) do nothing;
    end if;
  end if;
  return l || jsonb_build_object('copies', n);
end $$;

revoke all on function fabula.lot_label_info(text[]) from public, anon;
revoke all on function fabula.lot_labels(text, int) from public, anon;
revoke all on function fabula.lot_label_reprint(text, int, uuid) from public, anon;
grant execute on function fabula.lot_label_info(text[]) to authenticated;
grant execute on function fabula.lot_labels(text, int) to authenticated;
grant execute on function fabula.lot_label_reprint(text, int, uuid) to authenticated;

insert into fabula.security_accepted (key, reason) values
  ('authenticated_security_definer_function_executable:fabula.lot_label_info(p_codes text[])', 'by design (v1.03c, audit PRINT-08): lot name and expiry for labels.html; produzione/magazzino/spedizioni/haccp ≥ vede'),
  ('authenticated_security_definer_function_executable:fabula.lot_labels(p_q text, p_days integer)', 'by design (v1.03c, audit PRINT-08): recent lots for the tablet reprint list; produzione/magazzino/spedizioni/haccp ≥ vede'),
  ('authenticated_security_definer_function_executable:fabula.lot_label_reprint(p_lot text, p_copies integer, p_staff_id uuid)', 'by design (v1.03c, audit PRINT-08): checks the lot and counts the reprint; produzione/magazzino/spedizioni ≥ registra')
on conflict (key) do nothing;
