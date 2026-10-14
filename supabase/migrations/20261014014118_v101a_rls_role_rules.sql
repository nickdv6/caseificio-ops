-- v1.01a (14/10/2026) · RLS: a delete hole on five tables, the dashboard's 102 «RLS Policy Always True» warnings, and a scan check
-- for tables whose role rule is missing.
--
-- Background. Every app table has a base rule «any signed-in user» (permissive) plus RESTRICTIVE role rules
-- `<t>_role_select/insert/update/delete` (v0.37). Postgres needs both, so the role matrix decides. The Supabase dashboard runs
-- lint 0024 «RLS Policy Always True», which flags the base rules written as `true`; the advisor API used by the nightly
-- «Controllo sistema» bot does not return that lint, so the bot never saw it, and our own scan did not check that every
-- base rule has a role rule behind it.
--
-- 1. HOLE (fixed): bank_rules, milk_shipments, payment_payouts, payment_transactions and recon_acks were created (v0.65, v0.82)
--    with role rules for select, insert and update but none for delete. Any signed-in login (floor tablet, banco, marketing)
--    could delete their rows through the API. Nothing in the app or the database deletes from them. Added `<t>_role_delete`
--    like every other table.
-- 2. The 102 base rules written as `true` (the `*_authenticated_all` rules and a few `*_insert` / `*_update`) now read
--    `(select auth.uid()) is not null`. Same meaning for the authenticated role: every app login has a user id, and the role
--    rules still decide. UPDATE rules get the same WITH CHECK written out (lint 0024 also flags a missing WITH CHECK).
--    The 18 read rules written `using (true)` are not flagged by the dashboard and stay as they are.
-- 3. fabula.security_findings() gets two checks (CI and the hourly board run it):
--    - permissive_rls_policy (WARN): mirror of lint 0024 — a permissive insert/update/delete/all rule that is always true,
--      or an insert/update rule without WITH CHECK;
--    - rls_open_without_role_rule (ERROR for writes, WARN for reads): a rule lets any signed-in user do X on a table and no
--      RESTRICTIVE rule covers X. This is the check that would have caught (1).
--    Accepted with a reason: the four permission tables every page reads (perm.js / my_permissions) and record_corrections
--    (v0.96 D-02 correction trail, readable like the registers).
--    fabula.infra_record_advisors() compares permissive_rls_policy counts once the advisor API starts returning that lint.
--
-- New tables from now on: base rule
--   create policy <t>_authenticated_all on fabula.<t> for all to authenticated
--     using ((select auth.uid()) is not null) with check ((select auth.uid()) is not null);
-- plus the four `<t>_role_*` RESTRICTIVE rules. A `using (true)` write rule, or a missing role rule, fails CI.

-- ---------------------------------------------------------------- 1. the missing delete rules
do $$
declare t text;
begin
  foreach t in array array['bank_rules', 'milk_shipments', 'payment_payouts', 'payment_transactions', 'recon_acks'] loop
    if to_regclass('fabula.' || t) is not null
       and not exists (select 1 from pg_policy where polrelid = ('fabula.' || t)::regclass and polname = t || '_role_delete') then
      execute format('create policy %I on fabula.%I as restrictive for delete to authenticated using ((select fabula.can_table(%L, true)))',
                     t || '_role_delete', t, t);
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------- 2. base rules: `true` → signed in
do $$
declare
  r record;
  v_open constant text := '(select auth.uid()) is not null';
  v_n int := 0;
  v_left int;
begin
  for r in
    select n.nspname, c.relname, p.polname, p.polcmd,
           pg_get_expr(p.polqual, p.polrelid) as q, pg_get_expr(p.polwithcheck, p.polrelid) as wc
      from pg_policy p
      join pg_class c on c.oid = p.polrelid
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname in ('fabula', 'public')
       and p.polpermissive
       and p.polcmd <> 'r'
       and p.polroles = array['authenticated'::regrole::oid]
       and (pg_get_expr(p.polqual, p.polrelid) = 'true' or pg_get_expr(p.polwithcheck, p.polrelid) = 'true')
     order by 1, 2, 3
  loop
    if r.polcmd = 'a' then
      execute format('alter policy %I on %I.%I with check (%s)', r.polname, r.nspname, r.relname, v_open);
    elsif r.polcmd = 'd' then
      execute format('alter policy %I on %I.%I using (%s)', r.polname, r.nspname, r.relname, v_open);
    else -- 'w' update, '*' all: rewrite the `true` side(s); a missing WITH CHECK follows USING
      execute format('alter policy %I on %I.%I using (%s) with check (%s)', r.polname, r.nspname, r.relname,
                     case when r.q = 'true' then v_open else r.q end,
                     case when r.wc = 'true' or (r.wc is null and r.q = 'true') then v_open else coalesce(r.wc, r.q) end);
    end if;
    v_n := v_n + 1;
  end loop;

  select count(*) into v_left
    from pg_policy p join pg_class c on c.oid = p.polrelid join pg_namespace n on n.oid = c.relnamespace
   where n.nspname in ('fabula', 'public') and p.polpermissive and p.polcmd <> 'r'
     and (pg_get_expr(p.polqual, p.polrelid) = 'true' or pg_get_expr(p.polwithcheck, p.polrelid) = 'true');
  if v_left > 0 then
    raise exception 'v101a: % write rules still read `true` (not for authenticated only?) — check them by hand', v_left;
  end if;
  raise notice 'v101a: % base rules rewritten', v_n;
end $$;

-- ---------------------------------------------------------------- 3. scan: the two RLS checks
create or replace function fabula.security_findings()
 returns table(key text, lint text, level text, object text)
 language sql
 stable
 security definer
 set search_path = fabula, public, extensions
as $$
  with sch as (select oid, nspname from pg_namespace where nspname in ('fabula', 'public')),
  ext as (select objid from pg_depend where deptype = 'e'),
  f as (select p.oid, s.nspname || '.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' as obj, p.prosecdef, p.proconfig
          from pg_proc p join sch s on s.oid = p.pronamespace
         where p.prokind in ('f', 'p') and p.oid not in (select objid from ext)),
  r as (select c.oid, s.nspname || '.' || c.relname as obj, c.relkind, c.relrowsecurity, c.reloptions
          from pg_class c join sch s on s.oid = c.relnamespace
         where c.relkind in ('r', 'p', 'v', 'm') and c.oid not in (select objid from ext)),
  -- v1.01a: RLS rules, expressions lower-cased without spaces or brackets; «open» = true for any signed-in user
  forms as (select array['true', '1=1', 'selectauth.uidasuidisnotnull', 'auth.uidisnotnull',
                         'auth.role=''authenticated''::text', 'selectauth.roleasrole=''authenticated''::text'] as open),
  pol as (select r.oid as relid, r.obj, p.polname, p.polpermissive as perm, p.polcmd as cmd,
                 (0::oid = any (p.polroles) or 'authenticated'::regrole::oid = any (p.polroles)) as for_auth,
                 p.polwithcheck is null as no_check,
                 regexp_replace(lower(coalesce(pg_get_expr(p.polqual, p.polrelid), '')), '[\s()]', '', 'g') as q,
                 regexp_replace(lower(coalesce(pg_get_expr(p.polwithcheck, p.polrelid), '')), '[\s()]', '', 'g') as wc,
                 regexp_replace(lower(coalesce(pg_get_expr(p.polwithcheck, p.polrelid), pg_get_expr(p.polqual, p.polrelid), '')), '[\s()]', '', 'g') as wce
            from pg_policy p join r on r.oid = p.polrelid
           where r.relkind in ('r', 'p') and r.relrowsecurity),
  cmds(c, code) as (values ('SELECT', 'r'), ('INSERT', 'a'), ('UPDATE', 'w'), ('DELETE', 'd')),
  open_cmd as (select distinct p.relid, p.obj, k.c
                 from pol p join cmds k on p.cmd in (k.code, '*') cross join forms
                where p.perm and p.for_auth
                  and ((k.c in ('SELECT', 'UPDATE', 'DELETE') and p.q = any (forms.open))
                    or (k.c in ('INSERT', 'UPDATE') and p.wce = any (forms.open)))),
  x as (
    select 'security_definer_view' as lint, 'ERROR' as level, obj from r
     where relkind = 'v' and not coalesce(reloptions && array['security_invoker=true', 'security_invoker=on', 'security_invoker=1'], false)
    union all select 'rls_disabled_in_public', 'ERROR', obj from r where relkind in ('r', 'p') and not relrowsecurity
    union all select 'rls_enabled_no_policy', 'INFO', obj from r
     where relkind in ('r', 'p') and relrowsecurity and not exists (select 1 from pg_policy pp where pp.polrelid = r.oid)
    union all select 'anon_security_definer_function_executable', 'WARN', obj from f where prosecdef and has_function_privilege('anon', oid, 'EXECUTE')
    union all select 'authenticated_security_definer_function_executable', 'WARN', obj from f where prosecdef and has_function_privilege('authenticated', oid, 'EXECUTE')
    union all select 'function_search_path_mutable', 'WARN', obj from f
     where not exists (select 1 from unnest(coalesce(proconfig, '{}'::text[])) c where c like 'search_path=%')
    union all select 'anon_table_grant', 'WARN', obj from r
     where has_table_privilege('anon', oid, 'SELECT,INSERT,UPDATE')
    union all select 'public_bucket', 'WARN', 'storage.' || id from storage.buckets where public
    -- mirror of the dashboard lint 0024 (RLS Policy Always True)
    union all select 'permissive_rls_policy', 'WARN', p.obj || ' (' || p.polname || ')' from pol p
     where p.perm and p.cmd <> 'r'
       and (p.q in ('true', '1=1') or p.wc in ('true', '1=1') or (p.cmd in ('a', 'w') and p.no_check))
    -- any signed-in user may do X and no RESTRICTIVE rule covers X
    union all select 'rls_open_without_role_rule', case when o.c = 'SELECT' then 'WARN' else 'ERROR' end, o.obj || ' (' || o.c || ')'
      from open_cmd o
     where not exists (
       select 1 from pol rr join cmds k on rr.cmd in (k.code, '*') cross join forms
        where rr.relid = o.relid and not rr.perm and rr.for_auth and k.c = o.c
          and case when k.c = 'INSERT' then rr.wce <> '' and not rr.wce = any (forms.open)
                   else rr.q <> '' and not rr.q = any (forms.open) end)
  )
  select lint || ':' || obj, lint, level, obj from x
$$;

create or replace function fabula.infra_record_advisors(p_lints jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path = fabula, public, extensions
as $$
declare
  v_scan jsonb := coalesce((select data->'counts' from fabula.infra_status where key = 'security_scan'), '{}'::jsonb);
  v_covered text[] := array['security_definer_view', 'rls_disabled_in_public', 'rls_enabled_no_policy',
                            'anon_security_definer_function_executable', 'authenticated_security_definer_function_executable',
                            'function_search_path_mutable', 'permissive_rls_policy'];
  v_unknown jsonb := '[]'::jsonb; e jsonb; v_name text; v_n int;
begin
  if p_lints is null or jsonb_typeof(p_lints) <> 'array' then raise exception 'infra_record_advisors: expected a JSON array of {name, level, count}'; end if;
  for e in select * from jsonb_array_elements(p_lints) loop
    v_name := e->>'name'; v_n := coalesce((e->>'count')::int, 1);
    if v_name = any (v_covered) then
      if v_n <> coalesce((v_scan->>v_name)::int, 0) then
        v_unknown := v_unknown || jsonb_build_object('name', v_name, 'level', e->>'level', 'count', v_n,
                                                     'why', format('advisor %s, SQL scan %s', v_n, coalesce((v_scan->>v_name)::int, 0)));
      end if;
    elsif not exists (select 1 from fabula.security_accepted where key = 'advisor:' || v_name) then
      v_unknown := v_unknown || jsonb_build_object('name', v_name, 'level', e->>'level', 'count', v_n, 'why', 'non coperto dalla scansione SQL');
    end if;
  end loop;

  insert into fabula.infra_status (key, ok, detail, data, checked_at, last_ok_at, fail_streak)
  values ('advisors', jsonb_array_length(v_unknown) = 0,
          case when jsonb_array_length(v_unknown) = 0 then jsonb_array_length(p_lints) || ' lint types, all known'
               else jsonb_array_length(v_unknown) || ' to check: ' || (select string_agg(x->>'name', ', ') from jsonb_array_elements(v_unknown) x) end,
          jsonb_build_object('lints', p_lints, 'unknown', v_unknown), now(),
          case when jsonb_array_length(v_unknown) = 0 then now() end, 0)
  on conflict (key) do update set ok = excluded.ok, detail = excluded.detail, data = excluded.data, checked_at = excluded.checked_at,
    last_ok_at = coalesce(excluded.last_ok_at, infra_status.last_ok_at);

  if jsonb_array_length(v_unknown) > 0 then
    insert into fabula.notices (key, severity, title_it, items, expires_at)
    values ('infra_advisors', 'warn', 'Supabase Advisor: segnalazioni di sicurezza da verificare (Supabase → Advisors → Security)',
            (select jsonb_agg(jsonb_build_object('code', x->>'name', 'label_it', (x->>'level') || ' · ' || (x->>'why'))) from jsonb_array_elements(v_unknown) x),
            now() + interval '26 hours')
    on conflict (key) do update set title_it = excluded.title_it, items = excluded.items, expires_at = excluded.expires_at, resolved_at = null;
  else
    update fabula.notices set resolved_at = now() where key = 'infra_advisors' and resolved_at is null;
  end if;
  return jsonb_build_object('unknown', v_unknown);
end $$;

revoke execute on function fabula.security_findings() from public, anon, authenticated;
revoke execute on function fabula.infra_record_advisors(jsonb) from public, anon, authenticated;
grant execute on function fabula.security_findings(), fabula.infra_record_advisors(jsonb) to service_role;

-- ---------------------------------------------------------------- accepted: open reads that are meant to be open
insert into fabula.security_accepted (key, reason) values
  ('rls_open_without_role_rule:fabula.app_areas (SELECT)',
   'by design (v1.01a): permission table every page reads (perm.js / my_permissions); no write rule, so only SQL / service role change it'),
  ('rls_open_without_role_rule:fabula.app_roles (SELECT)',
   'by design (v1.01a): permission table every page reads (perm.js / my_permissions); writes only for a user manager (app_roles_admin_write)'),
  ('rls_open_without_role_rule:fabula.role_permissions (SELECT)',
   'by design (v1.01a): permission matrix every page reads (perm.js / my_permissions); writes only for a user manager (role_permissions_admin_write)'),
  ('rls_open_without_role_rule:fabula.table_areas (SELECT)',
   'by design (v1.01a): table → area map read by can_table and every page; no write rule, so only SQL / service role change it'),
  ('rls_open_without_role_rule:fabula.record_corrections (SELECT)',
   'by design (v0.96 D-02, reviewed v1.01a): correction trail of HACCP and traceability records, readable like the registers; written only by correct_record and the correction functions')
on conflict (key) do nothing;

select fabula.security_scan();
