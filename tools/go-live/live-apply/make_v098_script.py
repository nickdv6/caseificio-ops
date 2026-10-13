#!/usr/bin/env python3
"""Builds 2026-10-13_v098_sql-editor.sql from the three v0.98 migration files (one transaction, history guard, history rows).
Run from the repo root after any change to those files: python3 tools/go-live/live-apply/make_v098_script.py"""
import os

PREV = '20261013160932'   # the live history must end here (golive_badges_check_20261013, applied 13/10)
MIGS = [('20261013200000', 'v098a_settings_limits'), ('20261013200100', 'v098b_batch_milk_recipe_limits'),
        ('20261013200200', 'v098c_trade_quantities_prices')]
HERE = os.path.dirname(os.path.abspath(__file__)); REPO = os.path.abspath(os.path.join(HERE, '../../..'))
versions = ', '.join(f"'{v}'" for v, _ in MIGS)
out = [f'''-- v0.98a–c for the Supabase dashboard SQL Editor (13/10/2026): numbers and limits, from the 12/10 audit.
--   v0.98a  C-02/C-03/D-13 settings: limits, units, lists, high-impact changes to the bell, Italian commas, setting_num never breaks
--   v0.98b  D-06 batch yield and vat size + correct_batch_milk · D-07 milk: the database rejects, physical limits · D-27/B-14 recipe
--           doses ×2 need a confirmation and a reason · D-20 units and recipe items · D-19 dosing · D-18 goods receipt · FARM-07
--   v0.98c  TRADE-01 wholesale quantities (step, maximum, «Confermi?») · D-23 reserved prices and tiers
-- Same files as supabase/migrations/{MIGS[0][0]}_* … {MIGS[-1][0]}_* (built by make_v098_script.py).
-- One transaction: if any step fails nothing changes. It records the three versions in the migration history and refuses a second run.
-- Paste everything, Run, and check the last result shows {MIGS[-1][0]}, {MIGS[1][0]} and {MIGS[0][0]} at the top.
-- AFTER this: deploy the site (git pull/push of branch v098-numbers; the tablet then sends the milk correction, the pack lot and
-- the confirmations the database now asks for).
begin;
do $chk$ begin
  if exists (select 1 from supabase_migrations.schema_migrations where version in ({versions})) then
    raise exception 'STOP: v0.98 is already in the migration history — nothing to do';
  end if;
  if (select max(version) from supabase_migrations.schema_migrations) <> '{PREV}' then
    raise exception 'STOP: the live history does not end at {PREV} (golive_badges_check_20261013) — tell Claude before applying';
  end if;
end $chk$;
''']
for v, n in MIGS:
    s = open(os.path.join(REPO, 'supabase/migrations', f'{v}_{n}.sql')).read()
    out.append(f'\n-- ======================= {n.split("_")[0]} =======================\n' + s.rstrip() + '\n')
out.append('\ninsert into supabase_migrations.schema_migrations (version, name) values\n'
           + ',\n'.join(f"  ('{v}', '{n}')" for v, n in MIGS) + ';\ncommit;\n\n'
           'select version, name from supabase_migrations.schema_migrations order by version desc limit 6;\n')
open(os.path.join(HERE, '2026-10-13_v098_sql-editor.sql'), 'w').write(''.join(out))
print('written')
