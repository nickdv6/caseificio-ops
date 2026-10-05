-- v0.40a · fabula.bot_messages, the bot dashboard feed. The table was created live on 02/10 outside a migration file, so
-- v040 (post_bot_message, v_bot_dashboard, …) could not be rebuilt from the repo. v0.59 restores it from the live definition.
-- Idempotent: on the live database every statement is a no-op.

create table if not exists fabula.bot_messages (
  id bigserial primary key,
  agent text not null,
  run_id uuid references fabula.agent_runs(id),
  created_at timestamptz not null default now(),
  severity text not null default 'info' check (severity in ('info', 'warn', 'alert')),
  title text not null,
  body text,
  source text not null default 'bot' check (source in ('bot', 'auto', 'notice')),
  notice_key text,
  read_at timestamptz,
  read_by uuid references fabula.staff(id)
);
create index if not exists bot_messages_created on fabula.bot_messages (created_at desc);
create index if not exists bot_messages_agent on fabula.bot_messages (agent, created_at desc);
create index if not exists bot_messages_unread on fabula.bot_messages (created_at desc) where read_at is null;

alter table fabula.bot_messages enable row level security;
grant select, insert, update, delete on fabula.bot_messages to authenticated, service_role;
grant usage, select on sequence fabula.bot_messages_id_seq to authenticated, service_role;

insert into fabula.table_areas (table_name, area, write_level, read_open)
values ('bot_messages', 'sistema', 3, false)
on conflict (table_name) do nothing;

do $$
begin
  if not exists (select 1 from pg_policies where schemaname = 'fabula' and tablename = 'bot_messages' and policyname = 'bot_messages_authenticated_all') then
    create policy bot_messages_authenticated_all on fabula.bot_messages for all to authenticated using (true) with check (true);
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'fabula' and tablename = 'bot_messages' and policyname = 'bot_messages_role_select') then
    create policy bot_messages_role_select on fabula.bot_messages as restrictive for select to authenticated using ((select fabula.can_table('bot_messages', false)));
    create policy bot_messages_role_insert on fabula.bot_messages as restrictive for insert to authenticated with check ((select fabula.can_table('bot_messages', true)));
    create policy bot_messages_role_update on fabula.bot_messages as restrictive for update to authenticated using ((select fabula.can_table('bot_messages', true)));
    create policy bot_messages_role_delete on fabula.bot_messages as restrictive for delete to authenticated using ((select fabula.can_table('bot_messages', true)));
  end if;
end $$;
