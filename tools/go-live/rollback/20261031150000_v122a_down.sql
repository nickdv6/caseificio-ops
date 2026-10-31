-- Rollback of v1.22a (Sunday open all year, written into the migrations): puts back what was live before it, which is the same thing.
-- v1.22a only wrote into the migrations the two values live has had since 30/10/2026 18:37 UTC (trade.delivery_days '1,2,3,4,5,6,7',
-- prod.closed_weekdays ''). On live it changed nothing, so there is nothing to undo and this file does nothing.
-- Closing Sunday again is a decision, not a rollback: if it is ever taken, release it as a new migration with
--   update fabula.settings set value = '1,2,3,4,5,6' where key = 'trade.delivery_days';
--   update fabula.settings set value = '7' where key = 'prod.closed_weekdays';
-- and check the wholesale plans that deliver on Sunday first (fabula.trade_schedule_days, weekday 7).
-- To use a rollback, copy it into supabase/migrations under a new, later version and release it through the pipeline.

select 1;
