-- v0.37 · Default access roles + row-level security per role.
-- Model: app_roles (profiles) × app_areas (10 areas) → role_permissions.level 0 nessuno · 1 vede · 2 registra · 3 gestisce (configura e approva).
-- Every fabula table is mapped to an area in table_areas (with the level needed to write it: 2 for day-to-day records, 3 for configuration).
-- staff.app_role picks the profile (default from the job role); staff.email lets a new login claim its staff row (claim_staff_profile()).
-- RLS: the existing permissive "authenticated_all" policies stay; RESTRICTIVE policies are added on top, so a row is visible/writable only
-- when the caller's profile reaches the area level (select ≥ 1, write ≥ table write_level). Bots use service_role and are not affected.
-- Approvals: visible with level ≥ 1 and decidable with level 3 in the area of the request (PO → acquisti, milk plan → produzione, …).
-- Cross-area floor RPCs (badge, goods receipt, packing, stock count, PO sent) become SECURITY DEFINER with an explicit permission check.
-- All fabula views switch to security_invoker so they respect the caller's RLS.
-- my_permissions() → what the apps show; is_manager() now = sistema level 3.

-- 1 · catalog ---------------------------------------------------------------------------------------------
create table if not exists fabula.app_areas (code text primary key, name_it text not null, description_it text, sort int not null default 100);
create table if not exists fabula.app_roles (
  code text primary key, name_it text not null, description_it text, home text not null default 'console',
  can_manage_users boolean not null default false, sort int not null default 100, is_system boolean not null default true);
create table if not exists fabula.role_permissions (
  role_code text not null references fabula.app_roles(code) on update cascade,
  area text not null references fabula.app_areas(code),
  level smallint not null check (level between 0 and 3),
  primary key (role_code, area));
create table if not exists fabula.table_areas (
  table_name text primary key, area text not null references fabula.app_areas(code),
  write_level smallint not null default 2 check (write_level between 1 and 3),
  read_open boolean not null default false);
alter table fabula.staff add column if not exists app_role text references fabula.app_roles(code);
alter table fabula.staff add column if not exists email text;
create unique index if not exists staff_email_uq on fabula.staff (lower(email)) where email is not null;

insert into fabula.app_areas (code, name_it, description_it, sort) values
  ('produzione', 'Produzione', 'Latte in arrivo, caldaie, ricette e impostazioni di processo, piano latte, etichette, scarti, reflui, contatori', 10),
  ('haccp', 'HACCP e qualità', 'Controlli CCP, non conformità, blocchi lotto, analisi, infestanti, tarature, macchine, scadenze, formazione', 20),
  ('magazzino', 'Magazzino', 'Movimenti, giacenze, inventari, arrivo merce, anagrafica prodotti', 30),
  ('acquisti', 'Acquisti', 'Ordini fornitori, listini, condizioni fornitori', 40),
  ('vendite', 'Vendite', 'Ordini clienti, ingrosso, ordini fissi, clienti, mappa Shopify, chiusure cassa', 50),
  ('spedizioni', 'Spedizioni', 'Preparazione ordini, DDT, spedizioni e tracking', 60),
  ('marketing', 'Marketing', 'Calendario contenuti, campagne, canali, creator, campagna locale, foto e video', 70),
  ('finanza', 'Amministrazione', 'Fatture, banca, piano dei conti, pacchetto mensile', 80),
  ('personale', 'Personale', 'Anagrafica persone, turni, timbrature, ore e straordinari', 90),
  ('sistema', 'Sistema', 'Parametri, bot, registro modifiche, utenti e ruoli', 100),
  ('comune', 'Comune', 'Scansioni, attività del giorno, avvisi, documenti: tutti gli utenti attivi', 0)
on conflict (code) do nothing;

insert into fabula.app_roles (code, name_it, description_it, home, can_manage_users, sort) values
  ('titolare', 'Titolare', 'Tutto, compresi utenti e ruoli', 'console', true, 10),
  ('socio', 'Socio', 'Tutto tranne la gestione di utenti e ruoli', 'console', false, 20),
  ('resp_produzione', 'Responsabile produzione', 'Casaro / capo produzione: produzione e HACCP completi, approva piano latte e ricette', 'tablet', false, 30),
  ('produzione', 'Produzione', 'Operaio: registra latte, caldaie, controlli, magazzino, preparazione ordini dal tablet', 'tablet', false, 40),
  ('qualita', 'Qualità / HACCP', 'Responsabile autocontrollo: HACCP completo, vede produzione e magazzino', 'haccp', false, 50),
  ('spedizioni', 'Spedizioni', 'Prepara e spedisce ordini web e ingrosso, DDT, tracking', 'tablet', false, 60),
  ('banco', 'Banco', 'Vendita al banco: controlli HACCP del banco, ritiri, vede giacenze e ordini', 'tablet', false, 70),
  ('marketing', 'Marketing', 'Modulo marketing completo; vede vendite, giacenze e produzione', 'marketing', false, 80),
  ('amministrazione', 'Amministrazione', 'Contabilità e pagamenti: amministrazione completa, approva ordini fornitori, ore e straordinari', 'console', false, 90),
  ('consulente', 'Consulente esterno', 'Sola lettura (commercialista, consulente HACCP)', 'console', false, 100)
on conflict (code) do nothing;

-- level matrix: produzione, haccp, magazzino, acquisti, vendite, spedizioni, marketing, finanza, personale, sistema
insert into fabula.role_permissions (role_code, area, level)
select r.code, a.area, a.lvl from (values
  ('titolare',        array[3,3,3,3,3,3,3,3,3,3]),
  ('socio',           array[3,3,3,3,3,3,3,3,3,3]),
  ('resp_produzione', array[3,3,2,1,1,1,0,0,1,0]),
  ('produzione',      array[2,2,2,1,1,2,0,0,0,0]),
  ('qualita',         array[2,3,1,1,1,1,1,0,1,0]),
  ('spedizioni',      array[1,2,2,1,2,3,0,0,0,0]),
  ('banco',           array[1,2,1,0,1,2,1,0,0,0]),
  ('marketing',       array[1,0,1,0,1,0,3,0,0,0]),
  ('amministrazione', array[1,1,1,3,2,1,1,3,2,1]),
  ('consulente',      array[1,1,1,1,1,0,0,1,0,0])) r(code, lv)
cross join lateral (select unnest(array['produzione','haccp','magazzino','acquisti','vendite','spedizioni','marketing','finanza','personale','sistema']) area,
                           unnest(r.lv) lvl) a
on conflict (role_code, area) do nothing;

-- table → area (write_level 3 = configuration)
insert into fabula.table_areas (table_name, area, write_level, read_open) values
  ('milk_intake','produzione',2,false), ('batch_milk_inputs','produzione',2,false), ('production_batches','produzione',2,false),
  ('batch_consumables','produzione',2,false), ('batch_step_logs','produzione',2,false), ('labels','produzione',2,false),
  ('waste_log','produzione',2,false), ('effluent_log','produzione',2,false), ('meter_readings','produzione',2,false),
  ('milk_plans','produzione',3,false), ('farm_supply','produzione',3,false), ('recipes','produzione',3,false),
  ('process_presets','produzione',3,false), ('process_steps','produzione',3,false),
  ('haccp_log','haccp',2,false), ('non_conformities','haccp',2,false), ('lab_samples','haccp',2,false), ('lab_tests','haccp',2,false),
  ('pest_inspections','haccp',2,false), ('calibration_checks','haccp',2,false), ('recalls','haccp',2,false), ('recall_drills','haccp',2,false),
  ('sensor_readings','haccp',2,false), ('training_records','haccp',2,false),
  ('haccp_control_points','haccp',3,true), ('pest_stations','haccp',3,false), ('sops','haccp',3,true), ('sop_steps','haccp',3,true),
  ('compliance_deadlines','haccp',3,false), ('equipment','haccp',3,true), ('training_courses','haccp',3,true),
  ('stock_moves','magazzino',2,false), ('stock_counts','magazzino',2,false), ('stock_count_lines','magazzino',2,false),
  ('goods_receipts','magazzino',2,false), ('goods_receipt_lines','magazzino',2,false), ('products','magazzino',3,true),
  ('purchase_orders','acquisti',2,false), ('purchase_order_lines','acquisti',2,false), ('supplier_prices','acquisti',3,false),
  ('supplier_products','acquisti',3,false),
  ('sales_orders','vendite',2,false), ('sales_order_lines','vendite',2,false), ('pos_daily_closings','vendite',2,false),
  ('shopify_unmapped_lines','vendite',2,false), ('standing_orders','vendite',3,false), ('shopify_variant_map','vendite',3,false),
  ('parties','vendite',3,true),
  ('shipments','spedizioni',2,false), ('shipment_lines','spedizioni',2,false),
  ('mkt_ai_jobs','marketing',2,false), ('mkt_assets','marketing',2,false), ('mkt_campaigns','marketing',2,false), ('mkt_channels','marketing',3,false),
  ('mkt_claim_rules','marketing',3,false), ('mkt_collabs','marketing',2,false), ('mkt_content','marketing',2,false), ('mkt_influencers','marketing',2,false),
  ('mkt_local_items','marketing',2,false),
  ('invoices','finanza',2,false), ('invoice_lines','finanza',2,false), ('bank_transactions','finanza',2,false), ('chart_of_accounts','finanza',3,false),
  ('staff','personale',3,true), ('shifts','personale',2,false), ('rota_entries','personale',2,false),
  ('settings','sistema',3,true), ('agent_runs','sistema',2,false), ('audit_log','sistema',3,false), ('bot_schedule','sistema',3,true),
  ('bot_alerts','sistema',3,false), ('simulation_runs','sistema',3,false), ('notices','comune',2,true),
  ('scan_events','comune',2,false), ('task_instances','comune',2,false), ('task_schedules','comune',3,true), ('documents','comune',2,false),
  ('app_areas','sistema',3,true), ('app_roles','sistema',3,true), ('role_permissions','sistema',3,true), ('table_areas','sistema',3,true)
on conflict (table_name) do nothing;

-- default profile from the job role, for existing people
update fabula.staff set app_role = case role::text when 'owner' then 'titolare' when 'partner' then 'socio' when 'casaro' then 'resp_produzione'
  when 'operaio' then 'produzione' when 'commesso' then 'banco' when 'consulente' then 'consulente' else 'produzione' end
where app_role is null;
update fabula.staff s set email = u.email from auth.users u where u.id = s.auth_user_id and s.email is null;

create or replace function fabula.trg_staff_default_role() returns trigger language plpgsql as $$
begin
  if new.app_role is null then
    new.app_role := case new.role::text when 'owner' then 'titolare' when 'partner' then 'socio' when 'casaro' then 'resp_produzione'
      when 'operaio' then 'produzione' when 'commesso' then 'banco' when 'consulente' then 'consulente' else 'produzione' end;
  end if;
  new.email := nullif(lower(trim(new.email)), '');
  return new;
end $$;
do $$ begin if not exists (select 1 from pg_trigger where tgname = 'staff_default_role') then
  create trigger staff_default_role before insert or update of role, app_role, email on fabula.staff for each row execute function fabula.trg_staff_default_role(); end if; end $$;

-- 2 · permission functions ----------------------------------------------------------------------------------
create or replace function fabula.my_staff_id() returns uuid language sql stable security definer set search_path = fabula, public as $$
  select id from fabula.staff where auth_user_id = auth.uid() and active limit 1
$$;
create or replace function fabula.perm_level(p_area text) returns int language sql stable security definer set search_path = fabula, public as $$
  select case
    when auth.uid() is null then 3   -- service role / SQL editor / bots
    when p_area = 'comune' then (select case when exists (select 1 from fabula.staff where auth_user_id = auth.uid() and active) then 2 else 0 end)
    else coalesce((select rp.level from fabula.staff s join fabula.role_permissions rp on rp.role_code = s.app_role and rp.area = p_area
                   where s.auth_user_id = auth.uid() and s.active limit 1), 0) end
$$;
create or replace function fabula.can(p_area text, p_level int default 1) returns boolean language sql stable security definer set search_path = fabula, public as $$
  select fabula.perm_level(p_area) >= p_level
$$;
create or replace function fabula.can_table(p_table text, p_write boolean default false) returns boolean language sql stable security definer set search_path = fabula, public as $$
  select case when auth.uid() is null then true
    else coalesce((select case when p_write then fabula.perm_level(t.area) >= t.write_level
                               else t.read_open and fabula.perm_level('comune') > 0 or fabula.perm_level(t.area) >= 1 end
                   from fabula.table_areas t where t.table_name = p_table), fabula.perm_level('sistema') >= 3) end
$$;
create or replace function fabula.require_perm(p_area text, p_level int default 2) returns void language plpgsql stable security definer set search_path = fabula, public as $$
begin
  if not fabula.can(p_area, p_level) then
    raise exception 'Permesso negato: serve il livello % in "%"', p_level, (select name_it from fabula.app_areas where code = p_area) using errcode = '42501';
  end if;
end $$;
create or replace function fabula.approval_area(p_kind fabula.approval_kind, p_payload jsonb) returns text language sql immutable as $$
  select case p_kind::text
    when 'purchase_order' then 'acquisti' when 'payment' then 'finanza' when 'invoice_coding' then 'finanza'
    when 'price_change' then 'vendite' when 'shopify_publish' then 'marketing' when 'outreach_email' then 'marketing'
    when 'dop_declaration' then 'haccp'
    else case when p_payload->>'type' in ('milk_plan','recipe_update','process_preset') then 'produzione'
              when p_payload->>'type' ~ '^(content|mkt|local|campaign|post)' then 'marketing'
              when p_payload->>'type' ~ '^(invoice|payment|bank)' then 'finanza'
              when p_payload->>'type' ~ '^(haccp|lot|recall|nc)' then 'haccp'
              else 'sistema' end end
$$;
create or replace function fabula.is_manager() returns boolean language sql stable security definer set search_path = fabula, public as $$
  select auth.uid() is not null and fabula.perm_level('sistema') >= 3
$$;
create or replace function fabula.my_permissions() returns jsonb language sql stable security definer set search_path = fabula, public as $$
  select case when s.id is null then jsonb_build_object('staff_id', null, 'active', false, 'areas', '{}'::jsonb, 'pages', '{}'::jsonb)
  else jsonb_build_object(
    'staff_id', s.id, 'full_name', s.full_name, 'job_role', s.role, 'role', r.code, 'role_name', r.name_it, 'home', r.home, 'active', s.active,
    'can_manage_users', r.can_manage_users,
    'areas', (select jsonb_object_agg(a.code, coalesce(rp.level, case when a.code = 'comune' then 2 else 0 end)) from fabula.app_areas a
              left join fabula.role_permissions rp on rp.role_code = r.code and rp.area = a.code),
    'pages', jsonb_build_object(
       'tablet',   exists (select 1 from fabula.role_permissions where role_code = r.code and area in ('produzione','haccp','magazzino','spedizioni') and level >= 2),
       'console',  exists (select 1 from fabula.role_permissions where role_code = r.code and area in ('produzione','acquisti','vendite','magazzino','personale','finanza') and level >= 1),
       'haccp',    exists (select 1 from fabula.role_permissions where role_code = r.code and area = 'haccp' and level >= 1),
       'marketing',exists (select 1 from fabula.role_permissions where role_code = r.code and area = 'marketing' and level >= 1),
       'pacchetto',exists (select 1 from fabula.role_permissions where role_code = r.code and area = 'finanza' and level >= 1),
       'admin',    exists (select 1 from fabula.role_permissions where role_code = r.code and area = 'sistema' and level >= 1)))
  end
  from (select 1) x left join fabula.staff s on s.auth_user_id = auth.uid() and s.active left join fabula.app_roles r on r.code = s.app_role
$$;
create or replace function fabula.claim_staff_profile() returns jsonb language plpgsql security definer set search_path = fabula, public as $$
declare v_email text := lower(auth.jwt() ->> 'email'); v_id uuid;
begin
  if auth.uid() is null then return jsonb_build_object('ok', false, 'reason', 'not_logged_in'); end if;
  if exists (select 1 from fabula.staff where auth_user_id = auth.uid()) then return jsonb_build_object('ok', true, 'reason', 'already_linked'); end if;
  update fabula.staff set auth_user_id = auth.uid() where lower(email) = v_email and auth_user_id is null and active returning id into v_id;
  return jsonb_build_object('ok', v_id is not null, 'staff_id', v_id, 'reason', case when v_id is null then 'no_staff_row_for_email' end);
end $$;
grant execute on function fabula.my_staff_id(), fabula.perm_level(text), fabula.can(text, int), fabula.can_table(text, boolean), fabula.require_perm(text, int),
  fabula.approval_area(fabula.approval_kind, jsonb), fabula.is_manager(), fabula.my_permissions(), fabula.claim_staff_profile() to authenticated, service_role;
grant select on fabula.app_areas, fabula.app_roles, fabula.role_permissions, fabula.table_areas to authenticated;
grant all on fabula.app_areas, fabula.app_roles, fabula.role_permissions, fabula.table_areas to service_role;
grant insert, update on fabula.app_roles, fabula.role_permissions to authenticated;

-- 3 · RLS -----------------------------------------------------------------------------------------------------
-- catalog tables: readable by everyone logged in; roles and matrix editable only by a profile that manages users
do $$ declare t text; begin
  foreach t in array array['app_areas','app_roles','role_permissions','table_areas'] loop
    execute format('alter table fabula.%I enable row level security', t);
    if not exists (select 1 from pg_policies where schemaname = 'fabula' and tablename = t and policyname = t || '_read') then
      execute format('create policy %I on fabula.%I for select to authenticated using (true)', t || '_read', t); end if;
  end loop;
  if not exists (select 1 from pg_policies where schemaname = 'fabula' and tablename = 'app_roles' and policyname = 'app_roles_admin_write') then
    create policy app_roles_admin_write on fabula.app_roles for all to authenticated
      using (exists (select 1 from fabula.staff s join fabula.app_roles r on r.code = s.app_role where s.auth_user_id = auth.uid() and s.active and r.can_manage_users))
      with check (exists (select 1 from fabula.staff s join fabula.app_roles r on r.code = s.app_role where s.auth_user_id = auth.uid() and s.active and r.can_manage_users)); end if;
  if not exists (select 1 from pg_policies where schemaname = 'fabula' and tablename = 'role_permissions' and policyname = 'role_permissions_admin_write') then
    create policy role_permissions_admin_write on fabula.role_permissions for all to authenticated
      using (exists (select 1 from fabula.staff s join fabula.app_roles r on r.code = s.app_role where s.auth_user_id = auth.uid() and s.active and r.can_manage_users))
      with check (exists (select 1 from fabula.staff s join fabula.app_roles r on r.code = s.app_role where s.auth_user_id = auth.uid() and s.active and r.can_manage_users)); end if;
end $$;

-- restrictive layer on every mapped table (approvals handled below)
do $$ declare t record; begin
  for t in select ta.table_name from fabula.table_areas ta where to_regclass('fabula.' || ta.table_name) is not null
             and ta.table_name not in ('app_areas','app_roles','role_permissions','table_areas') loop
    execute format('alter table fabula.%I enable row level security', t.table_name);
    if not exists (select 1 from pg_policies where schemaname = 'fabula' and tablename = t.table_name and policyname = t.table_name || '_role_select') then
      execute format('create policy %I on fabula.%I as restrictive for select to authenticated using ((select fabula.can_table(%L, false)))', t.table_name || '_role_select', t.table_name, t.table_name);
      execute format('create policy %I on fabula.%I as restrictive for insert to authenticated with check ((select fabula.can_table(%L, true)))', t.table_name || '_role_insert', t.table_name, t.table_name);
      execute format('create policy %I on fabula.%I as restrictive for update to authenticated using ((select fabula.can_table(%L, true)))', t.table_name || '_role_update', t.table_name, t.table_name);
      execute format('create policy %I on fabula.%I as restrictive for delete to authenticated using ((select fabula.can_table(%L, true)))', t.table_name || '_role_delete', t.table_name, t.table_name);
    end if;
  end loop;
end $$;
-- staff: role, profile and email changes only by a user manager (others with personale 3 can still edit names, certificates, contract hours)
create or replace function fabula.trg_staff_guard() returns trigger language plpgsql security definer set search_path = fabula, public as $$
begin
  if auth.uid() is not null and (new.app_role is distinct from old.app_role or new.email is distinct from old.email or new.auth_user_id is distinct from old.auth_user_id
                                 or new.active is distinct from old.active)
     and not exists (select 1 from fabula.staff s join fabula.app_roles r on r.code = s.app_role where s.auth_user_id = auth.uid() and s.active and r.can_manage_users) then
    raise exception 'Solo chi gestisce utenti e ruoli può cambiare profilo, email o attivazione' using errcode = '42501';
  end if;
  return new;
end $$;
do $$ begin if not exists (select 1 from pg_trigger where tgname = 'staff_guard') then
  create trigger staff_guard before update on fabula.staff for each row execute function fabula.trg_staff_guard(); end if; end $$;

-- approvals: see with level 1 in the request's area, decide with level 3
alter table fabula.approvals enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'fabula' and tablename = 'approvals' and policyname = 'approvals_role_select') then
    create policy approvals_role_select on fabula.approvals as restrictive for select to authenticated using (fabula.can(fabula.approval_area(kind, payload), 1));
    create policy approvals_role_update on fabula.approvals as restrictive for update to authenticated using (fabula.can(fabula.approval_area(kind, payload), 3));
    create policy approvals_role_insert on fabula.approvals as restrictive for insert to authenticated with check (fabula.can(fabula.approval_area(kind, payload), 2));
    create policy approvals_role_delete on fabula.approvals as restrictive for delete to authenticated using (fabula.can('sistema', 3));
  end if; end $$;

-- 4 · views respect the caller --------------------------------------------------------------------------------
do $$ declare v text; begin
  for v in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'fabula' and c.relkind = 'v' loop
    execute format('alter view fabula.%I set (security_invoker = true)', v);
  end loop; end $$;

-- 5 · floor RPCs that cross areas: definer + explicit check -----------------------------------------------------
do $$ declare f record; d text; begin
  for f in select * from (values
      ('fabula.toggle_shift(text, uuid)', 'comune'), ('fabula.receive_purchase_order(text, jsonb, uuid, text, text)', 'magazzino'),
      ('fabula.pack_order(uuid, jsonb, uuid, numeric, text, text, text, boolean)', 'spedizioni'),
      ('fabula.post_stock_count(uuid, jsonb, uuid, text)', 'magazzino'), ('fabula.start_stock_count(uuid)', 'magazzino'),
      ('fabula.mark_po_sent(text, text)', 'acquisti')) x(sig, area) loop
    d := pg_get_functiondef(f.sig::regprocedure);
    if position('require_perm' in d) = 0 then
      d := regexp_replace(d, E'\nbegin\n', format(E'\nbegin\n  perform fabula.require_perm(%L, 2);\n', f.area));
      execute d;
    end if;
    execute format('alter function %s security definer set search_path = fabula, public', f.sig);
  end loop; end $$;

-- 6 · hardening (security advisor): "no logged-in user" means full access only for service_role / SQL, never for anon;
--     anon cannot execute any fabula function at all.
create or replace function fabula.perm_level(p_area text) returns int language sql stable security definer set search_path = fabula, public as $$
  select case
    when auth.uid() is null and coalesce(auth.role(), '') <> 'anon' then 3   -- service role / SQL editor / bots
    when auth.uid() is null then 0
    when p_area = 'comune' then (select case when exists (select 1 from fabula.staff where auth_user_id = auth.uid() and active) then 2 else 0 end)
    else coalesce((select rp.level from fabula.staff s join fabula.role_permissions rp on rp.role_code = s.app_role and rp.area = p_area
                   where s.auth_user_id = auth.uid() and s.active limit 1), 0) end
$$;
create or replace function fabula.can_table(p_table text, p_write boolean default false) returns boolean language sql stable security definer set search_path = fabula, public as $$
  select case when auth.uid() is null then coalesce(auth.role(), '') <> 'anon'
    else coalesce((select case when p_write then fabula.perm_level(t.area) >= t.write_level
                               else t.read_open and fabula.perm_level('comune') > 0 or fabula.perm_level(t.area) >= 1 end
                   from fabula.table_areas t where t.table_name = p_table), fabula.perm_level('sistema') >= 3) end
$$;
revoke execute on all functions in schema fabula from public, anon;
grant execute on all functions in schema fabula to authenticated, service_role;
alter default privileges in schema fabula revoke execute on functions from public, anon;
alter default privileges in schema fabula grant execute on functions to authenticated, service_role;
revoke execute on function fabula.bot_watchdog(timestamptz), fabula.trg_audit(), fabula.trg_staff_guard(), fabula._ensure_supplier_product() from authenticated;
