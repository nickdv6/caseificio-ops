-- v0.80a (06/10/2026) · Production floor guard rails.
-- 1. v_process_steps also returns ccp_code: the tablet makes CCP steps (pasteurisation, stretching, ricotta) ask for the
--    measured value instead of a one-tap "Fatto" that recorded the target as if measured, and never lets them be skipped.
-- 2. batch_ccp_check (constraint trigger, at commit): a batch closed with no CCP record (mozzarella: CCP 2 pasteurisation and
--    CCP 3 stretching; ricotta: CCP 4) posts an alert from Zio Ciro · Resa produzione. Deferred, so a CCP logged in the same
--    save as the close counts.
-- 3. fabula.prod_watch() at 19:45 Rome: batches still open from today or earlier, and accepted milk with kg left that is
--    48 h or more old (the disciplinare allows 60 h from milking) post one warning a day.

create or replace view fabula.v_process_steps with (security_invoker = true) as
 SELECT s.id AS step_id,
    s.preset_id,
    p.name AS preset_name,
    p.is_default,
    p.active AS preset_active,
    p.product_id,
    pr.sku AS product_sku,
    pr.name AS product_name,
    s.phase,
    s.step_order,
    s.name_it,
    s.equipment_id,
    e.code AS equipment_code,
    e.name AS equipment_name,
    s.target_temp_c,
    s.temp_min_c,
    s.temp_max_c,
    s.duration_min,
    s.duration_min_min,
    s.duration_max_min,
    s.speed,
    s.speed_unit,
    s.target_ph,
    s.ph_min,
    s.ph_max,
    s.extra,
    s.instruction_it,
    s.record_metric,
    s.active,
    NULLIF(concat_ws(' · '::text,
        CASE
            WHEN (s.target_temp_c IS NOT NULL) THEN ((replace((s.target_temp_c)::text, '.'::text, ','::text) || ' °C'::text) ||
            CASE
                WHEN ((s.temp_min_c IS NOT NULL) AND (s.temp_max_c IS NOT NULL)) THEN ((((' ('::text || replace((s.temp_min_c)::text, '.'::text, ','::text)) || '–'::text) || replace((s.temp_max_c)::text, '.'::text, ','::text)) || ')'::text)
                ELSE ''::text
            END)
            ELSE NULL::text
        END,
        CASE
            WHEN (s.duration_min IS NOT NULL) THEN ((replace((s.duration_min)::text, '.'::text, ','::text) || ' min'::text) ||
            CASE
                WHEN ((s.duration_min_min IS NOT NULL) AND (s.duration_max_min IS NOT NULL)) THEN ((((' ('::text || (s.duration_min_min)::text) || '–'::text) || (s.duration_max_min)::text) || ')'::text)
                ELSE ''::text
            END)
            ELSE NULL::text
        END,
        CASE
            WHEN (s.speed IS NOT NULL) THEN (('vel. '::text || replace((s.speed)::text, '.'::text, ','::text)) || COALESCE((' '::text || s.speed_unit), ''::text))
            ELSE NULL::text
        END,
        CASE
            WHEN (s.target_ph IS NOT NULL) THEN (('pH '::text || replace((s.target_ph)::text, '.'::text, ','::text)) ||
            CASE
                WHEN ((s.ph_min IS NOT NULL) AND (s.ph_max IS NOT NULL)) THEN ((((' ('::text || replace((s.ph_min)::text, '.'::text, ','::text)) || '–'::text) || replace((s.ph_max)::text, '.'::text, ','::text)) || ')'::text)
                ELSE ''::text
            END)
            ELSE NULL::text
        END, ( SELECT string_agg(((jsonb_each_text.key || ': '::text) || jsonb_each_text.value), ' · '::text) AS string_agg
           FROM jsonb_each_text(s.extra) jsonb_each_text(key, value))), ''::text) AS target_txt,
    s.ccp_code
   FROM (((fabula.process_steps s
     JOIN fabula.process_presets p ON ((p.id = s.preset_id)))
     JOIN fabula.products pr ON ((pr.id = p.product_id)))
     LEFT JOIN fabula.equipment e ON ((e.id = s.equipment_id)));

create or replace function fabula.trg_batch_ccp_check() returns trigger
language plpgsql security definer set search_path = fabula, public as $$
declare v_missing text[] := '{}'; v_need text[];
begin
  v_need := case when new.input_kind = 'whey' then array['CCP-RIC'] else array['CCP-PAST', 'CCP-STRETCH'] end;
  select coalesce(array_agg(c order by c), '{}') into v_missing from unnest(v_need) c
   where not exists (select 1 from fabula.haccp_log l join fabula.haccp_control_points cp on cp.id = l.control_point_id
                      where l.batch_id = new.id and cp.code = c);
  if cardinality(v_missing) > 0 and coalesce(new.source, '') not in ('simulation', 'test') then
    perform fabula.post_bot_message('produzione', 'alert',
      format('Lotto %s chiuso senza %s', new.batch_lot,
             array_to_string(array(select case m when 'CCP-PAST' then 'pastorizzazione (CCP 2)' when 'CCP-STRETCH' then 'temperatura di filatura (CCP 3)' else 'temperatura di affioramento (CCP 4)' end from unnest(v_missing) m), ' e ')),
      format(E'Il lotto %s è stato chiuso ma nel registro HACCP manca: %s.\nSe la misura è stata fatta su carta, ricopiala dal tablet (🛡 → Ricopia da foglio di carta) con data e ora del foglio. Se non è stata fatta, il lotto va valutato con il responsabile HACCP prima della vendita.',
             new.batch_lot, array_to_string(v_missing, ', ')));
  end if;
  return null;
end $$;
revoke all on function fabula.trg_batch_ccp_check() from public, anon, authenticated;
do $$ begin
  if not exists (select 1 from pg_trigger where tgrelid = 'fabula.production_batches'::regclass and tgname = 'batch_ccp_check') then
    create constraint trigger batch_ccp_check after update of output_kg on fabula.production_batches
      deferrable initially deferred for each row
      when (old.output_kg is null and new.output_kg is not null)
      execute function fabula.trg_batch_ccp_check();
  end if;
end $$;

create or replace function fabula.prod_watch(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = fabula, public as $$
declare v_day date := (p_now at time zone 'Europe/Rome')::date; v_open text; v_milk text; n_open int; n_milk int; v_title text;
begin
  if extract(hour from p_now at time zone 'Europe/Rome') <> 19 then return jsonb_build_object('skipped', 'not 19:xx in Rome'); end if;
  select count(*), string_agg(batch_lot || ' (' || to_char(coalesce(started_at, batch_date::timestamptz) at time zone 'Europe/Rome', 'DD/MM HH24:MI') || ')', ', ' order by batch_lot)
    into n_open, v_open
    from fabula.production_batches where output_kg is null and batch_date <= v_day and coalesce(source, '') not in ('simulation', 'test');
  select count(*), string_agg(format('%s: %s kg, arrivato %s', m.milk_lot, trim_scale(m.left_kg), to_char(m.arrived at time zone 'Europe/Rome', 'DD/MM HH24:MI')), E'\n• ' order by m.arrived)
    into n_milk, v_milk
    from (select mi.milk_lot, ((mi.intake_date + coalesce(mi.intake_time, time '07:00')) at time zone 'Europe/Rome') arrived,
                 mi.qty_kg - coalesce((select sum(bmi.qty_kg) from fabula.batch_milk_inputs bmi where bmi.milk_intake_id = mi.id), 0) left_kg
            from fabula.milk_intake mi where mi.accepted and coalesce(mi.source, '') <> 'simulation' and mi.intake_date >= v_day - 5) m
   where m.left_kg > 1 and m.arrived <= p_now - interval '48 hours';
  if n_open = 0 and n_milk = 0 then return jsonb_build_object('open_batches', 0, 'old_milk', 0); end if;
  v_title := format('Produzione %s: %s', to_char(v_day, 'DD/MM'), concat_ws(' · ', case when n_open > 0 then n_open || ' lott' || case when n_open = 1 then 'o aperto' else 'i aperti' end end,
                                                                     case when n_milk > 0 then n_milk || ' latte vicino alle 60 ore' end));
  if exists (select 1 from fabula.bot_messages where agent = 'produzione' and title = v_title) then return jsonb_build_object('skipped', 'already posted'); end if;
  perform fabula.post_bot_message('produzione', 'warn', v_title,
    concat_ws(E'\n\n',
      case when n_open > 0 then format(E'Lotti avviati e non chiusi:\n• %s\nSe sono finiti, scansiona l''etichetta sul tank e chiudili con i kg; se sono stati scartati, registra lo scarto.', replace(v_open, ', ', E'\n• ')) end,
      case when n_milk > 0 then format(E'Latte accettato e non ancora lavorato da 48 ore o più (il disciplinare DOP consente 60 ore dalla mungitura):\n• %s\nLavoralo domattina per primo o non usarlo per la DOP.', v_milk) end));
  return jsonb_build_object('open_batches', n_open, 'old_milk', n_milk);
end $$;
revoke all on function fabula.prod_watch(timestamptz) from public, anon, authenticated;

select cron.schedule('fabula_prod_watch', '45 17,18 * * *', $c$select fabula.prod_watch()$c$);
