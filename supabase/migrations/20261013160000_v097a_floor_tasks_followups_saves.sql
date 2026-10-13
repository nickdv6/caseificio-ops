-- v0.97a · Audit 12/10/2026, floor flows (High items): the task list, follow-ups that are not forgotten, offline times, refused saves.
--   A-05 (rest)  «Da fare oggi»: overdue shows the same day (computed live from each task's grace time); a check closes only a task
--                whose time has come (from 3 h before), so a re-check at 10:00 no longer closes the evening cold-room task;
--                «Non fatta» with a reason (skip_task); tasks left open more than 7 days are closed as not done.
--   A-15         «ricontrolla entro 1 ora» and «lavorare entro 2 ore» become timed tasks (T-FOLLOW): created by the reading or the
--                delivery, closed by the next reading / by the first vat started with that milk; not done in time → Telegram
--                (food safety). A cleaning round with items not done is pushed too (A-23).
--   D-04         save_ops takes the time the tablet saved a queued record (p_client_at, with the tablet's clock at sending,
--                p_client_now, so a wrong tablet clock cancels out): a check queued offline keeps the time it was taken (up to
--                7 days back, never in the future); the register prints «inserito nel sistema alle …».
--   D-15         save_ops says what went wrong in Italian (duplicate, check, permission, missing record), with the step named in
--                Italian; the original database text stays in the detail for the office.
--   A-08/D-29    two tablets offline that both started «L…-B»: the second one becomes the next free letter instead of being refused,
--                and the tablet carries the new letter over to everything it queued for that lot.
--   A-22         a process step confirmed without measuring no longer writes the target as the curd pH, and never erases a measured one.

-- ============================================================================================================================
-- 1. Follow-ups are tasks too (one generic on-demand schedule, details on the task itself)
-- ============================================================================================================================
alter table fabula.task_instances
  add column if not exists title_it text,
  add column if not exists scan text,
  add column if not exists followup_kind text,
  add column if not exists control_point_id uuid references fabula.haccp_control_points(id),
  add column if not exists milk_intake_id uuid references fabula.milk_intake(id),
  add column if not exists source_log_id uuid references fabula.haccp_log(id),
  add column if not exists alerted_at timestamptz;
do $mig$ begin
  if not exists (select 1 from pg_constraint where conname = 'task_instances_followup_kind_check') then
    alter table fabula.task_instances add constraint task_instances_followup_kind_check check (followup_kind in ('recheck', 'milk_start'));
  end if;
end $mig$;
comment on column fabula.task_instances.followup_kind is 'v0.97 (audit A-15): recheck = re-read a cold room within the hour; milk_start = warm milk into the vat within 2 hours';
-- the daily schedules stay one per (schedule, time); follow-ups may share a time
alter table fabula.task_instances drop constraint if exists task_instances_schedule_id_due_at_key;
create unique index if not exists task_instances_schedule_due_uq on fabula.task_instances (schedule_id, due_at) where followup_kind is null;
create index if not exists task_instances_followup_idx on fabula.task_instances (followup_kind, status) where followup_kind is not null;

insert into fabula.task_schedules (code, title_it, title_en, frequency, active, grace_minutes)
values ('T-FOLLOW', 'Ricontrollo dopo una registrazione fuori norma', 'Follow-up check after an out-of-range record', 'on_demand', true, 0)
on conflict (code) do nothing;

-- ============================================================================================================================
-- 2. The open-task view: overdue is computed now (not once a day), today vs earlier, follow-up details
-- ============================================================================================================================
create or replace view fabula.v_tasks_open with (security_invoker = true) as
 select ti.id,
    ti.due_at,
    case when ti.status = 'due' and ti.due_at + make_interval(mins => coalesce(s.grace_minutes, 120)) < now() then 'overdue'::fabula.task_status
         else ti.status end as status,
    s.code,
    coalesce(ti.title_it, s.title_it) as title_it,
    s.title_en,
    s.assigned_role,
    coalesce(e.code, fe.code) as equipment_code,
    coalesce(cp.code, fcp.code) as control_point_code,
    s.form_code,
    coalesce(s.control_point_id, ti.control_point_id) as control_point_id,
    coalesce(s.equipment_id, fcp.equipment_id) as equipment_id,
    ti.scan,
    ti.followup_kind,
    (ti.due_at at time zone 'Europe/Rome')::date as due_day,
    (ti.due_at at time zone 'Europe/Rome')::date = (now() at time zone 'Europe/Rome')::date as is_today
   from fabula.task_instances ti
     join fabula.task_schedules s on s.id = ti.schedule_id
     left join fabula.equipment e on e.id = s.equipment_id
     left join fabula.haccp_control_points cp on cp.id = s.control_point_id
     left join fabula.haccp_control_points fcp on fcp.id = ti.control_point_id
     left join fabula.equipment fe on fe.id = fcp.equipment_id
  where ti.status = any (array['due'::fabula.task_status, 'overdue'::fabula.task_status])
  order by ti.due_at;

-- tasks still open after 7 days are closed as not done (they stay in the history with the reason), so the list does not fill up
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.generate_daily_tasks(date)'::regprocedure);
  n := replace(d, E'  return n;\nend', E'  -- v0.97 (audit A-05): a task still open after 7 days is closed as not done, with the reason\n'
    || E'  update fabula.task_instances set status = ''skipped'', skip_reason = ''Non registrata entro 7 giorni: chiusa in automatico'', completed_at = now()\n'
    || E'   where status in (''due'', ''overdue'') and due_at < now() - interval ''7 days'';\n  return n;\nend');
  if n = d then raise exception 'v097a: generate_daily_tasks pattern not found'; end if;
  execute n;
end $mig$;

-- ============================================================================================================================
-- 3. A check closes the task whose time has come (A-05) and keeps the time it was done (D-04)
-- ============================================================================================================================
drop function if exists fabula.close_open_task(date, text, uuid, uuid, uuid, uuid);
create or replace function fabula.close_open_task(p_day date, p_code text default null, p_equipment_id uuid default null,
  p_control_point_id uuid default null, p_staff_id uuid default null, p_scan_event_id uuid default null, p_at timestamptz default null)
returns uuid language plpgsql set search_path = fabula, public as $$
declare v_id uuid; v_at timestamptz := coalesce(p_at, now()); v_from timestamptz;
begin
  if p_code is null and p_equipment_id is null and p_control_point_id is null then return null; end if;
  if v_at > now() + interval '5 minutes' or v_at < now() - interval '7 days' then v_at := now(); end if;   -- a wrong tablet clock
  v_from := coalesce(p_day, (v_at at time zone 'Europe/Rome')::date)::timestamp at time zone 'Europe/Rome';
  select ti.id into v_id from fabula.task_instances ti join fabula.task_schedules ts on ts.id = ti.schedule_id
   where ti.status in ('due', 'overdue') and ti.followup_kind is null and ti.due_at >= v_from and ti.due_at < v_from + interval '1 day'
     and (p_code is null or ts.code = p_code) and (p_equipment_id is null or ts.equipment_id = p_equipment_id)
     and (p_control_point_id is null or ts.control_point_id = p_control_point_id)
     -- v0.97 (audit A-05): with more than one task of that kind in the day (cold rooms morning and evening) a check closes only one
     -- whose time has come (from 3 hours before it): an extra re-check at 10:00 leaves the evening reading on the list
     and (ti.due_at - interval '3 hours' <= v_at
          or (select count(*) from fabula.task_instances t2 where t2.schedule_id = ti.schedule_id and t2.followup_kind is null
                 and t2.due_at >= v_from and t2.due_at < v_from + interval '1 day') = 1)
   order by (v_at between ti.due_at - interval '3 hours' and ti.due_at + interval '6 hours') desc, ti.due_at
   limit 1;
  if v_id is null then return null; end if;
  update fabula.task_instances set status = 'done', completed_at = v_at, completed_by_id = coalesce(p_staff_id, fabula.my_staff_id()),
         scan_event_id = coalesce(p_scan_event_id, scan_event_id)
   where id = v_id;
  return v_id;
end $$;
revoke all on function fabula.close_open_task(date, text, uuid, uuid, uuid, uuid, timestamptz) from public, anon;
grant execute on function fabula.close_open_task(date, text, uuid, uuid, uuid, uuid, timestamptz) to authenticated, service_role;

-- «Non fatta»: an honest «not done» with the reason, instead of a task that stays on the list for ever
create or replace function fabula.skip_task(p_task_id uuid, p_reason text, p_staff_id uuid default null)
returns jsonb language plpgsql security definer set search_path = fabula, public as $$
declare t record;
begin
  perform fabula.require_perm('comune', 2);
  if length(trim(coalesce(p_reason, ''))) < 3 then raise exception 'Scrivi perché non è stata fatta' using errcode = '22023'; end if;
  select ti.id, ti.status, coalesce(ti.title_it, s.title_it) title into t
    from fabula.task_instances ti join fabula.task_schedules s on s.id = ti.schedule_id where ti.id = p_task_id for update of ti;
  if t.id is null then raise exception 'Attività non trovata' using errcode = 'P0002'; end if;
  if t.status not in ('due', 'overdue') then raise exception 'Questa attività è già chiusa' using errcode = '22023'; end if;
  update fabula.task_instances set status = 'skipped', skip_reason = trim(p_reason), completed_at = now(),
         completed_by_id = coalesce(p_staff_id, fabula.my_staff_id())
   where id = p_task_id;
  return jsonb_build_object('ok', true, 'title', t.title);
end $$;
revoke all on function fabula.skip_task(uuid, text, uuid) from public, anon;
grant execute on function fabula.skip_task(uuid, text, uuid) to authenticated, service_role;

-- ============================================================================================================================
-- 4. Follow-ups (A-15): created by an out-of-range reading or a warm delivery, closed by what they ask for
-- ============================================================================================================================
create or replace function fabula.trg_haccp_followup()
returns trigger language plpgsql security definer set search_path = fabula, public as $$
declare cp record; v_eq text; v_due timestamptz; v_sched uuid := (select id from fabula.task_schedules where code = 'T-FOLLOW');
begin
  begin
    -- a new reading of the same control point closes the re-check it was asked for (not a paper line older than the first reading)
    update fabula.task_instances ti set status = 'done', completed_at = new.logged_at, completed_by_id = new.operator_id, haccp_log_id = new.id
     where ti.followup_kind = 'recheck' and ti.control_point_id = new.control_point_id and ti.status in ('due', 'overdue')
       and new.logged_at > coalesce((select l.logged_at from fabula.haccp_log l where l.id = ti.source_log_id), '-infinity'::timestamptz);
    select c.code, c.name, c.unit, c.equipment_id into cp from fabula.haccp_control_points c where c.id = new.control_point_id;
    -- a cold room in its alert band or over its limit: read it again within the hour (only for a reading of the last 3 hours)
    if cp.code like 'CCP-COLD-%' and new.result in ('warning', 'non_conformity') and new.measured_value is not null
       and new.logged_at > now() - interval '3 hours' and v_sched is not null then
      select code into v_eq from fabula.equipment where id = coalesce(new.equipment_id, cp.equipment_id);
      v_due := new.logged_at + interval '1 hour';
      insert into fabula.task_instances (schedule_id, due_at, title_it, scan, followup_kind, control_point_id, source_log_id)
      values (v_sched, v_due, format('Ricontrolla %s entro le %s (era %s %s)', cp.name, to_char(v_due at time zone 'Europe/Rome', 'HH24:MI'),
                                     fabula._it_num(new.measured_value), coalesce(cp.unit, '')),
              case when v_eq is not null then 'EQ:' || v_eq else 'CCP:' || cp.code end, 'recheck', new.control_point_id, new.id);
    end if;
    -- end-of-shift cleaning with items not done (A-23): the HACCP responsible hears it now
    if cp.code = 'PRP-CLEAN' and new.result = 'warning' then
      perform fabula.notify_enqueue('food_safety', 'Sanificazione di fine turno non completa',
        concat_ws(E'\n', new.corrective_action, coalesce('Registrata da ' || new.operator, null), 'Autocontrollo → Registro (MOD-06)'),
        'Autocontrollo', 'haccp_log', new.id::text, 'clean:' || new.id);
    end if;
  exception when others then raise warning 'follow-up (haccp_log %): %', new.id, sqlerrm;
  end;
  return null;
end $$;
revoke all on function fabula.trg_haccp_followup() from public, anon, authenticated;
drop trigger if exists haccp_log_followup on fabula.haccp_log;
create trigger haccp_log_followup after insert on fabula.haccp_log for each row execute function fabula.trg_haccp_followup();

-- a reading corrected later («Correggi», audit D-02) that is no longer out of range: its re-check is not needed any more
create or replace function fabula.trg_haccp_followup_corrected()
returns trigger language plpgsql security definer set search_path = fabula, public as $$
begin
  if new.result = 'ok' and old.result is distinct from 'ok' then
    update fabula.task_instances set status = 'skipped', skip_reason = 'Valore corretto: non più fuori norma', completed_at = now()
     where followup_kind = 'recheck' and source_log_id = new.id and status in ('due', 'overdue');
  end if;
  return null;
end $$;
revoke all on function fabula.trg_haccp_followup_corrected() from public, anon, authenticated;
drop trigger if exists haccp_log_followup_corrected on fabula.haccp_log;
create trigger haccp_log_followup_corrected after update of result on fabula.haccp_log for each row execute function fabula.trg_haccp_followup_corrected();

create or replace function fabula.trg_milk_followup()
returns trigger language plpgsql security definer set search_path = fabula, public as $$
declare v_warn numeric; v_at timestamptz; v_due timestamptz; v_sched uuid := (select id from fabula.task_schedules where code = 'T-FOLLOW');
begin
  begin
    if tg_op = 'INSERT' then
      select warn_max into v_warn from fabula.haccp_control_points where code = 'CCP-MILK-TEMP';
      if new.accepted is not false and new.temperature_c is not null and v_warn is not null and new.temperature_c > v_warn and v_sched is not null then
        v_at := coalesce((new.intake_date + new.intake_time) at time zone 'Europe/Rome', new.created_at, now());
        v_due := v_at + interval '2 hours';
        if v_due > now() - interval '1 hour' then        -- not for a paper sheet copied in hours later
          insert into fabula.task_instances (schedule_id, due_at, title_it, scan, followup_kind, milk_intake_id)
          values (v_sched, v_due, format('Metti in caldaia il latte %s entro le %s (arrivato a %s °C)', new.milk_lot,
                                         to_char(v_due at time zone 'Europe/Rome', 'HH24:MI'), fabula._it_num(new.temperature_c)),
                  'LOT:' || new.milk_lot, 'milk_start', new.id);
        end if;
      end if;
    elsif new.accepted is false and old.accepted is distinct from false then
      update fabula.task_instances set status = 'skipped', skip_reason = 'Latte respinto', completed_at = now()
       where milk_intake_id = new.id and followup_kind = 'milk_start' and status in ('due', 'overdue');
    elsif new.temperature_c is distinct from old.temperature_c
          and new.temperature_c <= (select warn_max from fabula.haccp_control_points where code = 'CCP-MILK-TEMP') then
      update fabula.task_instances set status = 'skipped', skip_reason = 'Temperatura corretta: non più sopra l''allerta', completed_at = now()
       where milk_intake_id = new.id and followup_kind = 'milk_start' and status in ('due', 'overdue');
    end if;
  exception when others then raise warning 'follow-up (milk_intake %): %', new.id, sqlerrm;
  end;
  return null;
end $$;
revoke all on function fabula.trg_milk_followup() from public, anon, authenticated;
drop trigger if exists milk_intake_followup on fabula.milk_intake;
create trigger milk_intake_followup after insert or update of accepted, temperature_c on fabula.milk_intake for each row execute function fabula.trg_milk_followup();

create or replace function fabula.trg_batch_input_followup()
returns trigger language plpgsql security definer set search_path = fabula, public as $$
begin
  update fabula.task_instances set status = 'done', completed_at = now(),
         completed_by_id = (select casaro_id from fabula.production_batches where id = new.batch_id)
   where followup_kind = 'milk_start' and milk_intake_id = new.milk_intake_id and status in ('due', 'overdue');
  return null;
end $$;
revoke all on function fabula.trg_batch_input_followup() from public, anon, authenticated;
drop trigger if exists batch_milk_inputs_followup on fabula.batch_milk_inputs;
create trigger batch_milk_inputs_followup after insert on fabula.batch_milk_inputs for each row execute function fabula.trg_batch_input_followup();

-- every 5 minutes: a follow-up past its time is pushed once to food safety (HACCP responsible, who is on shift, subscribers)
create or replace function fabula.followup_tick()
returns int language plpgsql security definer set search_path = fabula, public as $$
declare t record; n int := 0;
begin
  for t in select ti.id, ti.title_it, ti.followup_kind from fabula.task_instances ti
            where ti.followup_kind is not null and ti.status in ('due', 'overdue') and ti.alerted_at is null
              and ti.due_at < now() and ti.due_at > now() - interval '1 day'
            order by ti.due_at for update skip locked loop
    begin
      perform fabula.notify_enqueue('food_safety', left('Non fatto in tempo: ' || coalesce(t.title_it, 'ricontrollo'), 160),
        case t.followup_kind
          when 'recheck' then 'La temperatura della cella era fuori norma e il ricontrollo non è stato registrato. Controlla la cella e registra la temperatura sul tablet.'
          else 'Il latte è arrivato caldo e doveva andare in caldaia entro 2 ore (CCP 1a). Avvia il lotto o decidi con il responsabile HACCP cosa farne.' end,
        'Autocontrollo', 'task_instances', t.id::text, 'fu:' || t.id);
    exception when others then raise warning 'followup_tick %: %', t.id, sqlerrm;
    end;
    update fabula.task_instances set alerted_at = now() where id = t.id;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function fabula.followup_tick() from public, anon, authenticated;
grant execute on function fabula.followup_tick() to service_role;
do $mig$ begin
  if exists (select 1 from cron.job where jobname = 'fabula_followup_tick') then perform cron.unschedule('fabula_followup_tick'); end if;
  perform cron.schedule('fabula_followup_tick', '*/5 * * * *', $c$select fabula.followup_tick()$c$);
end $mig$;

-- ============================================================================================================================
-- 5. D-04: a check saved offline keeps the time it was taken
-- ============================================================================================================================
-- log_ccp (the version with p_logged_at): besides the paper copy, a time from the tablet up to 7 days back is kept; created_at keeps
-- when it arrived. Nothing else changes: the 7-argument version and log_milk_check pass now().
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.log_ccp(text,numeric,timestamp with time zone,uuid,text,text,text,text,text)'::regprocedure);
  n := replace(d, E'    v_at := p_logged_at;\n  end if;',
    E'    v_at := p_logged_at;\n'
    || E'  -- v0.97 (audit D-04): a check saved on the tablet without network keeps the time it was taken (created_at = when it arrived)\n'
    || E'  elsif p_logged_at is not null and p_logged_at < now() - interval ''2 minutes'' and p_logged_at > now() - interval ''7 days'' then\n'
    || E'    v_at := p_logged_at;\n  end if;');
  if n = d then raise exception 'v097a: log_ccp time pattern not found'; end if;
  execute n;
end $mig$;

-- log_batch_step: the time of the step (offline), and a step confirmed without measuring (p_actual null) never writes or erases the
-- curd pH / stretching temperature (A-22)
drop function if exists fabula.log_batch_step(text, uuid, numeric, uuid, text);
create or replace function fabula.log_batch_step(p_batch_lot text, p_step_id uuid, p_actual numeric, p_staff_id uuid default null,
  p_note text default null, p_at timestamptz default null)
returns text language plpgsql set search_path = fabula, public, extensions as $$
declare b record; s fabula.process_steps%rowtype; v_target numeric;
        v_at timestamptz := case when p_at is not null and p_at < now() - interval '2 minutes' and p_at > now() - interval '7 days' then p_at else now() end;
begin
  select id, preset_id into b from fabula.production_batches where batch_lot = p_batch_lot;
  select * into s from fabula.process_steps where id = p_step_id;
  if b.id is null or s.id is null then raise exception 'Lotto o passo sconosciuto: % / %', p_batch_lot, p_step_id; end if;
  v_target := case s.record_metric when 'temp' then s.target_temp_c when 'duration' then s.duration_min when 'ph' then s.target_ph when 'speed' then s.speed else null end;
  insert into fabula.batch_step_logs (batch_id, step_id, step_name, metric, target_value, actual_value, staff_id, note, logged_at)
  values (b.id, s.id, s.name_it, s.record_metric, v_target, p_actual, p_staff_id, p_note, v_at)
  -- a step confirmed again without measuring keeps the measured value, its time and who measured it
  on conflict (batch_id, step_id) do update set actual_value = coalesce(excluded.actual_value, fabula.batch_step_logs.actual_value),
     logged_at = case when excluded.actual_value is not null or fabula.batch_step_logs.actual_value is null then excluded.logged_at else fabula.batch_step_logs.logged_at end,
     staff_id = case when excluded.actual_value is not null or fabula.batch_step_logs.actual_value is null then coalesce(excluded.staff_id, fabula.batch_step_logs.staff_id) else fabula.batch_step_logs.staff_id end,
     note = coalesce(excluded.note, fabula.batch_step_logs.note);
  -- keep the legacy summary columns on the batch in step with the log (only a measured value)
  if p_actual is not null and s.record_metric = 'ph' and s.phase = 'make' then update fabula.production_batches set curd_ph = p_actual where id = b.id; end if;
  if p_actual is not null and s.record_metric = 'temp' and s.equipment_id = (select id from fabula.equipment where code = 'FIL-01') then update fabula.production_batches set stretch_temp_c = p_actual where id = b.id; end if;
  if b.preset_id is null then update fabula.production_batches set preset_id = s.preset_id where id = b.id; end if;
  return 'logged';
end $$;
revoke all on function fabula.log_batch_step(text, uuid, numeric, uuid, text, timestamptz) from public, anon;
grant execute on function fabula.log_batch_step(text, uuid, numeric, uuid, text, timestamptz) to authenticated, service_role;

-- a CCP recorded as a process step (pasteurisation in the start sequence) gets the step's time too
create or replace function fabula.trg_step_log_ccp()
returns trigger language plpgsql set search_path = fabula, public, extensions as $$
declare v_ccp text; v_lot text;
begin
  select ccp_code into v_ccp from fabula.process_steps where id = new.step_id;
  if v_ccp is null or new.actual_value is null then return new; end if;
  if tg_op = 'UPDATE' and old.actual_value is not distinct from new.actual_value then return new; end if;
  select batch_lot into v_lot from fabula.production_batches where id = new.batch_id;
  perform fabula.log_ccp(p_cp_code => v_ccp, p_value => new.actual_value, p_logged_at => new.logged_at, p_staff_id => new.staff_id,
                         p_batch_lot => v_lot, p_action => new.note, p_source => 'preset');
  return new;
end $$;

-- the CCP register prints when an offline record arrived
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.haccp_register(text,date,date)'::regprocedure);
  n := replace(d, $s$case when l.correction_note is not null then 'CORREZIONE: ' || l.correction_note end),$s$,
                  $s$case when l.correction_note is not null then 'CORREZIONE: ' || l.correction_note end,
                     case when l.source <> 'paper' and l.created_at > l.logged_at + interval '2 minutes' then 'inserito nel sistema alle ' || to_char(l.created_at at time zone 'Europe/Rome', 'DD/MM HH24:MI') end),$s$);
  if n = d then raise exception 'v097a: haccp_register offline pattern not found'; end if;
  execute n;
end $mig$;

-- ============================================================================================================================
-- 6. A-08 / D-29: a lot letter already taken by another tablet becomes the next free letter (only for a new row)
-- ============================================================================================================================
create or replace function fabula.trg_batch_lot_free()
returns trigger language plpgsql security definer set search_path = fabula, public as $$
declare v_pre text := left(new.batch_lot, 10); v_new text;
begin
  if new.batch_lot !~ '^L[0-9]{8}-[A-Z]$' then return new; end if;
  perform pg_advisory_xact_lock(hashtext('batch_lot:' || v_pre));        -- first: two tablets starting at the same moment wait for each other
  if not exists (select 1 from fabula.production_batches where batch_lot = new.batch_lot and id is distinct from new.id) then return new; end if;
  if exists (select 1 from fabula.production_batches where id = new.id) then return new; end if;   -- the same row sent again: refused on its id as before
  for c in 65 .. 90 loop
    if not exists (select 1 from fabula.production_batches where batch_lot = v_pre || chr(c)) then v_new := v_pre || chr(c); exit; end if;
  end loop;
  if v_new is null then
    raise exception 'Tutte le lettere dei lotti del % sono già usate (da A a Z): chiama l''ufficio', to_char(to_date(substr(v_pre, 2, 8), 'YYYYMMDD'), 'DD/MM') using errcode = '23505';
  end if;
  new.notes := concat_ws(' · ', nullif(new.notes, ''), format('Avviato sul tablet come %s, lettera già usata da un altro lotto: diventato %s', new.batch_lot, v_new));
  new.batch_lot := v_new;
  return new;
end $$;
revoke all on function fabula.trg_batch_lot_free() from public, anon, authenticated;
drop trigger if exists batch_lot_free on fabula.production_batches;
create trigger batch_lot_free before insert on fabula.production_batches for each row execute function fabula.trg_batch_lot_free();

-- ============================================================================================================================
-- 7. save_ops: the time the tablet saved it (D-04) and Italian errors (D-15)
-- ============================================================================================================================
drop function if exists fabula.save_ops(jsonb, uuid);
create or replace function fabula.save_ops(p_ops jsonb, p_qid uuid default null, p_client_at timestamptz default null, p_client_now timestamptz default null)
returns jsonb language plpgsql set search_path = fabula, public as $$
declare
  c_tables constant text[] := array['scan_events','milk_intake','labels','production_batches','batch_milk_inputs','stock_moves',
                                    'haccp_log','meter_readings','effluent_log','shipments','shipment_lines','waste_log','batch_step_logs'];
  c_rpcs constant text[] := array['log_ccp','receive_purchase_order','record_receipt_check','close_open_task','start_byproduct_batch',
                                  'log_batch_step','record_batch_consumable','log_milk_check','badge_in','badge_out'];
  v_n int := jsonb_array_length(p_ops);
  v_out jsonb := '[]';
  -- v0.97 (audit D-04): a save queued on the tablet more than 2 minutes ago (no network) keeps the time it was made. With the
  -- tablet's clock at sending (p_client_now) only the age counts, so a tablet clock that is off by minutes or days does not move it.
  v_cat timestamptz := case when p_client_at is null then null when p_client_now is null then p_client_at else now() - (p_client_now - p_client_at) end;
  v_late boolean := v_cat is not null and v_cat < now() - interval '2 minutes' and v_cat > now() - interval '7 days';
  v_prev jsonb; v_op jsonb; v_args jsonb; v_row jsonb; v_res jsonb; v_t text; v_cols text; v_where text; v_argl text; v_cnt int;
  v_proc oid; v_label text;
begin
  if jsonb_typeof(p_ops) is distinct from 'array' or v_n = 0 then raise exception 'save_ops: nessun passo' using errcode = '22023'; end if;
  if v_n > 50 then raise exception 'save_ops: troppi passi (%)', v_n using errcode = '22023'; end if;
  if p_qid is not null then
    perform pg_advisory_xact_lock(hashtextextended('save_ops:' || p_qid::text, 0));   -- a parallel re-send waits, then finds the ledger row
    v_prev := fabula.save_ledger_get(p_qid);
    if v_prev is not null then return v_prev -> 'result'; end if;
  end if;

  for k in 0 .. v_n - 1 loop
    v_op := p_ops -> k;
    v_label := coalesce(v_op ->> 'table', v_op ->> 'rpc', '?');
    begin
      if v_op ? 'rpc' then
        if not (v_op ->> 'rpc' = any (c_rpcs)) then raise exception 'funzione non ammessa: %', v_op ->> 'rpc' using errcode = '42501'; end if;
        v_args := coalesce(v_op -> 'args', '{}');
        if v_late and v_op ->> 'rpc' in ('log_ccp', 'log_milk_check') and not v_args ? 'p_logged_at' and coalesce(v_args ->> 'p_source', 'tablet') <> 'paper' then
          v_args := v_args || jsonb_build_object('p_logged_at', v_cat);
        elsif v_late and v_op ->> 'rpc' in ('close_open_task', 'log_batch_step') and not v_args ? 'p_at' then
          v_args := v_args || jsonb_build_object('p_at', v_cat);
        end if;
        select p.oid into v_proc from pg_proc p
         where p.pronamespace = 'fabula'::regnamespace and p.proname = v_op ->> 'rpc' and not p.proretset
           and not exists (select 1 from jsonb_object_keys(v_args) a(name)
                            where not (a.name = any (coalesce(p.proargnames, '{}'))))
         order by p.pronargs limit 1;
        if v_proc is null then raise exception 'funzione % con questi argomenti non trovata', v_op ->> 'rpc' using errcode = '42883'; end if;
        v_row := fabula.save_resolve(v_args, v_out);
        select string_agg(format('%I => %s', u.name,
                 case when t.typname in ('json', 'jsonb') then format('($1 -> %L)::%s', u.name, format_type(t.oid, null))
                      when t.typcategory = 'A' then format('array(select jsonb_array_elements_text($1 -> %L))::%s', u.name, format_type(t.oid, null))
                      else format('($1 ->> %L)::%s', u.name, format_type(t.oid, null)) end), ', ' order by u.i)
          into v_argl
          from pg_proc p
          cross join lateral unnest(p.proargnames[1:p.pronargs], p.proargtypes::oid[]) with ordinality u(name, typ, i)
          join pg_type t on t.oid = u.typ
         where p.oid = v_proc and v_row ? u.name;
        execute format('select to_jsonb(fabula.%I(%s))', v_op ->> 'rpc', coalesce(v_argl, '')) using v_row into v_res;

      elsif v_op ? 'table' then
        v_t := v_op ->> 'table';
        if not (v_t = any (c_tables)) then raise exception 'tabella non ammessa: %', v_t using errcode = '42501'; end if;
        v_row := fabula.save_resolve(coalesce(v_op -> 'row', '{}'), v_out);
        if v_late and v_t = 'haccp_log' and not (v_op ? 'update') and not v_row ? 'logged_at' then
          v_row := v_row || jsonb_build_object('logged_at', v_cat);             -- the cleaning round saved offline
        end if;
        select string_agg(format('%I', c.column_name), ', ' order by c.ordinal_position) into v_cols
          from information_schema.columns c
         where c.table_schema = 'fabula' and c.table_name = v_t and c.is_generated <> 'ALWAYS' and v_row ? c.column_name;
        if v_op ? 'update' then
          if v_t <> 'production_batches' then raise exception 'Le registrazioni (%) non si modificano: usa «Correggi»', v_t using errcode = '42501'; end if;   -- v0.96a (audit D-02)
          select string_agg(format('x.%I is not distinct from (jsonb_populate_record(null::fabula.%I, $2)).%I', c.column_name, v_t, c.column_name), ' and ')
            into v_where
            from information_schema.columns c
           where c.table_schema = 'fabula' and c.table_name = v_t and (v_op -> 'update') ? c.column_name;
          if v_where is null or (select count(*) from jsonb_object_keys(v_op -> 'update')) <>
                                (select count(*) from information_schema.columns c where c.table_schema = 'fabula' and c.table_name = v_t and (v_op -> 'update') ? c.column_name) then
            raise exception 'aggiornamento senza chiave valida' using errcode = '22023';
          end if;
          if v_cols is null then raise exception 'aggiornamento senza campi' using errcode = '22023'; end if;
          execute format('with u as (update fabula.%I x set (%s) = (select %s from jsonb_populate_record(null::fabula.%I, $1)) where %s returning x.*) '
                         'select (select to_jsonb(u) from u limit 1), (select count(*) from u)', v_t, v_cols, v_cols, v_t, v_where)
            using v_row, fabula.save_resolve(v_op -> 'update', v_out) into v_res, v_cnt;
          if v_cnt <> 1 then raise exception 'atteso 1 record da aggiornare in %, trovati %', v_t, v_cnt using errcode = 'P0002'; end if;
        else
          if v_cols is null then
            execute format('insert into fabula.%I as x default values returning to_jsonb(x.*)', v_t) into v_res;
          else
            execute format('insert into fabula.%I as x (%s) select %s from jsonb_populate_record(null::fabula.%I, $1) returning to_jsonb(x.*)',
                           v_t, v_cols, v_cols, v_t) using v_row into v_res;
          end if;
        end if;
      else
        raise exception 'passo senza tabella né funzione' using errcode = '22023';
      end if;
    exception when others then
      declare v_state text; v_msg text; v_detail text; v_hint text; v_cons text; v_col text; v_it text; v_name text;
      begin
        get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text, v_detail = pg_exception_detail, v_hint = pg_exception_hint,
                                v_cons = constraint_name, v_col = column_name;
        v_cons := nullif(v_cons, ''); v_col := nullif(v_col, '');           -- empty, not null, when the error names none
        -- v0.97 (audit D-15): what went wrong, in Italian and with the step's Italian name; the database text stays in the detail
        v_name := case v_label
          when 'scan_events' then 'scansione' when 'milk_intake' then 'arrivo latte' when 'labels' then 'etichetta'
          when 'production_batches' then 'lotto di produzione' when 'batch_milk_inputs' then 'latte messo in caldaia' when 'stock_moves' then 'magazzino'
          when 'haccp_log' then 'registro HACCP' when 'meter_readings' then 'contatore' when 'effluent_log' then 'reflui' when 'shipments' then 'spedizione'
          when 'shipment_lines' then 'riga di spedizione' when 'waste_log' then 'scarti' when 'batch_step_logs' then 'passo di lavorazione'
          when 'log_ccp' then 'controllo HACCP' when 'log_milk_check' then 'controllo del latte' when 'receive_purchase_order' then 'arrivo merce'
          when 'record_receipt_check' then 'controllo all''arrivo' when 'close_open_task' then 'attività del giorno' when 'start_byproduct_batch' then 'avvio ricotta'
          when 'log_batch_step' then 'passo di lavorazione' when 'record_batch_consumable' then 'dosaggio' when 'badge_in' then 'inizio turno'
          when 'badge_out' then 'fine turno' else v_label end;
        -- only the database's own English messages are replaced: the guards' messages are already Italian and say more
        v_it := case
          when v_state = '23505' and v_msg ~* 'duplicate key' then
            case when v_cons = 'production_batches_batch_lot_key' then 'Questo lotto esiste già nel database'
                 when v_cons = 'labels_code_key' then 'L''etichetta di questo lotto esiste già: il lotto risulta già chiuso o il latte già registrato'
                 when v_cons like '%\_pkey' then 'Questa registrazione è già nel database (inviata due volte)'
                 else 'Registrazione già presente (doppione)' end
          when v_state = '23514' and v_msg ~* 'violates check constraint' then
            coalesce((select obj_description(c.oid, 'pg_constraint') from pg_constraint c where c.conname = v_cons and c.connamespace = 'fabula'::regnamespace limit 1),
                     'Valore fuori dai limiti ammessi: controlla i numeri')
          when v_state = '23502' and v_msg ~* 'null value' then format('Manca un dato obbligatorio (%s)', coalesce(v_col, '?'))
          when v_state = '23503' and v_msg ~* 'foreign key' then 'Manca la registrazione da cui dipende (forse era stata rifiutata): avvisa l''ufficio'
          when v_state = '22003' and v_msg ~* 'overflow|out of range' then 'Numero troppo grande: controlla le cifre'
          when v_state in ('22P02', '22007', '22008') and v_msg ~* 'invalid|out of range' then 'Valore non valido: controlla numeri, date e ore'
          when v_state = '42501' and v_msg ~* 'row-level security|permission denied' then format('Il tuo profilo non può registrare questo (%s): chiedi al responsabile', v_name)
          when v_state = 'P0002' and v_op ->> 'table' = 'production_batches' and v_msg like 'atteso 1 record%' then 'Il lotto non è nel database (forse il suo avvio era stato rifiutato): avvisa l''ufficio'
          else v_msg end;
        raise exception '%', format('Passo %s di %s (%s): %s', k + 1, v_n, v_name, v_it)
          using errcode = v_state, detail = concat_ws(' · ', case when v_it is distinct from v_msg then v_msg end, nullif(v_detail, '')), hint = coalesce(v_hint, '');
      end;
    end;
    v_out := v_out || jsonb_build_array(coalesce(v_res, 'null'::jsonb));
  end loop;

  -- the ledger keeps only the ids written (the tablet doesn't use the rows), so it stays small
  if p_qid is not null then perform fabula.save_ledger_put(p_qid, v_n, (select coalesce(jsonb_agg(e -> 'id'), '[]') from jsonb_array_elements(v_out) e)); end if;
  return v_out;
end $$;
revoke all on function fabula.save_ops(jsonb, uuid, timestamptz, timestamptz) from public, anon;
grant execute on function fabula.save_ops(jsonb, uuid, timestamptz, timestamptz) to authenticated, service_role;

-- ============================================================================================================================
-- 8. The new definer function checks the caller inside: accepted in the evening security check
-- ============================================================================================================================
insert into fabula.security_accepted (key, reason, accepted_at) values
 ('authenticated_security_definer_function_executable:fabula.skip_task(p_task_id uuid, p_reason text, p_staff_id uuid)',
  'by design (v0.97a, audit A-05): require_perm(comune, 2); only an open task, with a reason; sets it skipped', now())
on conflict (key) do update set reason = excluded.reason, accepted_at = excluded.accepted_at;
