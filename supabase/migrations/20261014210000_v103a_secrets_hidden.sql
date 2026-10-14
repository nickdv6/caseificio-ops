-- v1.03a · Audit 12/10/2026, C-05: secrets are no longer readable by staff (and the same hole in two other places).
--   * The settings milk.farm_token, milk.farm_ship_token (v1.03b) and trade.job_secret are hidden from every login: the API never
--     returns them, cannot change them, and accepts only 32-64 hexadecimal characters. Only the database's own functions read
--     them. The Masseria links are shown and regenerated from Configurazione → Utenti e accessi → «Link della Masseria» (v1.03b).
--   * fabula._setting(key), which any login can call, no longer returns them.
--   * Registro modifiche: their values read «••••», for the old rows too.
--   * trade.job_secret is replaced once, since every login could read it until now (the trade-portal function reads it at
--     every call, so nothing else changes).
--   * Wholesale customers' portal keys (parties.portal_token) were readable by every login, which could then act as that customer
--     in the portal. The column is no longer readable through the API, and only the database can change it; staff with Vendite =
--     gestisce still get the customer's link from Ingrosso, as before.
--   * agent_runs (seen in the v1.02 review): logins read the run log but can no longer write it (only the bots and the database).

-- ============================================================================================================================
-- 1. Which settings are secret
-- ============================================================================================================================
create or replace function fabula.secret_setting(p_key text) returns boolean
language sql immutable set search_path = fabula, public as $$
  select coalesce(p_key in ('milk.farm_token', 'milk.farm_ship_token', 'trade.job_secret'), false)
$$;
grant execute on function fabula.secret_setting(text) to authenticated, anon, service_role;

-- never through the API: not read, not changed, not added, not deleted (the database's own functions and the service role bypass this)
drop policy if exists settings_no_secrets_select on fabula.settings;
drop policy if exists settings_no_secrets_insert on fabula.settings;
drop policy if exists settings_no_secrets_update on fabula.settings;
drop policy if exists settings_no_secrets_delete on fabula.settings;
create policy settings_no_secrets_select on fabula.settings as restrictive for select to authenticated, anon using (not fabula.secret_setting(key));
create policy settings_no_secrets_insert on fabula.settings as restrictive for insert to authenticated, anon with check (not fabula.secret_setting(key));
create policy settings_no_secrets_update on fabula.settings as restrictive for update to authenticated, anon
  using (not fabula.secret_setting(key)) with check (not fabula.secret_setting(key));
create policy settings_no_secrets_delete on fabula.settings as restrictive for delete to authenticated, anon using (not fabula.secret_setting(key));

-- the one definer reader any login can call
create or replace function fabula._setting(p_key text) returns text
language sql stable security definer set search_path = fabula, public as $$
  select nullif(trim(value), '') from fabula.settings where key = p_key and not fabula.secret_setting(p_key) $$;

-- a secret is 32-64 hexadecimal characters (scenario B of C-05: a «memorable» key the farm page refuses), and the two Masseria keys differ
create or replace function fabula.trg_settings_secret_format() returns trigger
language plpgsql set search_path = fabula, public as $$
begin
  new.value := lower(trim(coalesce(new.value, '')));
  if new.value !~ '^[0-9a-f]{32,64}$' then
    raise exception 'La chiave «%» deve essere di 32-64 caratteri esadecimali: per la Masseria usa «Genera nuovo link» in Configurazione → Utenti e accessi', new.key
      using errcode = '22023';
  end if;
  if new.key in ('milk.farm_token', 'milk.farm_ship_token')
     and exists (select 1 from fabula.settings s where s.key in ('milk.farm_token', 'milk.farm_ship_token') and s.key <> new.key and s.value = new.value) then
    raise exception 'Il link della Masseria e il QR delle spedizioni devono avere chiavi diverse' using errcode = '22023';
  end if;
  return new;
end $$;
drop trigger if exists settings_secret_format on fabula.settings;
create trigger settings_secret_format before insert or update of value on fabula.settings
  for each row when (fabula.secret_setting(new.key)) execute function fabula.trg_settings_secret_format();

-- a secret never raises the «Parametro cambiato» notice (it would carry the value)
update fabula.settings set impact_it = null where fabula.secret_setting(key) and impact_it is not null;

-- ============================================================================================================================
-- 2. Registro modifiche: a secret's value is never stored (new rows), and the old rows lose it
-- ============================================================================================================================
create or replace function fabula.trg_audit() returns trigger
language plpgsql security definer set search_path = fabula, public as $function$
declare o jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) end; n jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) end;
        ch text[]; v_uid uuid := auth.uid(); v_sid uuid; v_actor text; k text;
begin
  if tg_op = 'UPDATE' then
    select array_agg(key order by key) into ch from jsonb_each(n) e
     where key not in ('updated_at','last_synced_at') and (o -> key) is distinct from e.value;
    if ch is null then return new; end if;
    if tg_table_name = 'approvals' and not (ch && array['status','decided_by','decided_at','decision_note','payload','amount_eur']) then return new; end if;
  end if;
  -- v1.03a (audit C-05): a secret setting is recorded as changed, never with its value; a customer's portal key the same
  if tg_table_name = 'settings' and fabula.secret_setting(coalesce(n, o) ->> 'key') then
    if o ? 'value' then o := jsonb_set(o, '{value}', '"••••"'); end if;
    if n ? 'value' then n := jsonb_set(n, '{value}', '"••••"'); end if;
  end if;
  if tg_table_name = 'parties' then
    if o ? 'portal_token' and o ->> 'portal_token' is not null then o := jsonb_set(o, '{portal_token}', '"••••"'); end if;
    if n ? 'portal_token' and n ->> 'portal_token' is not null then n := jsonb_set(n, '{portal_token}', '"••••"'); end if;
  end if;
  if v_uid is not null then select id, full_name into v_sid, v_actor from fabula.staff where auth_user_id = v_uid; end if;
  v_actor := coalesce(v_actor, case when v_uid is not null then 'utente ' || left(v_uid::text, 8)
                                    else coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role', 'bot/service') end);
  k := coalesce(n, o) ->> 'id'; if k is null then k := coalesce(n, o) ->> 'key'; end if;
  if k is null and tg_table_name = 'supplier_products' then k := (coalesce(n, o) ->> 'supplier_id') || '/' || (coalesce(n, o) ->> 'product_id'); end if;
  insert into fabula.audit_log (table_name, row_key, action, changed, old_data, new_data, actor_staff_id, actor)
  values (tg_table_name, k, lower(tg_op), ch, o, n, v_sid, v_actor);
  return coalesce(new, old);
end $function$;

update fabula.audit_log
   set old_data = case when old_data ? 'value' then jsonb_set(old_data, '{value}', '"••••"') else old_data end,
       new_data = case when new_data ? 'value' then jsonb_set(new_data, '{value}', '"••••"') else new_data end
 where table_name = 'settings' and fabula.secret_setting(row_key)
   and (coalesce(old_data ->> 'value', '••••') <> '••••' or coalesce(new_data ->> 'value', '••••') <> '••••');
update fabula.audit_log
   set old_data = case when old_data ->> 'portal_token' is not null then jsonb_set(old_data, '{portal_token}', '"••••"') else old_data end,
       new_data = case when new_data ->> 'portal_token' is not null then jsonb_set(new_data, '{portal_token}', '"••••"') else new_data end
 where table_name = 'parties'
   and (coalesce(old_data ->> 'portal_token', '••••') <> '••••' or coalesce(new_data ->> 'portal_token', '••••') <> '••••');

-- every login could read it until now: a new one (the trade-portal function reads the setting at every call)
update fabula.settings set value = encode(extensions.gen_random_bytes(16), 'hex') where key = 'trade.job_secret';

-- ============================================================================================================================
-- 3. Wholesale customers' portal keys: not readable through the API, changed only by the database
-- ============================================================================================================================
-- Logins keep reading every other column (named one by one: a column added to parties later must be granted the same way,
-- `grant select (new_column) on fabula.parties to authenticated`; test_v103_security.sql checks it on every CI run).
do $mig$
declare cols text;
begin
  select string_agg(quote_ident(column_name), ', ' order by ordinal_position) into cols
    from information_schema.columns where table_schema = 'fabula' and table_name = 'parties' and column_name <> 'portal_token';
  execute 'revoke select on fabula.parties from authenticated, anon';
  execute format('grant select (%s) on fabula.parties to authenticated', cols);
end $mig$;

create or replace function fabula.trg_parties_portal_token_guard() returns trigger
language plpgsql set search_path = fabula, public as $$
begin
  -- the database's own functions (Ingrosso «Nuovo link», approval) run as their owner; a login through the API cannot set the key
  if current_user in ('authenticated', 'anon')
     and ((tg_op = 'INSERT' and new.portal_token is not null) or (tg_op = 'UPDATE' and new.portal_token is distinct from old.portal_token)) then
    raise exception 'Il link del portale si cambia solo da Ingrosso → scheda del cliente → «Nuovo link»' using errcode = '42501';
  end if;
  return new;
end $$;
drop trigger if exists parties_portal_token_guard on fabula.parties;
create trigger parties_portal_token_guard before insert or update of portal_token on fabula.parties
  for each row execute function fabula.trg_parties_portal_token_guard();

-- ============================================================================================================================
-- 4. agent_runs: read by logins, written only by the bots (database role) and the database's own functions
-- ============================================================================================================================
drop policy if exists agent_runs_authenticated_all on fabula.agent_runs;
drop policy if exists agent_runs_read on fabula.agent_runs;
create policy agent_runs_read on fabula.agent_runs for select to authenticated using (true);
revoke insert, update, delete, truncate on fabula.agent_runs from authenticated, anon;
