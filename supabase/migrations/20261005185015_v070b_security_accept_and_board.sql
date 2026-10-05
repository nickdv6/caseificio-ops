-- v0.70b (05/10/2026) · security scan after v0.69/v0.70 + go-live board (same-day update: `prev` stays on the 3 Oct audit).
-- bot_fallback_agents() (v0.69) gets a fixed search_path (lint function_search_path_mutable).
alter function fabula.bot_fallback_agents() set search_path = fabula, public;
-- the tablet calls these two as the signed-in user: production_plan checks require_perm('produzione', 1) inside;
-- expected_yield only returns an average yield percentage
insert into fabula.security_accepted (key, reason, accepted_at) values
 ('authenticated_security_definer_function_executable:fabula.production_plan(p_date date)',
  'by design: tablet Home card (v0.70); checks require_perm(produzione, 1) inside; read-only', now()),
 ('authenticated_security_definer_function_executable:fabula.expected_yield(p_product uuid, p_preset uuid, p_exclude uuid)',
  'by design: tablet batch close (v0.70); read-only, returns only an average yield %', now())
on conflict (key) do nothing;

insert into fabula.dash_areas(area, sort, built, reliable, automated, next_step, evidence, updated_at) values
 ('Production floor', 12, 93, 76, 50,
  'Casaro confirms the 6 placeholder doses, the presets and the vat size (prod.vat_kg = 800 kg); record the first real batch from the Home card',
  'v0.70 autopilot: Home shows "Produzione di oggi" from the milk on hand — equal vat loads, product + default preset, doses, expected kg from the yield history, 60 h DOP deadline, open batches; one tap opens the batch start filled in (works offline from the kept plan); closing asks to confirm a yield more than 4 points off and flags it (Zio Ciro in Configurazione → Bot). Tests: SQL 19/19, tablet 13/13 + e2e 22/22.', now())
on conflict (area) do update
   set built = greatest(dash_areas.built, excluded.built), reliable = greatest(dash_areas.reliable, excluded.reliable),
       automated = greatest(dash_areas.automated, excluded.automated), next_step = excluded.next_step,
       evidence = case when dash_areas.evidence like '%v0.70 autopilot%' then dash_areas.evidence else dash_areas.evidence || ' ' || excluded.evidence end,
       updated_at = excluded.updated_at;
