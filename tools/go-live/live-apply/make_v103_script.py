#!/usr/bin/env python3
"""Builds 2026-10-14_v103_sql-editor.sql from the three v1.03 migration files (one transaction, history guard, history rows).
Run from the repo root after any change to those files: python3 tools/go-live/live-apply/make_v103_script.py"""
import os

PREV = '20261014163100'   # the live history must end here (v102b_digest_quiet_nights, applied 14/10)
MIGS = [('20261014210000', 'v103a_secrets_hidden'), ('20261014210100', 'v103b_farm_links'), ('20261014210200', 'v103c_lot_label_reprint')]
HERE = os.path.dirname(os.path.abspath(__file__)); REPO = os.path.abspath(os.path.join(HERE, '../../..'))
versions = ', '.join(f"'{v}'" for v, _ in MIGS)
out = [f'''-- v1.03a–c for the Supabase dashboard SQL Editor (14/10/2026): secrets hidden, the Masseria's two links, lot labels from the database.
--   v1.03a  C-05 the farm keys and the trade job key are no longer readable or changeable by any login (and are replaced only by
--           the database); their values never reach the Registro; the trade job key is replaced; customers' portal keys hidden;
--           the bot run log is no longer writable by logins
--   v1.03b  FARM-04 a separate QR key for the poster (record shipments only), «Chi spedisce» on every load, new keys made on the
--           server from Configurazione → Utenti e accessi → «Link della Masseria»
--   v1.03c  PRINT-08 lot labels reprinted from the database (tablet «Ristampa etichette»), labels.html checks every lot
-- Same files as supabase/migrations/{MIGS[0][0]}_* … {MIGS[-1][0]}_* (built by make_v103_script.py).
-- One transaction: if any step fails nothing changes. It records the three versions in the migration history and refuses a second run.
-- Paste everything, Run, and check the last result shows {MIGS[-1][0]}, {MIGS[1][0]} and {MIGS[0][0]} at the top.
-- BEFORE this: deploy the function farm-order (README «v1.03»). AFTER: push the site, then the Masseria links (README).
begin;
do $chk$ begin
  if exists (select 1 from supabase_migrations.schema_migrations where version in ({versions})) then
    raise exception 'STOP: v1.03 is already in the migration history — nothing to do';
  end if;
  if (select max(version) from supabase_migrations.schema_migrations) <> '{PREV}' then
    raise exception 'STOP: the live history does not end at {PREV} (v102b_digest_quiet_nights) — tell Claude before applying';
  end if;
end $chk$;
''']
for v, n in MIGS:
    s = open(os.path.join(REPO, 'supabase/migrations', f'{v}_{n}.sql')).read()
    out.append(f'\n-- ======================= {n.split("_")[0]} =======================\n' + s.rstrip() + '\n')
out.append('\ninsert into supabase_migrations.schema_migrations (version, name) values\n'
           + ',\n'.join(f"  ('{v}', '{n}')" for v, n in MIGS) + ';\ncommit;\n\n'
           'select version, name from supabase_migrations.schema_migrations order by version desc limit 5;\n')
open(os.path.join(HERE, '2026-10-14_v103_sql-editor.sql'), 'w').write(''.join(out))
print('written')
