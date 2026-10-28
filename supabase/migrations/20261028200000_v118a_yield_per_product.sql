-- v1.18a · yield per product. Stracciatella counts its cream in the kg produced (about 0,6 kg of curd + 0,4 kg of cream per kg), so a
-- normal lot is ~50 % of the milk and the one milk limit for every product (prod.yield_max_pct, 45 %) refused it as «impossibile».
-- Scamorza runs ~25 %, so until it has 3 lots of its own the 30 % default (sales.yield_pct) flagged every lot «bassa».
-- A product can now carry its own expected, minimum and maximum yield; empty = exactly as before (the settings).
-- Database only for the rules; the tablet reads the same two limits for its own check at the close (app.js, sw perla-v82).

alter table fabula.products
  add column if not exists yield_expected_pct numeric,
  add column if not exists yield_min_pct numeric,
  add column if not exists yield_max_pct numeric;

alter table fabula.products
  add constraint products_yield_expected_pct_chk check (yield_expected_pct is null or (yield_expected_pct > 0 and yield_expected_pct <= 100)),
  add constraint products_yield_min_pct_chk check (yield_min_pct is null or (yield_min_pct > 0 and yield_min_pct <= 100)),
  add constraint products_yield_max_pct_chk check (yield_max_pct is null or (yield_max_pct > 0 and yield_max_pct <= 100)),
  add constraint products_yield_range_chk check (yield_min_pct is null or yield_max_pct is null or yield_min_pct < yield_max_pct),
  add constraint products_yield_expected_in_range_chk check (yield_expected_pct is null
    or ((yield_min_pct is null or yield_expected_pct >= yield_min_pct) and (yield_max_pct is null or yield_expected_pct <= yield_max_pct)));

comment on column fabula.products.yield_expected_pct is 'v1.18: expected yield (% of the milk or whey) used by expected_yield until the product has 3 lots of its own; empty = sales.yield_pct (or prod.ricotta_yield_pct for a by-product)';
comment on column fabula.products.yield_min_pct is 'v1.18: lowest normal yield for this product (below it the close needs the reason of the loss); empty = prod.yield_min_pct (whey: prod.ricotta_yield_min_pct)';
comment on column fabula.products.yield_max_pct is 'v1.18: highest possible yield for this product (above it the close is refused); empty = prod.yield_max_pct (whey: prod.ricotta_yield_max_pct)';

-- the batch limits: the product's own when set, else the settings (unchanged from v0.98 otherwise)
create or replace function fabula.trg_batch_bounds() returns trigger language plpgsql set search_path = fabula, public as $$
declare v_whey boolean := new.input_kind = 'whey'; v_vat numeric; v_par record; v_y numeric; v_lo numeric; v_hi numeric; v_what text;
        v_pmin numeric; v_pmax numeric;
begin
  if coalesce(new.source, '') in ('simulation', 'test') then return new; end if;
  if tg_op = 'INSERT' or new.milk_in_kg is distinct from old.milk_in_kg then
    if not v_whey then
      v_vat := fabula.setting_num('prod.vat_kg', null);
      if v_vat is not null and new.milk_in_kg > v_vat * 1.1 then
        raise exception using errcode = '23514', message = format(
          'Latte in caldaia %s kg: una caldaia ne tiene al massimo %s kg (Latte per lotto %s kg, +10 %%). Controlla i kg (senza punto: 310, non 3.100).',
          fabula._it_num(new.milk_in_kg), fabula._it_num(round(v_vat * 1.1)), fabula._it_num(v_vat));
      end if;
    elsif new.parent_batch_id is not null then
      select batch_lot, milk_in_kg into v_par from fabula.production_batches where id = new.parent_batch_id;
      if v_par.milk_in_kg is not null and new.milk_in_kg > v_par.milk_in_kg * 0.95 then
        raise exception using errcode = '23514', message = format('Siero per la ricotta %s kg: non può superare il latte della caldaia %s (%s kg). Controlla i kg.',
          fabula._it_num(new.milk_in_kg), v_par.batch_lot, fabula._it_num(v_par.milk_in_kg));
      end if;
    end if;
  end if;
  if new.output_kg is not null and new.milk_in_kg > 0
     and (tg_op = 'INSERT' or new.output_kg is distinct from old.output_kg or new.milk_in_kg is distinct from old.milk_in_kg) then
    v_y := round(new.output_kg / new.milk_in_kg * 100, 1);
    select yield_min_pct, yield_max_pct into v_pmin, v_pmax from fabula.products where id = new.product_id;
    if v_whey then v_lo := coalesce(v_pmin, fabula.setting_num('prod.ricotta_yield_min_pct', 2)); v_hi := coalesce(v_pmax, fabula.setting_num('prod.ricotta_yield_max_pct', 25)); v_what := 'siero';
    else v_lo := coalesce(v_pmin, fabula.setting_num('prod.yield_min_pct', 10)); v_hi := coalesce(v_pmax, fabula.setting_num('prod.yield_max_pct', 45)); v_what := 'latte'; end if;
    if v_y > v_hi then
      raise exception using errcode = '23514', message = format(
        'Resa %s %%: impossibile (al massimo %s %%). Controlla i kg di %s (%s) e i kg prodotti (%s).',
        fabula._it_num(v_y), fabula._it_num(v_hi), v_what, fabula._it_num(new.milk_in_kg), fabula._it_num(new.output_kg));
    end if;
    if v_y < v_lo and length(trim(coalesce(new.yield_note, ''))) < 3 then
      raise exception using errcode = '23514', message = format(
        'Resa %s %%: troppo bassa per un lotto normale (di solito almeno %s %%). Controlla i kg di %s (%s) e i kg prodotti (%s); se una parte è andata persa, scrivi cosa è successo.',
        fabula._it_num(v_y), fabula._it_num(v_lo), v_what, fabula._it_num(new.milk_in_kg), fabula._it_num(new.output_kg));
    end if;
  end if;
  return new;
end $$;
revoke all on function fabula.trg_batch_bounds() from public, anon, authenticated;
drop trigger if exists batch_yield_bounds on fabula.production_batches;
create trigger batch_yield_bounds before insert or update of milk_in_kg, output_kg, yield_note on fabula.production_batches
  for each row execute function fabula.trg_batch_bounds();

-- expected yield: the preset's last 10 lots if at least 3, else the product's last 30 days if at least 3, else (v1.18) the product's
-- own expected yield when set («default_product»: the tablet still shows it as «stimata»), else the default as before
create or replace function fabula.expected_yield(p_product uuid, p_preset uuid default null, p_exclude uuid default null) returns jsonb
language plpgsql stable security definer set search_path = fabula, public as $$
declare v_pct numeric; v_n int; v_src text; v_tol numeric := fabula.setting_num('prod.yield_tolerance_pts', 4);
begin
  if p_preset is not null then
    select round(avg(yield_pct), 1), count(*) into v_pct, v_n from (
      select yield_pct from fabula.production_batches
       where preset_id = p_preset and output_kg is not null and yield_pct > 0 and source is distinct from 'simulation' and id is distinct from p_exclude
       order by finished_at desc nulls last limit 10) x;
    if v_n >= 3 then return jsonb_build_object('pct', v_pct, 'source', 'preset', 'n', v_n, 'tolerance_pts', v_tol); end if;
  end if;
  select round(avg(yield_pct), 1), count(*) into v_pct, v_n from fabula.production_batches
   where product_id = p_product and output_kg is not null and yield_pct > 0 and source is distinct from 'simulation' and id is distinct from p_exclude
     and batch_date >= (now() at time zone 'Europe/Rome')::date - 30;
  if v_n >= 3 then return jsonb_build_object('pct', v_pct, 'source', 'avg_30d', 'n', v_n, 'tolerance_pts', v_tol); end if;
  select yield_expected_pct into v_pct from fabula.products where id = p_product;
  if v_pct is not null then
    return jsonb_build_object('pct', v_pct, 'source', 'default_product', 'n', coalesce(v_n, 0), 'tolerance_pts', v_tol);
  end if;
  if exists (select 1 from fabula.products where byproduct_product_id = p_product) then
    v_pct := fabula.setting_num('prod.ricotta_yield_pct', 10); v_src := 'default_byproduct';
  else
    v_pct := fabula.setting_num('sales.yield_pct', 30); v_src := 'default';
  end if;
  return jsonb_build_object('pct', v_pct, 'source', v_src, 'n', coalesce(v_n, 0), 'tolerance_pts', v_tol);
end $$;
revoke all on function fabula.expected_yield(uuid, uuid, uuid) from public, anon;
grant execute on function fabula.expected_yield(uuid, uuid, uuid) to authenticated, service_role;

-- the values for the lines added on live on 28/10/2026 (provisional, to confirm with the casaro); no row on a fresh replay
update fabula.products set yield_expected_pct = 50, yield_min_pct = 35, yield_max_pct = 70 where sku = 'STR-BUF-KG';
update fabula.products set yield_expected_pct = 25 where sku in ('SCA-BUF-KG', 'SCA-BUF-AFF-KG');
