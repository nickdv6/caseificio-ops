-- v1.22a (31/10/2026) · Sunday open all year, written into the migrations as it already is on live.
-- Nick, 30/10/2026: «assume sundays are open all year». That evening (18:37 UTC) two settings were changed on live directly, not
-- through a migration: prod.closed_weekdays '7' → '' (Sunday gets the full daily task list on the tablet) and trade.delivery_days
-- '1,2,3,4,5,6' → '1,2,3,4,5,6,7' (Sunday is a wholesale delivery day). A replay of the repo therefore still had Sunday closed, unlike
-- live, and the CI suite test_v110_security_saves failed every Saturday (its «tomorrow» had no delivery). Nick, 31/10/2026: «Fix it
-- properly».
-- Here the two values are written so that a replay equals live (checked on live 31/10: only these two rows changed on 30/10, and these
-- are their values). On live nothing changes: a row is touched only where its value differs, so no update, no audit row, no new
-- updated_at. Descriptions, kinds and every other setting are left as they are.
-- Rollback: tools/go-live/rollback/20261031150000_v122a_down.sql (nothing to undo on live; it says how to close Sunday again).

update fabula.settings set value = '1,2,3,4,5,6,7' where key = 'trade.delivery_days' and value is distinct from '1,2,3,4,5,6,7';
update fabula.settings set value = '' where key = 'prod.closed_weekdays' and value is distinct from '';
