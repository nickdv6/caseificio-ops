#!/usr/bin/env python3
"""Builds 2026-10-14_v102_sql-editor.sql from the two v1.02 migration files (one transaction, history guard, history rows).
Run from the repo root after any change to those files: python3 tools/go-live/live-apply/make_v102_script.py"""
import os

PREV = '20261014050000'   # the live history must end here (v100d_close_old_alarms, applied 14/10)
MIGS = [('20261014163000', 'v102a_shopify_sync'), ('20261014163100', 'v102b_digest_quiet_nights')]
HERE = os.path.dirname(os.path.abspath(__file__)); REPO = os.path.abspath(os.path.join(HERE, '../../..'))
versions = ', '.join(f"'{v}'" for v, _ in MIGS)
out = [f'''-- v1.02a–b for the Supabase dashboard SQL Editor (14/10/2026): Shopify sync in the database, morning summary, quiet nights.
--   v1.02a  E-18 orders, customers and stock copied by the server function shopify-sync (run by the database at the same times),
--           checked against Shopify's own counts; never more than 5 % of the customers deactivated at once; «Esegui ora»
--   v1.02b  E-07 a daily summary on Telegram at each person's time (Nick 07:30 New York); at night only food safety and
--           «system down» go out at once; the routine decisions of the day reach Telegram as «Da decidere»
-- Same files as supabase/migrations/{MIGS[0][0]}_* and {MIGS[-1][0]}_* (built by make_v102_script.py).
-- One transaction: if any step fails nothing changes. It records the two versions in the migration history and refuses a second run.
-- Paste everything, Run, and check the last result shows {MIGS[-1][0]} and {MIGS[0][0]} at the top.
-- BEFORE this: deploy the function shopify-sync (README «v1.02»). AFTER: pause the three Claude Shopify tasks, update the prompts.
begin;
do $chk$ begin
  if exists (select 1 from supabase_migrations.schema_migrations where version in ({versions})) then
    raise exception 'STOP: v1.02 is already in the migration history — nothing to do';
  end if;
  if (select max(version) from supabase_migrations.schema_migrations) <> '{PREV}' then
    raise exception 'STOP: the live history does not end at {PREV} (v100d_close_old_alarms) — tell Claude before applying';
  end if;
end $chk$;
''']
for v, n in MIGS:
    s = open(os.path.join(REPO, 'supabase/migrations', f'{v}_{n}.sql')).read()
    out.append(f'\n-- ======================= {n.split("_")[0]} =======================\n' + s.rstrip() + '\n')
out.append('\ninsert into supabase_migrations.schema_migrations (version, name) values\n'
           + ',\n'.join(f"  ('{v}', '{n}')" for v, n in MIGS) + ';\ncommit;\n\n'
           'select version, name from supabase_migrations.schema_migrations order by version desc limit 5;\n')
open(os.path.join(HERE, '2026-10-14_v102_sql-editor.sql'), 'w').write(''.join(out))
print('written')
