-- Rollback of v1.18a (yield per product): puts back the batch limits of v0.98 and the expected yield of v0.70 exactly as they were,
-- then drops the three product columns and their checks. v1.18a changed no grant, policy or other function. The yields written on
-- products are lost with the columns (they are in the audit log). To use it, copy it into supabase/migrations under a new, later
-- version and release it through the pipeline like any other release (the pipeline never re-releases an older commit). The v1.18
-- tablet selects yield_min_pct and yield_max_pct: revert those two selects in fabula-tablet/app.js in the same release (new sw CACHE).

create or replace function fabula.trg_batch_bounds() returns trigger language plpgsql set search_path = fabula, public as $$
declare v_whey boolean := new.input_kind = 'whey'; v_vat numeric; v_par record; v_y numeric; v_lo numeric; v_hi numeric; v_what text;
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
    if v_whey then v_lo := fabula.setting_num('prod.ricotta_yield_min_pct', 2); v_hi := fabula.setting_num('prod.ricotta_yield_max_pct', 25); v_what := 'siero';
    else v_lo := fabula.setting_num('prod.yield_min_pct', 10); v_hi := fabula.setting_num('prod.yield_max_pct', 45); v_what := 'latte'; end if;
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
  if exists (select 1 from fabula.products where byproduct_product_id = p_product) then
    v_pct := fabula.setting_num('prod.ricotta_yield_pct', 10); v_src := 'default_byproduct';
  else
    v_pct := fabula.setting_num('sales.yield_pct', 30); v_src := 'default';
  end if;
  return jsonb_build_object('pct', v_pct, 'source', v_src, 'n', coalesce(v_n, 0), 'tolerance_pts', v_tol);
end $$;
revoke all on function fabula.expected_yield(uuid, uuid, uuid) from public, anon;
grant execute on function fabula.expected_yield(uuid, uuid, uuid) to authenticated, service_role;

alter table fabula.products
  drop constraint if exists products_yield_expected_in_range_chk,
  drop constraint if exists products_yield_range_chk,
  drop constraint if exists products_yield_max_pct_chk,
  drop constraint if exists products_yield_min_pct_chk,
  drop constraint if exists products_yield_expected_pct_chk;
alter table fabula.products drop column if exists yield_expected_pct, drop column if exists yield_min_pct, drop column if exists yield_max_pct;
