-- v0.45 · Fix "infinite recursion detected in policy for relation app_roles".
-- app_roles_admin_write (FOR ALL, so also applied on SELECT) queried app_roles inside its own policy, and role_permissions_admin_write
-- joined app_roles too: every read of the profiles/permission matrix by a logged-in user failed, the Profilo dropdowns came up empty
-- and Salva sent app_role = '' → staff_app_role_fkey. The check now lives in a SECURITY DEFINER function (bypasses RLS, no recursion).
create or replace function fabula.can_manage_users() returns boolean language sql stable security definer set search_path = fabula, public as $$
  select exists (select 1 from fabula.staff s join fabula.app_roles r on r.code = s.app_role
                 where s.auth_user_id = auth.uid() and s.active and r.can_manage_users)
$$;
revoke execute on function fabula.can_manage_users() from public, anon;
grant execute on function fabula.can_manage_users() to authenticated, service_role;

drop policy if exists app_roles_admin_write on fabula.app_roles;
create policy app_roles_admin_write on fabula.app_roles for all to authenticated
  using ((select fabula.can_manage_users())) with check ((select fabula.can_manage_users()));
drop policy if exists role_permissions_admin_write on fabula.role_permissions;
create policy role_permissions_admin_write on fabula.role_permissions for all to authenticated
  using ((select fabula.can_manage_users())) with check ((select fabula.can_manage_users()));

-- belt and braces: an empty profile from a client is treated as "no choice" (default from job role), never as a code
create or replace function fabula.trg_staff_default_role() returns trigger language plpgsql as $$
begin
  new.app_role := nullif(trim(new.app_role), '');
  if new.app_role is null then
    new.app_role := case new.role::text when 'owner' then 'titolare' when 'partner' then 'socio' when 'casaro' then 'resp_produzione'
      when 'operaio' then 'produzione' when 'commesso' then 'banco' when 'consulente' then 'consulente' else 'produzione' end;
  end if;
  new.email := nullif(lower(trim(new.email)), '');
  return new;
end $$;
