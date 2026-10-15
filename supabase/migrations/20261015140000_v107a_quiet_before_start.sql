-- v1.07a «Prima dell'avvio» (15/10/2026): before the dairy starts working, the bots stop asking for things nobody can do yet.
-- Found live on 15/10 (project doc claude/golive-rescore-2026-10-15.md): every day since 09/10 the milk plan proposed 1.200 kg for a
-- dairy with no building, each plan sent Nick four Telegrams (the decision, its 30-minute reminder, the expiry and a reminder of the
-- expiry), the morning brief asked for HACCP records nobody could write and the evening check said the tablet was silent. 12 of the
-- 15 Telegrams Nick got in a week were these: teaching people to ignore Telegram before the trial week is the opposite of what the
-- alerts are for.
--
-- Quiet means BOTH: the day is before the start AND nothing real is happening (fabula._real_activity: a real lot in the last 14 days,
-- real milk or a real HACCP record in the last 7, or real finished product in stock). Real work before the start is always checked
-- (food safety first), and the milk plan comes back by itself as soon as real milk or lots appear.
--   * The start: for the floor checks and the briefs, the first of «Primo giorno con le attività», the trial week and the opening
--     (fabula.quiet_until); for the milk plan, the first of the trial week and the opening (fabula.milk_start): starting the cold-room
--     tasks early does not bring back daily milk proposals before any production.
--   * Setting prod.quiet_before_start (Sì by default) switches all of it off.
--   * plan_milk(): the automatic plan (no date given: the bot, the database's stand-in, «Esegui ora») proposes nothing on a quiet day
--     and says from when it starts. A plan that already exists is still reported as such; a plan asked for a given day (tests, the
--     Console's «Ordina» on an expired plan) is still made. bot_fallback_run and the «Perché?» of the milk plan say the same.
--   * ops_health_check: no «tablet silenzioso», no «conta di magazzino» on a quiet day.
--   * daily_brief / weekly_brief: on a quiet day the HACCP checks of the day and the overdue tasks are not asked; the JSON says
--     pre_opening with the start date, and their «Perché?» shows it.
--   * _haccp_evening_items (the tablet's evening list, v1.05): before the tasks start it now stays quiet only when nothing real is
--     happening — real product in the cold rooms or worked in the last days brings the evening checks back.
--   * expire_approvals: an expired decision is news, not a decision still open: no «Nessuno se ne occupa» reminder 30 minutes later
--     (also after the opening).
--   * notify_digest_text: on Monday (the reader's day), while quiet, the morning summary has one «Verso l'apertura» block.
--   * Automatic milk plans already waiting for a quiet day are closed without a message (they would only expire with a Telegram).
-- Part b (v107b): the Shopify stock message respects selling at zero stock, and the milk planning prompt's new version.

-- ============================== the switch ==============================
insert into fabula.settings (key, value, description, data_type, kind, sort, impact_it, min_value, max_value, unit) values
  ('prod.quiet_before_start', '1',
   'Silenzio prima dell''avvio: finché il caseificio non lavora (prima della settimana di prova o del «Primo giorno con le attività», e senza latte, lotti o prodotto veri) il piano latte non propone niente, il controllo serale non chiede tablet e conta di magazzino, i brief non chiedono i controlli HACCP. Latte o lotti veri riaccendono tutto da soli. No = sempre come a caseificio aperto.',
   'number', 'flag', 41,
   'Con «No» arrivano ogni giorno il piano latte da decidere e i controlli mancanti anche a caseificio chiuso.', null, null, null)
on conflict (key) do nothing;

create or replace function fabula._real_activity(p_day date)
returns boolean language sql stable set search_path = fabula, public as $$
  -- v1.07: something real is going on around this day: a lot in the last 14 days, milk or a HACCP record in the last 7, or
  -- finished product in stock (simulation data does not count)
  select exists (select 1 from fabula.production_batches where source <> 'simulation' and batch_date between p_day - 14 and p_day)
      or exists (select 1 from fabula.milk_intake where source <> 'simulation' and intake_date between p_day - 7 and p_day)
      or exists (select 1 from fabula.haccp_log where coalesce(source, '') <> 'simulation'
                  and (logged_at at time zone 'Europe/Rome')::date between p_day - 7 and p_day)
      or coalesce((select sum(m.qty) from fabula.stock_moves m join fabula.products p on p.id = m.product_id
                    where p.kind = 'finished_good' and coalesce(m.source, '') <> 'simulation'), 0) > 0.01
$$;

create or replace function fabula.quiet_until()
returns date language sql stable set search_path = fabula, public as $$
  -- v1.07: the floor checks and the briefs wake up on the first of «Primo giorno con le attività», the trial week, the opening
  select least(fabula._setting_date('prod.tasks_from'), fabula._setting_date('trial.start'), fabula._setting_date('mkt.store_opening_date'))
$$;

create or replace function fabula.milk_start()
returns date language sql stable set search_path = fabula, public as $$
  -- v1.07: the automatic milk plan wakes up on the first of the trial week and the opening (production, not the cold-room tasks)
  select least(fabula._setting_date('trial.start'), fabula._setting_date('mkt.store_opening_date'))
$$;

create or replace function fabula.quiet_day(p_day date)
returns boolean language sql stable set search_path = fabula, public as $$
  -- v1.07: the floor checks and the briefs stay quiet on this day
  select coalesce(fabula.setting_num('prod.quiet_before_start', 1), 1) = 1
     and coalesce(p_day < fabula.quiet_until(), false) and not fabula._real_activity(p_day)
$$;

create or replace function fabula.quiet_milk_day(p_day date)
returns boolean language sql stable set search_path = fabula, public as $$
  -- v1.07: the automatic milk plan proposes nothing for this production day
  select coalesce(fabula.setting_num('prod.quiet_before_start', 1), 1) = 1
     and coalesce(p_day < fabula.milk_start(), false) and not fabula._real_activity(p_day)
$$;

comment on function fabula.quiet_day(date) is 'v1.07: true while prod.quiet_before_start is on, the day is before fabula.quiet_until() and nothing real is happening (fabula._real_activity). The evening check''s floor items and the HACCP lines of the briefs stay quiet on such a day.';
comment on function fabula.quiet_milk_day(date) is 'v1.07: like quiet_day, with the production start (fabula.milk_start(): trial week or opening): the automatic milk plan proposes nothing for such a day.';
do $g$ declare f text; begin
  foreach f in array array['fabula._real_activity(date)', 'fabula.quiet_until()', 'fabula.milk_start()', 'fabula.quiet_day(date)', 'fabula.quiet_milk_day(date)'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated, service_role', f);
  end loop;
end $g$;

-- ============================== the milk plan, the stand-in, «Perché?», the evening check, the evening list ==============================
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.plan_milk'::regproc);
  n := replace(d, $s$  select count(*), coalesce(avg(total),0), coalesce(avg(whole),0) into v_n, v_total, v_whole_hist from (
$s$, $s$  -- v1.07: before production starts and with nothing real going on, the automatic plan (no date given) proposes nothing: no approval,
  -- no Telegram, nothing on the farm page. A plan asked for a given day is still made; real milk or lots bring the plan back by themselves.
  if p_date is null and fabula.quiet_milk_day(d) then
    return jsonb_build_object('date', d, 'weekday', v_wd, 'skipped', 'pre_opening',
      'tasks_start', fabula.milk_start(),
      'first_plan_day', case when extract(isodow from fabula.milk_start()) = 7 then fabula.milk_start() + 1 else fabula.milk_start() end,
      'message_it', format('Nessun piano latte prima dell''avvio: il primo sarà per %s. Latte o lotti veri prima di allora lo riattivano da soli (Configurazione → Parametri → Produzione e latte, «Silenzio prima dell''avvio»)',
                           fabula.it_day(case when extract(isodow from fabula.milk_start()) = 7 then fabula.milk_start() + 1 else fabula.milk_start() end)));
  end if;
  select count(*), coalesce(avg(total),0), coalesce(avg(whole),0) into v_n, v_total, v_whole_hist from (
$s$);
  if n = d then raise exception 'v107a: plan_milk pattern not found'; end if;
  execute n;

  d := pg_get_functiondef('fabula.bot_fallback_run'::regproc);
  n := replace(d, $s$    if r ? 'skipped' then
      sev := 'info'; ttl := format('Piano latte per %s già pronto', to_char(d, 'DD/MM'));
$s$, $s$    if r->>'skipped' = 'pre_opening' then   -- v1.07
      sev := 'info'; ttl := 'Nessun piano latte prima dell''avvio';
      summ := 'nessun piano prima dell''avvio';
      body := (r->>'message_it') || '.';
    elsif r ? 'skipped' then
      sev := 'info'; ttl := format('Piano latte per %s già pronto', to_char(d, 'DD/MM'));
$s$);
  if n = d then raise exception 'v107a: bot_fallback_run pattern not found'; end if;
  execute n;

  d := pg_get_functiondef('fabula._why_plan_milk'::regproc);
  n := replace(d, $s$  if d ? 'skipped' then
    return fabula._wout(format('Piano latte per %s già pronto', fabula._wd(d->'date')), array[
$s$, $s$  if d->>'skipped' = 'pre_opening' then   -- v1.07
    return fabula._wout('Nessun piano latte prima dell''avvio', array[
      fabula._wsec('Perché nessun piano', array[
        fabula._wr('Giorno del piano', fabula._wd(d->'date')),
        fabula._wr('Primo piano', fabula._wd(coalesce(d->'first_plan_day', d->'tasks_start')), 'settimana di prova o apertura, la prima delle due'),
        fabula._wr('Latte, lotti o prodotto veri', 'nessuno', 'ne basta uno per riattivare il piano')],
        'Prima di quel giorno il piano automatico non propone latte. Si cambia in Configurazione → Parametri → Produzione e latte («Silenzio prima dell''avvio») o con le date della settimana di prova e dell''apertura.')]);
  end if;
  if d ? 'skipped' then
    return fabula._wout(format('Piano latte per %s già pronto', fabula._wd(d->'date')), array[
$s$);
  if n = d then raise exception 'v107a: _why_plan_milk pattern not found'; end if;
  execute n;

  d := pg_get_functiondef('fabula.ops_health_check'::regproc);
  n := replace(d, $s$      from fabula.stock_counts where status = 'posted' having max(counted_at::date) < p_date - 9
$s$, $s$      from fabula.stock_counts where status = 'posted' and not fabula.quiet_day(p_date) having max(counted_at::date) < p_date - 9   -- v1.07
$s$);
  if n = d then raise exception 'v107a: ops_health_check stock_count_overdue pattern not found'; end if;
  d := n;
  n := replace(d, $s$    select 'stock_count_never', 'Nessuna conta magazzino registrata', 1 where not exists (select 1 from fabula.stock_counts where status = 'posted')
$s$, $s$    select 'stock_count_never', 'Nessuna conta magazzino registrata', 1 where not fabula.quiet_day(p_date) and not exists (select 1 from fabula.stock_counts where status = 'posted')   -- v1.07
$s$);
  if n = d then raise exception 'v107a: ops_health_check stock_count_never pattern not found'; end if;
  d := n;
  n := replace(d, $s$      where extract(isodow from p_date) between 1 and 6 and not exists (select 1 from fabula.scan_events where scanned_at::date = p_date)
$s$, $s$      where extract(isodow from p_date) between 1 and 6 and not fabula.quiet_day(p_date)   -- v1.07
        and not exists (select 1 from fabula.scan_events where scanned_at::date = p_date)
$s$);
  if n = d then raise exception 'v107a: ops_health_check tablet_silent pattern not found'; end if;
  execute n;

  -- the tablet's evening list (v1.05): before the tasks start it was quiet unless milk or a lot was worked THAT day; product kept in
  -- the cold rooms, or worked a few days ago, now brings the evening checks back too
  d := pg_get_functiondef('fabula._haccp_evening_items'::regproc);
  n := replace(d, $s$  if v_start is not null and p_date < v_start and not v_real_prod
     and not exists (select 1 from fabula.milk_intake where intake_date = p_date and source <> 'simulation') then
$s$, $s$  if v_start is not null and p_date < v_start and not v_real_prod
     and not fabula._real_activity(p_date) then   -- v1.07: nor real product in stock or worked in the last days
$s$);
  if n = d then raise exception 'v107a: _haccp_evening_items pattern not found'; end if;
  execute n;

  -- «Perché?» of the briefs: say why the HACCP lines are not asked
  d := pg_get_functiondef('fabula._why_daily_brief'::regproc);
  n := replace(d, $s$    fabula._wr('Registrazioni del giorno', coalesce(d #>> '{haccp,checks_logged}', 'n/d')),
$s$, $s$    fabula._wr('Registrazioni del giorno', coalesce(d #>> '{haccp,checks_logged}', 'n/d')),
    case when d ? 'pre_opening' then fabula._wr('Prima dell''avvio', 'controlli del giorno non richiesti',
                                                'fino a ' || fabula._wd(d #> '{pre_opening,tasks_start}') || ', se non ci sono latte, lotti o prodotto veri') end,   -- v1.07
$s$);
  if n = d then raise exception 'v107a: _why_daily_brief pattern not found'; end if;
  execute n;

  d := pg_get_functiondef('fabula._why_weekly_brief'::regproc);
  n := replace(d, $s$    fabula._wr('Registrazioni mancanti', coalesce(tw #>> '{compliance,missing_checks}', 'n/d'), null, case when fabula._wn(tw #> '{compliance,missing_checks}') > 0 then 'ko' end),
$s$, $s$    fabula._wr('Registrazioni mancanti', coalesce(tw #>> '{compliance,missing_checks}', 'n/d'),
               case when d ? 'pre_opening' then 'prima dell''avvio (' || fabula._wd(d #> '{pre_opening,tasks_start}') || ') non si contano' end,   -- v1.07
               case when fabula._wn(tw #> '{compliance,missing_checks}') > 0 then 'ko' end),
$s$);
  if n = d then raise exception 'v107a: _why_weekly_brief pattern not found'; end if;
  execute n;
end $mig$;

-- ============================== the briefs ==============================
create or replace function fabula.daily_brief(p_date date default (((now() at time zone 'Europe/Rome'::text))::date - 1))
returns jsonb language sql stable set search_path to 'fabula', 'public', 'extensions' as $$
  -- v1.05 (audit E-19): the changes the brief talks about, computed here so the bot never does arithmetic
  -- v1.07: on a quiet day (fabula.quiet_day: before the start, nothing real going on) nothing of the day's HACCP checks or tasks is
  -- asked; pre_opening says until when
  select case when fabula.quiet_day(p_date) then
           c || jsonb_build_object(
             'haccp', coalesce(c -> 'haccp', '{}'::jsonb) || jsonb_build_object('missing_daily_checks', '[]'::jsonb, 'evening_cold_checks_missing', '[]'::jsonb),
             'tasks', coalesce(c -> 'tasks', '{}'::jsonb) || jsonb_build_object('overdue', '[]'::jsonb),
             'pre_opening', jsonb_build_object('tasks_start', fabula.quiet_until(),
                                               'note_it', format('Prima dell''avvio (%s) i controlli HACCP del giorno non sono richiesti', fabula.it_day(fabula.quiet_until()))))
         else c end
    from (select b || jsonb_build_object('changes', jsonb_build_object(
                   'sales_vs_same_weekday_pct', fabula.pct_change((b #>> '{sales_trend,yesterday_eur}')::numeric, (b #>> '{sales_trend,same_weekday_avg_4w_eur}')::numeric),
                   'yield_vs_30d_points', round((b #>> '{yield,yesterday}')::numeric - (b #>> '{yield,avg_30d}')::numeric, 1),
                   'energy_kwh_per_kg_vs_30d_pct', fabula.pct_change((b #>> '{energy,yesterday_kwh_per_kg}')::numeric, (b #>> '{energy,avg_30d_kwh_per_kg}')::numeric))) c
            from (select fabula._daily_brief_base(p_date) b) x) y
$$;

create or replace function fabula.weekly_brief(p_week_end date default null::date)
returns jsonb language sql stable set search_path to 'fabula', 'public', 'extensions' as $$
  -- v1.05 (audit E-19): this week against the previous one, every number as a % change
  -- v1.07: weeks that are quiet at their end (fabula.quiet_day): the missing HACCP checks are 0, pre_opening says until when
  select b || jsonb_build_object('changes', fabula._pct_changes(b -> 'this_week', b -> 'previous_week'))
    from (select case when fabula.quiet_day((b0 ->> 'week_end')::date)
                      then jsonb_set(case when fabula.quiet_day((b0 ->> 'week_start')::date - 1)
                                          then jsonb_set(b0, '{previous_week,compliance,missing_checks}', '0'::jsonb, false) else b0 end,
                                     '{this_week,compliance,missing_checks}', '0'::jsonb, false)
                           || jsonb_build_object('pre_opening', jsonb_build_object('tasks_start', fabula.quiet_until()))
                      else b0 end b
            from (select fabula._weekly_brief_base(p_week_end) b0) y) x
$$;

-- ============================== an expiry is not a decision ==============================
create or replace function fabula.expire_approvals(p_now timestamp with time zone default now())
returns integer language plpgsql security definer set search_path to 'fabula', 'public' as $function$
declare a fabula.approvals; n int := 0; v_type text; v_what text; v_title text; v_out uuid;
begin
  for a in select * from fabula.approvals
            where status = 'pending' and expires_at is not null and expires_at <= p_now
              and coalesce(payload->>'type', '') <> 'recall_assessment'      -- v0.93a: a recall decision never lapses by itself
            order by expires_at for update skip locked loop
    update fabula.approvals set status = 'expired', decided_by = 'Scadenza', decided_at = p_now, decision_note = 'scaduta senza decisione'
     where id = a.id and status = 'pending';
    if not found then continue; end if;
    n := n + 1;
    v_type := fabula.approval_type(a.kind, a.payload);
    v_what := case v_type
      when 'milk_plan' then format('Nessun ordine di latte per %s: la Masseria non vede niente. Se serve latte, ordinalo da Console → Oggi → Decise di recente («Ordina di nuovo») o chiama la Masseria.',
                                   fabula.it_day((a.payload->>'plan_date')::date))
      when 'purchase_order' then case when coalesce((a.payload->>'manual')::boolean, false)
                                      then format('L''ordine %s (creato da %s dal catalogo) è annullato: se serve ancora rifallo da Anagrafiche → Fornitori.',
                                                  coalesce(a.payload->>'po_number', ''), coalesce(a.payload->>'created_by', '?'))
                                      else format('L''ordine %s è annullato: il bot Acquisti lo riproporrà se serve ancora.', coalesce(a.payload->>'po_number', '')) end
      when 'sell_down' then 'La promo non è partita: nessun codice sul tablet, nessun post.'
      when 'content_post' then 'Il post non è stato approvato in tempo: non esce. Riprogrammalo da Marketing se serve.'
      else 'Nessuna azione è stata fatta.' end;
    v_title := left('Scaduta senza decisione · ' || a.summary, 120);
    begin
      perform fabula.post_bot_message('auto_approve', 'warn', v_title, a.summary || E'\n\n' || v_what);
    exception when others then raise warning 'expire_approvals message %: %', a.id, sqlerrm;
    end;
    if v_type = 'milk_plan' and not coalesce((a.payload->>'is_simulation')::boolean, false) then
      begin
        v_out := fabula.notify_enqueue('decisions', v_title, v_what, 'Approvazioni', 'approvals', a.id::text, 'exp:' || a.id);
        -- v1.07: the expiry is news, not a decision still open: no «Nessuno se ne occupa» reminder 30 minutes later
        if v_out is not null then update fabula.notify_outbox set escalate_at = null where id = v_out; end if;
      exception when others then raise warning 'expire_approvals notify %: %', a.id, sqlerrm;
      end;
    end if;
  end loop;
  return n;
end $function$;

-- ============================== «Verso l'apertura» in Monday's summary ==============================
create or replace function fabula._digest_golive(p_day date)
returns text[] language plpgsql stable security definer set search_path = fabula, public as $$
-- v1.07: the «Verso l'apertura» block of Monday's summary: done / total of the go-live list, from when the work starts, the first
-- three items not done (in the list's order). Lines already escaped for Telegram HTML.
declare g jsonb := fabula.golive_checklist(); v_start date := fabula.quiet_until(); n_done int; n_all int; n_left int; t text[] := '{}'; x record;
begin
  select count(*) filter (where (i->>'done')::boolean), count(*) into n_done, n_all from jsonb_array_elements(coalesce(g->'items', '[]')) i;
  if n_all = 0 then return t; end if;
  t := t || ''::text || ('<b>Verso l''apertura</b> ' || n_done || ' di ' || n_all || ' fatti'
                         || case when v_start is not null and v_start > p_day
                                 then ' · si parte ' || fabula.it_day(v_start) || ' (' || case when v_start - p_day = 1 then 'domani'
                                                                                              else 'tra ' || fabula.it_n(v_start - p_day, 'giorno', 'giorni') end || ')'
                                 else '' end);
  for x in select i->>'label' as label from jsonb_array_elements(g->'items') with ordinality o(i, k) where not (i->>'done')::boolean order by k limit 3 loop
    t := t || ('• ' || fabula.tg_esc(left(coalesce(x.label, ''), 110)));
  end loop;
  n_left := n_all - n_done - 3;
  if n_left > 0 then t := t || ('… e altri ' || n_left || ' (Configurazione → Panoramica → Verso l''apertura)'); end if;
  return t;
end $$;
revoke all on function fabula._digest_golive(date) from public, anon, authenticated;
grant execute on function fabula._digest_golive(date) to service_role;

do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.notify_digest_text'::regproc);
  n := replace(d, $s$  if v_site <> '' then t := t || ''::text || ('<a href="' || v_site || '/console.html#oggi">Apri la Console</a>'); end if;
$s$, $s$  -- v1.07: while the dairy is quiet before the start, on Monday (the reader's day), the go-live list in one block
  if v_sys >= 1 and extract(isodow from (p_now at time zone v_tz)::date) = 1 and fabula.quiet_day((p_now at time zone 'Europe/Rome')::date) then
    begin
      t := t || fabula._digest_golive((p_now at time zone 'Europe/Rome')::date);
    exception when others then raise warning 'notify_digest_text golive: %', sqlerrm;
    end;
  end if;
  if v_site <> '' then t := t || ''::text || ('<a href="' || v_site || '/console.html#oggi">Apri la Console</a>'); end if;
$s$);
  if n = d then raise exception 'v107a: notify_digest_text pattern not found'; end if;
  execute n;
end $mig$;

-- ============================== automatic plans already waiting for a quiet day ==============================
-- closed without a message (they would only expire with a Telegram); their bot message is marked read by the approvals trigger
update fabula.approvals a set status = 'expired', decided_by = 'Prima dell''avvio', decided_at = now(),
       decision_note = 'v1.07: nessun piano automatico prima dell''avvio'
 where a.status = 'pending' and a.requested_by = 'agent:milk_planning' and a.related_table = 'milk_plans'
   and fabula.approval_type(a.kind, a.payload) = 'milk_plan'
   and fabula.quiet_milk_day((a.payload->>'plan_date')::date);
