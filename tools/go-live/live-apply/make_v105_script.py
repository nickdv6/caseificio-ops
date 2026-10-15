#!/usr/bin/env python3
"""Builds 2026-10-15_v105_sql-editor.sql from the three v1.05 migration files (one transaction, history guard, history rows).
Run from the repo root after any change to those files: python3 tools/go-live/live-apply/make_v105_script.py"""
import os

PREV = '20261014230200'   # the live history must end here (v104c_bank_tasks_perms, applied 15/10)
MIGS = [('20261015090000', 'v105a_messages_checks'), ('20261015090100', 'v105b_prompts_tasks'), ('20261015090200', 'v105c_evening_golive')]
HERE = os.path.dirname(os.path.abspath(__file__)); REPO = os.path.abspath(os.path.join(HERE, '../../..'))
versions = ', '.join(f"'{v}'" for v, _ in MIGS)
out = [f'''-- v1.05a–c for the Supabase dashboard SQL Editor (15/10/2026): bots, alerts and operations from the 12/10 audit (area E).
--   v1.05a  E-06 one table of rules for the database's own messages (severity, Telegram topic, area): milk not worked for 48 h is
--           now a food-safety alarm; E-09 the open alarms and notices for every office profile, by area (Console → Oggi and the
--           bell); E-14 the system checks in Italian; E-27 the drift warning says which way to fix it, and schema_fingerprint()
--           lets Claude compare live with the repo; E-28 the database jobs and the backup secret are checked (the save-ledger
--           trim job is now made by the migration)
--   v1.05b  E-16 one next step for the placeholder names; E-17 prompt versions and drift; E-19 the briefs' changes computed by
--           the database, web-found leads «Da verificare»; E-32 no daily tasks before the tasks start, only cold rooms on closed
--           days (the nightly task job is switched back on: before the start it creates nothing)
--   v1.05c  E-31 the evening HACCP list live on the tablet from 14:00, yesterday's gaps in the morning; E-30 the go-live list in
--           Italian in Configurazione → Panoramica, signed with a note
-- Same files as supabase/migrations/{MIGS[0][0]}_* … {MIGS[-1][0]}_* (built by make_v105_script.py).
-- One transaction: if any step fails nothing changes. It records the three versions in the migration history and refuses a second run.
-- Paste everything, Run, and check the last result shows {MIGS[-1][0]}, {MIGS[1][0]} and {MIGS[0][0]} at the top.
-- AFTER this: push the site (perla-v72, README «v1.05»), then the bots' scheduled tasks get the new prompts.
begin;
do $chk$ begin
  if exists (select 1 from supabase_migrations.schema_migrations where version in ({versions})) then
    raise exception 'STOP: v1.05 is already in the migration history — nothing to do';
  end if;
  if (select max(version) from supabase_migrations.schema_migrations) <> '{PREV}' then
    raise exception 'STOP: the live history does not end at {PREV} (v104c_bank_tasks_perms) — tell Claude before applying';
  end if;
end $chk$;
''']
for v, n in MIGS:
    s = open(os.path.join(REPO, 'supabase/migrations', f'{v}_{n}.sql'), encoding='utf-8').read()
    out.append(f'\n-- ======================= {n.split("_")[0]} =======================\n' + s.rstrip() + '\n')
out.append('\ninsert into supabase_migrations.schema_migrations (version, name) values\n'
           + ',\n'.join(f"  ('{v}', '{n}')" for v, n in MIGS) + ';\ncommit;\n\n'
           'select version, name from supabase_migrations.schema_migrations order by version desc limit 5;\n')
open(os.path.join(HERE, '2026-10-15_v105_sql-editor.sql'), 'w', encoding='utf-8').write(''.join(out))
print('written')
