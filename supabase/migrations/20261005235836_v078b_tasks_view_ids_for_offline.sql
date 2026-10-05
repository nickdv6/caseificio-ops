-- v0.78b (05/10/2026) · v_tasks_open also returns control_point_id and equipment_id, so a tablet without network can hide the
-- tasks it already closed (their close is still in its queue). Columns appended at the end; same rows, same security_invoker.
create or replace view fabula.v_tasks_open with (security_invoker = true) as
 SELECT ti.id,
    ti.due_at,
    ti.status,
    s.code,
    s.title_it,
    s.title_en,
    s.assigned_role,
    e.code AS equipment_code,
    cp.code AS control_point_code,
    s.form_code,
    s.control_point_id,
    s.equipment_id
   FROM (((fabula.task_instances ti
     JOIN fabula.task_schedules s ON ((s.id = ti.schedule_id)))
     LEFT JOIN fabula.equipment e ON ((e.id = s.equipment_id)))
     LEFT JOIN fabula.haccp_control_points cp ON ((cp.id = s.control_point_id)))
  WHERE (ti.status = ANY (ARRAY['due'::fabula.task_status, 'overdue'::fabula.task_status]))
  ORDER BY ti.due_at;
