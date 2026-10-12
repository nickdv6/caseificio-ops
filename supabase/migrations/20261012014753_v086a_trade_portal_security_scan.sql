-- v0.86a (12/10/2026) · security scan after v0.83 (trade portal): 8 new findings.
-- 1) Two helpers without a fixed search_path (lint function_search_path_mutable).
alter function fabula.trade_now_rome() set search_path = fabula, public;
alter function fabula.trade_wd_it(integer) set search_path = fabula, public;

-- 2) Two SECURITY DEFINER functions with no permission check inside: only cron and other definer
--    functions call them, so signed-in users lose EXECUTE.
--    trade_push_queue posts to the trade-portal edge function with the stored job secret;
--    trade_notice_refresh rewrites the Console notice of pending applications.
revoke execute on function fabula.trade_push_queue(boolean) from public, anon, authenticated;
revoke execute on function fabula.trade_notice_refresh() from public, anon, authenticated;
grant execute on function fabula.trade_push_queue(boolean) to service_role;
grant execute on function fabula.trade_notice_refresh() to service_role;

-- 3) Four called as the signed-in user by design, each gated inside.
insert into fabula.security_accepted (key, reason, accepted_at) values
 ('authenticated_security_definer_function_executable:fabula.trade_approve(p_app uuid, p_note text)',
  'by design: trade-portal edge function calls it with the staff JWT (v0.83); require_perm(vendite, 3) inside', now()),
 ('authenticated_security_definer_function_executable:fabula.trade_reject(p_app uuid, p_note text)',
  'by design: trade-portal edge function calls it with the staff JWT (v0.83); require_perm(vendite, 3) inside', now()),
 ('authenticated_security_definer_function_executable:fabula.trade_staff_action(p_customer uuid, p_action text, p_payload jsonb, p_force boolean)',
  'by design: tablet Ingrosso console (v0.83); require_perm(vendite, 2) inside, vendite 3 for set_trade_status', now()),
 ('authenticated_security_definer_function_executable:fabula.trade_customers()',
  'by design: tablet Ingrosso console (v0.83); read-only, empty below vendite 1, portal link only at vendite 3', now())
on conflict (key) do nothing;

select fabula.security_scan();
