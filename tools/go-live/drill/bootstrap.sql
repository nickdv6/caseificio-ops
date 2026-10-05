-- minimal Supabase-like platform for replaying the repo migrations on plain Postgres 16
do $$ begin
  if not exists (select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname='service_role') then create role service_role nologin bypassrls; end if;
  if not exists (select 1 from pg_roles where rolname='authenticator') then create role authenticator noinherit login; grant anon, authenticated, service_role to authenticator; end if;
  if not exists (select 1 from pg_roles where rolname='supabase_admin') then create role supabase_admin superuser; end if;
end $$;
create schema auth; create schema storage; create schema extensions; create schema cron; create schema net; create schema vault; create schema supabase_migrations;
grant usage on schema auth, storage, extensions to anon, authenticated, service_role;
create extension pgcrypto with schema extensions; create extension "uuid-ossp" with schema extensions;
create table auth.users (id uuid primary key default gen_random_uuid(), email text, raw_user_meta_data jsonb default '{}', raw_app_meta_data jsonb default '{}', created_at timestamptz default now(), last_sign_in_at timestamptz, email_confirmed_at timestamptz, invited_at timestamptz, deleted_at timestamptz, banned_until timestamptz);
create function auth.uid() returns uuid language sql stable as $$ select coalesce(nullif(current_setting('request.jwt.claim.sub', true), ''), (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'))::uuid $$;
create function auth.role() returns text language sql stable as $$ select coalesce(nullif(current_setting('request.jwt.claim.role', true), ''), (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role'), current_user::text) $$;
create function auth.jwt() returns jsonb language sql stable as $$ select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb $$;
create table storage.buckets (id text primary key, name text not null, public boolean default false, file_size_limit bigint, allowed_mime_types text[], owner uuid, created_at timestamptz default now(), updated_at timestamptz default now());
create table storage.objects (id uuid primary key default gen_random_uuid(), bucket_id text references storage.buckets(id), name text, owner uuid, owner_id text, metadata jsonb, path_tokens text[] generated always as (string_to_array(name, '/')) stored, created_at timestamptz default now(), updated_at timestamptz default now(), last_accessed_at timestamptz);
alter table storage.objects enable row level security;
create function storage.foldername(name text) returns text[] language sql immutable as $$ select (string_to_array(name, '/'))[1:array_length(string_to_array(name, '/'),1)-1] $$;
create function storage.filename(name text) returns text language sql immutable as $$ select (string_to_array(name, '/'))[array_length(string_to_array(name, '/'),1)] $$;
create table cron.job (jobid bigserial primary key, schedule text, command text, nodename text default 'localhost', nodeport int default 5432, database text default current_database(), username text default current_user, active boolean default true, jobname text unique);
create table cron.job_run_details (runid bigserial primary key, jobid bigint, status text, return_message text, start_time timestamptz, end_time timestamptz);
create function cron.schedule(job_name text, schedule text, command text) returns bigint language sql as $$ insert into cron.job(jobname, schedule, command) values (job_name, schedule, command) on conflict (jobname) do update set schedule = excluded.schedule, command = excluded.command returning jobid $$;
create function cron.schedule(schedule text, command text) returns bigint language sql as $$ insert into cron.job(schedule, command) values (schedule, command) returning jobid $$;
create function cron.unschedule(job_name text) returns boolean language sql as $$ with d as (delete from cron.job where jobname = job_name returning 1) select count(*) > 0 from d $$;
-- v0.68: pg_net stub keeps each request (net.http_request_queue) and answers come from net._http_response (tests insert them)
create sequence net.request_seq;
create table net.http_request_queue (id bigint primary key, method text, url text, headers jsonb, body jsonb, created timestamptz default now());
create table net._http_response (id bigint primary key, status_code int, content_type text, headers jsonb, content text, timed_out boolean, error_msg text, created timestamptz default now());
create function net.http_post(url text, body jsonb default '{}', params jsonb default '{}', headers jsonb default '{}', timeout_milliseconds int default 5000) returns bigint language sql as $$ insert into net.http_request_queue(id, method, url, headers, body) values (nextval('net.request_seq'), 'POST', url, headers, body) returning id $$;
create function net.http_get(url text, params jsonb default '{}', headers jsonb default '{}', timeout_milliseconds int default 5000) returns bigint language sql as $$ insert into net.http_request_queue(id, method, url, headers) values (nextval('net.request_seq'), 'GET', url, headers) returning id $$;
create table vault.secrets (id uuid primary key default gen_random_uuid(), name text unique, secret text, description text, created_at timestamptz default now());
create view vault.decrypted_secrets as select id, name, secret, secret as decrypted_secret, description, created_at from vault.secrets;
create function vault.create_secret(secret text, name text default null, description text default '') returns uuid language sql as $$ insert into vault.secrets(secret, name, description) values (secret, name, description) returning id $$;
create table supabase_migrations.schema_migrations (version text primary key, statements text[], name text);
-- pg_net / pg_cron "extensions" are faked above; make create extension statements no-ops
