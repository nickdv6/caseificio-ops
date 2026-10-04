-- v0.54 · Storage bucket "documents": the full database backups (backups/…) were readable and overwritable by every signed-in user.
-- The read/upload/update policies only checked bucket_id. Now:
--   · backups/… is reachable only by the backup-export edge function (service role bypasses RLS) — no policy grants it to users
--   · read and upload need an active staff profile (fabula.perm_level('comune') > 0), not just any auth account
--   · overwriting a file is allowed to whoever uploaded it, or to HACCP managers (level 3) — so lab certificates, DDT photos and
--     calibration certificates can't be silently replaced by another profile
-- The bucket itself stays private. Delete stays not granted (no policy) as before.
insert into storage.buckets (id, name, public) values ('documents', 'documents', false) on conflict (id) do nothing;

drop policy if exists "fabula staff read documents" on storage.objects;
drop policy if exists "fabula staff upload documents" on storage.objects;
drop policy if exists "fabula staff update documents" on storage.objects;

create policy "fabula staff read documents" on storage.objects for select to authenticated
  using (bucket_id = 'documents' and name not like 'backups/%' and (select fabula.perm_level('comune')) > 0);

create policy "fabula staff upload documents" on storage.objects for insert to authenticated
  with check (bucket_id = 'documents' and name not like 'backups/%' and (select fabula.perm_level('comune')) > 0);

create policy "fabula staff update documents" on storage.objects for update to authenticated
  using (bucket_id = 'documents' and name not like 'backups/%' and (select fabula.perm_level('comune')) > 0
         and (owner_id = (select auth.uid())::text or (select fabula.perm_level('haccp')) >= 3))
  with check (bucket_id = 'documents' and name not like 'backups/%');

insert into supabase_migrations.schema_migrations (version, name) values ('20261004203000','v054_documents_storage_lockdown') on conflict do nothing;
