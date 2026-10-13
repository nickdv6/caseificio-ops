#!/usr/bin/env python3
"""Builds 2026-10-13_v099_sql-editor.sql from the two v0.99 migration files (one transaction, history guard, history rows).
Run from the repo root after any change to those files: python3 tools/go-live/live-apply/make_v099_script.py"""
import os

PREV = '20261013200200'   # the live history must end here (v098c_trade_quantities_prices, applied 13/10)
MIGS = [('20261013210000', 'v099a_approvals_decide_undo'), ('20261013210100', 'v099b_orders_recipes_holds_prices')]
HERE = os.path.dirname(os.path.abspath(__file__)); REPO = os.path.abspath(os.path.join(HERE, '../../..'))
versions = ', '.join(f"'{v}'" for v, _ in MIGS)
out = [f'''-- v0.99a–b for the Supabase dashboard SQL Editor (13/10/2026): office decisions and undo, from the 12/10 audit.
--   v0.99a  B-09 milk plan «Approva con … kg», warnings, «Ordina di nuovo» · B-11 DOP declaration «Segna inviata» · B-12 urgency,
--           «Annulla» and history · D-24 a decision stays decided · E-10 automatic approvals said and undoable · E-12/E-11 deadlines
--           every 10 minutes · B-13 post card = what gets published · FIX: a milk plan approved in the Console now reaches the farm
--   v0.99b  B-18 catalogue orders (limit, creator, «Annulla ordine») · B-19 milk forecast and Vendite from the Ingrosso plans ·
--           B-15 «Togli» from tomorrow / «Rimetti» · B-06 lot release and NC closing · B-22/B-23 what Shopify has · TRADE-06 notice
-- Same files as supabase/migrations/{MIGS[0][0]}_* and {MIGS[-1][0]}_* (built by make_v099_script.py).
-- One transaction: if any step fails nothing changes. It records the two versions in the migration history and refuses a second run.
-- Paste everything, Run, and check the last result shows {MIGS[-1][0]} and {MIGS[0][0]} at the top.
-- AFTER this: deploy the trade-portal function, then the site (git push of branch v099-office to main).
begin;
do $chk$ begin
  if exists (select 1 from supabase_migrations.schema_migrations where version in ({versions})) then
    raise exception 'STOP: v0.99 is already in the migration history — nothing to do';
  end if;
  if (select max(version) from supabase_migrations.schema_migrations) <> '{PREV}' then
    raise exception 'STOP: the live history does not end at {PREV} (v098c_trade_quantities_prices) — tell Claude before applying';
  end if;
end $chk$;
''']
for v, n in MIGS:
    s = open(os.path.join(REPO, 'supabase/migrations', f'{v}_{n}.sql')).read()
    out.append(f'\n-- ======================= {n.split("_")[0]} =======================\n' + s.rstrip() + '\n')
out.append('\ninsert into supabase_migrations.schema_migrations (version, name) values\n'
           + ',\n'.join(f"  ('{v}', '{n}')" for v, n in MIGS) + ';\ncommit;\n\n'
           'select version, name from supabase_migrations.schema_migrations order by version desc limit 5;\n')
open(os.path.join(HERE, '2026-10-13_v099_sql-editor.sql'), 'w').write(''.join(out))
print('written')
