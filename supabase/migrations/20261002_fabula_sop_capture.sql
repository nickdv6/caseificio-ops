-- =============================================================================
-- Latteria Fabula — v0.2: physical capture + SOP layer
-- Applies on top of 20261001_fabula_core_schema.sql
--
-- Adds:  staff, equipment, labels, documents, sensor_readings, shipments,
--        pos_daily_closings, meter_readings, waste_log, sops/sop_steps,
--        task_schedules/task_instances, non_conformities, recalls
-- Changes to v0.1: operator/casaro/received_by get FK columns to staff;
--        haccp_log gets equipment_id; a generic scan_events table records
--        every QR scan so the "did it happen" question is always answerable.
-- =============================================================================
set search_path = fabula, public;

-- -----------------------------------------------------------------------------
-- Enums
-- -----------------------------------------------------------------------------
create type fabula.staff_role      as enum ('owner','partner','casaro','operaio','commesso','consulente');
create type fabula.equipment_kind  as enum ('cold_room','pasteurizer','stretcher','vat','scale','thermometer','packaging','vehicle','pos','other');
create type fabula.label_kind      as enum ('milk_lot','batch_lot','retail_pack','wholesale_case','equipment','staff_badge','location');
create type fabula.document_kind   as enum ('ddt_in','ddt_out','supplier_cert','consorzio','haccp_plan','contract','photo','invoice_pdf','other');
create type fabula.shipment_status as enum ('planned','picked','in_transit','delivered','returned');
create type fabula.task_frequency  as enum ('per_batch','per_shift','daily','twice_daily','weekly','monthly','quarterly','yearly','on_demand');
create type fabula.task_status     as enum ('due','done','skipped','overdue');
create type fabula.nc_severity     as enum ('minor','major','critical');
create type fabula.nc_status       as enum ('open','investigating','corrected','closed');
create type fabula.scan_action     as enum ('milk_receive','batch_start','batch_end','temp_check','clean_done','pick','deliver','task_done','lookup');

-- -----------------------------------------------------------------------------
-- 1. Staff — who did the step; replaces free-text operator fields
-- -----------------------------------------------------------------------------
create table fabula.staff (
  id               uuid primary key default gen_random_uuid(),
  auth_user_id     uuid unique,                        -- auth.users.id when they log in on the tablet
  full_name        text not null,
  role             fabula.staff_role not null,
  badge_code       text unique,                        -- what the staff QR encodes
  haccp_training_expires date,
  active           boolean not null default true,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

alter table fabula.milk_intake        add column received_by_id uuid references fabula.staff(id);
alter table fabula.production_batches add column casaro_id      uuid references fabula.staff(id);
alter table fabula.haccp_log          add column operator_id    uuid references fabula.staff(id);
alter table fabula.haccp_log          add column verified_by_id uuid references fabula.staff(id);

-- -----------------------------------------------------------------------------
-- 2. Equipment — every machine gets a QR; HACCP checks reference it
-- -----------------------------------------------------------------------------
create table fabula.equipment (
  id               uuid primary key default gen_random_uuid(),
  code             text not null unique,               -- 'CF-01', what the QR encodes
  name             text not null,
  kind             fabula.equipment_kind not null,
  location         text,
  serial_number    text,
  calibration_interval_days int,
  last_calibrated_on date,
  next_calibration_on date generated always as
                     (case when last_calibrated_on is not null and calibration_interval_days is not null
                           then last_calibrated_on + calibration_interval_days end) stored,
  maintenance_interval_days int,
  last_maintenance_on date,
  active           boolean not null default true,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

alter table fabula.haccp_log add column equipment_id uuid references fabula.equipment(id);
alter table fabula.haccp_control_points add column equipment_id uuid references fabula.equipment(id);

-- -----------------------------------------------------------------------------
-- 3. Labels — every printed QR, so a scan always resolves to something
-- -----------------------------------------------------------------------------
create table fabula.labels (
  id               uuid primary key default gen_random_uuid(),
  kind             fabula.label_kind not null,
  code             text not null unique,               -- payload inside the QR, e.g. 'LOT:L20261002-A' or 'EQ:CF-01'
  lot_number       text,
  product_id       uuid references fabula.products(id),
  batch_id         uuid references fabula.production_batches(id),
  milk_intake_id   uuid references fabula.milk_intake(id),
  equipment_id     uuid references fabula.equipment(id),
  staff_id         uuid references fabula.staff(id),
  qty_printed      int not null default 1,
  template         text,                               -- 'retail_500g', 'case_a5'
  printed_by_id    uuid references fabula.staff(id),
  printed_at       timestamptz not null default now()
);
create index labels_lot_idx on fabula.labels (lot_number);

-- Every scan, raw. Agents answer "was the cold room checked?" from here.
create table fabula.scan_events (
  id               uuid primary key default gen_random_uuid(),
  scanned_at       timestamptz not null default now(),
  code             text not null,                      -- what was in the QR
  action           fabula.scan_action not null,
  staff_id         uuid references fabula.staff(id),
  label_id         uuid references fabula.labels(id),
  equipment_id     uuid references fabula.equipment(id),
  device           text,                               -- 'tablet-1', 'nick-iphone'
  resulting_table  text,                               -- which record the scan created/updated
  resulting_id     uuid,
  payload          jsonb not null default '{}'::jsonb  -- e.g. {"temp_c": 3.6}
);
create index scan_events_time_idx on fabula.scan_events (scanned_at desc);
create index scan_events_code_idx on fabula.scan_events (code);

-- -----------------------------------------------------------------------------
-- 4. Documents — DDTs, certificates, photos; OCR text for the accounting agent
-- -----------------------------------------------------------------------------
create table fabula.documents (
  id               uuid primary key default gen_random_uuid(),
  kind             fabula.document_kind not null,
  storage_path     text not null,                      -- Supabase Storage
  original_filename text,
  mime_type        text,
  ocr_text         text,
  extracted        jsonb,                              -- agent's structured read: {"ddt_number":"123","kg":1200,...}
  related_table    text,
  related_id       uuid,
  party_id         uuid references fabula.parties(id),
  document_date    date,
  uploaded_by_id   uuid references fabula.staff(id),
  verified         boolean not null default false,     -- human confirmed the extraction
  created_at       timestamptz not null default now()
);
create index documents_related_idx on fabula.documents (related_table, related_id);

-- -----------------------------------------------------------------------------
-- 5. Sensor readings — cold rooms should not depend on a human
-- -----------------------------------------------------------------------------
create table fabula.sensor_readings (
  id               bigint generated always as identity primary key,
  equipment_id     uuid not null references fabula.equipment(id),
  read_at          timestamptz not null default now(),
  temperature_c    numeric(5,2),
  humidity_pct     numeric(5,2),
  door_open        boolean,
  battery_pct      numeric(5,2),
  source           text not null default 'sensor'
);
create index sensor_readings_eq_time_idx on fabula.sensor_readings (equipment_id, read_at desc);

-- Roll sensor data into HACCP log twice a day (call from a cron / edge function)
create or replace function fabula.rollup_sensor_haccp(p_window interval default interval '12 hours')
returns int language plpgsql as $$
declare n int := 0;
begin
  insert into fabula.haccp_log (control_point_id, equipment_id, logged_at, measured_value, result, operator, source)
  select cp.id, cp.equipment_id, now(),
         max(sr.temperature_c),
         case when max(sr.temperature_c) > cp.max_value or min(sr.temperature_c) < cp.min_value
              then 'non_conformity'::fabula.haccp_result else 'ok'::fabula.haccp_result end,
         'sensor', 'sensor'
  from fabula.haccp_control_points cp
  join fabula.sensor_readings sr on sr.equipment_id = cp.equipment_id
  where cp.active and cp.equipment_id is not null
    and sr.read_at > now() - p_window
  group by cp.id, cp.equipment_id, cp.max_value, cp.min_value;
  get diagnostics n = row_count;
  return n;
end $$;

-- -----------------------------------------------------------------------------
-- 6. Outbound logistics — wholesale deliveries with lot numbers and POD
-- -----------------------------------------------------------------------------
create table fabula.shipments (
  id               uuid primary key default gen_random_uuid(),
  ddt_number       text not null unique,
  customer_id      uuid not null references fabula.parties(id),
  sales_order_id   uuid references fabula.sales_orders(id),
  status           fabula.shipment_status not null default 'planned',
  ship_date        date not null default current_date,
  driver_id        uuid references fabula.staff(id),
  vehicle_id       uuid references fabula.equipment(id),
  temp_at_departure_c numeric(4,1),
  temp_at_delivery_c  numeric(4,1),
  delivered_at     timestamptz,
  pod_document_id  uuid references fabula.documents(id), -- signed DDT photo
  notes            text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

create table fabula.shipment_lines (
  id               uuid primary key default gen_random_uuid(),
  shipment_id      uuid not null references fabula.shipments(id) on delete cascade,
  product_id       uuid not null references fabula.products(id),
  lot_number       text not null,
  qty              numeric(10,3) not null check (qty > 0)
);
create index shipment_lines_lot_idx on fabula.shipment_lines (lot_number);

-- -----------------------------------------------------------------------------
-- 7. POS daily close — registratore telematico vs what we recorded
-- -----------------------------------------------------------------------------
create table fabula.pos_daily_closings (
  closing_date     date primary key,
  rt_total_eur     numeric(12,2) not null,             -- from the registratore telematico Z report
  rt_receipts      int,
  cash_counted_eur numeric(12,2),
  card_eur         numeric(12,2),
  recorded_total_eur numeric(12,2),                    -- sum(sales_orders.total_eur) store_pos that day, filled by agent
  variance_eur     numeric(12,2) generated always as (rt_total_eur - coalesce(recorded_total_eur,0)) stored,
  closed_by_id     uuid references fabula.staff(id),
  z_report_document_id uuid references fabula.documents(id),
  notes            text,
  created_at       timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- 8. Meter readings — kWh per kg is your most sensitive number
-- -----------------------------------------------------------------------------
create table fabula.meter_readings (
  id               uuid primary key default gen_random_uuid(),
  meter            text not null,                      -- 'elec_main', 'gas', 'water'
  read_at          timestamptz not null default now(),
  reading          numeric(14,3) not null,             -- cumulative
  unit             text not null,                      -- kWh, m3
  read_by_id       uuid references fabula.staff(id),
  source           text not null default 'manual'
);
create index meter_readings_idx on fabula.meter_readings (meter, read_at desc);

create or replace view fabula.v_energy_per_kg as
with daily as (
  select meter, read_at::date as d,
         max(reading) - min(reading) as consumed, max(unit) as unit
  from fabula.meter_readings group by meter, read_at::date
)
select d.d as production_date, d.meter, d.consumed, d.unit,
       p.output_kg,
       round(d.consumed / nullif(p.output_kg,0), 3) as per_kg_output
from daily d
left join (select batch_date, sum(output_kg) output_kg from fabula.production_batches group by batch_date) p
       on p.batch_date = d.d;

-- -----------------------------------------------------------------------------
-- 9. Waste — the number that drives milk procurement
-- -----------------------------------------------------------------------------
create table fabula.waste_log (
  id               uuid primary key default gen_random_uuid(),
  wasted_at        timestamptz not null default now(),
  product_id       uuid not null references fabula.products(id),
  lot_number       text,
  qty              numeric(10,3) not null check (qty > 0),
  reason           text not null,                      -- 'scaduto','difetto','reso cliente','campione'
  stock_move_id    uuid references fabula.stock_moves(id),
  logged_by_id     uuid references fabula.staff(id),
  notes            text
);

-- -----------------------------------------------------------------------------
-- 10. SOPs — the written procedure, versioned
-- -----------------------------------------------------------------------------
create table fabula.sops (
  id               uuid primary key default gen_random_uuid(),
  code             text not null,                      -- 'SOP-RIC-01'
  version          int not null default 1,
  title            text not null,
  title_it         text,
  area             text not null,                      -- ricezione | produzione | haccp | magazzino | vendita | amministrazione
  document_id      uuid references fabula.documents(id),
  effective_from   date not null default current_date,
  superseded_on    date,
  approved_by_id   uuid references fabula.staff(id),
  unique (code, version)
);

create table fabula.sop_steps (
  id               uuid primary key default gen_random_uuid(),
  sop_id           uuid not null references fabula.sops(id) on delete cascade,
  step_no          int not null,
  instruction_it   text not null,
  instruction_en   text,
  scan_action      fabula.scan_action,                 -- if this step is completed by a scan
  requires_value   text,                               -- 'temp_c', 'kg', 'ph'
  control_point_id uuid references fabula.haccp_control_points(id),
  unique (sop_id, step_no)
);

-- -----------------------------------------------------------------------------
-- 11. Task schedules + instances — "what should have happened today"
-- -----------------------------------------------------------------------------
create table fabula.task_schedules (
  id               uuid primary key default gen_random_uuid(),
  code             text not null unique,
  title_it         text not null,
  title_en         text,
  frequency        fabula.task_frequency not null,
  sop_id           uuid references fabula.sops(id),
  control_point_id uuid references fabula.haccp_control_points(id),
  equipment_id     uuid references fabula.equipment(id),
  assigned_role    fabula.staff_role,
  due_time         time,                               -- for daily/twice_daily
  grace_minutes    int not null default 120,
  active           boolean not null default true
);

create table fabula.task_instances (
  id               uuid primary key default gen_random_uuid(),
  schedule_id      uuid not null references fabula.task_schedules(id),
  due_at           timestamptz not null,
  status           fabula.task_status not null default 'due',
  completed_at     timestamptz,
  completed_by_id  uuid references fabula.staff(id),
  scan_event_id    uuid references fabula.scan_events(id),
  haccp_log_id     uuid references fabula.haccp_log(id),
  skip_reason      text,
  unique (schedule_id, due_at)
);
create index task_instances_open_idx on fabula.task_instances (status, due_at) where status in ('due','overdue');

-- Generate today's instances (idempotent; call from cron each morning)
create or replace function fabula.generate_daily_tasks(p_date date default current_date)
returns int language plpgsql as $$
declare n int := 0;
begin
  insert into fabula.task_instances (schedule_id, due_at)
  select s.id, (p_date + coalesce(s.due_time, time '12:00'))::timestamptz
  from fabula.task_schedules s
  where s.active and s.frequency in ('daily','per_shift')
  union all
  select s.id, (p_date + time '08:00')::timestamptz from fabula.task_schedules s
  where s.active and s.frequency = 'twice_daily'
  union all
  select s.id, (p_date + time '18:00')::timestamptz from fabula.task_schedules s
  where s.active and s.frequency = 'twice_daily'
  union all
  select s.id, (p_date + coalesce(s.due_time, time '12:00'))::timestamptz from fabula.task_schedules s
  where s.active and s.frequency = 'weekly' and extract(isodow from p_date) = 1
  union all
  select s.id, (p_date + coalesce(s.due_time, time '12:00'))::timestamptz from fabula.task_schedules s
  where s.active and s.frequency = 'monthly' and extract(day from p_date) = 1
  on conflict do nothing;
  get diagnostics n = row_count;
  -- mark yesterday's leftovers overdue
  update fabula.task_instances set status = 'overdue'
  where status = 'due' and due_at + make_interval(mins => 120) < now();
  return n;
end $$;

create or replace view fabula.v_tasks_open as
select ti.id, ti.due_at, ti.status, s.code, s.title_it, s.title_en, s.assigned_role, e.code as equipment_code
from fabula.task_instances ti
join fabula.task_schedules s on s.id = ti.schedule_id
left join fabula.equipment e on e.id = s.equipment_id
where ti.status in ('due','overdue')
order by ti.due_at;

-- -----------------------------------------------------------------------------
-- 12. Non-conformities + recalls
-- -----------------------------------------------------------------------------
create table fabula.non_conformities (
  id               uuid primary key default gen_random_uuid(),
  opened_at        timestamptz not null default now(),
  severity         fabula.nc_severity not null,
  status           fabula.nc_status not null default 'open',
  description      text not null,
  haccp_log_id     uuid references fabula.haccp_log(id),
  batch_id         uuid references fabula.production_batches(id),
  lot_number       text,
  equipment_id     uuid references fabula.equipment(id),
  root_cause       text,
  corrective_action text,
  preventive_action text,
  opened_by_id     uuid references fabula.staff(id),
  closed_by_id     uuid references fabula.staff(id),
  closed_at        timestamptz,
  document_id      uuid references fabula.documents(id)
);

create table fabula.recalls (
  id               uuid primary key default gen_random_uuid(),
  opened_at        timestamptz not null default now(),
  lot_numbers      text[] not null,
  reason           text not null,
  non_conformity_id uuid references fabula.non_conformities(id),
  asl_notified_at  timestamptz,                        -- autorità sanitaria
  consorzio_notified_at timestamptz,
  closed_at        timestamptz,
  opened_by_id     uuid references fabula.staff(id)
);

-- Who got a lot: one query, the whole recall list
create or replace view fabula.v_lot_distribution as
select sl.lot_number, 'wholesale' as channel, p.legal_name as customer, sh.ddt_number as ref, sh.ship_date as on_date, sl.qty
from fabula.shipment_lines sl
join fabula.shipments sh on sh.id = sl.shipment_id
join fabula.parties p on p.id = sh.customer_id
union all
select sol.lot_number, so.channel::text, coalesce(p.legal_name,'anonimo'), so.order_number, so.order_date, sol.qty
from fabula.sales_order_lines sol
join fabula.sales_orders so on so.id = sol.sales_order_id
left join fabula.parties p on p.id = so.customer_id
where sol.lot_number is not null;

-- -----------------------------------------------------------------------------
-- Triggers, RLS, grants for new tables
-- -----------------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['staff','equipment','shipments']
  loop
    execute format('create trigger %I_updated_at before update on fabula.%I
                    for each row execute function fabula.set_updated_at()', t, t);
  end loop;
  for t in select table_name from information_schema.tables
           where table_schema = 'fabula' and table_type = 'BASE TABLE'
             and table_name in ('staff','equipment','labels','scan_events','documents','sensor_readings',
                                'shipments','shipment_lines','pos_daily_closings','meter_readings','waste_log',
                                'sops','sop_steps','task_schedules','task_instances','non_conformities','recalls')
  loop
    execute format('alter table fabula.%I enable row level security', t);
    execute format('create policy %I_authenticated_all on fabula.%I
                    for all to authenticated using (true) with check (true)', t, t);
  end loop;
end $$;
grant all on all tables in schema fabula to authenticated, service_role;
grant all on all sequences in schema fabula to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- Seed: equipment, link control points, SOP + daily schedule
-- -----------------------------------------------------------------------------
insert into fabula.equipment (code, name, kind, calibration_interval_days) values
  ('CF-01','Cella frigo 1','cold_room',null),
  ('CF-02','Cella frigo 2','cold_room',null),
  ('PAST-01','Pastorizzatore','pasteurizer',null),
  ('FIL-01','Filatrice','stretcher',null),
  ('BIL-01','Bilancia ricezione','scale',365),
  ('TERM-01','Termometro a sonda','thermometer',180),
  ('RT-01','Registratore telematico','pos',null);

update fabula.haccp_control_points cp set equipment_id = e.id from fabula.equipment e
 where (cp.code,e.code) in (('CCP-COLD-1','CF-01'),('CCP-COLD-2','CF-02'),('CCP-PAST','PAST-01'),('CCP-MILK-TEMP','TERM-01'));

insert into fabula.labels (kind, code, equipment_id)
select 'equipment', 'EQ:'||code, id from fabula.equipment;

insert into fabula.sops (code, title, title_it, area) values
  ('SOP-01','Daily floor routine','Routine giornaliera di caseificio','produzione');

insert into fabula.sop_steps (sop_id, step_no, instruction_it, instruction_en, scan_action, requires_value)
select s.id, v.n, v.it, v.en, v.act::fabula.scan_action, v.val from fabula.sops s,
(values
 (1,'Apertura: scansiona CF-01 e CF-02, inserisci la temperatura','Opening: scan both cold rooms, enter temperature','temp_check','temp_c'),
 (2,'Arrivo latte: scansiona il DDT, conferma kg e temperatura del latte','Milk arrival: scan the DDT, confirm kg and milk temperature','milk_receive','temp_c'),
 (3,'Inizio lavorazione: scansiona il lotto latte, inserisci kg in lavorazione','Start batch: scan milk lot, enter kg into the vat','batch_start','kg'),
 (4,'Pastorizzazione: scansiona PAST-01, inserisci la temperatura raggiunta','Pasteurisation: scan PAST-01, enter temperature reached','temp_check','temp_c'),
 (5,'Fine lavorazione: inserisci kg prodotto, stampa le etichette lotto','End batch: enter kg produced, print lot labels','batch_end','kg'),
 (6,'Vendita banco / spedizione: scansiona l''etichetta lotto','Sale or shipment: scan the lot label','pick',null),
 (7,'Chiusura: scansiona CF-01 e CF-02, inserisci la temperatura','Closing: scan both cold rooms, enter temperature','temp_check','temp_c'),
 (8,'Sanificazione: scansiona il cartello pulizia a fine turno','Cleaning: scan the cleaning sign at end of shift','clean_done',null),
 (9,'Chiusura cassa: inserisci il totale dello scontrino Z','Till close: enter the Z report total','task_done','eur'),
 (10,'Lettura contatore luce','Electricity meter reading','task_done','kwh')
) as v(n,it,en,act,val)
where s.code='SOP-01';

insert into fabula.task_schedules (code, title_it, title_en, frequency, due_time, control_point_id, equipment_id, assigned_role)
select v.code, v.it, v.en, v.freq::fabula.task_frequency, v.t::time, cp.id, e.id, v.role::fabula.staff_role
from (values
 ('T-CF1',  'Temperatura cella 1',        'Cold room 1 temp',      'twice_daily', null,    'CCP-COLD-1','CF-01','operaio'),
 ('T-CF2',  'Temperatura cella 2',        'Cold room 2 temp',      'twice_daily', null,    'CCP-COLD-2','CF-02','operaio'),
 ('T-CLEAN','Sanificazione fine turno',   'End-of-shift cleaning', 'daily',       '18:30', 'PRP-CLEAN', null,   'operaio'),
 ('T-PEST', 'Controllo infestanti',       'Pest check',            'weekly',      '09:00', 'PRP-PEST',  null,   'casaro'),
 ('T-Z',    'Chiusura cassa (scontrino Z)','Till close (Z report)','daily',       '19:30', null,        'RT-01','commesso'),
 ('T-KWH',  'Lettura contatore',          'Meter reading',         'daily',       '19:30', null,        null,   'operaio'),
 ('T-CAL',  'Taratura termometro',        'Thermometer calibration','monthly',    '09:00', null,        'TERM-01','casaro'),
 ('T-DOP',  'Dichiarazione produzione Consorzio','Consorzio production declaration','monthly','09:00', null, null, 'partner')
) as v(code,it,en,freq,t,cp,eq,role)
left join fabula.haccp_control_points cp on cp.code = v.cp
left join fabula.equipment e on e.code = v.eq;
