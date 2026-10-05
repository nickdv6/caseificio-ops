-- v0.65a (05/10/2026) · Farm shipments: the Masseria's weight is the source of truth (finished and applied 05/10).
-- At the farm someone scans the QR (latte.html?t=<token>&azione=spedizione) and enters the kg shipped (plus, optionally,
-- milk temperature, DDT number, a note). That creates a milk_shipments row with its own lot code (M<yymmdd>-<n>).
-- At the dairy, the tablet's milk-intake form offers the shipments still on the road: picking one fills in supplier,
-- lot and the farm's kg (locked) — the dairy confirms receipt and records the arrival checks (temperature, antibiotics:
-- CCP 1a/1b stay mandatory). Saving the intake marks the shipment received (or rejected) by trigger.
-- The farm page shows the latest shipment with its status, the last 30 days and the month's total.

create table if not exists fabula.milk_shipments (
  id uuid primary key default gen_random_uuid(),
  shipped_at timestamptz not null default now(),
  ship_date date not null default ((now() at time zone 'Europe/Rome')::date),
  supplier_id uuid references fabula.parties(id),
  kg numeric(8,1) not null check (kg > 0 and kg <= 5000),
  milk_lot text not null unique,
  temperature_c numeric(4,1) check (temperature_c between -2 and 40),
  ddt_number text,
  note text,
  status text not null default 'shipped' check (status in ('shipped', 'received', 'rejected')),
  milk_intake_id uuid references fabula.milk_intake(id),
  received_at timestamptz,
  received_by_id uuid references fabula.staff(id),
  source text not null default 'farm_page',
  created_at timestamptz not null default now()
);
create index if not exists milk_shipments_status_idx on fabula.milk_shipments (status, shipped_at desc);
comment on table fabula.milk_shipments is 'v0.65: milk shipped by the Masseria (weight entered at the farm = source of truth); received/rejected when the dairy saves the intake.';
alter table fabula.milk_shipments enable row level security;
grant select, insert, update on fabula.milk_shipments to authenticated;
grant all on fabula.milk_shipments to service_role;
insert into fabula.table_areas(table_name, area, read_open, write_level) values ('milk_shipments', 'produzione', false, 2)
on conflict (table_name) do nothing;
do $$ begin
  if not exists (select 1 from pg_policy where polrelid = 'fabula.milk_shipments'::regclass and polname = 'milk_shipments_authenticated_all') then
    create policy milk_shipments_authenticated_all on fabula.milk_shipments for all to authenticated using (true) with check (true);
    create policy milk_shipments_role_select on fabula.milk_shipments as restrictive for select to authenticated using ((select fabula.can_table('milk_shipments', false)));
    create policy milk_shipments_role_insert on fabula.milk_shipments as restrictive for insert to authenticated with check ((select fabula.can_table('milk_shipments', true)));
    create policy milk_shipments_role_update on fabula.milk_shipments as restrictive for update to authenticated using ((select fabula.can_table('milk_shipments', true)));
  end if;
  if not exists (select 1 from pg_trigger where tgrelid = 'fabula.milk_shipments'::regclass and tgname = 'milk_shipments_audit') then
    create trigger milk_shipments_audit after insert or update on fabula.milk_shipments for each row execute function fabula.trg_audit();
  end if;
end $$;

alter table fabula.milk_intake add column if not exists shipment_id uuid references fabula.milk_shipments(id);

insert into fabula.settings(key, value, description, data_type, sort) values
 ('milk.farm_supplier_id', coalesce((select id::text from fabula.parties where is_milk_supplier and legal_name ilike 'masseria%' order by created_at limit 1), ''),
  'Fornitore (anagrafica) delle spedizioni registrate dalla pagina della Masseria', 'text', 31)
on conflict (key) do nothing;

-- the farm records a shipment (token checked here; called by the edge function farm-order)
create or replace function fabula.farm_milk_ship(p_token text, p_kg numeric, p_temp numeric default null, p_ddt text default null, p_note text default null)
returns jsonb language plpgsql security definer set search_path = fabula, public as $$
declare v_tok text := (select value from fabula.settings where key = 'milk.farm_token');
        v_today date := (now() at time zone 'Europe/Rome')::date; v_n int; v_lot text; r fabula.milk_shipments;
begin
  if v_tok is null or length(v_tok) < 16 or p_token is distinct from v_tok then return null; end if;
  if p_kg is null or p_kg <= 0 or p_kg > 5000 then raise exception 'Peso non valido: %', p_kg using errcode = '22023'; end if;
  if p_temp is not null and (p_temp < -2 or p_temp > 40) then raise exception 'Temperatura non valida: %', p_temp using errcode = '22023'; end if;
  perform pg_advisory_xact_lock(hashtext('farm_milk_ship'));
  -- a second tap within 3 minutes with the same weight returns the shipment already recorded
  select * into r from fabula.milk_shipments where kg = round(p_kg, 1) and shipped_at > now() - interval '3 minutes' order by shipped_at desc limit 1;
  if found then return jsonb_build_object('id', r.id, 'milk_lot', r.milk_lot, 'kg', r.kg, 'shipped_at', r.shipped_at, 'duplicate', true); end if;
  select count(*) into v_n from fabula.milk_shipments where ship_date = v_today;
  if v_n >= 8 then raise exception 'Troppe spedizioni oggi (%)', v_n using errcode = '22023'; end if;
  v_lot := 'M' || to_char(v_today, 'YYMMDD') || '-' || (v_n + 1);
  while exists (select 1 from fabula.milk_shipments where milk_lot = v_lot) or exists (select 1 from fabula.labels where upper(code) = upper('LOT:' || v_lot)) loop
    v_n := v_n + 1; v_lot := 'M' || to_char(v_today, 'YYMMDD') || '-' || (v_n + 1);
  end loop;
  insert into fabula.milk_shipments (ship_date, supplier_id, kg, milk_lot, temperature_c, ddt_number, note)
  values (v_today, nullif((select value from fabula.settings where key = 'milk.farm_supplier_id'), '')::uuid, round(p_kg, 1), v_lot,
          p_temp, nullif(left(trim(coalesce(p_ddt, '')), 40), ''), nullif(left(trim(coalesce(p_note, '')), 300), ''))
  returning * into r;
  return jsonb_build_object('id', r.id, 'milk_lot', r.milk_lot, 'kg', r.kg, 'shipped_at', r.shipped_at);
end $$;
revoke all on function fabula.farm_milk_ship(text, numeric, numeric, text, text) from public, anon, authenticated;
grant execute on function fabula.farm_milk_ship(text, numeric, numeric, text, text) to service_role;

-- the farm page: latest shipment, last 30 days, month totals, and the orders (v0.64)
create or replace function fabula.farm_milk_orders(p_token text) returns jsonb
language plpgsql stable security definer set search_path = fabula, public as $$
declare v_today date := (now() at time zone 'Europe/Rome')::date; v_tok text := (select value from fabula.settings where key = 'milk.farm_token');
begin
  if v_tok is null or length(v_tok) < 16 or p_token is distinct from v_tok then return null; end if;
  return jsonb_build_object(
    'company', fabula.company_name(),
    'receiving_hours', (select value from fabula.settings where key = 'company.receiving_hours'),
    'today', v_today,
    'shipments', (select coalesce(jsonb_agg(jsonb_build_object('milk_lot', s.milk_lot, 'kg', s.kg, 'shipped_at', s.shipped_at, 'ship_date', s.ship_date,
                                                              'temperature_c', s.temperature_c, 'ddt_number', s.ddt_number, 'status', s.status, 'received_at', s.received_at,
                                                              'arrival_temp_c', mi.temperature_c, 'rejection_reason', mi.rejection_reason)
                                           order by s.shipped_at desc), '[]')
                    from fabula.milk_shipments s left join fabula.milk_intake mi on mi.id = s.milk_intake_id
                   where s.ship_date >= v_today - 30),
    'month', jsonb_build_object(
        'received_kg', (select coalesce(sum(kg), 0) from fabula.milk_shipments where status = 'received' and ship_date >= date_trunc('month', v_today)::date),
        'shipments', (select count(*) from fabula.milk_shipments where status = 'received' and ship_date >= date_trunc('month', v_today)::date),
        'prev_received_kg', (select coalesce(sum(kg), 0) from fabula.milk_shipments where status = 'received'
                               and ship_date >= (date_trunc('month', v_today) - interval '1 month')::date and ship_date < date_trunc('month', v_today)::date)),
    'orders', (select coalesce(jsonb_agg(jsonb_build_object('plan_date', plan_date, 'milk_kg', milk_kg, 'seen_at', farm_seen_at) order by plan_date), '[]')
                 from fabula.milk_plans where status = 'approved' and plan_date between v_today and v_today + 7),
    'pending', (select coalesce(jsonb_agg(jsonb_build_object('plan_date', m.plan_date, 'milk_kg', m.milk_kg, 'decide_by', a.expires_at) order by m.plan_date), '[]')
                  from fabula.milk_plans m left join fabula.approvals a on a.id = m.approval_id
                 where m.status = 'proposed' and m.plan_date between v_today and v_today + 7
                   and (a.expires_at is null or a.expires_at > now())));
end $$;

-- an intake that picks a shipment takes the farm's kg, lot and supplier (the farm's weight is the source of truth),
-- and a shipment can be received only once
create or replace function fabula.milk_intake_shipment_check() returns trigger
language plpgsql security definer set search_path = fabula, public as $$
declare s fabula.milk_shipments;
begin
  if new.shipment_id is null then return new; end if;
  select * into s from fabula.milk_shipments where id = new.shipment_id for update;
  if not found then raise exception 'Spedizione non trovata' using errcode = '23503'; end if;
  if s.status <> 'shipped' and (s.milk_intake_id is distinct from new.id) then
    raise exception 'La spedizione % è già stata %', s.milk_lot, case s.status when 'received' then 'ricevuta' else 'respinta' end using errcode = '23505';
  end if;
  new.qty_kg := s.kg; new.milk_lot := s.milk_lot;
  if s.supplier_id is not null then new.supplier_id := s.supplier_id; end if;
  if coalesce(new.ddt_number, '') = '' then new.ddt_number := s.ddt_number; end if;
  return new;
end $$;
revoke all on function fabula.milk_intake_shipment_check() from public, anon, authenticated;
do $$ begin
  if not exists (select 1 from pg_trigger where tgrelid = 'fabula.milk_intake'::regclass and tgname = 'milk_intake_shipment_check') then
    create trigger milk_intake_shipment_check before insert or update of shipment_id on fabula.milk_intake for each row execute function fabula.milk_intake_shipment_check();
  end if;
end $$;

-- saving the intake at the dairy closes the shipment
create or replace function fabula.milk_intake_shipment_received() returns trigger
language plpgsql security definer set search_path = fabula, public as $$
begin
  if new.shipment_id is not null then
    update fabula.milk_shipments
       set status = case when new.accepted is false then 'rejected' else 'received' end,
           milk_intake_id = new.id, received_at = coalesce(received_at, now()), received_by_id = coalesce(new.received_by_id, received_by_id)
     where id = new.shipment_id and status = 'shipped';
  end if;
  return new;
end $$;
revoke all on function fabula.milk_intake_shipment_received() from public, anon, authenticated;
do $$ begin
  if not exists (select 1 from pg_trigger where tgrelid = 'fabula.milk_intake'::regclass and tgname = 'milk_intake_shipment_received') then
    create trigger milk_intake_shipment_received after insert on fabula.milk_intake for each row execute function fabula.milk_intake_shipment_received();
  end if;
end $$;
