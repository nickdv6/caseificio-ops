#!/usr/bin/env python3
"""Restore a La Perla backup (backups/*.json.gz from the backup-export edge function) into a Postgres database.

Tested 05/10/2026 (restore drill, see BACKUP-RESTORE.md): the real latest.json.gz restored into a scratch database
built from supabase/migrations matched the live database table by table (row counts and content checksums).

PARTNERS / NOT A DEVELOPER: do not use this script. Read sop/sistema_giu.html ("Sistema giù: cosa fare"): switch to paper and
call Nick. This script is for the developer runbook (BACKUP-RESTORE.md).

Usage (v0.96, audit E-23: the safe way is the default; wiping needs to be asked for, twice)
  # 0) when was the backup taken? (UTC and Agropoli time)
  python3 restore_backup.py when latest.json.gz

  # 1) DEFAULT = PARTIAL: adds back only the backup rows that are missing (by primary key); never deletes or overwrites anything
  python3 restore_backup.py sql latest.json.gz > partial.sql          # the day-to-day RECORDS (HACCP, milk, lots, stock, sales…)
  python3 restore_backup.py sql latest.json.gz --tables haccp_log,non_conformities > partial.sql   # only some tables
  python3 restore_backup.py sql latest.json.gz --tables all > partial.sql   # every table: also brings back settings, PINs,
      # rota or standing orders deleted ON PURPOSE after the backup — only when that is what you want

  # 2) FULL restore (empties EVERY table and reloads the backup): only into a new/empty project, never the live one
  python3 restore_backup.py sql latest.json.gz --wipe-all --target <project-ref> > restore.sql
      # the SQL refuses to run when ANY record (HACCP, milk, lots, stock, sales, shifts…) is newer than the backup

  # Every generated SQL starts with a safety stop: it runs only if `set restore.confirm = '<exported_at>';` was run first
  # (the exact line is printed, together with the backup time). --confirm <exported_at> adds that line for you.

  # 3) or load straight into a database with psql available (same rules; --confirm is required)
  python3 restore_backup.py load latest.json.gz --db "postgresql://postgres:…@db.<ref>.supabase.co:5432/postgres" --confirm <exported_at>

  # 3) check a database against the backup (row counts + per-table checksums of the restored rows)
  python3 restore_backup.py verify latest.json.gz --db "…"

  # 4) (v0.68) who had a login and which files were stored at backup time
  python3 restore_backup.py logins latest.json.gz   # email · staff name · role · last sign-in → re-invite these people
  python3 restore_backup.py files latest.json.gz    # bucket/name · size · type → what to copy back into Storage

What the restore does
  * one transaction; session_replication_role = replica, so triggers (audit log, stock guard, bot messages, staff guard…)
    don't fire and foreign keys aren't checked while the tables are refilled in any order;
  * partial restore (default, all tables or --tables): inserts only the backup rows whose primary key is missing
    (on conflict do nothing);
  * full restore (--wipe-all --target <ref>): TRUNCATEs every table and re-inserts the backup rows with
    jsonb_populate_recordset, skipping generated columns and overriding identity columns;
  * moves every serial/identity sequence past the highest restored id.

Not in the backup (restore separately): passwords (since v0.68 the list of logins is in `auth_users`: re-invite the people and
re-link staff.auth_user_id by email), Storage files themselves (since v0.68 their list is in `storage_manifest`), Vault secrets,
pg_cron jobs (in the migrations), edge function secrets.
"""
import argparse, gzip, json, os, re, secrets, subprocess, sys, datetime
from urllib.parse import urlparse
from zoneinfo import ZoneInfo

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

# the records the floor and the office write every day: what a partial restore puts back by default, and what a full restore
# checks first (any of them newer than the backup = live data that the wipe would destroy)
RECORD_TABLES = ['haccp_log', 'non_conformities', 'record_corrections', 'milk_intake', 'milk_shipments', 'batch_milk_inputs', 'production_batches',
                 'batch_step_logs', 'batch_consumables', 'stock_moves', 'labels', 'lab_samples', 'calibration_checks', 'pest_inspections',
                 'goods_receipts', 'goods_receipt_lines', 'shipments', 'shipment_lines', 'sales_orders', 'sales_order_lines', 'scan_events',
                 'meter_readings', 'effluent_log', 'waste_log', 'shifts', 'task_instances', 'stock_counts', 'stock_count_lines',
                 'pos_daily_closings', 'invoices', 'invoice_lines', 'documents', 'haccp_register_reviews', 'training_records']

WIPE_CHECK = [t for t in RECORD_TABLES if t != 'labels']   # the migrations themselves create a few station labels

def rome_time(b):
    try:
        t = datetime.datetime.fromisoformat(str(b.get('exported_at')).replace('Z', '+00:00'))
        return t.astimezone(ZoneInfo('Europe/Rome')).strftime('%d/%m/%Y alle %H:%M')
    except Exception:
        return str(b.get('exported_at'))

def sq(v):            # an SQL string literal
    return "'" + str(v).replace("'", "''") + "'"

def restore_sql(b, tables=None, wipe=False, target=None, confirm=None):
    if wipe and tables:
        sys.exit('--wipe-all restores every table: leave out --tables (or leave out --wipe-all for a partial restore)')
    if wipe or tables == ['all']:
        names = sorted(b['tables'])
    elif tables:
        names = [t for t in tables if t in b['tables']]
    else:
        names = [t for t in RECORD_TABLES if t in b['tables']]
        print('Ripristino parziale delle registrazioni: ' + ', '.join(names) + ' (le altre tabelle con --tables …)', file=sys.stderr)
    tables = None if tables == ['all'] else tables
    missing = [t for t in (tables or []) if t not in b['tables']]
    if missing:
        sys.exit('not in the backup: ' + ', '.join(missing))
    exp = str(b.get('exported_at')); when = rome_time(b)
    if confirm is not None and confirm != exp:
        sys.exit(f"--confirm does not match this backup: it was exported at {exp} ({when}, ora italiana)")
    tag = 'bk' + secrets.token_hex(4)
    lose = (f"RIPRISTINO COMPLETO del progetto {target}: svuota TUTTE le tabelle e rimette il backup del {when}: "
            f"perderai tutto quello registrato dopo.") if wipe else \
           (f"Ripristino parziale dal backup del {when}: aggiunge solo le righe mancanti di {len(names)} tabelle, non cancella e non cambia niente.")
    stop = f"set restore.confirm = {sq(exp)};"
    guard = [f"do $guard$ begin",
             f"  if coalesce(current_setting('restore.confirm', true), '') <> {sq(exp)} then",
             f"    raise exception using message = {sq('FERMO: ripristino non confermato. ' + lose + ' Se sei sicuro, aggiungi in cima e riesegui: ' + stop)};",
             f"  end if;"]
    if wipe:
        # any record newer than the backup = a database in use: the wipe would destroy it (whatever the time of day)
        guard = ["do $guard$ declare v_have text[]; v_newer text; begin",
                 *guard[1:],
                 "  select array_agg(c.table_name::text) into v_have from information_schema.columns c",
                 "   where c.table_schema = 'fabula' and c.column_name = 'created_at' and c.table_name::text = any (array[" + ', '.join(sq(t) for t in WIPE_CHECK) + "]);",
                 "  if v_have is not null then",
                 f"    execute 'select string_agg(t, '', '') from (' || (select string_agg(format('select %L t where exists (select 1 from fabula.%I where created_at > %L::timestamptz)', x, x, {sq(exp)}), ' union all ') from unnest(v_have) x) || ') q' into v_newer;",
                 "  end if;",
                 "  if v_newer is not null then",
                 f"    raise exception using message = {sq('FERMO: questo database contiene registrazioni più recenti del backup (' + when + ') in: ')} || v_newer || {sq('. Il ripristino completo le cancellerebbe: si fa solo su un progetto nuovo e vuoto. Per rimettere righe perse usa il ripristino parziale (senza --wipe-all).')};",
                 "  end if;"]

    guard.append("end $guard$;")
    print(f"Il backup è del {when} (ora italiana). {lose}", file=sys.stderr)
    out = [f"-- La Perla restore · backup {b.get('mode')} exported {exp} ({when} ora italiana) · {len(names)} tables, "
           f"{sum(len(b['tables'][t]) for t in names)} rows · {'FULL: wipes every table of ' + str(target) if wipe else 'PARTIAL: adds missing rows only'}",
           f"-- {lose}",
           f"-- Safety stop: the line below must be run first (it is the backup's time, to show you read it).",
           (stop if confirm else f"-- {stop}"),
           'begin;', *guard, "set local session_replication_role = replica;", HELPER.strip()]
    merge = not wipe
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

def db_targets(db):
    """What a --target must equal for this connection string: the Supabase project ref (from db.<ref>.supabase.co or the
    pooler user postgres.<ref>), or else the database name. Never a substring: «postgres» or «supabase» match nothing."""
    u = urlparse(db or '')
    refs = set()
    m = re.match(r'^db\.([a-z0-9]{15,30})\.supabase\.co$', u.hostname or '')
    if m: refs.add(m.group(1))
    m = re.match(r'^postgres\.([a-z0-9]{15,30})$', u.username or '')
    if m: refs.add(m.group(1))
    if refs: return refs
    name = (u.path or '').lstrip('/')
    return {name} if name else set()

def psql(db, sql):
    r = subprocess.run(['psql', db, '-v', 'ON_ERROR_STOP=1', '-At', '-q'], input=sql, capture_output=True, text=True)
    if r.returncode:
        sys.exit(r.stderr.strip())
    return r.stdout

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('action', choices=['sql', 'load', 'verify', 'counts', 'logins', 'files', 'when'])
    ap.add_argument('backup')
    ap.add_argument('--db', default=os.environ.get('DATABASE_URL'))
    ap.add_argument('--tables', help='comma-separated table names (default: all tables in the backup)')
    ap.add_argument('--wipe-all', action='store_true', help='FULL restore: empty every table and reload the backup (new/empty project only)')
    ap.add_argument('--target', help='with --wipe-all: the project ref (or local database name) you mean to wipe')
    ap.add_argument('--confirm', help="the backup's exported_at (see `when`): adds the safety-stop line to the SQL")
    a = ap.parse_args()
    b = load_backup(a.backup)
    tables = [t.strip() for t in a.tables.split(',')] if a.tables else None
    if a.action == 'when':
        print(b.get('exported_at')); print(f"{rome_time(b)} ora italiana · {b.get('mode')}", file=sys.stderr); return
    if a.wipe_all and a.action in ('sql', 'load'):
        if not a.target:
            sys.exit('--wipe-all needs --target <project ref>: the project you mean to wipe (never the live one with real data)')
        if a.action == 'load' and a.target not in db_targets(a.db):
            sys.exit(f'--target {a.target} is not the database of --db ({", ".join(sorted(db_targets(a.db))) or "?"}): refusing to wipe a different database')
    if a.action == 'counts':
        for t in sorted(b['tables']):
            print(f"{t}\t{len(b['tables'][t])}")
        return
    if a.action == 'logins':
        users = b.get('auth_users')
        if users is None: sys.exit('this backup predates v0.68: no list of logins')
        for u in users:
            st = u.get('staff') or {}
            print(f"{u.get('email')}\t{st.get('full_name') or '-'}\t{st.get('app_role') or '-'}\t{'active' if st.get('active') else 'inactive' if st else 'no staff row'}\tlast sign-in {u.get('last_sign_in_at') or 'never'}")
        print(f"{len(users)} logins", file=sys.stderr); return
    if a.action == 'files':
        files = b.get('storage_manifest')
        if files is None: sys.exit('this backup predates v0.68: no file list')
        for f in files:
            print(f"{f['bucket']}/{f['name']}\t{f.get('size')}\t{f.get('mimetype') or ''}\t{f.get('updated_at') or ''}")
        print(f"{len(files)} files, {sum(int(f.get('size') or 0) for f in files)} bytes", file=sys.stderr); return
    if a.action == 'sql':
        sys.stdout.write(restore_sql(b, tables, a.wipe_all, a.target, a.confirm)); return
    if not a.db:
        sys.exit('--db (or DATABASE_URL) is required')
    if a.action == 'load':
        if not a.confirm:
            sys.exit(f"--confirm is required: the backup was exported at {b.get('exported_at')} ({rome_time(b)} ora italiana); "
                     f"pass --confirm '{b.get('exported_at')}' if that is the backup you mean")
        out = psql(a.db, restore_sql(b, tables, a.wipe_all, a.target, a.confirm))
        print(out.strip().splitlines()[-1] if out.strip() else 'done')
    sums = json.loads(psql(a.db, CHECKSUM_SQL).strip())
    bad = [(t, len(b['tables'][t]), sums.get(t, {}).get('n')) for t in (tables or sorted(b['tables'])) if sums.get(t, {}).get('n') != len(b['tables'][t])]
    print(json.dumps({'tables': len(tables or b['tables']), 'rows_in_backup': sum(len(b['tables'][t]) for t in (tables or b['tables'])),
                      'count_mismatches': bad, 'checksums': sums}, indent=1) if bad else
          f"OK · {len(tables or b['tables'])} tables · row counts match the backup")
    json.dump(sums, open('restored_checksums.json', 'w'))   # compare with the live database's checksums (same formula)

if __name__ == '__main__':
    main()
