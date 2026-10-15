#!/usr/bin/env python3
"""Builds 2026-10-15_v106_sql-editor.sql from the two v1.06 migration files (one transaction, history guard, history rows).
Run from the repo root after any change to those files: python3 tools/go-live/live-apply/make_v106_script.py"""
import os

PREV = '20261015090200'   # the live history must end here (v105c_evening_golive, applied 15/10)
MIGS = [('20261015120000', 'v106a_perche_basis'), ('20261015120100', 'v106b_perche_why')]
HERE = os.path.dirname(os.path.abspath(__file__)); REPO = os.path.abspath(os.path.join(HERE, '../../..'))
versions = ', '.join(f"'{v}'" for v, _ in MIGS)
out = [f'''-- v1.06a–b for the Supabase dashboard SQL Editor (15/10/2026): «Perché?» on the bots' messages (project doc
-- claude/perche-spec-v106-2026-10-15.md, claude/audit-fixes-v106-2026-10-15.md).
--   v1.06a  where the data behind a message is kept (fabula.message_basis, keep_basis), post_bot_message links it to the message and
--           checks the message's numbers against it; the database's stand-in, the auto-approvals and three food-safety alarms keep
--           theirs; the feed and the alarms say which messages have it; Telegram «perché»; Panoramica → Sistema «Numeri dei
--           messaggi»; nightly clean-up after 90 days
--   v1.06b  the data written out in Italian (fabula.message_why) and the 9 prompts' new versions
-- Same files as supabase/migrations/{MIGS[0][0]}_* and {MIGS[-1][0]}_* (built by make_v106_script.py).
-- One transaction: if any step fails nothing changes. It records the two versions in the migration history and refuses a second run.
-- Paste everything, Run, and check the last result shows {MIGS[-1][0]} and {MIGS[0][0]} at the top.
-- AFTER this: push the site (perla-v73, README «v1.06»), then the bots' scheduled tasks get the new prompts.
begin;
do $chk$ begin
  if exists (select 1 from supabase_migrations.schema_migrations where version in ({versions})) then
    raise exception 'STOP: v1.06 is already in the migration history — nothing to do';
  end if;
  if (select max(version) from supabase_migrations.schema_migrations) <> '{PREV}' then
    raise exception 'STOP: the live history does not end at {PREV} (v105c_evening_golive) — tell Claude before applying';
  end if;
end $chk$;
''']
for v, n in MIGS:
    s = open(os.path.join(REPO, 'supabase/migrations', f'{v}_{n}.sql'), encoding='utf-8').read()
    out.append(f'\n-- ======================= {n.split("_")[0]} =======================\n' + s.rstrip() + '\n')
out.append('\ninsert into supabase_migrations.schema_migrations (version, name) values\n'
           + ',\n'.join(f"  ('{v}', '{n}')" for v, n in MIGS) + ';\ncommit;\n\n'
           'select version, name from supabase_migrations.schema_migrations order by version desc limit 5;\n')
open(os.path.join(HERE, '2026-10-15_v106_sql-editor.sql'), 'w', encoding='utf-8').write(''.join(out))
print('written')
