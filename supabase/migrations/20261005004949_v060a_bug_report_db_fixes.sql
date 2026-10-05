-- v0.60a (05/10/2026) · database fixes from the 04/10 bug report (tablet support, HACCP permissions, marketing, sales, recipes, advisors)
-- Every statement is create-or-replace / alter / idempotent DDL; no data is changed.

-- 1. Tablet: close today's task with one RPC (queued when offline, for the Agropoli day it was done). Same rights as before (RLS).
create or replace function fabula.close_open_task(p_day date, p_code text default null, p_equipment_id uuid default null, p_control_point_id uuid default null,
                                                  p_staff_id uuid default null, p_scan_event_id uuid default null)
returns uuid language plpgsql set search_path = fabula, public as $$
declare v_id uuid; v_from timestamptz := (coalesce(p_day, (now() at time zone 'Europe/Rome')::date)::timestamp at time zone 'Europe/Rome');
begin
  if p_code is null and p_equipment_id is null and p_control_point_id is null then return null; end if;
  select ti.id into v_id from fabula.task_instances ti join fabula.task_schedules ts on ts.id = ti.schedule_id
   where ti.status in ('due', 'overdue') and ti.due_at >= v_from and ti.due_at < v_from + interval '1 day'
     and (p_code is null or ts.code = p_code) and (p_equipment_id is null or ts.equipment_id = p_equipment_id)
     and (p_control_point_id is null or ts.control_point_id = p_control_point_id)
   order by ti.due_at limit 1;
  if v_id is null then return null; end if;
  update fabula.task_instances set status = 'done', completed_at = now(), completed_by_id = coalesce(fabula.my_staff_id(), p_staff_id), scan_event_id = coalesce(p_scan_event_id, scan_event_id)
   where id = v_id;
  return v_id;
end $$;
revoke execute on function fabula.close_open_task(date, text, uuid, uuid, uuid, uuid) from public, anon;
grant execute on function fabula.close_open_task(date, text, uuid, uuid, uuid, uuid) to authenticated, service_role;

-- "In turno" on the tablet: names and hours only, for any active staff member (floor profiles have personale = 0, so v_open_shifts was empty)
create or replace function fabula.floor_open_shifts()
returns table (full_name text, hours_so_far numeric) language sql stable security definer set search_path = fabula, public as $$
  select st.full_name, round(extract(epoch from now() - s.clock_in) / 3600.0, 1)
    from fabula.shifts s join fabula.staff st on st.id = s.staff_id
   where s.clock_out is null and (fabula.my_staff_id() is not null or auth.uid() is null)
   order by s.clock_in
$$;
revoke execute on function fabula.floor_open_shifts() from public, anon;
grant execute on function fabula.floor_open_shifts() to authenticated, service_role;

-- 2. Pest-control visit / deadlines: complete_deadline() updated 0 rows for HACCP level-2 users (table needs level 3) and the visit rolled back.
CREATE OR REPLACE FUNCTION fabula.complete_deadline(p_id uuid, p_on date DEFAULT ((now() AT TIME ZONE 'Europe/Rome'::text))::date, p_note text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'fabula', 'public', 'extensions'
AS $function$
declare d record; v_new uuid;
begin
  perform fabula.require_perm('haccp', 2);   -- v0.60: runs as definer so HACCP level 2 (pest-control visit) can close a deadline
  update fabula.compliance_deadlines set done_on = p_on, done_note = p_note where id = p_id and done_on is null returning * into d;
  if d is null then raise exception 'Scadenza non trovata o già chiusa: %', p_id; end if;
  if d.interval_days is not null then
    insert into fabula.compliance_deadlines (kind, subject_it, due_on, interval_days, responsible, contact, notes)
    values (d.kind, d.subject_it, p_on + d.interval_days, d.interval_days, d.responsible, d.contact, d.notes) returning id into v_new;
  end if;
  return v_new;
end $function$;
revoke execute on function fabula.complete_deadline(uuid, date, text) from public, anon;
grant execute on function fabula.complete_deadline(uuid, date, text) to authenticated, service_role;

-- 3. Releasing a held lot: manager-only in the database too, and signed by the logged-in person (p_staff_id could be spoofed).
CREATE OR REPLACE FUNCTION fabula.release_lot_hold(p_lot text, p_staff_id uuid, p_note text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'fabula', 'public', 'extensions'
AS $function$
begin
  perform fabula.require_perm('haccp', 3);   -- v0.60: only HACCP managers release a lot, also through the API
  if coalesce(trim(p_note), '') = '' then raise exception 'Serve una motivazione (es. esito analisi conforme, valutazione del consulente)'; end if;
  update fabula.production_batches set food_safety_hold = false, hold_released_at = now(), hold_released_by_id = case when auth.uid() is not null then fabula.my_staff_id() else p_staff_id end,   -- a user can't sign as someone else
        
         notes = concat_ws(E'\n', notes, format('[%s] sblocco: %s', to_char(now() at time zone 'Europe/Rome', 'DD/MM HH24:MI'), p_note))
  where batch_lot = p_lot and food_safety_hold;
  if not found then raise exception 'Lotto % non bloccato', p_lot; end if;
  return 'released';
end $function$;
revoke execute on function fabula.release_lot_hold(text, uuid, text) from public, anon;
grant execute on function fabula.release_lot_hold(text, uuid, text) to authenticated, service_role;

-- 4. Closing (or reopening) a non-conformity: HACCP managers only, signed by the logged-in person
create or replace function fabula.trg_nc_close_guard() returns trigger language plpgsql security definer set search_path = fabula, public as $$
begin
  if auth.uid() is null then return new; end if;                 -- bots / SQL
  if (new.status = 'closed') is distinct from (old.status = 'closed') then
    perform fabula.require_perm('haccp', 3);
    if new.status = 'closed' then new.closed_by_id := fabula.my_staff_id(); new.closed_at := now();
    else new.closed_by_id := null; new.closed_at := null; end if;
  elsif new.closed_by_id is distinct from old.closed_by_id then
    new.closed_by_id := old.closed_by_id;
  end if;
  return new;
end $$;
revoke execute on function fabula.trg_nc_close_guard() from public, anon, authenticated;
do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'nc_close_guard' and tgrelid = 'fabula.non_conformities'::regclass) then
    create trigger nc_close_guard before update on fabula.non_conformities for each row execute function fabula.trg_nc_close_guard();
  end if;
end $$;

-- 5. Marketing: editing an approved post keeps it approved even when the new text fails the claims check
CREATE OR REPLACE FUNCTION fabula.mkt_content_before()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'fabula', 'public', 'extensions'
AS $function$
declare v_ai boolean; v_appr uuid;
begin
  select coalesce(bool_or(ai_generated), false) into v_ai from fabula.mkt_assets where id = any(new.asset_ids);
  new.claims := fabula.mkt_check_claims(concat_ws(' ', new.caption_it, new.caption_en, new.hashtags), new.collab_id is not null or new.pillar = 'collab', v_ai);
  new.claims_blocking := (select count(*) from jsonb_array_elements(new.claims) e where e->>'severity' = 'block');
  new.updated_at := now();
  -- v0.60: an approved/scheduled post whose text or media changes goes back to review when the new text fails the claims check
  -- or the editor can't approve marketing content; it used to stay approved
  if tg_op = 'UPDATE' and old.status in ('approved', 'scheduled') and new.status = old.status
     and (new.caption_it, new.caption_en, new.hashtags, new.asset_ids) is distinct from (old.caption_it, old.caption_en, old.hashtags, old.asset_ids)
     and (new.claims_blocking > 0 or (auth.uid() is not null and not fabula.can('marketing', 3))) then
    new.status := 'review'; new.approved_by := null;
  end if;
  if new.status = 'review' and (tg_op = 'INSERT' or old.status is distinct from 'review') then
    insert into fabula.approvals (kind, requested_by, summary, payload, related_table, related_id, expires_at)
    values ('other', 'agent:marketing',
            format('Post %s %s%s: %s', new.platform, coalesce(to_char(new.scheduled_at at time zone 'Europe/Rome', 'DD/MM HH24:MI'), 'senza data'),
                   case when new.claims_blocking > 0 then format(' · ⚠ %s da correggere', new.claims_blocking) else '' end,
                   left(coalesce(new.caption_it, new.brief_it, ''), 90)),
            jsonb_build_object('type', 'content_post', 'content_id', new.id, 'platform', new.platform, 'caption_it', new.caption_it, 'claims', new.claims),
            'mkt_content', new.id, coalesce(new.scheduled_at, now() + interval '7 days'))
    returning id into v_appr;
    new.approval_id := v_appr;
  end if;
  return new;
end $function$;

-- 6. Predis drafts: media duplicated when the webhook and "Recupera bozze" both completed the job
CREATE OR REPLACE FUNCTION fabula.mkt_ai_complete(p_external_id text, p_status text, p_caption text, p_media jsonb, p_raw jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'fabula', 'public'
AS $function$
declare j fabula.mkt_ai_jobs%rowtype; m text; v_ids uuid[] := '{}'; v_id uuid;
begin
  select * into j from fabula.mkt_ai_jobs where p_external_id = any(external_ids) order by created_at desc limit 1;
  if j.id is null then return jsonb_build_object('ok', false, 'reason', 'job sconosciuto'); end if;
  -- v0.60: the webhook and "Recupera bozze" can both deliver the same job: the second call adds nothing
  if j.status = 'completed' and p_status = 'completed' then return jsonb_build_object('ok', true, 'job', j.id, 'content', j.content_id, 'assets', 0, 'already', true); end if;
  if p_status = 'completed' then
    for m in select jsonb_array_elements_text(coalesce(p_media, '[]')) loop
      select id into v_id from fabula.mkt_assets where url = m and source = 'predis' limit 1;
      if v_id is null then
        insert into fabula.mkt_assets (kind, url, source, ai_generated, consent_ok, hygiene_ok, caption, tags)
        values (case when m ~* '\.(mp4|mov|webm)' then 'video' else 'graphic' end, m, 'predis', true, true, false, p_caption, array['predis', p_external_id])
        returning id into v_id;
      end if;
      if not v_id = any(v_ids) then v_ids := v_ids || v_id; end if;
    end loop;
    update fabula.mkt_ai_jobs set status = 'completed', response = coalesce(response, '[]'::jsonb) || coalesce(p_raw, '{}'::jsonb), completed_at = now() where id = j.id;
    update fabula.mkt_content set status = case when status = 'generating' then 'draft' else status end,
           caption_it = coalesce(caption_it, p_caption), asset_ids = asset_ids || array(select x from unnest(v_ids) x where not x = any(asset_ids)) where id = j.content_id;
  else
    update fabula.mkt_ai_jobs set status = 'error', error = coalesce(p_raw::text, 'errore'), completed_at = now() where id = j.id;
    update fabula.mkt_content set status = 'idea' where id = j.content_id and status = 'generating';
  end if;
  return jsonb_build_object('ok', true, 'job', j.id, 'content', j.content_id, 'assets', coalesce(array_length(v_ids, 1), 0));
end $function$;
