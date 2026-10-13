#!/usr/bin/env python3
"""Builds 2026-10-13_v097_sql-editor.sql from the two v0.97 migration files (one transaction, history guard, history rows).
Run from the repo root after any change to those files: python3 tools/go-live/live-apply/make_v097_script.py"""
import os

PREV = '20261013140257'   # the live history must end here (quick_fixes_20261013, applied 13/10 14:02 UTC)
MIGS = [('20261013160000', 'v097a_floor_tasks_followups_saves'), ('20261013160100', 'v097b_stock_count_dop_age')]
HERE = os.path.dirname(os.path.abspath(__file__)); REPO = os.path.abspath(os.path.join(HERE, '../../..'))
versions = ', '.join(f"'{v}'" for v, _ in MIGS)
out = [f'''-- v0.97a–b for the Supabase dashboard SQL Editor (13/10/2026): the floor-flow items of the 12/10 audit.
--   v0.97a  A-05 task list (overdue the same day, earlier days apart, «Non fatta», a check closes the task whose time has come) ·
--           A-15 follow-ups as timed tasks with a Telegram push · D-04 a record saved offline keeps its time · D-15 Italian errors ·
--           A-08 two tablets with the same lot letter · A-22 a step not measured keeps the curd pH
--   v0.97b  D-05 stock count against the stock at saving · A-14 no DOP batch from milk past 60 hours · A-20 paper milk date
-- Same files as supabase/migrations/{MIGS[0][0]}_* … {MIGS[-1][0]}_* (built by make_v097_script.py).
-- One transaction: if any step fails nothing changes. It records the two versions in the migration history and refuses a second run.
-- Paste everything, Run, and check the last result shows {MIGS[-1][0]} and {MIGS[0][0]} at the top.
-- AFTER this: deploy the site (git pull/push of branch v097-floor; the tablet then sends the new save time and calls skip_task).
begin;
do $chk$ begin
  if exists (select 1 from supabase_migrations.schema_migrations where version in ({versions})) then
    raise exception 'STOP: v0.97 is already in the migration history — nothing to do';
  end if;
  if (select max(version) from supabase_migrations.schema_migrations) <> '{PREV}' then
    raise exception 'STOP: the live history does not end at {PREV} (quick_fixes_20261013) — tell Claude before applying';
  end if;
end $chk$;
''']
for v, n in MIGS:
    s = open(os.path.join(REPO, 'supabase/migrations', f'{v}_{n}.sql')).read()
    out.append(f'\n-- ======================= {n.split("_")[0]} =======================\n' + s.rstrip() + '\n')
out.append('\ninsert into supabase_migrations.schema_migrations (version, name) values\n'
           + ',\n'.join(f"  ('{v}', '{n}')" for v, n in MIGS) + ';\ncommit;\n\n'
           'select version, name from supabase_migrations.schema_migrations order by version desc limit 6;\n')
open(os.path.join(HERE, '2026-10-13_v097_sql-editor.sql'), 'w').write(''.join(out))
print('written')
