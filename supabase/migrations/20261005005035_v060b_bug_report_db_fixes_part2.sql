-- v0.60b (05/10/2026) · database fixes from the 04/10 bug report, part 2 (marketing, sales, recipes, advisors, backups, users, settings)

-- 7. Marketing weekly status: "Preordini" counted a multi-product order once per product
CREATE OR REPLACE FUNCTION fabula.mkt_weekly_status(p_from date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'fabula', 'public', 'extensions'
AS $function$
  with d as (select coalesce(p_from, (now() at time zone 'Europe/Rome')::date) d0)
  select jsonb_build_object(
    'from', d0, 'to', d0 + 6,
    'content_next_7d', (select coalesce(jsonb_agg(jsonb_build_object('when', to_char(scheduled_at at time zone 'Europe/Rome','DY DD/MM HH24:MI'), 'platform', platform, 'pillar', pillar, 'status', status,
                         'no_asset', cardinality(asset_ids) = 0, 'blocking', claims_blocking, 'text', left(coalesce(caption_it, brief_it, ''), 80)) order by scheduled_at), '[]')
                        from fabula.mkt_content where scheduled_at >= d0 and scheduled_at < d0 + 7),
    'content_gaps', 7 - (select count(distinct (scheduled_at at time zone 'Europe/Rome')::date) from fabula.mkt_content where scheduled_at >= d0 and scheduled_at < d0 + 7 and status <> 'rejected'),
    'to_review', (select count(*) from fabula.mkt_content where status = 'review'),
    'ai_jobs_stuck', (select count(*) from fabula.mkt_ai_jobs where status in ('queued','in_progress') and created_at < now() - interval '2 hours'),
    'influencers_follow_up', (select coalesce(jsonb_agg(jsonb_build_object('name', name, 'handle', handle, 'status', status, 'last_contact', last_contact_on, 'next', next_action)), '[]')
                              from fabula.mkt_influencers where status in ('contacted','negotiating','gifted') and (last_contact_on is null or last_contact_on < d0 - 7)),
    'collabs_missing_disclosure', (select count(*) from fabula.mkt_collabs where post_url is not null and disclosure_ok is not true),
    'codes', (select coalesce(jsonb_agg(to_jsonb(p) order by p.revenue_eur desc), '[]') from fabula.v_mkt_code_performance p where p.orders > 0),
    'channels_30d', (select coalesce(jsonb_agg(to_jsonb(c) order by c.revenue_eur desc), '[]') from fabula.v_mkt_channel_sales_30d c),
    'pickups_next_7d', (select coalesce(jsonb_agg(jsonb_build_object('date', pickup_date, 'orders', orders, 'kg', kg) order by pickup_date), '[]')
                        from (select o.pickup_date, count(distinct o.id) orders, round(sum(l.qty), 2) kg   -- v0.60: orders counted once, not once per product
                                from fabula.sales_orders o join fabula.sales_order_lines l on l.sales_order_id = o.id
                               where o.fulfilment_kind = 'pickup' and o.status = 'confirmed' and o.pickup_date between d0 and d0 + 6 group by 1) x),
    'channels_not_live', (select coalesce(jsonb_agg(name order by sort), '[]') from fabula.mkt_channels where status <> 'live'),
    'budget', jsonb_build_object('year_eur', fabula.setting_num('opex.marketing_eur_year', 15900),
                                 'campaigns_budget_eur', (select coalesce(sum(budget_eur), 0) from fabula.mkt_campaigns where status <> 'cancelled'),
                                 'spent_eur', (select coalesce(sum(spent_eur), 0) from fabula.mkt_campaigns) + (select coalesce(sum(fee_eur + product_value_eur), 0) from fabula.mkt_collabs)))
  from d $function$;

-- 8. Sales: new leads always started as "nuovo" (sales_add_lead ignored stage)
CREATE OR REPLACE FUNCTION fabula.sales_add_lead(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'fabula', 'public'
AS $function$
declare v_id uuid; v_exists uuid;
begin
  perform fabula.require_perm('vendite', 2);
  if coalesce(trim(p->>'name'), '') = '' then raise exception 'name obbligatorio'; end if;
  select id into v_exists from fabula.sales_leads where lower(name) = lower(trim(p->>'name')) and lower(coalesce(town, '')) = lower(coalesce(trim(p->>'town'), ''));
  if v_exists is not null then return jsonb_build_object('id', v_exists, 'created', false, 'reason', 'già presente'); end if;
  if exists (select 1 from fabula.parties where active and lower(coalesce(trade_name, legal_name)) = lower(trim(p->>'name'))) then
    return jsonb_build_object('created', false, 'reason', 'già cliente');
  end if;
  insert into fabula.sales_leads (name, segment, town, address, phone, email, website, instagram, fit_note, size_hint, current_supplier,
                                  source, source_url, priority, est_kg_week, next_action, next_action_date, notes, stage)
  values (trim(p->>'name'), coalesce(p->>'segment', 'ristorante'), nullif(p->>'town', ''), nullif(p->>'address', ''), nullif(p->>'phone', ''),
          nullif(p->>'email', ''), nullif(p->>'website', ''), nullif(p->>'instagram', ''), nullif(p->>'fit_note', ''), nullif(p->>'size_hint', ''),
          nullif(p->>'current_supplier', ''), coalesce(nullif(p->>'source', ''), 'manuale'), nullif(p->>'source_url', ''),
          coalesce((p->>'priority')::smallint, 2), nullif(p->>'est_kg_week', '')::numeric,
          coalesce(nullif(p->>'next_action', ''), 'Primo contatto (WhatsApp o visita)'),
          coalesce(nullif(p->>'next_action_date', '')::date, (now() at time zone 'Europe/Rome')::date + 2), nullif(p->>'notes', ''),
          coalesce(nullif(p->>'stage', ''), 'nuovo'))   -- v0.60: the stage chosen in the form is kept
  returning id into v_id;
  return jsonb_build_object('id', v_id, 'created', true);
end $function$;

-- 9. Recipes: an instruction could not be cleared ('' now clears it; null keeps it)
CREATE OR REPLACE FUNCTION fabula.update_recipe_dose(p_recipe_id uuid, p_qty numeric, p_round_up boolean DEFAULT NULL::boolean, p_instruction text DEFAULT NULL::text, p_step_order integer DEFAULT NULL::integer, p_notes text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'fabula', 'public', 'extensions'
AS $function$
declare r fabula.recipes%rowtype; v_id uuid; d date := (now() at time zone 'Europe/Rome')::date;
begin
  select * into r from fabula.recipes where id = p_recipe_id;
  if r.id is null then raise exception 'Ricetta non trovata'; end if;
  if p_qty is null or p_qty <= 0 then raise exception 'Dose non valida'; end if;
  if r.valid_from >= d then
    update fabula.recipes set qty_per_unit = p_qty, round_up = coalesce(p_round_up, round_up), instruction_it = case when p_instruction is null then instruction_it else nullif(btrim(p_instruction), '') end, step_order = coalesce(p_step_order, step_order), notes = coalesce(p_notes, notes), source = 'console' where id = r.id;
    return r.id;
  end if;
  update fabula.recipes set valid_to = d - 1 where id = r.id;
  insert into fabula.recipes (finished_product_id, component_product_id, basis, qty_per_unit, round_up, valid_from, source, notes, phase, step_order, instruction_it)
  values (r.finished_product_id, r.component_product_id, r.basis, p_qty, coalesce(p_round_up, r.round_up), d, 'console', coalesce(p_notes, r.notes), r.phase, coalesce(p_step_order, r.step_order), case when p_instruction is null then r.instruction_it else nullif(btrim(p_instruction), '') end)
  returning id into v_id;
  return v_id;
end $function$;

-- recipe editor showed the old dose after a save just after midnight (UTC current_date)
create or replace view fabula.v_recipe_editor with (security_invoker = true) as
 SELECT r.id AS recipe_id,
    f.sku AS finished_sku,
    f.name AS finished_name,
    c.id AS component_id,
    c.sku AS component_sku,
    c.name AS component_name,
    c.unit,
    r.basis::text AS basis,
    r.qty_per_unit,
    r.round_up,
    r.phase,
    r.step_order,
    r.instruction_it,
    r.valid_from,
    r.source,
    r.notes
   FROM fabula.recipes r
     JOIN fabula.products f ON f.id = r.finished_product_id
     JOIN fabula.products c ON c.id = r.component_product_id
  WHERE r.valid_from <= (now() AT TIME ZONE 'Europe/Rome'::text)::date AND (r.valid_to IS NULL OR r.valid_to >= (now() AT TIME ZONE 'Europe/Rome'::text)::date)
  ORDER BY f.sku, r.phase DESC, r.step_order, c.name;

-- 10. Advisors: pin search_path on the 5 flagged functions
alter function fabula.trg_staff_default_role() set search_path = fabula, public;
alter function fabula._it_d(date) set search_path = fabula, public;
alter function fabula._it_dt(timestamp with time zone) set search_path = fabula, public;
alter function fabula._it_num(numeric) set search_path = fabula, public;
alter function fabula._it_res(fabula.haccp_result) set search_path = fabula, public;

-- 11. Backups: each table's sort key, so the export pages through it in a stable order
create or replace function fabula.backup_table_keys()
returns jsonb language sql stable set search_path = fabula, public as $$
  select coalesce(jsonb_object_agg(t.relname, coalesce(pk.cols, allc.cols)), '{}'::jsonb)
    from pg_class t
    left join lateral (select jsonb_agg(a.attname order by array_position(i.indkey::int2[], a.attnum)) cols
                         from pg_index i join pg_attribute a on a.attrelid = i.indrelid and a.attnum = any(i.indkey)
                        where i.indrelid = t.oid and i.indisprimary) pk on true
    left join lateral (select jsonb_agg(a.attname order by a.attnum) cols from pg_attribute a
                        where a.attrelid = t.oid and a.attnum > 0 and not a.attisdropped
                          and format_type(a.atttypid, a.atttypmod) not in ('json', 'jsonb', 'bytea')) allc on true
   where t.relnamespace = 'fabula'::regnamespace and t.relkind in ('r', 'p')
$$;
revoke execute on function fabula.backup_table_keys() from public, anon, authenticated;
grant execute on function fabula.backup_table_keys() to service_role;

-- 12. Users: never leave the system without an active person who can manage users (the only titolare could demote or
--     deactivate himself in Configurazione and lock everyone out of user management)
create or replace function fabula.trg_staff_keep_admin() returns trigger language plpgsql security definer set search_path = fabula, public as $$
begin
  if not exists (select 1 from fabula.staff s join fabula.app_roles r on r.code = s.app_role where s.active and r.can_manage_users) then
    raise exception 'Serve almeno una persona attiva con un profilo che gestisce gli utenti (es. Titolare): assegnalo a qualcun altro prima di cambiare questo' using errcode = '23514';
  end if;
  return null;
end $$;
revoke execute on function fabula.trg_staff_keep_admin() from public, anon, authenticated;
do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'staff_keep_admin' and tgrelid = 'fabula.staff'::regclass) then
    create constraint trigger staff_keep_admin after update of app_role, active on fabula.staff
      deferrable initially deferred for each row execute function fabula.trg_staff_keep_admin();
  end if;
end $$;

-- 13. Marketing settings (mkt.*: Predis brand id, pickup rules…) can be saved by the Marketing profile (marketing ≥ 2);
--     before, its saves changed 0 rows. Every other setting still needs Configurazione rights.
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'fabula' and tablename = 'settings' and policyname = 'settings_marketing_write') then
    create policy settings_marketing_write on fabula.settings for update to authenticated
      using (key like 'mkt.%' and fabula.can('marketing', 2)) with check (key like 'mkt.%' and fabula.can('marketing', 2));
  end if;
end $$;
alter policy settings_role_update on fabula.settings
  using ((select fabula.can_table('settings', true)) or (key like 'mkt.%' and fabula.can('marketing', 2)));
