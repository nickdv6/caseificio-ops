alter role authenticator with login password 'testpw';
create or replace function auth.uid() returns uuid language sql stable as $$ select coalesce(nullif(current_setting('request.jwt.claim.sub', true), ''), (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'))::uuid $$;
create or replace function auth.role() returns text language sql stable as $$ select coalesce(nullif(current_setting('request.jwt.claim.role', true), ''), (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role'), current_user::text) $$;
insert into auth.users(id, email) values ('00000000-0000-4000-a000-000000000001', 'casaro@test.it') on conflict do nothing;
insert into fabula.staff(id, full_name, auth_user_id, app_role, role, active) values ('10000000-0000-4000-a000-000000000001', 'Test Casaro', '00000000-0000-4000-a000-000000000001', 'produzione', 'casaro', true) on conflict do nothing;
-- v1.05 (audit E-32): the daily tasks and the tablet's evening list start from prod.tasks_from (the replay's opening date is in 2027), and Sunday is closed: the suites work on any day
update fabula.settings set value = '2026-01-01' where key = 'prod.tasks_from';
update fabula.settings set value = '' where key = 'prod.closed_weekdays';
