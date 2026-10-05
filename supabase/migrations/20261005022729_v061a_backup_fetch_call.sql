-- v0.61a (05/10/2026) · restore drill: the database asks backup-export (mode "fetch") for a stored backup file, with the
-- Vault token, so the file can be read back from net._http_response without anyone handling the token or a service key.
-- Read-only on the storage side; service role / SQL only.
create or replace function fabula.backup_fetch_call(p_path text default 'backups/latest.json.gz')
 returns bigint
 language plpgsql
 security definer
 set search_path = fabula, public, extensions
as $$
declare v_id bigint; v_token text;
begin
  if p_path !~ '^backups/(latest|daily/\d{4}-\d{2}-\d{2})\.json\.gz$' then
    raise exception 'backup_fetch_call: path non valido (%): usare backups/latest.json.gz o backups/daily/AAAA-MM-GG.json.gz', p_path;
  end if;
  select decrypted_secret into v_token from vault.decrypted_secrets where name = 'backup_export_token';
  if v_token is null then raise exception 'Vault secret backup_export_token missing'; end if;
  select net.http_post(
           url := 'https://ojkquhzaeypsphncjqwy.supabase.co/functions/v1/backup-export',
           body := jsonb_build_object('mode', 'fetch', 'path', p_path),
           headers := jsonb_build_object('Content-Type', 'application/json', 'x-backup-token', v_token),
           timeout_milliseconds := 60000)
    into v_id;
  return v_id;
end $$;
revoke execute on function fabula.backup_fetch_call(text) from public, anon, authenticated;
grant execute on function fabula.backup_fetch_call(text) to service_role;
