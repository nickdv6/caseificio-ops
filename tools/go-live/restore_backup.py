#!/usr/bin/env python3
"""Restore a La Perla backup (backups/*.json.gz from the backup-export edge function) into a Postgres database.

Tested 05/10/2026 (restore drill, see BACKUP-RESTORE.md): the real latest.json.gz restored into a scratch database
built from supabase/migrations matched the live database table by table (row counts and content checksums).

Usage
  # 1) write the restore SQL (one transaction) — paste into the Supabase SQL editor or run with psql
  python3 restore_backup.py sql latest.json.gz > restore.sql
  python3 restore_backup.py sql latest.json.gz --tables haccp_log,non_conformities > partial.sql   # only some tables:
      # adds the backup rows that are missing (by primary key) and leaves every other row as it is

  # 2) or load straight into a database with psql available
  python3 restore_backup.py load latest.json.gz --db "postgresql://postgres:…@db.<ref>.supabase.co:5432/postgres"

  # 3) check a database against the backup (row counts + per-table checksums of the restored rows)
  python3 restore_backup.py verify latest.json.gz --db "…"

What the restore does
  * one transaction; session_replication_role = replica, so triggers (audit log, stock guard, bot messages, staff guard…)
    don't fire and foreign keys aren't checked while the tables are refilled in any order;
  * full restore (no --tables): TRUNCATEs every table and re-inserts the backup rows with jsonb_populate_recordset,
    skipping generated columns and overriding identity columns;
  * partial restore (--tables): inserts only the backup rows whose primary key is missing (on conflict do nothing);
  * moves every serial/identity sequence past the highest restored id.

Not in the backup (restore separately): Supabase Auth users (logins: staff.auth_user_id points to them), Storage files
(DDT photos, lab certificates, the backups themselves), Vault secrets, pg_cron jobs (in the migrations), edge function secrets.
"""
import argparse, gzip, json, os, secrets, subprocess, sys

def load_backup(path):
    raw = open(path, 'rb').read()
    if raw[:2] == b'\x1f\x8b':
        raw = gzip.decompress(raw)
    b = json.loads(raw)
    if b.get('format') != 'la-perla-backup/1':
        sys.exit(f"not a La Perla backup (format={b.get('format')!r})")
    return b

HELPER = r"""
create or replace function pg_temp.restore_table(p_table text, p_rows jsonb, p_merge boolean default false) returns int language plpgsql as $f$
declare v_cols text; v_n int;
begin
  select string_agg(format('%I', a.attname), ', ' order by a.attnum) into v_cols
    from pg_attribute a
   where a.attrelid = format('fabula.%I', p_table)::regclass and a.attnum > 0 and not a.attisdropped and a.attgenerated = '';
  execute format('insert into fabula.%I (%s) overriding system value select %s from jsonb_populate_recordset(null::fabula.%I, $1)%s',
                 p_table, v_cols, v_cols, p_table, case when p_merge then ' on conflict do nothing' else '' end) using p_rows;
  get diagnostics v_n = row_count;
  return v_n;
end $f$;
create or replace function pg_temp.reset_sequences() returns int language plpgsql as $f$
declare r record; v_max bigint; v_n int := 0;
begin
  for r in select a.attrelid::regclass::text tbl, a.attname col, pg_get_serial_sequence(a.attrelid::regclass::text, a.attname) seq
             from pg_attribute a join pg_class c on c.oid = a.attrelid
            where c.relnamespace = 'fabula'::regnamespace and c.relkind = 'r' and a.attnum > 0 and not a.attisdropped
              and pg_get_serial_sequence(a.attrelid::regclass::text, a.attname) is not null loop
    execute format('select max(%I) from %s', r.col, r.tbl) into v_max;
    if v_max is not null then perform setval(r.seq, v_max, true); else perform setval(r.seq, 1, false); end if;
    v_n := v_n + 1;
  end loop;
  return v_n;
end $f$;
"""

def restore_sql(b, tables=None):
    names = sorted(b['tables']) if not tables else [t for t in tables if t in b['tables']]
    missing = [t for t in (tables or []) if t not in b['tables']]
    if missing:
        sys.exit('not in the backup: ' + ', '.join(missing))
    tag = 'bk' + secrets.token_hex(4)
    out = [f"-- La Perla restore · backup {b.get('mode')} exported {b.get('exported_at')} ({b.get('rome_day')}) · {len(names)} tables, "
           f"{sum(len(b['tables'][t]) for t in names)} rows",
           'begin;', "set local session_replication_role = replica;", HELPER.strip()]
    merge = bool(tables)
    if not merge:
        out.append('truncate table ' + ', '.join(f'fabula."{t}"' for t in names) + ';')
    for t in names:
        rows = json.dumps(b['tables'][t], ensure_ascii=False, separators=(',', ':'))
        if f'${tag}$' in rows:
            sys.exit('dollar-quote tag clash, run again')
        out.append(f"select '{t}' as restored, pg_temp.restore_table('{t}', ${tag}${rows}${tag}$::jsonb, {'true' if merge else 'false'}) as rows;")
    out.append('select pg_temp.reset_sequences() as sequences_reset;')
    out.append('commit;')
    return '\n'.join(out) + '\n'

# same checksum the drill computed on the live database: md5 of each row as jsonb text, in primary-key order
CHECKSUM_SQL = r"""
with k as (select coalesce((select jsonb_object_agg(t.relname, coalesce(pk.cols, allc.cols))
    from pg_class t
    left join lateral (select jsonb_agg(a.attname order by array_position(i.indkey::int2[], a.attnum)) cols
                         from pg_index i join pg_attribute a on a.attrelid = i.indrelid and a.attnum = any(i.indkey)
                        where i.indrelid = t.oid and i.indisprimary) pk on true
    left join lateral (select jsonb_agg(a.attname order by a.attnum) cols from pg_attribute a
                        where a.attrelid = t.oid and a.attnum > 0 and not a.attisdropped
                          and format_type(a.atttypid, a.atttypmod) not in ('json', 'jsonb', 'bytea')) allc on true
   where t.relnamespace = 'fabula'::regnamespace and t.relkind in ('r', 'p')), '{}') j)
select jsonb_object_agg(t, jsonb_build_object(
       'n', (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from fabula.%I', t), false, true, '')))[1]::text::int,
       'h', (xpath('/row/h/text()', query_to_xml(format('select md5(coalesce(string_agg(to_jsonb(x)::text, %L order by %s), %L)) as h from fabula.%I x', E'\n',
            (select string_agg(format('x.%I', c), ', ') from jsonb_array_elements_text((select j from k)->t) c), '', t), false, true, '')))[1]::text))
  from unnest((select array_agg(table_name::text order by table_name) from information_schema.tables
                where table_schema = 'fabula' and table_type = 'BASE TABLE')) t;
"""

def psql(db, sql):
    r = subprocess.run(['psql', db, '-v', 'ON_ERROR_STOP=1', '-At', '-q'], input=sql, capture_output=True, text=True)
    if r.returncode:
        sys.exit(r.stderr.strip())
    return r.stdout

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('action', choices=['sql', 'load', 'verify', 'counts'])
    ap.add_argument('backup')
    ap.add_argument('--db', default=os.environ.get('DATABASE_URL'))
    ap.add_argument('--tables', help='comma-separated table names (default: all tables in the backup)')
    a = ap.parse_args()
    b = load_backup(a.backup)
    tables = [t.strip() for t in a.tables.split(',')] if a.tables else None
    if a.action == 'counts':
        for t in sorted(b['tables']):
            print(f"{t}\t{len(b['tables'][t])}")
        return
    if a.action == 'sql':
        sys.stdout.write(restore_sql(b, tables)); return
    if not a.db:
        sys.exit('--db (or DATABASE_URL) is required')
    if a.action == 'load':
        out = psql(a.db, restore_sql(b, tables))
        print(out.strip().splitlines()[-1] if out.strip() else 'done')
    sums = json.loads(psql(a.db, CHECKSUM_SQL).strip())
    bad = [(t, len(b['tables'][t]), sums.get(t, {}).get('n')) for t in (tables or sorted(b['tables'])) if sums.get(t, {}).get('n') != len(b['tables'][t])]
    print(json.dumps({'tables': len(tables or b['tables']), 'rows_in_backup': sum(len(b['tables'][t]) for t in (tables or b['tables'])),
                      'count_mismatches': bad, 'checksums': sums}, indent=1) if bad else
          f"OK · {len(tables or b['tables'])} tables · row counts match the backup")
    json.dump(sums, open('restored_checksums.json', 'w'))   # compare with the live database's checksums (same formula)

if __name__ == '__main__':
    main()
