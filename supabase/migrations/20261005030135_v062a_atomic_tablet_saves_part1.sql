-- v0.62a part 1 (05/10/2026) · ledger for exactly-once tablet saves (see part 3: fabula.save_ops)
create table if not exists fabula.save_ledger (
  qid uuid primary key,
  staff_id uuid,
  steps int not null,
  result jsonb,
  created_at timestamptz not null default now()
);
create index if not exists save_ledger_created_idx on fabula.save_ledger (created_at);
alter table fabula.save_ledger enable row level security;
revoke all on fabula.save_ledger from anon, authenticated;
comment on table fabula.save_ledger is 'v0.62: one row per tablet save run by save_ops() (exactly-once re-sends). Kept 30 days. Only reachable through save_ledger_get/put.';

create or replace function fabula.save_ledger_get(p_qid uuid) returns jsonb
language sql stable security definer set search_path = fabula, public as $$
  select jsonb_build_object('result', l.result) from fabula.save_ledger l where l.qid = p_qid
$$;

-- "$k.field" → field of step k's result; a reference to a missing value removes the key (same as the tablet's own resolver)
create or replace function fabula.save_resolve(p_v jsonb, p_out jsonb) returns jsonb
language plpgsql immutable set search_path = fabula, public as $$
declare v_m text[]; v_res jsonb; v_k text; v_x jsonb;
begin
  case jsonb_typeof(p_v)
    when 'string' then
      v_m := regexp_match(p_v #>> '{}', '^\$(\d+)\.(\w+)$');
      if v_m is null then return p_v; end if;
      return p_out -> (v_m[1]::int) -> v_m[2];               -- SQL null when missing
    when 'object' then
      v_res := '{}';
      for v_k, v_x in select key, value from jsonb_each(p_v) loop
        v_x := fabula.save_resolve(v_x, p_out);
        if v_x is not null then v_res := v_res || jsonb_build_object(v_k, v_x); end if;
      end loop;
      return v_res;
    when 'array' then
      return coalesce((select jsonb_agg(coalesce(fabula.save_resolve(e, p_out), 'null'::jsonb) order by i)
                         from jsonb_array_elements(p_v) with ordinality a(e, i)), '[]');
    else return p_v;
  end case;
end $$;
grant execute on function fabula.save_ledger_get(uuid) to authenticated, service_role;
grant execute on function fabula.save_resolve(jsonb, jsonb) to authenticated, service_role;
