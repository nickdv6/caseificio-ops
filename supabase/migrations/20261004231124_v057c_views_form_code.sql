-- v0.57c · v_haccp_plan espone form_code (colonna Registro nel Piano) · v_tasks_open torna security_invoker (persa nel create or replace della v057a)
create or replace view fabula.v_haccp_plan with (security_invoker = true) as
select cp.sort, cp.ccp_no, cp.code, cp.name, cp.is_ccp, cp.process_step, cp.applies_when, cp.hazard_it, cp.critical_limit_it,
       cp.min_value, cp.max_value, cp.warn_min, cp.warn_max, cp.unit, cp.frequency, cp.monitoring_it, cp.corrective_it, cp.verification_it,
       cp.records_it, cp.nc_severity, cp.active, e.code as equipment_code,
       (select count(*) from fabula.haccp_log l where l.control_point_id = cp.id and l.logged_at > now() - interval '30 days') as logs_30d,
       (select count(*) from fabula.haccp_log l where l.control_point_id = cp.id and l.logged_at > now() - interval '30 days' and l.result = 'non_conformity'::fabula.haccp_result) as nc_30d,
       (select max(l.logged_at) from fabula.haccp_log l where l.control_point_id = cp.id) as last_logged_at,
       cp.form_code
from fabula.haccp_control_points cp
left join fabula.equipment e on e.id = cp.equipment_id
order by cp.sort, cp.code;
alter view fabula.v_tasks_open set (security_invoker = true);
