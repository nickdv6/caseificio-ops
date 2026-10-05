-- v0.77a (05/10/2026) · Trial week: an evening check of what each trial day actually recorded.
-- Set trial.start (Configurazione → Parametri, AAAA-MM-GG) to day 1 of the trial week; trial.days = 5.
-- fabula.trial_check(day) lists every step expected that day (the daily routine + that day's extra steps from the
-- "Settimana di prova" script) with ✓/✗ and what the database holds. fabula.trial_report() runs every evening at
-- 20:35 Rome during the trial and posts the list to the bell as "Zia Carmela · Settimana di prova"; outside the trial
-- week it does nothing. Read-only apart from the message.

insert into fabula.settings (key, value, description, data_type, sort, updated_at) values
 ('trial.start', '', 'Primo giorno della settimana di prova (AAAA-MM-GG). Vuoto = nessuna prova in corso', 'text', 95, now()),
 ('trial.days', '5', 'Giorni della settimana di prova', 'number', 95, now())
on conflict (key) do nothing;

insert into fabula.bot_nicknames (agent, nickname, title_it, sort, updated_at)
values ('prova', 'Zia Carmela', 'Settimana di prova', coalesce((select max(sort) + 1 from fabula.bot_nicknames), 50), now())
on conflict (agent) do nothing;

create or replace function fabula.trial_check(p_day date default (now() at time zone 'Europe/Rome')::date) returns jsonb
language plpgsql stable security definer set search_path = fabula, public as $$
declare
  v_start date := nullif((select value from fabula.settings where key = 'trial.start'), '')::date;
  v_n int; v_dayno int; steps jsonb := '[]';
  a int; b int; c int; t text;
  v_from timestamptz := (p_day::timestamp at time zone 'Europe/Rome');
  v_to timestamptz := ((p_day + 1)::timestamp at time zone 'Europe/Rome');
begin
  v_dayno := case when v_start is null then null else p_day - v_start + 1 end;

  -- milk
  select count(*), count(*) filter (where temperature_c is null), coalesce(sum(qty_kg), 0) into a, b, c
    from fabula.milk_intake where intake_date = p_day and accepted and coalesce(source, '') <> 'simulation';
  steps := steps || jsonb_build_object('step', 'Latte ricevuto e accettato (con temperatura)', 'ok', a > 0 and b = 0,
           'detail', case when a = 0 then 'nessun conferimento registrato' else a || ' conferimenti · ' || c || ' kg' || case when b > 0 then ' · ' || b || ' senza temperatura' else '' end end);
  select count(*) into a from fabula.haccp_log l join fabula.haccp_control_points cp on cp.id = l.control_point_id
   where cp.code = 'CCP-MILK-ABX' and l.logged_at >= v_from and l.logged_at < v_to;
  steps := steps || jsonb_build_object('step', 'Test antibiotici sul latte (CCP 1b, MOD-01)', 'ok', a > 0, 'detail', a || ' registrazioni');

  -- pasteuriser
  select count(*) into a from fabula.haccp_log l join fabula.haccp_control_points cp on cp.id = l.control_point_id
   where cp.code = 'PRP-PAST-VALVE' and l.logged_at >= v_from and l.logged_at < v_to;
  steps := steps || jsonb_build_object('step', 'Pastorizzatore: verifica di inizio giornata (MOD-02)', 'ok', a > 0, 'detail', a || ' registrazioni');
  select count(*) into a from fabula.haccp_log l join fabula.haccp_control_points cp on cp.id = l.control_point_id
   where cp.code = 'CCP-PAST' and l.logged_at >= v_from and l.logged_at < v_to;
  steps := steps || jsonb_build_object('step', 'Pastorizzazione registrata (CCP 2, MOD-02)', 'ok', a > 0, 'detail', a || ' registrazioni');

  -- batches
  select count(*), count(*) filter (where output_kg is not null and finished_at is not null), count(*) filter (where yield_flag is not null),
         string_agg(batch_lot || ' resa ' || yield_flag, ', ') filter (where yield_flag is not null)
    into a, b, c, t
    from fabula.production_batches where batch_date = p_day and coalesce(source, '') <> 'simulation' and input_kind = 'milk';
  steps := steps || jsonb_build_object('step', 'Lotti di mozzarella avviati e chiusi', 'ok', a > 0 and a = b,
           'detail', case when a = 0 then 'nessun lotto' else a || ' avviati · ' || b || ' chiusi' || case when c > 0 then ' · resa fuori norma: ' || t else '' end end);
  select count(*), count(*) filter (where not exists (select 1 from fabula.haccp_log l join fabula.haccp_control_points cp on cp.id = l.control_point_id
                                                       where l.batch_id = pb.id and cp.code = 'CCP-STRETCH')),
         string_agg(pb.batch_lot, ', ') filter (where not exists (select 1 from fabula.haccp_log l join fabula.haccp_control_points cp on cp.id = l.control_point_id
                                                                  where l.batch_id = pb.id and cp.code = 'CCP-STRETCH'))
    into a, b, t
    from fabula.production_batches pb where pb.batch_date = p_day and coalesce(pb.source, '') <> 'simulation' and pb.input_kind = 'milk';
  steps := steps || jsonb_build_object('step', 'Temperatura pasta filata su ogni lotto (CCP 3, MOD-03)', 'ok', a > 0 and b = 0,
           'detail', case when a = 0 then 'nessun lotto' when b = 0 then 'tutti i ' || a || ' lotti' else 'manca su: ' || t end);

  -- cold rooms, cleaning
  select count(*) filter (where cp.code = 'CCP-COLD-1'), count(*) filter (where cp.code = 'CCP-COLD-2') into a, b
    from fabula.haccp_log l join fabula.haccp_control_points cp on cp.id = l.control_point_id
   where cp.code in ('CCP-COLD-1', 'CCP-COLD-2') and l.logged_at >= v_from and l.logged_at < v_to;
  steps := steps || jsonb_build_object('step', 'Temperature celle, 2 volte al giorno (CCP 5, MOD-05)', 'ok', a >= 2 and b >= 2, 'detail', 'cella 1: ' || a || ' · cella 2: ' || b);
  select count(*) into a from fabula.haccp_log l join fabula.haccp_control_points cp on cp.id = l.control_point_id
   where cp.code = 'PRP-CLEAN' and l.logged_at >= v_from and l.logged_at < v_to;
  steps := steps || jsonb_build_object('step', 'Sanificazione di fine turno (MOD-06)', 'ok', a > 0, 'detail', a || ' registrazioni');

  -- out of limit handled
  select count(*), count(*) filter (where coalesce(corrective_action, '') = '') into a, b
    from fabula.haccp_log where result <> 'ok' and logged_at >= v_from and logged_at < v_to;
  steps := steps || jsonb_build_object('step', 'Ogni valore fuori limite ha la sua azione correttiva', 'ok', b = 0,
           'detail', case when a = 0 then 'nessun valore fuori limite' else a || ' fuori limite · ' || b || ' senza azione' end);

  -- tasks left open
  select count(*), string_agg(s.title_it, ', ' order by ti.due_at) into a, t
    from fabula.task_instances ti join fabula.task_schedules s on s.id = ti.schedule_id
   where ti.status in ('due', 'overdue') and ti.due_at >= v_from and ti.due_at < v_to;
  steps := steps || jsonb_build_object('step', 'Attività del giorno chiuse', 'ok', a = 0, 'detail', case when a = 0 then 'tutte chiuse' else a || ' aperte: ' || left(t, 200) end);

  -- tablets
  select count(*) into a from fabula.tablet_rejects where resolved_at is null;
  select count(*) into b from fabula.devices where queue_len > 0 and oldest_queued_at < now() - interval '2 hours';
  steps := steps || jsonb_build_object('step', 'Tablet: nulla in attesa, nessuna registrazione rifiutata', 'ok', a = 0 and b = 0,
           'detail', a || ' rifiutate da sistemare · ' || b || ' tablet con registrazioni ferme da oltre 2 ore');

  -- bots
  select count(*), string_agg(distinct agent, ', ') into a, t from fabula.agent_runs where status = 'error' and started_at >= v_from and started_at < v_to;
  steps := steps || jsonb_build_object('step', 'Nessun errore dei bot', 'ok', a = 0, 'detail', case when a = 0 then 'nessuno' else a || ': ' || t end);

  -- extra steps of the script, by trial day
  if v_dayno = 1 then
    select count(*) into a from fabula.stock_counts where status = 'posted' and counted_at < v_to;
    steps := steps || jsonb_build_object('step', 'Giorno 1 · conta di magazzino iniziale confermata', 'ok', a > 0, 'detail', a || ' conte confermate');
    select count(*) into a from fabula.devices where last_seen_at >= v_from and app_version = fabula.live_app_version();
    steps := steps || jsonb_build_object('step', 'Giorno 1 · tablet di produzione collegato, app aggiornata', 'ok', a > 0, 'detail', a || ' dispositivi oggi');
  elsif v_dayno = 2 then
    select count(*) into a from fabula.production_batches where batch_date = p_day and input_kind = 'whey' and coalesce(source, '') <> 'simulation';
    steps := steps || jsonb_build_object('step', 'Giorno 2 · ricotta dal siero', 'ok', a > 0, 'detail', a || ' lotti di ricotta');
    select count(*) into a from fabula.haccp_log l join fabula.haccp_control_points cp on cp.id = l.control_point_id
     where cp.code = 'CCP-RIC' and l.logged_at >= v_from and l.logged_at < v_to;
    steps := steps || jsonb_build_object('step', 'Giorno 2 · temperatura di affioramento ricotta (CCP 4, MOD-04)', 'ok', a > 0, 'detail', a || ' registrazioni');
  elsif v_dayno = 3 then
    select count(*), string_agg(coalesce(ddt_number, '?'), ', ') into a, t from fabula.shipments where packed_at >= v_from and packed_at < v_to;
    steps := steps || jsonb_build_object('step', 'Giorno 3 · ordine preparato da "Da spedire" con DDT', 'ok', a > 0, 'detail', case when a = 0 then 'nessuna spedizione' else a || ' · DDT ' || t end);
    select count(*) into a from fabula.sales_orders where order_date = p_day and coalesce(source, '') <> 'simulation';
    steps := steps || jsonb_build_object('step', 'Giorno 3 · vendite del giorno registrate', 'ok', a > 0, 'detail', a || ' ordini o scontrini');
  elsif v_dayno = 4 then
    select count(*) into a from fabula.haccp_log where source = 'paper' and created_at >= v_from and created_at < v_to;
    steps := steps || jsonb_build_object('step', 'Giorno 4 · registrazione da foglio di carta ricopiata sul tablet', 'ok', a > 0, 'detail', a || ' ricopiate');
    select count(*) into a from fabula.lab_samples s join fabula.lab_tests lt on lt.id = s.test_id where lt.code = 'MOZ-DOP' and s.taken_on = p_day;
    steps := steps || jsonb_build_object('step', 'Giorno 4 · campione MOZ-DOP per il laboratorio (umidità)', 'ok', a > 0, 'detail', a || ' campioni');
  elsif v_dayno = 5 then
    select count(*) into a from fabula.recall_drills where run_at >= v_from and run_at < v_to;
    steps := steps || jsonb_build_object('step', 'Giorno 5 · prova di richiamo su un lotto (MOD-14)', 'ok', a > 0, 'detail', a || ' prove');
    select count(*) into a from fabula.haccp_register_reviews where reviewed_at >= v_from and reviewed_at < v_to;
    steps := steps || jsonb_build_object('step', 'Giorno 5 · registri della settimana stampati e verificati', 'ok', a > 0, 'detail', a || ' registri verificati');
  end if;

  select count(*) filter (where (x->>'ok')::boolean), count(*) into a, b from jsonb_array_elements(steps) x;
  return jsonb_build_object('day', p_day, 'trial_day', v_dayno, 'ok', a, 'total', b, 'steps', steps);
end $$;
revoke all on function fabula.trial_check(date) from public, anon;
grant execute on function fabula.trial_check(date) to authenticated, service_role;

-- every evening during the trial (20:35 Rome, both DST offsets scheduled; runs once)
create or replace function fabula.trial_report(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = fabula, public as $$
declare v_day date := (p_now at time zone 'Europe/Rome')::date; v_start date := nullif((select value from fabula.settings where key = 'trial.start'), '')::date;
        r jsonb; v_title text; v_body text;
begin
  if v_start is null or v_day < v_start or v_day >= v_start + fabula.setting_num('trial.days', 5)::int then return jsonb_build_object('skipped', 'no trial today'); end if;
  if extract(hour from p_now at time zone 'Europe/Rome') <> 20 then return jsonb_build_object('skipped', 'not 20:xx in Rome'); end if;
  r := fabula.trial_check(v_day);
  v_title := format('Prova giorno %s (%s): %s di %s passaggi ok', r->>'trial_day', to_char(v_day, 'DD/MM'), r->>'ok', r->>'total');
  if exists (select 1 from fabula.bot_messages where agent = 'prova' and title = v_title) then return jsonb_build_object('skipped', 'already posted'); end if;
  select string_agg(case when (x->>'ok')::boolean then '✓ ' else '✗ ' end || (x->>'step') || ' — ' || (x->>'detail'), E'\n') into v_body from jsonb_array_elements(r->'steps') x;
  v_body := v_body || E'\n\n' || case when (r->>'ok') = (r->>'total') then 'Giornata completa.' else 'Le righe con ✗ vanno sistemate domattina o spiegate nella riunione di fine prova.' end
            || ' Il programma della settimana è nel documento "Settimana di prova".';
  perform fabula.post_bot_message('prova', case when (r->>'ok') = (r->>'total') then 'info' else 'warn' end, v_title, v_body);
  return r;
end $$;
revoke all on function fabula.trial_report(timestamptz) from public, anon, authenticated;

select cron.schedule('fabula_trial_report', '35 18,19 * * *', $c$select fabula.trial_report()$c$);

insert into fabula.security_accepted (key, reason, accepted_at) values
 ('authenticated_security_definer_function_executable:fabula.trial_check(p_day date)',
  'by design: read-only trial-week checklist (v0.77); counts only, no row data beyond lot numbers, DDT numbers and task titles', now())
on conflict (key) do nothing;
