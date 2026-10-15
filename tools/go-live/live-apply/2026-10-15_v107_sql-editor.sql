-- v1.07a–b for the Supabase dashboard SQL Editor (15/10/2026): «Prima dell'avvio», the bots stay quiet before the first day with
-- the tasks (project doc claude/audit-fixes-v107-2026-10-15.md).
--   v1.07a  fabula.quiet_day() and the setting prod.quiet_before_start; the automatic milk plan proposes nothing before the start
--           (the stand-in and «Perché?» say so); the evening check skips the tablet and the stock count; the briefs do not ask for
--           the day's HACCP checks unless real milk or a lot was worked; an expired decision gets no 30-minute reminder; Monday's
--           summary has «Verso l'apertura»
--   v1.07b  the Shopify stock message respects selling at zero stock (shopify.sell_at_zero); the milk planning prompt's new version
-- Same files as supabase/migrations/20261015140000_* and 20261015140100_* (built by make_v107_script.py).
-- One transaction: if any step fails nothing changes. It records the two versions in the migration history and refuses a second run.
-- Paste everything, Run, and check the last result shows 20261015140100 and 20261015140000 at the top.
-- AFTER this: merge and push to main (the app does not change, so Netlify does not deploy), then the bots' scheduled tasks get the
-- new milk planning prompt.
begin;
do $chk$ begin
  if exists (select 1 from supabase_migrations.schema_migrations where version in ('20261015140000', '20261015140100')) then
    raise exception 'STOP: v1.07 is already in the migration history — nothing to do';
  end if;
  if (select max(version) from supabase_migrations.schema_migrations) <> '20261015120100' then
    raise exception 'STOP: the live history does not end at 20261015120100 (v106b_perche_why) — tell Claude before applying';
  end if;
end $chk$;

-- ======================= v107a =======================
-- v1.07a «Prima dell'avvio» (15/10/2026): before the first day with the tasks, the bots stop asking for things a dairy that is not
-- working yet cannot do. Found live on 15/10 (project doc claude/golive-rescore-2026-10-15.md): every day since 09/10 the milk plan
-- proposed 1.200 kg for a dairy with no building, each plan sent Nick four Telegrams (the decision, its 30-minute reminder, the
-- expiry and a reminder of the expiry), the morning brief asked for HACCP records nobody could write and the evening check said the
-- tablet was silent. 12 of the 15 Telegrams Nick got in a week were these. Teaching people to ignore Telegram before the trial week is
-- the opposite of what the alerts are for.
--
--   * fabula.quiet_day(date): true while the setting prod.quiet_before_start is on (default) and the day is before
--     fabula.tasks_start_date() («Primo giorno con le attività», else the trial week, else the opening: v1.05). One switch for all.
--   * plan_milk(): the automatic plan (no date given: the bot, the database's stand-in, «Esegui ora») proposes nothing for a quiet day
--     and says from when it starts. A plan asked for a given day (Console «Ordina di nuovo», tests) is still made.
--   * bot_fallback_run and the «Perché?» of the milk plan say the same.
--   * ops_health_check: no «tablet silenzioso» and no «conta di magazzino» on a quiet day (the count is on the go-live list).
--   * daily_brief / weekly_brief: on a quiet day with no real milk or lot, the HACCP checks of the day and the overdue tasks are not
--     asked; the JSON says pre_opening with the start date. A real lot or milk before the start is still checked (food safety first,
--     as the evening list since v1.05).
--   * expire_approvals: an expired decision is news, not a decision still open: no «Nessuno se ne occupa» reminder 30 minutes later
--     (also after the opening).
--   * notify_digest_text: on Monday, while quiet, the morning summary has one «Verso l'apertura» block (done / total, from when it
--     starts, the next three items not done).
-- Part b (v107b): the Shopify stock message respects selling at zero stock, and the milk planning prompt's new version.

-- ============================== the switch ==============================
insert into fabula.settings (key, value, description, data_type, kind, sort, impact_it, min_value, max_value, unit) values
  ('prod.quiet_before_start', '1',
   'Silenzio prima dell''avvio: fino al primo giorno con le attività (vedi sopra; vuoto = settimana di prova o apertura) il piano latte non propone niente e i bot non chiedono tablet, conta di magazzino e controlli HACCP del giorno. No = si comportano come a caseificio aperto.',
   'number', 'flag', 40,
   'Con «No» arrivano ogni giorno il piano latte da decidere e i controlli mancanti anche a caseificio chiuso.', null, null, null)
on conflict (key) do nothing;

create or replace function fabula.quiet_day(p_day date)
returns boolean language sql stable set search_path = fabula, public as $$
  -- v1.07: a day before the first day with the tasks, while «Silenzio prima dell'avvio» is on
  select coalesce(fabula.setting_num('prod.quiet_before_start', 1), 1) = 1
     and p_day is not null and fabula.tasks_start_date() is not null and p_day < fabula.tasks_start_date()
$$;
comment on function fabula.quiet_day(date) is 'v1.07: true while prod.quiet_before_start is on and the day is before fabula.tasks_start_date(). The automatic milk plan, the floor checks of the evening check and the HACCP lines of the briefs stay quiet on such a day.';
revoke all on function fabula.quiet_day(date) from public, anon;
grant execute on function fabula.quiet_day(date) to authenticated, service_role;

-- ============================== the milk plan ==============================
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.plan_milk'::regproc);
  n := replace(d, $s$  if exists (select 1 from fabula.milk_plans where plan_date = d and status in ('proposed','approved')) then
$s$, $s$  -- v1.07: before the first day with the tasks the automatic plan (no date given) proposes nothing: no approval, no Telegram, nothing
  -- on the farm page. A plan asked for a given day (Console «Ordina di nuovo», tests) is still made.
  if p_date is null and fabula.quiet_day(d) then
    return jsonb_build_object('date', d, 'weekday', v_wd, 'skipped', 'pre_opening', 'tasks_start', fabula.tasks_start_date(),
      'message_it', format('Nessun piano latte prima dell''avvio: le proposte ripartono per %s (Configurazione → Parametri → Produzione e latte, «Primo giorno con le attività»)',
                           fabula.it_day(fabula.tasks_start_date())));
  end if;
  if exists (select 1 from fabula.milk_plans where plan_date = d and status in ('proposed','approved')) then
$s$);
  if n = d then raise exception 'v107a: plan_milk pattern not found'; end if;
  execute n;

  d := pg_get_functiondef('fabula.bot_fallback_run'::regproc);
  n := replace(d, $s$    if r ? 'skipped' then
      sev := 'info'; ttl := format('Piano latte per %s già pronto', to_char(d, 'DD/MM'));
$s$, $s$    if r->>'skipped' = 'pre_opening' then   -- v1.07
      sev := 'info'; ttl := 'Nessun piano latte prima dell''avvio';
      summ := 'prima dell''avvio: nessun piano';
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
        fabula._wr('Primo giorno con le attività', fabula._wd(d->'tasks_start'))],
        'Prima di quel giorno il piano automatico non propone latte. Si cambia in Configurazione → Parametri → Produzione e latte («Primo giorno con le attività», «Silenzio prima dell''avvio»).')]);
  end if;
  if d ? 'skipped' then
    return fabula._wout(format('Piano latte per %s già pronto', fabula._wd(d->'date')), array[
$s$);
  if n = d then raise exception 'v107a: _why_plan_milk pattern not found'; end if;
  execute n;

  -- ============================== the evening check ==============================
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
end $mig$;

-- ============================== the briefs ==============================
-- a quiet day with no real milk and no real lot: the day's HACCP checks and the overdue tasks are not asked
create or replace function fabula.daily_brief(p_date date default (((now() at time zone 'Europe/Rome'::text))::date - 1))
returns jsonb language sql stable set search_path to 'fabula', 'public', 'extensions' as $$
  -- v1.05 (audit E-19): the changes the brief talks about, computed here so the bot never does arithmetic
  -- v1.07: before the first day with the tasks (fabula.quiet_day) and with no real milk or lot that day, nothing of the day's
  -- HACCP checks or tasks is asked; pre_opening says from when
  select case when q then
           c || jsonb_build_object(
             'haccp', coalesce(c -> 'haccp', '{}'::jsonb) || jsonb_build_object('missing_daily_checks', '[]'::jsonb, 'evening_cold_checks_missing', '[]'::jsonb),
             'tasks', coalesce(c -> 'tasks', '{}'::jsonb) || jsonb_build_object('overdue', '[]'::jsonb),
             'pre_opening', jsonb_build_object('tasks_start', fabula.tasks_start_date(),
                                               'note_it', format('Prima dell''avvio (%s) i controlli HACCP del giorno non sono richiesti', fabula.it_day(fabula.tasks_start_date()))))
         else c end
    from (select b || jsonb_build_object('changes', jsonb_build_object(
                   'sales_vs_same_weekday_pct', fabula.pct_change((b #>> '{sales_trend,yesterday_eur}')::numeric, (b #>> '{sales_trend,same_weekday_avg_4w_eur}')::numeric),
                   'yield_vs_30d_points', round((b #>> '{yield,yesterday}')::numeric - (b #>> '{yield,avg_30d}')::numeric, 1),
                   'energy_kwh_per_kg_vs_30d_pct', fabula.pct_change((b #>> '{energy,yesterday_kwh_per_kg}')::numeric, (b #>> '{energy,avg_30d_kwh_per_kg}')::numeric))) c,
                 fabula.quiet_day(p_date)
                 and not exists (select 1 from fabula.production_batches where batch_date = p_date and source <> 'simulation')
                 and not exists (select 1 from fabula.milk_intake where intake_date = p_date and source <> 'simulation') q
            from (select fabula._daily_brief_base(p_date) b) x) y
$$;

create or replace function fabula.weekly_brief(p_week_end date default null::date)
returns jsonb language sql stable set search_path to 'fabula', 'public', 'extensions' as $$
  -- v1.05 (audit E-19): this week against the previous one, every number as a % change
  -- v1.07: a week that ends before the first day with the tasks, with no real lot in the two weeks: the missing HACCP checks are 0
  select b || jsonb_build_object('changes', fabula._pct_changes(b -> 'this_week', b -> 'previous_week'))
    from (select case when fabula.quiet_day((b0 ->> 'week_end')::date)
                       and not exists (select 1 from fabula.production_batches where source <> 'simulation'
                                        and batch_date between (b0 ->> 'week_start')::date - 7 and (b0 ->> 'week_end')::date)
                      then jsonb_set(jsonb_set(b0, '{this_week,compliance,missing_checks}', '0'::jsonb, false), '{previous_week,compliance,missing_checks}', '0'::jsonb, false)
                           || jsonb_build_object('pre_opening', jsonb_build_object('tasks_start', fabula.tasks_start_date()))
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
-- v1.07: the «Verso l'apertura» block of Monday's summary: done / total of the go-live list, from when the tasks start, the first
-- three items not done (in the list's order). Lines already escaped for Telegram HTML.
declare g jsonb := fabula.golive_checklist(); v_start date := fabula.tasks_start_date(); n_done int; n_all int; n_left int; t text[] := '{}'; x record;
begin
  select count(*) filter (where (i->>'done')::boolean), count(*) into n_done, n_all from jsonb_array_elements(coalesce(g->'items', '[]')) i;
  if n_all = 0 then return t; end if;
  t := t || ''::text || ('<b>Verso l''apertura</b> ' || n_done || ' di ' || n_all || ' fatti'
                         || case when v_start is not null then ' · si parte ' || fabula.it_day(v_start) || ' (tra ' || (v_start - p_day) || ' giorni)' else '' end);
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
$s$, $s$  -- v1.07: before the first day with the tasks, on Monday (the reader's day), the go-live list in one block
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

-- ======================= v107b =======================
-- v1.07b (15/10/2026): the Shopify stock message follows the decision that the website and the till sell at zero stock, and the
-- milk planning prompt's new version (it handles the plan's new «pre_opening» answer, v1.07a).
--   * shopify.sell_at_zero (default Sì, as decided on 02/10, v0.39): the website and the till keep selling at zero stock, production
--     follows the orders. The stock check no longer asks to turn off «Continua a vendere quando esaurito» (it did on 15/10, against
--     that decision); it lists instead the tracked products that stop at zero. With «No» it behaves as before. The setting is part
--     of the message's fingerprint, so changing it gives a full message rather than «(invariato)».

insert into fabula.settings (key, value, description, data_type, kind, sort, impact_it, min_value, max_value, unit) values
  ('shopify.sell_at_zero', '1',
   'Sito e cassa vendono anche a scorte zero (la produzione segue gli ordini). Sì = il controllo giacenze segnala i prodotti che si fermano a zero; No = segnala quelli che vendono a zero.',
   'number', 'flag', 56,
   'Con «No» il controllo giacenze chiede di togliere «Continua a vendere quando esaurito» su Shopify.', null, null, null)
on conflict (key) do nothing;

do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.shopify_sync_finish'::regproc);
  n := replace(d, $s$      if jsonb_array_length(coalesce(res->'selling_at_zero', '[]')) > 0 then
        todo := todo || format('%s anche a scorte zero: in Shopify togli «Continua a vendere quando esaurito» (%s)', fabula.it_n(jsonb_array_length(res->'selling_at_zero'), 'prodotto si vende', 'prodotti si vendono'),
                               (select string_agg(e #>> '{}', ', ') from jsonb_array_elements(res->'selling_at_zero') e));
$s$, $s$      if coalesce(fabula.setting_num('shopify.sell_at_zero', 1), 1) = 1 then
        -- v1.07b: selling at zero stock is the decision (shopify.sell_at_zero): only a tracked product that stops at zero is a problem
        if exists (select 1 from jsonb_array_elements(coalesce(res->'variants', '[]')) v
                    where v->>'policy' = 'DENY' and coalesce((v->>'tracked')::boolean, false)) then
          todo := todo || format('%s a scorte zero: in Shopify attiva «Continua a vendere quando esaurito» (%s)',
                                 fabula.it_n((select count(*)::int from jsonb_array_elements(res->'variants') v where v->>'policy' = 'DENY' and coalesce((v->>'tracked')::boolean, false)),
                                             'prodotto si ferma', 'prodotti si fermano'),
                                 (select string_agg(v->>'label', ', ' order by v->>'label') from jsonb_array_elements(res->'variants') v
                                   where v->>'policy' = 'DENY' and coalesce((v->>'tracked')::boolean, false)));
        end if;
      elsif jsonb_array_length(coalesce(res->'selling_at_zero', '[]')) > 0 then
        todo := todo || format('%s anche a scorte zero: in Shopify togli «Continua a vendere quando esaurito» (%s)', fabula.it_n(jsonb_array_length(res->'selling_at_zero'), 'prodotto si vende', 'prodotti si vendono'),
                               (select string_agg(e #>> '{}', ', ') from jsonb_array_elements(res->'selling_at_zero') e));
$s$);
  if n = d then raise exception 'v107b: shopify_sync_finish selling_at_zero pattern not found'; end if;
  d := n;
  -- the decision is part of what makes the message «the same as last time»: changing it gives a full message, not «(invariato)»
  n := replace(d, $s$      fp := md5(coalesce(res->>'push', '') || '|' || coalesce((select string_agg(concat_ws(':', v->>'variant_id', v->>'available_units', v->>'shopify_qty', v->>'tracked', v->>'policy'), ',' order by v->>'variant_id')
$s$, $s$      fp := md5(coalesce(fabula.setting_text('shopify.sell_at_zero'), '1') || '|' || coalesce(res->>'push', '') || '|' || coalesce((select string_agg(concat_ws(':', v->>'variant_id', v->>'available_units', v->>'shopify_qty', v->>'tracked', v->>'policy'), ',' order by v->>'variant_id')
$s$);
  if n = d then raise exception 'v107b: shopify_sync_finish fingerprint pattern not found'; end if;
  execute n;
end $mig$;

-- ============================== the prompt (tools/bots/sync_rules.py --versions) ==============================
insert into fabula.bot_prompt_versions (agent, version) values
  ('milk_planning', '7ab9d0a933')
on conflict (agent) do update set version = excluded.version, updated_at = now();

insert into supabase_migrations.schema_migrations (version, name) values
  ('20261015140000', 'v107a_quiet_before_start'),
  ('20261015140100', 'v107b_sell_at_zero_prompt');
commit;

select version, name from supabase_migrations.schema_migrations order by version desc limit 5;
