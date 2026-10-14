#!/usr/bin/env python3
"""Builds 2026-10-15_v104_sql-editor.sql from the three v1.04 migration files (one transaction, history guard, history rows).
Run from the repo root after any change to those files: python3 tools/go-live/live-apply/make_v104_script.py"""
import os

PREV = '20261014210200'   # the live history must end here (v103c_lot_label_reprint, applied 14/10)
MIGS = [('20261014230000', 'v104a_paper_packing_ddt'), ('20261014230100', 'v104b_nc_receipts'), ('20261014230200', 'v104c_bank_tasks_perms')]
HERE = os.path.dirname(os.path.abspath(__file__)); REPO = os.path.abspath(os.path.join(HERE, '../../..'))
versions = ', '.join(f"'{v}'" for v, _ in MIGS)
out = [f'''-- v1.04a–c for the Supabase dashboard SQL Editor (15/10/2026): database guard rails from the 12/10 audit.
--   v1.04a  D-17 a paper sheet line is not copied twice, and a lot's check must fall in that lot's working time;
--           D-22 / PRINT-04 packing compares each product with the order (more than +30 % is refused), and DDT numbers are one
--           progressive series per year made by the database (DDT-2026-0001…), for packing and the direct shipment from a lot
--   v1.04b  D-26 non-conformities can no longer be quietly rewritten; a «NON conforme» arrival stays so, and its goods are isolated
--           for dosing while the NC is open
--   v1.04c  D-28 bank matching checks direction and double matches; D-31 a task tied to a control point needs its reading;
--           D-33 approvals and purchase orders from a login start «in attesa» / in bozza; no negative PO prices
-- Same files as supabase/migrations/{MIGS[0][0]}_* … {MIGS[-1][0]}_* (built by make_v104_script.py).
-- One transaction: if any step fails nothing changes. It records the three versions in the migration history and refuses a second run.
-- Paste everything, Run, and check the last result shows {MIGS[-1][0]}, {MIGS[1][0]} and {MIGS[0][0]} at the top.
-- AFTER this: push the site (perla-v71, README «v1.04»).
begin;
do $chk$ begin
  if exists (select 1 from supabase_migrations.schema_migrations where version in ({versions})) then
    raise exception 'STOP: v1.04 is already in the migration history — nothing to do';
  end if;
  if (select max(version) from supabase_migrations.schema_migrations) <> '{PREV}' then
    raise exception 'STOP: the live history does not end at {PREV} (v103c_lot_label_reprint) — tell Claude before applying';
  end if;
end $chk$;
''']
for v, n in MIGS:
    s = open(os.path.join(REPO, 'supabase/migrations', f'{v}_{n}.sql')).read()
    out.append(f'\n-- ======================= {n.split("_")[0]} =======================\n' + s.rstrip() + '\n')
out.append('\ninsert into supabase_migrations.schema_migrations (version, name) values\n'
           + ',\n'.join(f"  ('{v}', '{n}')" for v, n in MIGS) + ';\ncommit;\n\n'
           'select version, name from supabase_migrations.schema_migrations order by version desc limit 5;\n')
open(os.path.join(HERE, '2026-10-15_v104_sql-editor.sql'), 'w').write(''.join(out))
print('written')
