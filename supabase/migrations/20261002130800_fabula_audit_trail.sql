-- v0.35 · Audit trail on settings, approvals and master data.
-- audit_log: one row per insert/update/delete on the watched tables — table, row key, action, changed columns, old/new values,
-- who (staff name from the logged-in user; 'bot/service' for scheduled bots and SQL), when. Written only by the trigger (security definer).
-- Watched: settings, approvals (status/decision changes only), recipes, standing_orders, staff, products, equipment, compliance_deadlines,
-- haccp_control_points, process_steps, supplier_products, supplier_prices, farm_supply, shopify_variant_map, training_courses, rota_entries.
-- v_settings_history = settings rows of the log, old → new value. Configurazione → Registro modifiche shows the log.

create table if not exists fabula.audit_log (
  id           bigserial primary key,
  at           timestamptz not null default now(),
  table_name   text not null,
  row_key      text,
  action       text not null check (action in ('insert','update','delete')),
  changed      text[],
  old_data     jsonb,
  new_data     jsonb,
  actor_staff_id uuid,
  actor        text not null);
create index if not exists audit_log_table_at on fabula.audit_log (table_name, at desc);
create index if not exists audit_log_at on fabula.audit_log (at desc);
alter table fabula.audit_log enable row level security;
do $$ begin if not exists (select 1 from pg_policies where schemaname = 'fabula' and tablename = 'audit_log' and policyname = 'audit_log_read') then
  create policy audit_log_read on fabula.audit_log for select to authenticated using (true); end if; end $$;
grant select on fabula.audit_log to authenticated; grant all on fabula.audit_log to service_role;
grant usage on sequence fabula.audit_log_id_seq to service_role;

create or replace function fabula.trg_audit() returns trigger language plpgsql security definer set search_path = fabula, public as $$
declare o jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) end; n jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) end;
        ch text[]; v_uid uuid := auth.uid(); v_sid uuid; v_actor text; k text;
begin
  if tg_op = 'UPDATE' then
    select array_agg(key order by key) into ch from jsonb_each(n) e
     where key not in ('updated_at','last_synced_at') and (o -> key) is distinct from e.value;
    if ch is null then return new; end if;
    if tg_table_name = 'approvals' and not (ch && array['status','decided_by','decided_at','decision_note','payload','amount_eur']) then return new; end if;
  end if;
  if v_uid is not null then select id, full_name into v_sid, v_actor from fabula.staff where auth_user_id = v_uid; end if;
  v_actor := coalesce(v_actor, case when v_uid is not null then 'utente ' || left(v_uid::text, 8)
                                    else coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role', 'bot/service') end);
  k := coalesce(n, o) ->> 'id'; if k is null then k := coalesce(n, o) ->> 'key'; end if;
  if k is null and tg_table_name = 'supplier_products' then k := (coalesce(n, o) ->> 'supplier_id') || '/' || (coalesce(n, o) ->> 'product_id'); end if;
  insert into fabula.audit_log (table_name, row_key, action, changed, old_data, new_data, actor_staff_id, actor)
  values (tg_table_name, k, lower(tg_op), ch, o, n, v_sid, v_actor);
  return coalesce(new, old);
end $$;

do $$ declare t text; begin
  foreach t in array array['settings','approvals','recipes','standing_orders','staff','products','equipment','compliance_deadlines','haccp_control_points',
                           'process_steps','supplier_products','supplier_prices','farm_supply','shopify_variant_map','training_courses','rota_entries'] loop
    if to_regclass('fabula.' || t) is not null and not exists (select 1 from pg_trigger where tgname = t || '_audit' and tgrelid = ('fabula.' || t)::regclass) then
      execute format('create trigger %I after insert or update or delete on fabula.%I for each row execute function fabula.trg_audit()', t || '_audit', t);
    end if;
  end loop;
end $$;

create or replace view fabula.v_settings_history with (security_invoker = true) as
select a.at, a.row_key as key, a.action, a.old_data ->> 'value' as old_value, a.new_data ->> 'value' as new_value, a.actor,
       coalesce(a.new_data, a.old_data) ->> 'description' as description
from fabula.audit_log a where a.table_name = 'settings'
order by a.at desc;
grant select on fabula.v_settings_history to authenticated, service_role;
