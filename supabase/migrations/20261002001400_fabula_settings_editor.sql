-- =============================================================================
-- v0.14: settings & dates editor on the console.
--   Writes to fabula.settings are allowed only to staff with role owner/partner
--   (equipment, staff and compliance_deadlines already allow authenticated writes;
--   per-role tightening of those is a later RLS pass).
--   fabula.is_manager() helper; settings.updated_at kept current by trigger.
-- Written without destructive keywords (connector rule).
-- =============================================================================
set search_path = fabula, public;

create or replace function fabula.is_manager() returns boolean language sql stable security definer set search_path = fabula, public as $$
  select exists (select 1 from fabula.staff s where s.auth_user_id = auth.uid() and s.active and s.role in ('owner','partner'))
$$;
grant execute on function fabula.is_manager() to authenticated, service_role;

do $$ begin
  if not exists (select 1 from pg_policies where schemaname='fabula' and tablename='settings' and policyname='settings_manager_write') then
    create policy settings_manager_write on fabula.settings for update to authenticated using (fabula.is_manager()) with check (fabula.is_manager());
  end if;
  if not exists (select 1 from pg_policies where schemaname='fabula' and tablename='settings' and policyname='settings_manager_insert') then
    create policy settings_manager_insert on fabula.settings for insert to authenticated with check (fabula.is_manager());
  end if;
end $$;
grant update, insert on fabula.settings to authenticated;

create or replace function fabula.touch_settings() returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;
do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'settings_touch') then
    create trigger settings_touch before update on fabula.settings for each row execute function fabula.touch_settings();
  end if;
end $$;

-- Console reads this: equipment with the computed next dates
create or replace view fabula.v_equipment_schedule as
select e.id, e.code, e.name, e.kind, e.active, e.technician_contact,
       e.calibration_interval_days, e.last_calibrated_on, e.next_calibration_on,
       e.maintenance_interval_days, e.last_maintenance_on,
       case when e.last_maintenance_on is not null and e.maintenance_interval_days is not null then e.last_maintenance_on + e.maintenance_interval_days end as next_maintenance_on
from fabula.equipment e order by e.code;
grant select on fabula.v_equipment_schedule to authenticated, service_role;
