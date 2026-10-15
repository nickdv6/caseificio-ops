#!/usr/bin/env python3
"""Builds 2026-10-15_v107_sql-editor.sql from the two v1.07 migration files (one transaction, history guard, history rows).
Run from the repo root after any change to those files: python3 tools/go-live/live-apply/make_v107_script.py"""
import os

PREV = '20261015120100'   # the live history must end here (v106b_perche_why, applied 15/10)
MIGS = [('20261015140000', 'v107a_quiet_before_start'), ('20261015140100', 'v107b_sell_at_zero_prompt')]
HERE = os.path.dirname(os.path.abspath(__file__)); REPO = os.path.abspath(os.path.join(HERE, '../../..'))
versions = ', '.join(f"'{v}'" for v, _ in MIGS)
out = [f'''-- v1.07a–b for the Supabase dashboard SQL Editor (15/10/2026): «Prima dell'avvio», the bots stay quiet before the first day with
-- the tasks (project doc claude/audit-fixes-v107-2026-10-15.md).
--   v1.07a  fabula.quiet_day() and the setting prod.quiet_before_start; the automatic milk plan proposes nothing before the start
--           (the stand-in and «Perché?» say so); the evening check skips the tablet and the stock count; the briefs do not ask for
--           the day's HACCP checks unless real milk or a lot was worked; an expired decision gets no 30-minute reminder; Monday's
--           summary has «Verso l'apertura»
--   v1.07b  the Shopify stock message respects selling at zero stock (shopify.sell_at_zero); the milk planning prompt's new version
-- Same files as supabase/migrations/{MIGS[0][0]}_* and {MIGS[-1][0]}_* (built by make_v107_script.py).
-- One transaction: if any step fails nothing changes. It records the two versions in the migration history and refuses a second run.
-- Paste everything, Run, and check the last result shows {MIGS[-1][0]} and {MIGS[0][0]} at the top.
-- AFTER this: merge and push to main (the app does not change, so Netlify does not deploy), then the bots' scheduled tasks get the
-- new milk planning prompt.
begin;
do $chk$ begin
  if exists (select 1 from supabase_migrations.schema_migrations where version in ({versions})) then
    raise exception 'STOP: v1.07 is already in the migration history — nothing to do';
  end if;
  if (select max(version) from supabase_migrations.schema_migrations) <> '{PREV}' then
    raise exception 'STOP: the live history does not end at {PREV} (v106b_perche_why) — tell Claude before applying';
  end if;
end $chk$;
''']
for v, n in MIGS:
    s = open(os.path.join(REPO, 'supabase/migrations', f'{v}_{n}.sql'), encoding='utf-8').read()
    out.append(f'\n-- ======================= {n.split("_")[0]} =======================\n' + s.rstrip() + '\n')
out.append('\ninsert into supabase_migrations.schema_migrations (version, name) values\n'
           + ',\n'.join(f"  ('{v}', '{n}')" for v, n in MIGS) + ';\ncommit;\n\n'
           'select version, name from supabase_migrations.schema_migrations order by version desc limit 5;\n')
open(os.path.join(HERE, '2026-10-15_v107_sql-editor.sql'), 'w', encoding='utf-8').write(''.join(out))
print('written')
