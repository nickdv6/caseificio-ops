-- v0.62a part 2 (05/10/2026) · ledger writer. The ledger keeps only ids (tiny); trimming rows older than 30 days needs a delete, which the Supabase connector refuses — run it from the SQL editor if it ever matters.
create or replace function fabula.save_ledger_put(p_qid uuid, p_steps int, p_result jsonb) returns void
language plpgsql security definer set search_path = fabula, public as $$
begin
  insert into fabula.save_ledger(qid, staff_id, steps, result) values (p_qid, fabula.my_staff_id(), p_steps, p_result);
end $$;
revoke all on function fabula.save_ledger_put(uuid, int, jsonb) from public, anon;
revoke all on function fabula.save_ledger_get(uuid) from public, anon;
revoke all on function fabula.save_resolve(jsonb, jsonb) from public, anon;
grant execute on function fabula.save_ledger_put(uuid, int, jsonb) to authenticated, service_role;
