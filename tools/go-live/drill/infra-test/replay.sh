#!/bin/bash
# Build a scratch database from every migration (same as run_drill.sh step 1). usage: replay.sh <dbname> [extra.sql ...]
set -u
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../../../.." && pwd); DB=$1; shift
WORK=$(mktemp -d /tmp/infra.XXXX); chmod 777 "$WORK"
pg_ctlcluster 16 main start 2>/dev/null || true
PSQL() { su postgres -c "psql -q -d $DB -v ON_ERROR_STOP=1 $*"; }
su postgres -c "dropdb --if-exists $DB; createdb $DB" >/dev/null
cp "$REPO/tools/go-live/drill/bootstrap.sql" "$WORK/b.sql"; chmod 644 "$WORK/b.sql"
PSQL -f "$WORK/b.sql" >/dev/null || { echo "bootstrap failed"; exit 1; }
fail=0
for f in $(ls "$REPO"/supabase/migrations/*.sql | sort) "$@"; do
  sed -E 's/create extension if not exists pg_net[^;]*;/-- pg_net stubbed/I; s/create extension if not exists pg_cron[^;]*;/-- pg_cron stubbed/I' "$f" > "$WORK/cur.sql"; chmod 644 "$WORK/cur.sql"
  out=$(PSQL -1 -f "$WORK/cur.sql" 2>&1) || { echo "FAIL $(basename "$f") :: $(echo "$out" | grep -m3 -E 'ERROR|LINE')"; fail=$((fail+1)); }
  v=$(basename "$f" | grep -oE '^[0-9]{14}'); [ -n "$v" ] && PSQL -c "\"insert into supabase_migrations.schema_migrations(version) values ('$v') on conflict do nothing\"" >/dev/null
done
echo "migrations: $(ls "$REPO"/supabase/migrations/*.sql | wc -l) + $# extra · failures: $fail"
