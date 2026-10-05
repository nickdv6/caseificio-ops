-- v0.70a (05/10/2026) · Production autopilot.
-- fabula.production_plan(date): what to make today from the milk on hand. For every accepted milk delivery with kg not yet
-- in a batch (oldest first) it proposes the batches: the milk split into equal vat loads (setting prod.vat_kg), the product
-- (mozzarella) with its default process preset, the start doses from the recipe, and the expected kg from the yield history
-- (fabula.expected_yield). It also returns the batches still open, what was made today, today's approved milk plan target
-- and, for each milk lot, the time left before the 60 h DOP limit. The tablet shows it on Home: one tap opens the batch
-- start already filled in.
-- Yield check: when a batch is closed, the expected yield is stored on the batch (yield_expected_pct); if the real yield is
-- off by more than prod.yield_tolerance_pts points the batch gets yield_flag 'bassa'/'alta' and a message goes to
-- Configurazione → Bot (bell). The tablet also asks to confirm a yield that far off before saving (likely a typo in the kg).

insert into fabula.settings(key, value, description, data_type, sort) values
 ('prod.vat_kg', '800', 'Latte per caldaia: kg massimi per lotto (Fortino 800 L, da confermare con il casaro)', 'number', 40),
 ('prod.yield_tolerance_pts', '4', 'Scostamento di resa (punti %) oltre cui il tablet chiede conferma e la console avvisa', 'number', 41),
 ('prod.ricotta_yield_pct', '10', 'Resa ricotta su siero (%) finché non ci sono lotti veri (prova 29/09: 60 kg siero → 6 kg)', 'number', 42)
on conflict (key) do nothing;

alter table fabula.production_batches add column if not exists yield_expected_pct numeric(5,2);
alter table fabula.production_batches add column if not exists yield_flag text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'production_batches_yield_flag_chk') then
    alter table fabula.production_batches add constraint production_batches_yield_flag_chk check (yield_flag in ('bassa', 'alta'));
  end if;
end $$;
comment on column fabula.production_batches.yield_expected_pct is 'v0.70: yield expected when the batch was closed (fabula.expected_yield)';
comment on column fabula.production_batches.yield_flag is 'v0.70: bassa/alta when the real yield is off by more than prod.yield_tolerance_pts';

-- expected yield for a product (and preset): the preset's last 10 batches if there are at least 3, else the product's last
-- 30 days if at least 3 batches, else the default (mozzarella: sales.yield_pct; a by-product such as ricotta: prod.ricotta_yield_pct)
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

-- today's production plan (read-only; anyone who can see production)
create or replace function fabula.production_plan(p_date date default ((now() at time zone 'Europe/Rome')::date)) returns jsonb
language plpgsql stable security definer set search_path = fabula, public as $$
declare v_vat numeric := greatest(fabula.setting_num('prod.vat_kg', 800), 50); v_min numeric := fabula.setting_num('milk.min_run_kg', 300);
        v_shelf int := fabula.setting_num('milk.raw_shelf_days', 2)::int; v_whey_pct numeric := fabula.setting_num('effluent.whey_pct_of_milk', 62);
        v_prod record; v_preset record; v_y jsonb; v_ric jsonb; m record; v_n int; v_kg numeric; v_rest numeric; v_seq int := 0;
        milk jsonb := '[]'; props jsonb := '[]'; v_doses jsonb; i int;
begin
  perform fabula.require_perm('produzione', 1);
  -- main product: the active finished good that is not a by-product (mozzarella), with its default preset
  select p.id, p.name, p.byproduct_product_id into v_prod from fabula.products p
   where p.kind = 'finished_good' and p.active and not exists (select 1 from fabula.products q where q.byproduct_product_id = p.id)
   order by (p.sku = 'MOZ-DOP-KG') desc, p.name limit 1;
  select pp.id, pp.name into v_preset from fabula.process_presets pp where pp.product_id = v_prod.id and pp.active order by pp.is_default desc, pp.created_at limit 1;
  v_y := fabula.expected_yield(v_prod.id, v_preset.id);
  if v_prod.byproduct_product_id is not null then v_ric := fabula.expected_yield(v_prod.byproduct_product_id); end if;

  for m in
    select mi.id, mi.milk_lot, mi.qty_kg, mi.intake_date, mi.intake_time, pa.legal_name supplier,
           least(coalesce(s.shipped_at, 'infinity'::timestamptz), (mi.intake_date + coalesce(mi.intake_time, '06:00')) at time zone 'Europe/Rome') + interval '60 hours' use_by,
           coalesce((select sum(bm.qty_kg) from fabula.batch_milk_inputs bm where bm.milk_intake_id = mi.id), 0) used
      from fabula.milk_intake mi
      left join fabula.parties pa on pa.id = mi.supplier_id
      left join fabula.milk_shipments s on s.id = mi.shipment_id
     where mi.accepted is not false and mi.intake_date between p_date - (v_shelf + 1) and p_date and coalesce(mi.source, '') <> 'simulation'
     order by mi.intake_date, mi.intake_time nulls first, mi.created_at
  loop
    v_rest := round(m.qty_kg - m.used, 1);
    continue when v_rest < 1;
    milk := milk || jsonb_build_object('milk_intake_id', m.id, 'milk_lot', m.milk_lot, 'supplier', m.supplier, 'intake_date', m.intake_date,
              'kg', m.qty_kg, 'used_kg', m.used, 'left_kg', v_rest, 'use_by', m.use_by,
              'hours_left', round(extract(epoch from (m.use_by - now())) / 3600, 1));
    -- equal vat loads: 1,150 kg with an 800 kg vat → 2 × 575 kg
    v_n := ceil(v_rest / v_vat)::int;
    for i in 1..v_n loop
      v_kg := case when i < v_n then round(v_rest / v_n, 1) else v_rest - round(v_rest / v_n, 1) * (v_n - 1) end;
      v_seq := v_seq + 1;
      select coalesce(jsonb_agg(jsonb_build_object('sku', r.sku, 'name', r.name, 'unit', r.unit,
                       'qty', case when r.round_up then ceil(r.qty_per_unit * v_kg) else round(r.qty_per_unit * v_kg, 3) end) order by r.step_order), '[]')
        into v_doses from fabula.v_recipe_active r where r.finished_product_id = v_prod.id and r.phase = 'start' and r.basis = 'per_kg_milk';
      props := props || jsonb_build_object('seq', v_seq, 'milk_intake_id', m.id, 'milk_lot', m.milk_lot, 'left_kg', v_rest, 'milk_kg', v_kg,
                 'product_id', v_prod.id, 'product', v_prod.name, 'preset_id', v_preset.id, 'preset', v_preset.name,
                 'yield_pct', v_y->'pct', 'yield_source', v_y->'source', 'expected_kg', round(v_kg * (v_y->>'pct')::numeric / 100, 1),
                 'whey_kg', round(v_kg * v_whey_pct / 100, 0),
                 'ricotta_kg', case when v_ric is not null then round(v_kg * v_whey_pct / 100 * (v_ric->>'pct')::numeric / 100, 1) end,
                 'doses', v_doses, 'use_by', m.use_by, 'small', v_rest < v_min);
    end loop;
  end loop;

  return jsonb_build_object(
    'date', p_date, 'vat_kg', v_vat, 'min_run_kg', v_min, 'tolerance_pts', v_y->'tolerance_pts',
    'yield', v_y, 'product', v_prod.name,
    'target', (select jsonb_build_object('milk_kg', mp.milk_kg, 'planned_output_kg', mp.planned_output_kg, 'status', mp.status)
                 from fabula.milk_plans mp where mp.plan_date = p_date and mp.status in ('approved', 'proposed') order by (mp.status = 'approved') desc limit 1),
    'milk', milk, 'proposals', props,
    'open', (select coalesce(jsonb_agg(jsonb_build_object('batch_id', b.id, 'batch_lot', b.batch_lot, 'product', p.name, 'input_kind', b.input_kind,
                       'milk_in_kg', b.milk_in_kg, 'started_at', b.started_at, 'batch_date', b.batch_date,
                       'expected_kg', round(b.milk_in_kg * (fabula.expected_yield(b.product_id, b.preset_id)->>'pct')::numeric / 100, 1)) order by b.started_at), '[]')
               from fabula.production_batches b join fabula.products p on p.id = b.product_id
              where b.output_kg is null and b.batch_date >= p_date - 3 and b.source is distinct from 'simulation'),
    'done', (select jsonb_build_object('batches', count(*), 'output_kg', coalesce(sum(b.output_kg), 0), 'milk_kg', coalesce(sum(b.milk_in_kg), 0),
                       'yield_pct', case when sum(b.milk_in_kg) > 0 then round(sum(b.output_kg) / sum(b.milk_in_kg) * 100, 1) end,
                       'flags', count(*) filter (where b.yield_flag is not null))
               from fabula.production_batches b
              where b.batch_date = p_date and b.output_kg is not null and b.product_id = v_prod.id and b.source is distinct from 'simulation'),
    'expected_kg', (select coalesce(sum((x->>'expected_kg')::numeric), 0) from jsonb_array_elements(props) x));
end $$;
revoke all on function fabula.production_plan(date) from public, anon;
grant execute on function fabula.production_plan(date) to authenticated, service_role;

-- at close: store the expected yield and flag a yield that is far off
create or replace function fabula.trg_batch_yield_check() returns trigger
language plpgsql security definer set search_path = fabula, public as $$
declare v_y jsonb; v_real numeric;
begin
  if new.output_kg is null or new.milk_in_kg is null or new.milk_in_kg <= 0 or new.source = 'simulation' then return new; end if;
  if tg_op = 'UPDATE' and old.output_kg is not distinct from new.output_kg and old.milk_in_kg is not distinct from new.milk_in_kg then return new; end if;
  v_y := fabula.expected_yield(new.product_id, new.preset_id, new.id);
  v_real := round(new.output_kg / new.milk_in_kg * 100, 2);
  new.yield_expected_pct := (v_y->>'pct')::numeric;
  new.yield_flag := case when v_real < new.yield_expected_pct - (v_y->>'tolerance_pts')::numeric then 'bassa'
                         when v_real > new.yield_expected_pct + (v_y->>'tolerance_pts')::numeric then 'alta' end;
  return new;
end $$;
revoke all on function fabula.trg_batch_yield_check() from public, anon, authenticated;

create or replace function fabula.trg_batch_yield_notify() returns trigger
language plpgsql security definer set search_path = fabula, public as $$
declare v_real numeric;
begin
  if new.yield_flag is null or (tg_op = 'UPDATE' and old.yield_flag is not distinct from new.yield_flag and old.output_kg is not distinct from new.output_kg) then return new; end if;
  v_real := round(new.output_kg / new.milk_in_kg * 100, 1);
  perform fabula.post_bot_message('produzione', 'warn',
    format('Resa %s lotto %s: %s%% (attesa %s%%)', new.yield_flag, new.batch_lot, trim_scale(v_real), trim_scale(new.yield_expected_pct)),
    format(E'Lotto %s (%s): %s kg %s → %s kg, resa %s%% contro %s%% attesa (tolleranza ±%s punti).\n%s',
           new.batch_lot, (select name from fabula.products where id = new.product_id), trim_scale(new.milk_in_kg),
           case when new.input_kind = 'whey' then 'di siero' else 'di latte' end, trim_scale(new.output_kg), trim_scale(v_real),
           trim_scale(new.yield_expected_pct), trim_scale(fabula.setting_num('prod.yield_tolerance_pts', 4)),
           case when new.yield_flag = 'bassa'
                then 'Controllare: kg pesati (prodotto e latte), grasso e proteine del latte, pH e tempi di maturazione, perdite in filatura.'
                else 'Controllare: kg pesati (latte inserito giusto?), umidità del prodotto (limite DOP 65%), acqua di filatura.' end));
  return new;
end $$;
revoke all on function fabula.trg_batch_yield_notify() from public, anon, authenticated;

do $$ begin
  if not exists (select 1 from pg_trigger where tgrelid = 'fabula.production_batches'::regclass and tgname = 'batch_yield_check') then
    create trigger batch_yield_check before insert or update of output_kg, milk_in_kg on fabula.production_batches
      for each row execute function fabula.trg_batch_yield_check();
  end if;
  if not exists (select 1 from pg_trigger where tgrelid = 'fabula.production_batches'::regclass and tgname = 'batch_yield_notify') then
    create trigger batch_yield_notify after insert or update of output_kg, milk_in_kg on fabula.production_batches
      for each row execute function fabula.trg_batch_yield_notify();
  end if;
end $$;

-- the yield messages appear in Configurazione → Bot under their own name
insert into fabula.bot_nicknames (agent, nickname, title_it, sort, updated_at)
values ('produzione', 'Zio Ciro', 'Resa produzione', coalesce((select max(sort) + 1 from fabula.bot_nicknames), 50), now())
on conflict (agent) do nothing;
