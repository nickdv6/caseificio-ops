-- v0.41b: three SECURITY DEFINER functions added in v0.39/v0.40 were executable by anon
-- (default PUBLIC grant). Close them to anon; keep signed-in users and bots.
revoke execute on function fabula.bot_display_name(text) from public, anon;
revoke execute on function fabula.trg_milk_intake_stock() from public, anon;
revoke execute on function fabula.trg_stock_move_guard() from public, anon;
grant execute on function fabula.bot_display_name(text) to authenticated, service_role;
grant execute on function fabula.trg_milk_intake_stock() to authenticated, service_role;
grant execute on function fabula.trg_stock_move_guard() to authenticated, service_role;
