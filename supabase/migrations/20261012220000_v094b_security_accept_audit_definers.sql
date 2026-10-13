-- v0.94b (12/10/2026) · security scan after v0.93a / v0.94a: four functions now run as definer on purpose. Each checks the caller's
-- permission inside, so they are recorded as accepted and the evening security check does not raise them as new findings.
insert into fabula.security_accepted (key, reason, accepted_at) values
 ('authenticated_security_definer_function_executable:fabula.log_ccp(p_cp_code text, p_value numeric, p_logged_at timestamp with time zone, p_staff_id uuid, p_batch_lot text, p_action text, p_source text, p_equipment_code text, p_written_by text)',
  'by design (v0.93a, audit D-01): definer so a CCP out of limit always holds the lot; checks require_perm(haccp, 2) inside', now()),
 ('authenticated_security_definer_function_executable:fabula.hold_lot(p_lot text, p_reason text, p_staff_id uuid)',
  'by design (v0.93a, audit D-01): checks require_perm(haccp, 2) inside', now()),
 ('authenticated_security_definer_function_executable:fabula.record_lab_result(p_sample_code text, p_outcome text, p_value numeric, p_text text, p_report_no text, p_report_date date, p_document_id uuid, p_staff_id uuid)',
  'by design (v0.93a, audit D-01/B-10): checks require_perm(haccp, 2) inside', now()),
 ('authenticated_security_definer_function_executable:fabula.milk_shipment_cancel(p_id uuid, p_reason text)',
  'by design (v0.94a, audit A-10/FARM-03): console cancels a farm load; checks require_perm(produzione, 2) inside, reason required', now())
on conflict (key) do nothing;
