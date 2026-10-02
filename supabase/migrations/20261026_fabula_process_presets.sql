-- =============================================================================
-- Fabula v0.26 — process presets: machine settings per recipe step, saved as
-- labelled configurations the casaro can pick at batch start and fine-tune.
--   * process_presets (per finished product, one default) → process_steps
--     (phase start/make/close, order, machine, temperature target/min/max,
--     duration, speed, pH, free extras, instruction, which value to record)
--   * production_batches.preset_id; batch_step_logs = target vs actual per step
--   * clone_preset / set_default_preset / log_batch_step / default_preset
--   * v_process_steps (tablet + console), v_preset_results (yield per preset)
--   * seed: Mozzarella "Base · prova 29/09", Ricotta "Base" — all values are
--     textbook starting points marked da confermare con il casaro
-- Written without destructive keywords (connector rule).
-- =============================================================================
set search_path = fabula, public;

create table if not exists fabula.process_presets (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references fabula.products(id),
  name text not null,
  description text,
  is_default boolean not null default false,
  active boolean not null default true,
  based_on_id uuid references fabula.process_presets(id),
  created_by_id uuid references fabula.staff(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (product_id, name)
);
create table if not exists fabula.process_steps (
  id uuid primary key default gen_random_uuid(),
  preset_id uuid not null references fabula.process_presets(id),
  phase text not null default 'make' check (phase in ('start', 'make', 'close')),
  step_order int not null default 10,
  name_it text not null,
  equipment_id uuid references fabula.equipment(id),
  target_temp_c numeric, temp_min_c numeric, temp_max_c numeric,
  duration_min numeric, duration_min_min numeric, duration_max_min numeric,
  speed numeric, speed_unit text,
  target_ph numeric, ph_min numeric, ph_max numeric,
  extra jsonb not null default '{}'::jsonb,
  instruction_it text,
  record_metric text not null default 'none' check (record_metric in ('temp', 'duration', 'ph', 'speed', 'none')),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists process_steps_preset_idx on fabula.process_steps (preset_id, phase, step_order);
alter table fabula.production_batches add column if not exists preset_id uuid references fabula.process_presets(id);
create table if not exists fabula.batch_step_logs (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references fabula.production_batches(id),
  step_id uuid references fabula.process_steps(id),
  step_name text,
  metric text,
  target_value numeric,
  actual_value numeric,
  logged_at timestamptz not null default now(),
  staff_id uuid references fabula.staff(id),
  note text,
  source text not null default 'tablet',
  unique (batch_id, step_id)
);
alter table fabula.process_presets enable row level security;
alter table fabula.process_steps enable row level security;
alter table fabula.batch_step_logs enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'fabula' and tablename = 'process_presets' and policyname = 'process_presets_authenticated_all') then
    create policy process_presets_authenticated_all on fabula.process_presets for all to authenticated using (true) with check (true); end if;
  if not exists (select 1 from pg_policies where schemaname = 'fabula' and tablename = 'process_steps' and policyname = 'process_steps_authenticated_all') then
    create policy process_steps_authenticated_all on fabula.process_steps for all to authenticated using (true) with check (true); end if;
  if not exists (select 1 from pg_policies where schemaname = 'fabula' and tablename = 'batch_step_logs' and policyname = 'batch_step_logs_authenticated_all') then
    create policy batch_step_logs_authenticated_all on fabula.batch_step_logs for all to authenticated using (true) with check (true); end if;
end $$;
grant select, insert, update on fabula.process_presets, fabula.process_steps, fabula.batch_step_logs to authenticated, service_role;

-- machines seen in the 29/09 trial media (equipment-inventory doc); plates to be read on site
insert into fabula.equipment (code, name, kind, location, maintenance_interval_days, active)
select v.code, v.name, v.kind::fabula.equipment_kind, 'caseificio', 180, true
from (values ('TINA-01', 'Tina di coagulazione', 'vat'), ('TINO-01', 'Tino riscaldato con agitatore', 'vat'),
             ('TRIT-01', 'Tritacagliata', 'other'), ('FORM-01', 'Formatrice', 'other'), ('VAS-01', 'Vasca di rassodamento', 'other')) v(code, name, kind)
where not exists (select 1 from fabula.equipment e where e.code = v.code);

-- ---------- functions ----------
create or replace function fabula.default_preset(p_product_id uuid)
returns uuid language sql stable as $$
  select id from fabula.process_presets where product_id = p_product_id and active
  order by is_default desc, created_at limit 1
$$;

create or replace function fabula.set_default_preset(p_preset_id uuid)
returns void language plpgsql as $$
declare v_prod uuid;
begin
  select product_id into v_prod from fabula.process_presets where id = p_preset_id;
  if v_prod is null then raise exception 'Preset sconosciuto'; end if;
  update fabula.process_presets set is_default = (id = p_preset_id), updated_at = now() where product_id = v_prod;
end $$;

create or replace function fabula.clone_preset(p_preset_id uuid, p_name text, p_staff_id uuid default null)
returns uuid language plpgsql as $$
declare src fabula.process_presets%rowtype; v_new uuid;
begin
  select * into src from fabula.process_presets where id = p_preset_id;
  if src.id is null then raise exception 'Preset sconosciuto'; end if;
  if coalesce(trim(p_name), '') = '' then raise exception 'Dai un nome al nuovo preset'; end if;
  insert into fabula.process_presets (product_id, name, description, is_default, active, based_on_id, created_by_id)
  values (src.product_id, trim(p_name), 'Copia di "' || src.name || '" del ' || to_char(now() at time zone 'Europe/Rome', 'DD/MM/YYYY'), false, true, src.id, p_staff_id)
  returning id into v_new;
  insert into fabula.process_steps (preset_id, phase, step_order, name_it, equipment_id, target_temp_c, temp_min_c, temp_max_c, duration_min, duration_min_min, duration_max_min, speed, speed_unit, target_ph, ph_min, ph_max, extra, instruction_it, record_metric, active)
  select v_new, phase, step_order, name_it, equipment_id, target_temp_c, temp_min_c, temp_max_c, duration_min, duration_min_min, duration_max_min, speed, speed_unit, target_ph, ph_min, ph_max, extra, instruction_it, record_metric, active
  from fabula.process_steps where preset_id = src.id and active;
  return v_new;
end $$;

create or replace function fabula.log_batch_step(p_batch_lot text, p_step_id uuid, p_actual numeric, p_staff_id uuid default null, p_note text default null)
returns text language plpgsql as $$
declare b record; s fabula.process_steps%rowtype; v_target numeric;
begin
  select id, preset_id into b from fabula.production_batches where batch_lot = p_batch_lot;
  select * into s from fabula.process_steps where id = p_step_id;
  if b.id is null or s.id is null then raise exception 'Lotto o passo sconosciuto: % / %', p_batch_lot, p_step_id; end if;
  v_target := case s.record_metric when 'temp' then s.target_temp_c when 'duration' then s.duration_min when 'ph' then s.target_ph when 'speed' then s.speed else null end;
  insert into fabula.batch_step_logs (batch_id, step_id, step_name, metric, target_value, actual_value, staff_id, note)
  values (b.id, s.id, s.name_it, s.record_metric, v_target, p_actual, p_staff_id, p_note)
  on conflict (batch_id, step_id) do update set actual_value = excluded.actual_value, logged_at = now(), staff_id = coalesce(excluded.staff_id, fabula.batch_step_logs.staff_id), note = coalesce(excluded.note, fabula.batch_step_logs.note);
  -- keep the legacy summary columns on the batch in step with the log
  if s.record_metric = 'ph' and s.phase = 'make' then update fabula.production_batches set curd_ph = p_actual where id = b.id; end if;
  if s.record_metric = 'temp' and s.equipment_id = (select id from fabula.equipment where code = 'FIL-01') then update fabula.production_batches set stretch_temp_c = p_actual where id = b.id; end if;
  if b.preset_id is null then update fabula.production_batches set preset_id = s.preset_id where id = b.id; end if;
  return 'logged';
end $$;

-- ---------- views ----------
create or replace view fabula.v_process_steps as
  select s.id as step_id, s.preset_id, p.name as preset_name, p.is_default, p.active as preset_active, p.product_id, pr.sku as product_sku, pr.name as product_name,
         s.phase, s.step_order, s.name_it, s.equipment_id, e.code as equipment_code, e.name as equipment_name,
         s.target_temp_c, s.temp_min_c, s.temp_max_c, s.duration_min, s.duration_min_min, s.duration_max_min, s.speed, s.speed_unit, s.target_ph, s.ph_min, s.ph_max,
         s.extra, s.instruction_it, s.record_metric, s.active,
         nullif(concat_ws(' · ',
           case when s.target_temp_c is not null then replace(s.target_temp_c::text, '.', ',') || ' °C' || case when s.temp_min_c is not null and s.temp_max_c is not null then ' (' || replace(s.temp_min_c::text, '.', ',') || '–' || replace(s.temp_max_c::text, '.', ',') || ')' else '' end end,
           case when s.duration_min is not null then replace(s.duration_min::text, '.', ',') || ' min' || case when s.duration_min_min is not null and s.duration_max_min is not null then ' (' || s.duration_min_min::text || '–' || s.duration_max_min::text || ')' else '' end end,
           case when s.speed is not null then 'vel. ' || replace(s.speed::text, '.', ',') || coalesce(' ' || s.speed_unit, '') end,
           case when s.target_ph is not null then 'pH ' || replace(s.target_ph::text, '.', ',') || case when s.ph_min is not null and s.ph_max is not null then ' (' || replace(s.ph_min::text, '.', ',') || '–' || replace(s.ph_max::text, '.', ',') || ')' else '' end end,
           (select string_agg(key || ': ' || value, ' · ') from jsonb_each_text(s.extra))), '') as target_txt
  from fabula.process_steps s
  join fabula.process_presets p on p.id = s.preset_id
  join fabula.products pr on pr.id = p.product_id
  left join fabula.equipment e on e.id = s.equipment_id;
grant select on fabula.v_process_steps to authenticated, service_role;

create or replace view fabula.v_preset_results as
  select p.id as preset_id, p.product_id, pr.sku as product_sku, pr.name as product_name, p.name, p.description, p.is_default, p.active, p.created_at, p.based_on_id,
         (select name from fabula.process_presets b where b.id = p.based_on_id) as based_on_name,
         (select count(*) from fabula.process_steps s where s.preset_id = p.id and s.active) as n_steps,
         (select count(*) from fabula.production_batches b where b.preset_id = p.id and b.output_kg is not null) as n_batches,
         (select round(avg(b.yield_pct), 1) from fabula.production_batches b where b.preset_id = p.id and b.output_kg is not null) as avg_yield_pct,
         (select round(avg(b.curd_ph), 2) from fabula.production_batches b where b.preset_id = p.id and b.curd_ph is not null) as avg_curd_ph,
         (select max(b.batch_date) from fabula.production_batches b where b.preset_id = p.id) as last_batch_date,
         (select round(avg(abs(l.actual_value - l.target_value) / nullif(abs(l.target_value), 0)) * 100, 1) from fabula.batch_step_logs l join fabula.production_batches b on b.id = l.batch_id where b.preset_id = p.id and l.target_value is not null and l.actual_value is not null) as avg_abs_dev_pct
  from fabula.process_presets p join fabula.products pr on pr.id = p.product_id;
grant select on fabula.v_preset_results to authenticated, service_role;

-- ---------- seed presets (textbook values, da confermare con il casaro) ----------
do $$
declare v_moz uuid; v_ric uuid; v_pm uuid; v_pr uuid; eq_tina uuid; eq_tino uuid; eq_fil uuid; eq_trit uuid; eq_form uuid; eq_vas uuid;
begin
  select id into v_moz from fabula.products where sku = 'MOZ-DOP-KG';
  select id into v_ric from fabula.products where sku = 'RIC-BUF-KG';
  select id into eq_tina from fabula.equipment where code = 'TINA-01'; select id into eq_tino from fabula.equipment where code = 'TINO-01';
  select id into eq_fil from fabula.equipment where code = 'FIL-01'; select id into eq_trit from fabula.equipment where code = 'TRIT-01';
  select id into eq_form from fabula.equipment where code = 'FORM-01'; select id into eq_vas from fabula.equipment where code = 'VAS-01';
  if v_moz is not null and not exists (select 1 from fabula.process_presets where product_id = v_moz) then
    insert into fabula.process_presets (product_id, name, description, is_default) values (v_moz, 'Base · prova 29/09', 'Valori di partenza da manuale, da confermare con il casaro sulla prova del 29/09. Copia questo preset per provare varianti.', true) returning id into v_pm;
    insert into fabula.process_steps (preset_id, phase, step_order, name_it, equipment_id, target_temp_c, temp_min_c, temp_max_c, duration_min, duration_min_min, duration_max_min, speed, speed_unit, target_ph, ph_min, ph_max, extra, instruction_it, record_metric) values
      (v_pm, 'start', 5,  'Riscaldamento del latte', eq_tina, 36, 35, 38, null, null, null, null, null, null, null, null, '{}', 'Porta il latte a 36–38 °C in tina. Latte intero crudo o termizzato secondo disciplinare.', 'temp'),
      (v_pm, 'start', 7,  'Siero-innesto naturale', eq_tina, 36, null, null, null, null, null, null, null, null, null, null, '{"dose": "da definire (% sul latte)"}', 'Aggiungi il siero-innesto del giorno prima e mescola.', 'none'),
      (v_pm, 'start', 12, 'Coagulazione', eq_tina, 36, null, null, 25, 20, 30, null, null, null, null, null, '{}', 'Lascia in quiete fino alla presa: la cagliata si stacca netta dalla parete.', 'duration'),
      (v_pm, 'start', 14, 'Rottura della cagliata', eq_tina, null, null, null, 8, 5, 10, 1, 'livello', null, null, null, '{}', 'Prima rottura a noce, poi a nocciola con lo spino, lentamente.', 'none'),
      (v_pm, 'start', 16, 'Riposo sotto siero', eq_tina, null, null, null, 15, 10, 20, null, null, null, null, null, '{}', 'Lascia depositare; estrai il siero per il siero-innesto e per la ricotta.', 'none'),
      (v_pm, 'make', 10, 'Maturazione della cagliata', null, null, null, null, 240, 180, 300, null, null, 4.95, 4.9, 5.1, '{"prova": "filatura a mano in acqua a 90 °C"}', 'Cagliata sul tavolo spersore fino a pH 4,9–5,1 e prova di filatura positiva.', 'ph'),
      (v_pm, 'make', 20, 'Tritatura', eq_trit, null, null, null, null, null, null, null, null, null, null, null, '{}', 'Riduci la cagliata matura a strisce con la tritacagliata.', 'none'),
      (v_pm, 'make', 30, 'Filatura', eq_fil, 92, 90, 95, 5, 3, 8, 2, 'livello', null, null, null, '{"pasta": "60–65 °C"}', 'Acqua a 90–95 °C; la pasta deve essere lucida, tesa e a 60–65 °C.', 'temp'),
      (v_pm, 'make', 40, 'Formatura', eq_form, null, null, null, null, null, null, 1, 'livello', null, null, null, '{"tamburo": "125 g / 250 g / 500 g"}', 'Monta il tamburo del formato del giorno; getto d''acqua acceso.', 'none'),
      (v_pm, 'make', 50, 'Rassodamento', eq_vas, 12, 10, 15, 15, 10, 20, null, null, null, null, null, '{}', 'Acqua fredda in vasca di rassodamento.', 'duration'),
      (v_pm, 'make', 60, 'Salatura in salamoia', null, 12, 10, 15, 45, 30, 90, null, null, null, null, null, '{"salamoia": "12–18% NaCl"}', 'Tempo in salamoia secondo la pezzatura: meno per i bocconcini, di più per le 500 g.', 'duration'),
      (v_pm, 'close', 20, 'Liquido di governo', null, 12, 10, 14, null, null, null, null, null, null, null, null, '{"composizione": "acqua, siero diluito, sale 1–2%"}', 'Confeziona nel liquido di governo; conserva a 10–14 °C, mai in frigo sotto i 4 °C.', 'none');
  end if;
  if v_ric is not null and not exists (select 1 from fabula.process_presets where product_id = v_ric) then
    insert into fabula.process_presets (product_id, name, description, is_default) values (v_ric, 'Base', 'Ricotta dal siero di filatura: valori di partenza, da confermare con il casaro.', true) returning id into v_pr;
    insert into fabula.process_steps (preset_id, phase, step_order, name_it, equipment_id, target_temp_c, temp_min_c, temp_max_c, duration_min, duration_min_min, duration_max_min, speed, speed_unit, target_ph, ph_min, ph_max, extra, instruction_it, record_metric) values
      (v_pr, 'start', 5,  'Riscaldamento del siero', eq_tino, 80, 78, 85, null, null, null, 1, 'livello', null, null, null, '{}', 'Scalda il siero nel tino con agitazione lenta.', 'temp'),
      (v_pr, 'start', 25, 'Affioramento', eq_tino, 88, 85, 92, 10, 5, 15, 0, 'livello', null, null, null, '{}', 'A 85–90 °C ferma l''agitatore e lascia affiorare la ricotta.', 'temp'),
      (v_pr, 'start', 30, 'Raccolta nelle fuscelle', null, null, null, null, 5, null, null, null, null, null, null, null, '{}', 'Raccogli con la schiumarola nelle fuscelle sul tavolo spersoio.', 'none'),
      (v_pr, 'close', 20, 'Sgrondo e raffreddamento', null, 4, 2, 4, 60, 30, 120, null, null, null, null, null, '{}', 'Lascia sgrondare, poi in cella a 4 °C.', 'none');
  end if;
end $$;
