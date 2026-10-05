-- v0.62a part 3 (05/10/2026) · fabula.save_ops: one tablet save (scan event + rows + RPCs) in ONE transaction, exactly once per p_qid.
-- Security invoker: RLS, role policies and triggers apply as for the single calls the tablet made before.
create or replace function fabula.save_ops(p_ops jsonb, p_qid uuid default null) returns jsonb
language plpgsql set search_path = fabula, public as $$
declare
  c_tables constant text[] := array['scan_events','milk_intake','labels','production_batches','batch_milk_inputs','stock_moves',
                                    'haccp_log','meter_readings','effluent_log','shipments','shipment_lines','waste_log','batch_step_logs'];
  c_rpcs constant text[] := array['log_ccp','receive_purchase_order','record_receipt_check','close_open_task','start_byproduct_batch',
                                  'log_batch_step','record_batch_consumable'];
  v_n int := jsonb_array_length(p_ops);
  v_out jsonb := '[]';
  v_prev jsonb; v_op jsonb; v_row jsonb; v_res jsonb; v_t text; v_cols text; v_where text; v_args text; v_cnt int;
  v_proc oid; v_label text;
begin
  if jsonb_typeof(p_ops) is distinct from 'array' or v_n = 0 then raise exception 'save_ops: nessun passo' using errcode = '22023'; end if;
  if v_n > 50 then raise exception 'save_ops: troppi passi (%)', v_n using errcode = '22023'; end if;
  if p_qid is not null then
    perform pg_advisory_xact_lock(hashtextextended('save_ops:' || p_qid::text, 0));   -- a parallel re-send waits, then finds the ledger row
    v_prev := fabula.save_ledger_get(p_qid);
    if v_prev is not null then return v_prev -> 'result'; end if;
  end if;

  for k in 0 .. v_n - 1 loop
    v_op := p_ops -> k;
    v_label := coalesce(v_op ->> 'table', v_op ->> 'rpc', '?');
    begin
      if v_op ? 'rpc' then
        if not (v_op ->> 'rpc' = any (c_rpcs)) then raise exception 'funzione non ammessa: %', v_op ->> 'rpc' using errcode = '42501'; end if;
        select p.oid into v_proc from pg_proc p
         where p.pronamespace = 'fabula'::regnamespace and p.proname = v_op ->> 'rpc' and not p.proretset
           and not exists (select 1 from jsonb_object_keys(coalesce(v_op -> 'args', '{}')) a(name)
                            where not (a.name = any (coalesce(p.proargnames, '{}'))))
         order by p.pronargs limit 1;
        if v_proc is null then raise exception 'funzione % con questi argomenti non trovata', v_op ->> 'rpc' using errcode = '42883'; end if;
        v_row := fabula.save_resolve(coalesce(v_op -> 'args', '{}'), v_out);
        select string_agg(format('%I => %s', u.name,
                 case when t.typname in ('json', 'jsonb') then format('($1 -> %L)::%s', u.name, format_type(t.oid, null))
                      when t.typcategory = 'A' then format('array(select jsonb_array_elements_text($1 -> %L))::%s', u.name, format_type(t.oid, null))
                      else format('($1 ->> %L)::%s', u.name, format_type(t.oid, null)) end), ', ' order by u.i)
          into v_args
          from pg_proc p
          cross join lateral unnest(p.proargnames[1:p.pronargs], p.proargtypes::oid[]) with ordinality u(name, typ, i)
          join pg_type t on t.oid = u.typ
         where p.oid = v_proc and v_row ? u.name;
        execute format('select to_jsonb(fabula.%I(%s))', v_op ->> 'rpc', coalesce(v_args, '')) using v_row into v_res;

      elsif v_op ? 'table' then
        v_t := v_op ->> 'table';
        if not (v_t = any (c_tables)) then raise exception 'tabella non ammessa: %', v_t using errcode = '42501'; end if;
        v_row := fabula.save_resolve(coalesce(v_op -> 'row', '{}'), v_out);
        select string_agg(format('%I', c.column_name), ', ' order by c.ordinal_position) into v_cols
          from information_schema.columns c
         where c.table_schema = 'fabula' and c.table_name = v_t and c.is_generated <> 'ALWAYS' and v_row ? c.column_name;
        if v_op ? 'update' then
          select string_agg(format('x.%I is not distinct from (jsonb_populate_record(null::fabula.%I, $2)).%I', c.column_name, v_t, c.column_name), ' and ')
            into v_where
            from information_schema.columns c
           where c.table_schema = 'fabula' and c.table_name = v_t and (v_op -> 'update') ? c.column_name;
          if v_where is null or (select count(*) from jsonb_object_keys(v_op -> 'update')) <>
                                (select count(*) from information_schema.columns c where c.table_schema = 'fabula' and c.table_name = v_t and (v_op -> 'update') ? c.column_name) then
            raise exception 'aggiornamento senza chiave valida' using errcode = '22023';
          end if;
          if v_cols is null then raise exception 'aggiornamento senza campi' using errcode = '22023'; end if;
          execute format('with u as (update fabula.%I x set (%s) = (select %s from jsonb_populate_record(null::fabula.%I, $1)) where %s returning x.*) '
                         'select (select to_jsonb(u) from u limit 1), (select count(*) from u)', v_t, v_cols, v_cols, v_t, v_where)
            using v_row, fabula.save_resolve(v_op -> 'update', v_out) into v_res, v_cnt;
          if v_cnt <> 1 then raise exception 'atteso 1 record da aggiornare in %, trovati %', v_t, v_cnt using errcode = 'P0002'; end if;
        else
          if v_cols is null then
            execute format('insert into fabula.%I as x default values returning to_jsonb(x.*)', v_t) into v_res;
          else
            execute format('insert into fabula.%I as x (%s) select %s from jsonb_populate_record(null::fabula.%I, $1) returning to_jsonb(x.*)',
                           v_t, v_cols, v_cols, v_t) using v_row into v_res;
          end if;
        end if;
      else
        raise exception 'passo senza tabella né funzione' using errcode = '22023';
      end if;
    exception when others then
      declare v_state text; v_msg text; v_detail text; v_hint text;
      begin
        get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text, v_detail = pg_exception_detail, v_hint = pg_exception_hint;
        raise exception '%', format('Passo %s di %s (%s): %s', k + 1, v_n, v_label, v_msg)
          using errcode = v_state, detail = coalesce(v_detail, ''), hint = coalesce(v_hint, '');
      end;
    end;
    v_out := v_out || jsonb_build_array(coalesce(v_res, 'null'::jsonb));
  end loop;

  -- the ledger keeps only the ids written (the tablet doesn't use the rows), so it stays small
  if p_qid is not null then perform fabula.save_ledger_put(p_qid, v_n, (select coalesce(jsonb_agg(e -> 'id'), '[]') from jsonb_array_elements(v_out) e)); end if;
  return v_out;
end $$;

revoke all on function fabula.save_ops(jsonb, uuid) from public, anon;
grant execute on function fabula.save_ops(jsonb, uuid) to authenticated, service_role;
comment on function fabula.save_ops(jsonb, uuid) is 'v0.62: runs one tablet save (several steps) in one transaction, exactly once per p_qid. Security invoker: RLS and role policies apply.';
