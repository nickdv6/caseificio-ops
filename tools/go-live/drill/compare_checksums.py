#!/usr/bin/env python3
"""Compare live vs restored per-table checksums (both from restore_backup.py CHECKSUM_SQL).

usage: compare_checksums.py live_checksums.json restored_checksums.json [backup.json.gz]

Lists identical and differing tables. Known harmless differences: numeric columns lose trailing zeros on the way
through the backup's JSON (1.50 → 1.5), and the backup's own in-progress agent_runs row (agent 'backup_export',
status running) differs. Any table whose row count differs needs a look.
"""
import json, sys, gzip

def load(p):
    raw = open(p, 'rb').read()
    if raw[:2] == b'\x1f\x8b':
        raw = gzip.decompress(raw)
    d = json.loads(raw)
    if isinstance(d, list):          # raw execute_sql output: [{"jsonb_object_agg": {...}}]
        d = next(iter(d[0].values()))
    return d

live, rest = load(sys.argv[1]), load(sys.argv[2])
same = [t for t in live if rest.get(t) == live[t]]
diff = sorted(t for t in live if t in rest and rest[t] != live[t])
missing = sorted(set(live) - set(rest)); extra = sorted(set(rest) - set(live))
print(f"tables: live {len(live)}, restored {len(rest)} · identical {len(same)} · differ {len(diff)}")
for t in diff:
    print(f"  {t}: rows live {live[t]['n']} / restored {rest[t]['n']}")
if missing: print('  missing after restore:', ', '.join(missing))
if extra:   print('  only in restored copy:', ', '.join(extra))
print(f"rows: live {sum(v['n'] for v in live.values())}, restored {sum(v['n'] for v in rest.values())}")
print("Differences in a few tables with equal row counts are normally representation only (numeric trailing zeros) or the "
      "backup's own running agent_runs row; inspect any table whose row count differs.")
