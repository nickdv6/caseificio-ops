-- v0.39 · 2026-10-02 · milk price standardised at €1.70/kg; plan benchmark from settings
-- (part of the v0.39 integrity pass; see 20261002172859 for the overview)

-- v0.39 · 2026-10-02 · integrity pass
--   1. milk price standardised at €1.70/kg (setting + default on every intake; no more hard-coded €1.30)
--   2. accepted milk intakes book raw-milk stock (with a processing deadline as expiry)
--   3. milk is pasteurised before mozzarella: CCP 2 active, pasteurisation step in the mozzarella preset, lab plan adjusted
--   4. lot guard on finished-goods stock: system-allocated sales spill FEFO instead of driving a lot negative;
--      scanned sales keep the scanned lot (label = truth for recalls) and raise a notice; existing negative lots repaired
--   5. web overselling: Shopify inventory push switched off; paid-but-unshipped web orders become milk-plan demand
--   6. bots on Agropoli time: bot_schedule due times and bot_watchdog in Europe/Rome; plan benchmark from settings
--   7. reliability: pg_cron heartbeat independent of the Claude scheduler; simulation tools and mkt_ai_complete no longer callable by users

-- ---------------------------------------------------------------- 1. milk price
insert into fabula.settings (key, value, description, data_type, sort) values
  ('milk.price_eur_kg', '1.70', 'Prezzo del latte di bufala €/kg IVA esclusa — usato per ogni conferimento senza prezzo e in tutti i costi', 'number', 5),
  ('milk.raw_shelf_days', '2', 'Giorni entro cui il latte conferito va lavorato (scadenza del lotto latte in magazzino)', 'number', 6),
  ('benchmark.annual_profit_eur', '155500', 'Utile operativo annuo di piano (investment-recommendation v47) — riferimento del brief settimanale', 'number', 7)
on conflict (key) do update set value = excluded.value, description = excluded.description;

create or replace function fabula.trg_milk_price_default() returns trigger
language plpgsql set search_path = fabula, public as $$
begin
  if new.price_eur_per_kg is null then new.price_eur_per_kg := fabula.setting_num('milk.price_eur_kg', 1.70); end if;
  return new;
end $$;
create or replace trigger milk_intake_price_default before insert on fabula.milk_intake
  for each row execute function fabula.trg_milk_price_default();

update fabula.milk_intake set price_eur_per_kg = 1.70 where price_eur_per_kg is distinct from 1.70;
update fabula.stock_moves m set unit_cost_eur = 1.70
  from fabula.products p where p.id = m.product_id and p.sku = 'RAW-MILK' and m.move_type = 'milk_intake';

-- the €1.30 fallbacks and the old €220,787 benchmark become settings
do $$
declare f record; d text;
begin
  for f in select p.oid from pg_proc p where p.pronamespace = 'fabula'::regnamespace and p.prokind = 'f'
             and p.proname in ('plan_milk', 'demand_7d', 'monthly_package', 'unit_cost_estimate', '_week_block', 'weekly_brief') loop
    d := pg_get_functiondef(f.oid);
    d := replace(d, '1.30', 'fabula.setting_num(''milk.price_eur_kg'', 1.70)');
    d := replace(d, 'round(220787.0 / 52, 2)', 'round(fabula.setting_num(''benchmark.annual_profit_eur'', 155500) / 52, 2)');
    execute d;
  end loop;
end $$;
