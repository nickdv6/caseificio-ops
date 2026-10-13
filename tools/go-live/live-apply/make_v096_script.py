#!/usr/bin/env python3
"""Builds 2026-10-13_v096_sql-editor.sql from the four v0.96 migration files (one transaction, history guard, history rows).
Run from the repo root after any change to those files: python3 tools/go-live/live-apply/make_v096_script.py"""
import os

PREV = '20261013041309'   # the live history must end here (bubalina_launch_newsletter_utm, applied 13/10 04:13 UTC)
MIGS = [('20261013090000', 'v096a_critical_milk_ccp_records'), ('20261013090100', 'v096b_operator'),
        ('20261013090200', 'v096c_notify_telegram'), ('20261013090300', 'v096d_milk_dairy_weight')]
HERE = os.path.dirname(os.path.abspath(__file__)); REPO = os.path.abspath(os.path.join(HERE, '../../..'))
versions = ', '.join(f"'{v}'" for v, _ in MIGS)
out = [f'''-- v0.96a–d for the Supabase dashboard SQL Editor (13/10/2026): the remaining Critical items of the 12/10 audit.
--   v0.96a  A-04 a positive milk check blocks that delivery and every lot made from it · A-03 a lot closed without its CCPs is held ·
--           D-02 HACCP and traceability records are locked, «Correggi» with a reason is the only way to change them · D-21 no double close
--   v0.96b  A-01 who is recording on the shared tablet: badge or name + PIN, both identities on every record, badge-in never clocks out
--   v0.96c  E-01 alerts on Telegram (@bubalina_avvisi_bot): outbox, routing by topic, quiet hours, «Me ne occupo io», 30-min reminder
--   v0.96d  FARM-02 the dairy scale weight is kept next to the farm's; over 2 % (with a reason) it is what entered
-- Same files as supabase/migrations/{MIGS[0][0]}_* … {MIGS[-1][0]}_* (built by make_v096_script.py).
-- One transaction: if any step fails nothing changes. It records the four versions in the migration history and refuses a second run.
-- Paste everything, Run, and check the last result shows {MIGS[-1][0]} … {MIGS[0][0]} at the top.
-- AFTER this: deploy the site (the tablet calls the new functions), deploy the edge function `notify` and set its two secrets.
begin;
do $chk$ begin
  if exists (select 1 from supabase_migrations.schema_migrations where version in ({versions})) then
    raise exception 'STOP: v0.96 is already in the migration history — nothing to do';
  end if;
  if (select max(version) from supabase_migrations.schema_migrations) <> '{PREV}' then
    raise exception 'STOP: the live history does not end at {PREV} (bubalina_launch_newsletter_utm) — tell Claude before applying';
  end if;
end $chk$;
''']
for v, n in MIGS:
    s = open(os.path.join(REPO, 'supabase/migrations', f'{v}_{n}.sql')).read()
    out.append(f'\n-- ======================= {n.split("_")[0]} =======================\n' + s.rstrip() + '\n')
out.append('\ninsert into supabase_migrations.schema_migrations (version, name) values\n'
           + ',\n'.join(f"  ('{v}', '{n}')" for v, n in MIGS) + ';\ncommit;\n\n'
           'select version, name from supabase_migrations.schema_migrations order by version desc limit 6;\n')
open(os.path.join(HERE, '2026-10-13_v096_sql-editor.sql'), 'w').write(''.join(out))
print('written')
