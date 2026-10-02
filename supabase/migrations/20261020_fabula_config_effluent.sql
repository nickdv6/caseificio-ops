-- =============================================================================
-- Fabula v0.20 — configuration page groups + effluent (acque reflue) register
-- -----------------------------------------------------------------------------
--   * settings gains data_type (number | text) and sort so the admin page can
--     render a tab per group: Azienda, Latte, Vendite, Lavoro, Utenze, Reflui,
--     Masseria, Benchmark. Company data (name, P.IVA, address…) lives here and
--     feeds the printable PO.
--   * effluent_log: every discharge of scotta/siero, wash water or sludge, with
--     destination (pig farm, ricotta, sewer, hauler) and the FIR/RENTRI/DDT ref.
--     v_effluent_recent / v_effluent_monthly for console + package.
--     haccp_evening_status() adds "Reflui del giorno" when there was production
--     and nothing was logged. Compliance deadlines seeded for AUA, discharge
--     analysis, by-product contract.
-- Written without destructive keywords (connector rule).
-- =============================================================================
set search_path = fabula, public;

-- 1. settings: type + order --------------------------------------------------------
alter table fabula.settings add column if not exists data_type text not null default 'number';
alter table fabula.settings add column if not exists sort int not null default 100;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'settings_data_type_chk') then
    alter table fabula.settings add constraint settings_data_type_chk check (data_type in ('number','text'));
  end if;
end $$;
-- setting_text(key, default): text companion of setting_num
create or replace function fabula.setting_text(p_key text, p_default text default null) returns text language sql stable as $$
  select coalesce((select nullif(trim(value), '') from fabula.settings where key = p_key), p_default)
$$;
grant execute on function fabula.setting_text(text, text) to authenticated, service_role;

insert into fabula.settings (key, value, description, data_type, sort) values
  ('company.name',       'La Perla del Cilento', 'Nome commerciale (intestazione ordini, pagine)', 'text', 10),
  ('company.legal_name', '',                     'Ragione sociale (es. Masseria Cilentana Società Agricola)', 'text', 11),
  ('company.piva',       '',                     'Partita IVA dell''acquirente (NON quella del venditore)', 'text', 12),
  ('company.address',    'Agropoli (SA)',        'Indirizzo del caseificio (via, CAP, comune)', 'text', 13),
  ('company.email',      '',                     'Email ordini / amministrazione', 'text', 14),
  ('company.phone',      '',                     'Telefono / WhatsApp aziendale', 'text', 15),
  ('company.pec',        '',                     'PEC', 'text', 16),
  ('company.sdi',        '',                     'Codice destinatario SDI (fatturazione elettronica)', 'text', 17),
  ('company.receiving_hours', 'lun–sab 7:00–13:00', 'Orario di ricevimento merce stampato sugli ordini', 'text', 18),
  ('energy.water_eur_m3',  '2.50', 'Acqua potabile €/m³ (da bolletta, da confermare)', 'number', 20),
  ('energy.sewer_eur_m3',  '1.20', 'Fognatura e depurazione €/m³ (da bolletta, da confermare)', 'number', 21),
  ('energy.gas_eur_smc',   '1.10', 'Gas €/Smc (da bolletta, da confermare)', 'number', 22),
  ('effluent.whey_pct_of_milk', '62', 'Siero prodotto in % del latte lavorato', 'number', 30),
  ('effluent.wash_water_l_per_kg_milk', '2.5', 'Acque di lavaggio stimate, litri per kg di latte lavorato', 'number', 31),
  ('effluent.disposal_eur_m3', '0', 'Costo smaltimento reflui €/m³ se ritirati da trasportatore (0 = fognatura/allevamento)', 'number', 32)
on conflict (key) do update set data_type = excluded.data_type, sort = excluded.sort;
update fabula.settings set sort = case split_part(key, '.', 1) when 'milk' then 40 when 'farm' then 45 when 'price' then 50 when 'sell' then 55 when 'labor' then 60 when 'energy' then coalesce(nullif(sort, 100), 20) when 'opex' then 90 else sort end
 where key not like 'company.%' and key not like 'effluent.%';

-- 2. effluent register ----------------------------------------------------------------
create table if not exists fabula.effluent_log (
  id           uuid primary key default gen_random_uuid(),
  log_date     date not null default (now() at time zone 'Europe/Rome')::date,
  logged_at    timestamptz not null default now(),
  kind         text not null check (kind in ('scotta','siero','acque_lavaggio','fanghi','altro')),
  qty          numeric(12,2) not null check (qty >= 0),
  unit         text not null default 'l' check (unit in ('l','kg','m3')),
  destination  text not null check (destination in ('ricotta','allevamento','fognatura','trasportatore','depuratore_interno','altro')),
  recipient    text,                 -- allevamento / trasportatore / gestore
  document_ref text,                 -- FIR / RENTRI / DDT sottoprodotto
  ph           numeric(4,2),
  temp_c       numeric(5,2),
  notes        text,
  staff_id     uuid references fabula.staff(id),
  source       text not null default 'tablet'
);
create index if not exists effluent_log_date_idx on fabula.effluent_log (log_date desc);
grant all on fabula.effluent_log to authenticated, service_role;
alter table fabula.effluent_log enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname='fabula' and tablename='effluent_log' and policyname='effluent_log_authenticated_all') then
    create policy effluent_log_authenticated_all on fabula.effluent_log for all to authenticated using (true) with check (true);
  end if;
end $$;

-- litres everywhere (kg ≈ l for these fluids) → m³
create or replace function fabula.effluent_m3(p_qty numeric, p_unit text) returns numeric language sql immutable as $$
  select case p_unit when 'm3' then p_qty else p_qty / 1000.0 end
$$;
create or replace view fabula.v_effluent_recent as
  select e.log_date, e.kind, e.destination, e.recipient, e.document_ref, e.qty, e.unit, round(fabula.effluent_m3(e.qty, e.unit), 2) as m3, e.ph, e.temp_c, e.notes, s.full_name as logged_by
  from fabula.effluent_log e left join fabula.staff s on s.id = e.staff_id
  where e.log_date >= (now() at time zone 'Europe/Rome')::date - 14
  order by e.log_date desc, e.logged_at desc;
grant select on fabula.v_effluent_recent to authenticated, service_role;
create or replace view fabula.v_effluent_monthly as
  select date_trunc('month', log_date)::date as month, kind, destination,
         round(sum(fabula.effluent_m3(qty, unit)), 2) as m3, count(*) as entries,
         count(*) filter (where document_ref is not null) as documented
  from fabula.effluent_log group by 1, 2, 3 order by 1 desc, 2, 3;
grant select on fabula.v_effluent_monthly to authenticated, service_role;
-- expected vs logged, per day: whey from milk processed, wash water from the ratio in settings
create or replace view fabula.v_effluent_balance as
  select d.batch_date as log_date,
         round(d.milk_kg, 0) as milk_kg,
         round(d.milk_kg * fabula.setting_num('effluent.whey_pct_of_milk', 62) / 100 / 1000, 2) as whey_expected_m3,
         round(d.milk_kg * fabula.setting_num('effluent.wash_water_l_per_kg_milk', 2.5) / 1000, 2) as wash_expected_m3,
         coalesce((select round(sum(fabula.effluent_m3(qty, unit)), 2) from fabula.effluent_log e where e.log_date = d.batch_date and e.kind in ('siero','scotta')), 0) as whey_logged_m3,
         coalesce((select round(sum(fabula.effluent_m3(qty, unit)), 2) from fabula.effluent_log e where e.log_date = d.batch_date and e.kind = 'acque_lavaggio'), 0) as wash_logged_m3
  from (select batch_date, sum(milk_in_kg) milk_kg from fabula.production_batches where input_kind is distinct from 'whey' and milk_in_kg is not null group by batch_date) d
  where d.batch_date >= (now() at time zone 'Europe/Rome')::date - 30
  order by 1 desc;
grant select on fabula.v_effluent_balance to authenticated, service_role;

-- 3. evening nudge: reflui del giorno ----------------------------------------------------------
create or replace function fabula.haccp_evening_status(p_date date default (now() at time zone 'Europe/Rome')::date)
returns jsonb language plpgsql as $$
declare items jsonb := '[]'; v_key text := 'haccp_evening:' || p_date; n int;
begin
  select coalesce(jsonb_agg(jsonb_build_object('code', 'cold:' || cp.code, 'label_it', 'Temperatura serale ' || coalesce(e.code, cp.name), 'scan', 'EQ:' || e.code) order by cp.code), '[]') into items
  from fabula.haccp_control_points cp left join fabula.equipment e on e.id = cp.equipment_id
  where cp.active and cp.frequency = 'twice_daily'
    and not exists (select 1 from fabula.haccp_log l where l.control_point_id = cp.id and l.logged_at::date = p_date and (l.logged_at at time zone 'Europe/Rome')::time >= time '15:00');
  if not exists (select 1 from fabula.haccp_log l join fabula.haccp_control_points cp on cp.id = l.control_point_id where cp.code = 'PRP-CLEAN' and l.logged_at::date = p_date) then
    items := items || jsonb_build_object('code', 'clean', 'label_it', 'Sanificazione fine turno', 'scan', 'CLEAN:');
  end if;
  if exists (select 1 from fabula.production_batches where batch_date = p_date) or exists (select 1 from fabula.sales_orders where order_date = p_date) then
    if not exists (select 1 from fabula.pos_daily_closings where closing_date = p_date) then
      items := items || jsonb_build_object('code', 'z', 'label_it', 'Chiusura cassa (scontrino Z)', 'scan', 'EQ:RT-01'); end if;
    if not exists (select 1 from fabula.meter_readings where meter = 'elec_main' and read_at::date = p_date) then
      items := items || jsonb_build_object('code', 'kwh', 'label_it', 'Lettura contatore', 'scan', 'METER:elec_main'); end if;
  end if;
  -- production day without an effluent entry → ask for scotta / wash water
  if exists (select 1 from fabula.production_batches where batch_date = p_date and source <> 'simulation')
     and not exists (select 1 from fabula.effluent_log where log_date = p_date) then
    items := items || jsonb_build_object('code', 'effluent', 'label_it', 'Reflui del giorno (scotta, acque di lavaggio)', 'scan', 'EFFL:');
  end if;
  select items || coalesce(jsonb_agg(jsonb_build_object('code', 'batch:' || batch_lot, 'label_it', 'Lotto ' || batch_lot || ' non chiuso (kg prodotto)', 'scan', 'LOT:' || batch_lot)), '[]') into items
  from fabula.production_batches where batch_date = p_date and output_kg is null and source <> 'simulation';
  select items || coalesce(jsonb_agg(jsonb_build_object('code', 'shift:' || st.badge_code, 'label_it', st.full_name || ': badge di uscita non passato', 'scan', st.badge_code)), '[]') into items
  from fabula.shifts s join fabula.staff st on st.id = s.staff_id where s.clock_out is null and (s.clock_in at time zone 'Europe/Rome')::date = p_date;
  n := jsonb_array_length(items);
  if n > 0 then
    insert into fabula.notices (key, severity, title_it, items, expires_at)
    values (v_key, 'alert', format('Prima di chiudere: %s cose da registrare', n), items, ((p_date + 1)::timestamp + time '05:00') at time zone 'Europe/Rome')
    on conflict (key) do update set items = excluded.items, title_it = excluded.title_it, resolved_at = null;
  else
    update fabula.notices set resolved_at = now() where key = v_key and resolved_at is null;
  end if;
  return jsonb_build_object('date', p_date, 'missing', items, 'count', n,
    'is_simulation', exists (select 1 from fabula.simulation_runs where p_date between from_date and to_date),
    'closed_day', not (exists (select 1 from fabula.production_batches where batch_date = p_date) or exists (select 1 from fabula.sales_orders where order_date = p_date)));
end $$;

-- 4. compliance deadlines for discharges (dates unknown until the AUA is in hand) -------------------
insert into fabula.compliance_deadlines (kind, subject_it, interval_days, responsible, notes)
select v.kind, v.subject, v.interval_days, 'partner', v.notes from (values
  ('environment', 'AUA / autorizzazione allo scarico (verifica validità e prescrizioni)', 5475, 'Autorizzazione Unica Ambientale (DPR 59/2013): copia dal venditore in due diligence; indica se le acque di lavaggio vanno in fognatura o a trasportatore'),
  ('environment', 'Analisi acque di scarico (autocontrollo prescritto dall''AUA)', 365, 'Parametri tipici: COD, BOD5, SST, pH, grassi, azoto, fosforo — laboratorio accreditato'),
  ('environment', 'Contratto ritiro siero/scotta (allevamento o trasportatore) e tracciabilità sottoprodotto', 365, 'Se destinato ad alimentazione animale: sottoprodotto di origine animale cat. 3 (Reg. CE 1069/2009), documento commerciale per ogni ritiro; se rifiuto: FIR/RENTRI')
) v(kind, subject, interval_days, notes)
where not exists (select 1 from fabula.compliance_deadlines d where d.subject_it = v.subject);
