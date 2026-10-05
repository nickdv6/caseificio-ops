#!/bin/bash
# Backup restore drill (see ../BACKUP-RESTORE.md → "Restore drill").
# Builds an empty database from supabase/migrations on a local Postgres 16, restores a backup into it and checks it.
#
# usage: run_drill.sh <backup.json.gz> [live_checksums.json]
#   live_checksums.json = output of restore_backup.py's CHECKSUM_SQL run on the live database (optional but recommended)
# needs: Postgres 16 server + psql on this machine, run as root (uses `su postgres`).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
BACKUP=$(readlink -f "$1"); LIVE=${2:+$(readlink -f "$2")}
DB=restore_drill
WORK=$(mktemp -d /tmp/drill.XXXX); chmod 777 "$WORK"
cp "$BACKUP" "$WORK/backup.json.gz"; chmod 644 "$WORK/backup.json.gz"
pg_ctlcluster 16 main start 2>/dev/null || true
PSQL() { su postgres -c "psql -q -d $DB -v ON_ERROR_STOP=1 $*"; }

echo "== 1. build an empty database from $(ls "$REPO"/supabase/migrations/*.sql | wc -l) migrations"
su postgres -c "dropdb --if-exists $DB; createdb $DB" >/dev/null
PSQL < "$HERE/bootstrap.sql" >/dev/null || { echo "bootstrap failed"; exit 1; }
fail=0
for f in $(ls "$REPO"/supabase/migrations/*.sql | sort); do
  # pg_net / pg_cron are stubbed by bootstrap.sql
  sed -E 's/create extension if not exists pg_net[^;]*;/-- pg_net stubbed/I; s/create extension if not exists pg_cron[^;]*;/-- pg_cron stubbed/I' "$f" > "$WORK/cur.sql"
  chmod 644 "$WORK/cur.sql"
  out=$(PSQL -1 < "$WORK/cur.sql" 2>&1) || { echo "FAIL $(basename "$f") :: $(echo "$out" | grep -m2 ERROR)"; fail=$((fail+1)); }
done
echo "migration failures: $fail"; [ $fail -eq 0 ] || exit 1

echo "== 2. restore the backup (full)"
cd "$WORK"
python3 "$REPO/tools/go-live/restore_backup.py" sql backup.json.gz > restore.sql && chmod 644 restore.sql
t0=$(date +%s.%N); PSQL < restore.sql > /dev/null || { echo "restore failed"; exit 1; }
echo "loaded in $(echo "$(date +%s.%N) - $t0" | bc) s"

echo "== 3. row counts + checksums"
cp "$REPO/tools/go-live/restore_backup.py" "$WORK/" && chmod 644 "$WORK/restore_backup.py"
su postgres -c "cd $WORK && python3 restore_backup.py verify backup.json.gz --db 'postgresql:///$DB'"
if [ -n "$LIVE" ]; then python3 "$HERE/compare_checksums.py" "$LIVE" restored_checksums.json backup.json.gz; fi

echo "== 4. foreign keys (orphan rows) and sequences"
PSQL -At <<'SQL'
do $$ declare r record; v bigint; n int := 0; bad int := 0; begin
  for r in select c.conrelid::regclass ch, c.confrelid::regclass pa,
                  (select string_agg(format('c.%I', a.attname), ',' order by k.i) from unnest(c.conkey) with ordinality k(n, i) join pg_attribute a on a.attrelid = c.conrelid and a.attnum = k.n) ccols,
                  (select string_agg(format('p.%I', a.attname), ',' order by k.i) from unnest(c.confkey) with ordinality k(n, i) join pg_attribute a on a.attrelid = c.confrelid and a.attnum = k.n) pcols
             from pg_constraint c where c.contype = 'f' and c.connamespace = 'fabula'::regnamespace loop
    execute format('select count(*) from %s c where row(%s) is not null and not exists (select 1 from %s p where row(%s) = row(%s))', r.ch, r.ccols, r.pa, r.pcols, r.ccols) into v;
    n := n + 1; if v > 0 then bad := bad + 1; raise notice 'orphans: % → % (% rows)', r.ch, r.pa, v; end if;
  end loop;
  raise notice 'foreign keys checked: %, with orphans: %', n, bad;
end $$;
select 'ops_dashboard() on the restored copy: ' || case when fabula.ops_dashboard() ? 'checks' then 'OK' else 'FAILED' end;
SQL
echo "work files in $WORK (database: $DB)"
