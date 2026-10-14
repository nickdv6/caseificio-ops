#!/usr/bin/env python3
"""Builds 2026-10-14_v100_sql-editor.sql from the two v1.00 migration files (one transaction, history guard, history rows).
Run from the repo root after any change to those files: python3 tools/go-live/live-apply/make_v100_script.py"""
import os

PREV = '20261014014118'   # the live history must end here (v101a_rls_role_rules, applied 14/10 by the RLS session)
MIGS = [('20261014043000', 'v100b_feed_reads_links_names'), ('20261014043100', 'v100c_notices_incidents_runnow')]
HERE = os.path.dirname(os.path.abspath(__file__)); REPO = os.path.abspath(os.path.join(HERE, '../../..'))
versions = ', '.join(f"'{v}'" for v, _ in MIGS)
out = [f'''-- v1.00b–c for the Supabase dashboard SQL Editor (14/10/2026): alerts and operations, from the 12/10 audit.
--   v1.00b  E-04/C-12 read per person, «Risolto» with a note · E-05 routine messages close by themselves · E-08 a link in every
--           message (only to the app's own pages) · E-13 names say what the bot does · food-safety alarms from «Sicurezza alimentare»
--   v1.00c  E-03 notices for the floor or the office · E-33 one incident (and one Telegram) per bot that stopped, closed by itself;
--           the hourly database job runs the check · E-21 «Esegui ora (versione del database)», the refused saves in Autocontrollo ·
--           a closed alarm stops its Telegram reminder · one open copy per notice in the feed
-- Same files as supabase/migrations/{MIGS[0][0]}_* and {MIGS[-1][0]}_* (built by make_v100_script.py).
-- One transaction: if any step fails nothing changes. It records the two versions in the migration history and refuses a second run.
-- Paste everything, Run, and check the last result shows {MIGS[-1][0]} and {MIGS[0][0]} at the top.
-- AFTER this: the site (git push of branch v100-alerts to main). No edge function changes.
begin;
do $chk$ begin
  if exists (select 1 from supabase_migrations.schema_migrations where version in ({versions})) then
    raise exception 'STOP: v1.00 is already in the migration history — nothing to do';
  end if;
  if (select max(version) from supabase_migrations.schema_migrations) <> '{PREV}' then
    raise exception 'STOP: the live history does not end at {PREV} (v101a_rls_role_rules) — tell Claude before applying';
  end if;
end $chk$;
''']
for v, n in MIGS:
    s = open(os.path.join(REPO, 'supabase/migrations', f'{v}_{n}.sql')).read()
    out.append(f'\n-- ======================= {n.split("_")[0]} =======================\n' + s.rstrip() + '\n')
out.append('\ninsert into supabase_migrations.schema_migrations (version, name) values\n'
           + ',\n'.join(f"  ('{v}', '{n}')" for v, n in MIGS) + ';\ncommit;\n\n'
           'select version, name from supabase_migrations.schema_migrations order by version desc limit 5;\n')
open(os.path.join(HERE, '2026-10-14_v100_sql-editor.sql'), 'w').write(''.join(out))
print('written')
