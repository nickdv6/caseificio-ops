-- v0.69a (05/10/2026) · Self-healing bots: when a scheduled bot doesn't start, the database does its core job itself.
-- Every 5 minutes pg_cron runs fabula.bot_fallback(). For each bot slot of today whose grace period (bot_schedule.grace_min,
-- 45 min) has passed with no run in agent_runs, and for at most 6 hours after the due time, it runs the bot's database
-- work once (ledger fabula.bot_fallback_runs, one row per bot and slot), logs the run in agent_runs (details.via =
-- 'db_fallback') and posts the result in Configurazione → Bot. The functions are the same ones the bots call and all skip
-- work already done, so a bot that starts late after the fallback changes nothing.
--   milk_planning    plan_milk()                 tomorrow's milk proposal (approve by 06:00; the farm page shows it)
--   procurement      propose_purchase_orders()   purchase orders under stock, waiting for approval
--   wholesale_orders confirm_standing_orders()   tomorrow's standing wholesale orders + the WhatsApp texts to send
--   haccp_nudge      haccp_evening_status()      the red "Prima di chiudere" banner on the tablet
--   ops_health       ops_health_check()          expires stale approvals; data, food-safety and infra checks
--   sell_down        sell_down_signals()         sell-down promo proposals (no Shopify code: valid at the counter)
--   backup_export    backup_export_call()        re-sends the nightly backup once (the backup logs its own run)
-- Bots that need Shopify or write text (Shopify sync, briefs, marketing, sales, deadlines) keep the existing alarms.
-- Setting bots.db_fallback (Configurazione → Parametri) = 0 switches it off.
-- Also: the nightly backup now runs at 21:15 Rome time all year (pg_cron runs in UTC: after 25/10 it would have run at
-- 20:15 and the heartbeat would have reported it missing every night).

create table if not exists fabula.bot_fallback_runs (
  agent text not null,
  slot timestamptz not null,
  ran_at timestamptz not null default now(),
  status text not null default 'running' check (status in ('running', 'ok', 'error')),
  summary text,
  result jsonb,
  primary key (agent, slot)
);
comment on table fabula.bot_fallback_runs is 'v0.69: database stand-in runs for bots that did not start (one row per bot and due slot).';
alter table fabula.bot_fallback_runs enable row level security;
grant select on fabula.bot_fallback_runs to authenticated;
grant all on fabula.bot_fallback_runs to service_role;
insert into fabula.table_areas(table_name, area, read_open, write_level) values ('bot_fallback_runs', 'sistema', false, 3)
on conflict (table_name) do nothing;
do $$ begin
  if not exists (select 1 from pg_policy where polrelid = 'fabula.bot_fallback_runs'::regclass and polname = 'bot_fallback_runs_authenticated_all') then
    create policy bot_fallback_runs_authenticated_all on fabula.bot_fallback_runs for select to authenticated using (true);
    create policy bot_fallback_runs_role_select on fabula.bot_fallback_runs as restrictive for select to authenticated using ((select fabula.can_table('bot_fallback_runs', false)));
  end if;
end $$;

insert into fabula.settings(key, value, description, data_type, sort) values
 ('bots.db_fallback', '1', 'Se un bot non parte, il database fa il suo lavoro (piano latte, ordini, banner HACCP…): 1 = sì, 0 = no', 'number', 90)
on conflict (key) do nothing;

create or replace function fabula.bot_fallback_agents() returns text[] language sql immutable as $$
  select array['milk_planning', 'procurement', 'wholesale_orders', 'haccp_nudge', 'ops_health', 'sell_down', 'backup_export']
$$;

-- one stand-in run: does the bot's database work and returns severity, title, body (Italian) and a one-line summary
create or replace function fabula.bot_fallback_run(p_agent text, p_day date) returns jsonb
language plpgsql security definer set search_path = fabula, public as $$
declare r jsonb; x jsonb; sev text := 'warn'; ttl text; body text; summ text; n int; d date; v_fs text; v_other text;
begin
  case p_agent
  when 'milk_planning' then
    r := fabula.plan_milk(); d := (r->>'date')::date;
    if r ? 'skipped' then
      sev := 'info'; ttl := format('Piano latte per %s già pronto', to_char(d, 'DD/MM'));
      summ := 'piano già presente';
      body := format('Il piano latte per %s c''era già: %s kg (%s).', to_char(d, 'DD/MM'), r#>>'{plan,milk_kg}', r#>>'{plan,status}');
    else
      ttl := format('Latte per %s: %s kg da approvare', to_char(d, 'DD/MM'), trim_scale((r->>'milk_kg')::numeric));
      summ := format('proposta latte %s kg per %s', trim_scale((r->>'milk_kg')::numeric), to_char(d, 'DD/MM'));
      body := format(E'Proposta latte per %s %s: %s kg (≈ %s kg di mozzarella, € %s).%s\nApprovala entro le 06:00 in Console → Da approvare: la Masseria la vede sulla sua pagina.\n\n%s',
                     r->>'weekday', to_char(d, 'DD/MM'), trim_scale((r->>'milk_kg')::numeric), r->>'planned_output_kg', r->>'est_cost_eur',
                     case when (r#>>'{farm,exceeds_farm_supply}')::boolean then ' ⚠ Oltre la disponibilità della Masseria.' else '' end, r->>'rationale');
    end if;

  when 'procurement' then
    r := fabula.propose_purchase_orders(p_day); n := (r->>'count')::int;
    if n = 0 then
      sev := 'info'; ttl := 'Nessun ordine fornitori da proporre'; summ := 'nessun ordine';
      body := format('Nessun materiale sotto scorta da ordinare oggi (%s articoli saltati: ordine già aperto o fornitore mancante).', jsonb_array_length(r->'skipped'));
    else
      ttl := format('%s ordini fornitori da approvare', n); summ := ttl;
      select string_agg(format('• %s: %s %s %s da %s, € %s%s', c->>'po_number', c->>'qty', c->>'unit', c->>'name', c->>'supplier', c->>'total_eur',
                               case when (c->>'price_missing')::boolean then ' · PREZZO MANCANTE' else '' end), E'\n')
        into body from jsonb_array_elements(r->'created') c;
      body := body || E'\nApprova o correggi in Console → Da approvare.';
    end if;

  when 'wholesale_orders' then
    r := fabula.confirm_standing_orders(); n := (r->>'booked')::int; d := (r->>'date')::date;
    select string_agg(case when (c->>'already_booked')::boolean then format('• %s: già registrato (%s)', c->>'customer', c->>'order_number')
                           else format(E'• %s · %s · € %s\n  WhatsApp a %s: %s', c->>'customer', c->>'order_number', c->>'total_eur', coalesce(c->>'phone', 'telefono mancante'), c->>'message_it') end, E'\n')
      into body from jsonb_array_elements(r->'customers') c;
    sev := case when n > 0 then 'warn' else 'info' end;
    ttl := case when n > 0 then format('%s ordini ingrosso fissi per %s registrati', n, to_char(d, 'DD/MM')) else format('Nessun nuovo ordine ingrosso per %s', to_char(d, 'DD/MM')) end;
    summ := format('%s ordini fissi per %s', n, to_char(d, 'DD/MM'));
    body := coalesce(body, format('Nessun cliente ha un ordine fisso per %s.', r->>'weekday'))
            || format(E'\nTotale ingrosso confermato per %s %s: %s kg.', r->>'weekday', to_char(d, 'DD/MM'), trim_scale((r->>'total_kg')::numeric))
            || case when (r->>'is_placeholder')::boolean then E'\n(Clienti di prova: sostituirli in Vendite.)' else '' end;

  when 'haccp_nudge' then
    r := fabula.haccp_evening_status(p_day); n := (r->>'count')::int;
    select string_agg('⚠ CCP · ' || (m->>'label_it'), E'\n') filter (where m->>'code' ~ '^(ccp:|abx|ph)'),
           string_agg('• ' || (m->>'label_it'), E'\n') filter (where m->>'code' !~ '^(ccp:|abx|ph)')
      into v_fs, v_other from jsonb_array_elements(r->'missing') m;
    if jsonb_array_length(r->'lots_on_hold') = 0 and (n = 0 or (r->>'closed_day')::boolean) then
      sev := 'info'; ttl := case when n = 0 then 'Tutto registrato' else 'Giornata chiusa' end; summ := lower(ttl);
      body := case when n = 0 then 'Le registrazioni di oggi sono complete.' else 'Nessuna produzione né vendita oggi.' end;
    else
      sev := case when v_fs is not null or jsonb_array_length(r->'lots_on_hold') > 0 then 'alert' else 'warn' end;
      ttl := format('Prima di chiudere: %s cose da registrare', n);
      summ := format('%s registrazioni mancanti', n);
      body := concat_ws(E'\n', v_fs, v_other,
                        case when jsonb_array_length(r->'lots_on_hold') > 0 then 'Lotti bloccati, non vendere: ' || (select string_agg(l #>> '{}', ', ') from jsonb_array_elements(r->'lots_on_hold') l) end,
                        case when n > 0 then 'Il tablet mostra la lista in rosso: basta toccare la voce per registrarla.' end);
    end if;

  when 'ops_health' then
    r := fabula.ops_health_check(p_day);
    begin x := fabula.infra_checks(); exception when others then x := '{}'::jsonb; end;
    select string_agg('• ' || (q->>'text'), E'\n') into v_other from jsonb_array_elements(r->'data_quality') q;
    select string_agg(format('• %s: %s', k, v->>'detail'), E'\n') into v_fs from jsonb_each(x) e(k, v) where not coalesce((v->>'done')::boolean, false);
    n := (r->>'issues')::int + coalesce((select count(*) from jsonb_each(x) e(k, v) where not coalesce((v->>'done')::boolean, false)), 0)::int
         + jsonb_array_length(r->'bots_missing') + (r->>'bots_errors')::int;
    sev := case when exists (select 1 from jsonb_array_elements(r->'data_quality') q where q->>'key' in ('nc_critical_open', 'held_lot_sold', 'ccp_missing', 'instrument_out_of_service', 'pest_inside_7d')) then 'alert'
                when n > 0 then 'warn' else 'info' end;
    ttl := case when n = 0 then 'Nessun problema' else format('%s cose da controllare', n) end;
    summ := format('%s bot mancanti, %s errori, %s problemi dati', jsonb_array_length(r->'bots_missing'), r->>'bots_errors', r->>'issues');
    body := concat_ws(E'\n',
              case when jsonb_array_length(r->'bots_missing') > 0 then 'Bot non partiti oggi: ' || (select string_agg(fabula.bot_display_name(b #>> '{}'), ', ') from jsonb_array_elements(r->'bots_missing') b) end,
              case when (r->>'bots_errors')::int > 0 then format('Errori dei bot oggi: %s (Configurazione → Bot)', r->>'bots_errors') end,
              v_other, case when v_fs is not null then E'Infrastruttura:\n' || v_fs end,
              case when n = 0 then 'Bot, dati, sicurezza alimentare e infrastruttura in ordine.' end,
              'Il controllo degli advisor Supabase lo fa solo il bot.');

  when 'sell_down' then
    r := fabula.sell_down_signals(p_day); n := (r#>>'{totals,proposals_created}')::int;
    sev := case when (r#>>'{totals,expired_lots}')::int > 0 then 'alert' when n > 0 then 'warn' else 'info' end;
    ttl := case when n > 0 then format('%s promo da approvare', n) when (r#>>'{totals,at_risk_kg}')::numeric > 0 then format('%s kg a rischio, nessuna promo nuova', r#>>'{totals,at_risk_kg}') else 'Nessun lotto a rischio' end;
    summ := format('%s promo proposte, %s kg a rischio', n, r#>>'{totals,at_risk_kg}');
    select string_agg(format('• %s lotto %s: %s kg a rischio, scade %s → %s', l->>'name', l->>'lot', l->>'at_risk_kg', to_char((l->>'expiry')::date, 'DD/MM'),
                             case l->>'action' when 'ritirare' then 'SCADUTO, ritirare' when 'promo_banco' then 'promo al banco' when 'offerta_ingrosso_e_promo' then 'promo + offerta ingrosso' when 'spingere_al_banco' then 'spingere al banco' else 'ok' end), E'\n')
      into body from jsonb_array_elements(r->'lots') l where (l->>'at_risk_kg')::numeric > 0 or l->>'action' = 'ritirare';
    body := coalesce(body, 'Nessun lotto a rischio nei prossimi giorni.')
            || case when n > 0 then E'\nApprova in Console → Da approvare. Senza il bot non c''è il codice sconto Shopify: la promo vale al banco.' else '' end;

  when 'backup_export' then
    perform fabula.backup_export_call('nightly');
    ttl := 'Backup notturno rilanciato'; summ := 'backup notturno rilanciato';
    body := 'Il backup notturno non risultava fatto: il database lo ha rilanciato. Se tra un''ora manca ancora, controllare Configurazione → Bot.';

  else
    raise exception 'Nessun ripiego per il bot %', p_agent;
  end case;
  return jsonb_build_object('severity', sev, 'title', ttl, 'body', body, 'summary', summ, 'result', r);
end $$;
revoke all on function fabula.bot_fallback_run(text, date) from public, anon, authenticated;

-- every 5 minutes (pg_cron): stand in for the bots that didn't start
create or replace function fabula.bot_fallback(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = fabula, public as $$
declare v_day date := (p_now at time zone 'Europe/Rome')::date; r record; v_due timestamptz; v_claimed int; o jsonb; v_run uuid;
        done jsonb := '[]'::jsonb; v_err text;
begin
  if fabula.setting_num('bots.db_fallback', 1) <> 1 then return jsonb_build_object('enabled', false); end if;
  for r in select bs.agent, bs.grace_min, t.due from fabula.bot_schedule bs cross join unnest(bs.due_times) t(due)
           where bs.active and bs.agent = any (fabula.bot_fallback_agents())
             and extract(isodow from v_day) = any (bs.weekdays) and (bs.month_day is null or extract(day from v_day) = bs.month_day)
           order by t.due loop
    v_due := (v_day + r.due) at time zone 'Europe/Rome';
    continue when p_now < v_due + make_interval(mins => r.grace_min) or p_now >= v_due + interval '6 hours';
    continue when exists (select 1 from fabula.agent_runs ar where ar.agent = r.agent and ar.started_at >= v_due - interval '30 minutes');
    insert into fabula.bot_fallback_runs (agent, slot, ran_at) values (r.agent, v_due, p_now) on conflict do nothing;
    get diagnostics v_claimed = row_count;
    continue when v_claimed = 0;
    begin
      o := fabula.bot_fallback_run(r.agent, v_day);
      v_run := null;
      if r.agent <> 'backup_export' then        -- the backup logs its own run when it finishes
        insert into fabula.agent_runs (agent, started_at, finished_at, status, summary, details)
        values (r.agent, p_now, clock_timestamp(), 'ok', 'Eseguito dal database (bot non partito): ' || coalesce(o->>'summary', ''),
                jsonb_build_object('via', 'db_fallback', 'due', v_due, 'result', o->'result'))
        returning id into v_run;
      end if;
      perform fabula.post_bot_message(r.agent, o->>'severity', 'Sostituito dal database · ' || coalesce(o->>'title', ''),
                format(E'Il bot "%s" non è partito alle %s: il database ha fatto il suo lavoro. Le notifiche del bot non sono partite: è tutto qui sotto.\n\n%s',
                       fabula.bot_display_name(r.agent), to_char(r.due, 'HH24:MI'), coalesce(o->>'body', '')), v_run);
      update fabula.bot_fallback_runs set status = 'ok', summary = o->>'summary', result = o->'result' where agent = r.agent and slot = v_due;
      done := done || jsonb_build_object('agent', r.agent, 'due', to_char(r.due, 'HH24:MI'), 'status', 'ok', 'summary', o->>'summary');
    exception when others then
      v_err := sqlerrm;
      insert into fabula.agent_runs (agent, started_at, finished_at, status, summary, error, details)
      values (r.agent, p_now, clock_timestamp(), 'error', 'Ripiego del database non riuscito', left(v_err, 500), jsonb_build_object('via', 'db_fallback', 'due', v_due));
      update fabula.bot_fallback_runs set status = 'error', summary = left(v_err, 300) where agent = r.agent and slot = v_due;
      done := done || jsonb_build_object('agent', r.agent, 'due', to_char(r.due, 'HH24:MI'), 'status', 'error', 'error', left(v_err, 200));
    end;
  end loop;
  return jsonb_build_object('enabled', true, 'checked_at', p_now, 'runs', done);
end $$;
revoke all on function fabula.bot_fallback(timestamptz) from public, anon, authenticated;

-- the alarm bot waits 20 more minutes for the bots the database can stand in for, so it reports what the fallback
-- could not fix instead of a bot that has just been covered (the fallback's own errors still alert as errors)
create or replace function fabula.bot_watchdog(p_now timestamp with time zone DEFAULT now()) returns jsonb
language plpgsql security definer set search_path = fabula, public as $$
declare v_ny timestamp := p_now at time zone 'Europe/Rome'; v_day date := (p_now at time zone 'Europe/Rome')::date;
        r record; a jsonb := '[]'::jsonb; v_due timestamptz; v_ref text; n int; v_msg text;
begin
  for r in select ar.id, ar.agent, ar.started_at, coalesce(nullif(ar.error, ''), nullif(ar.summary, ''), 'errore senza dettagli') err, fabula.bot_display_name(ar.agent) nm
           from fabula.agent_runs ar left join fabula.bot_schedule bs on bs.agent = ar.agent
           where ar.status = 'error' and ar.started_at > p_now - interval '26 hours' order by ar.started_at loop
    insert into fabula.bot_alerts (agent, kind, ref, detail) values (r.agent, 'error', r.id::text, left(r.err, 300)) on conflict do nothing;
    get diagnostics n = row_count;
    if n > 0 then a := a || jsonb_build_object('agent', r.agent, 'name', r.nm, 'kind', 'error', 'at', r.started_at, 'detail', left(r.err, 200)); end if;
  end loop;
  for r in select bs.*, t.due from fabula.bot_schedule bs cross join unnest(bs.due_times) t(due)
           where bs.active and extract(isodow from v_day) = any (bs.weekdays) and (bs.month_day is null or extract(day from v_day) = bs.month_day)
             and v_day + t.due + make_interval(mins => bs.grace_min
                   + case when bs.agent = any (fabula.bot_fallback_agents()) and fabula.setting_num('bots.db_fallback', 1) = 1 then 20 else 0 end) <= v_ny loop
    v_due := (v_day + r.due) at time zone 'Europe/Rome';
    if not exists (select 1 from fabula.agent_runs ar where ar.agent = r.agent and ar.started_at >= v_due - interval '30 minutes') then
      v_ref := to_char(v_day + r.due, 'YYYY-MM-DD HH24:MI');
      insert into fabula.bot_alerts (agent, kind, ref, detail) values (r.agent, 'missed', v_ref, null) on conflict do nothing;
      get diagnostics n = row_count;
      if n > 0 then a := a || jsonb_build_object('agent', r.agent, 'name', fabula.bot_display_name(r.agent), 'kind', 'missed', 'due_ny', to_char(r.due, 'HH24:MI'),
                                                 'due_rome', to_char(v_due at time zone 'Europe/Rome', 'HH24:MI')); end if;
    end if;
  end loop;
  for r in select ar.id, ar.agent, ar.started_at, fabula.bot_display_name(ar.agent) nm from fabula.agent_runs ar left join fabula.bot_schedule bs on bs.agent = ar.agent
           where ar.finished_at is null and ar.status is distinct from 'error' and ar.started_at between p_now - interval '26 hours' and p_now - interval '30 minutes' loop
    insert into fabula.bot_alerts (agent, kind, ref) values (r.agent, 'stuck', r.id::text) on conflict do nothing;
    get diagnostics n = row_count;
    if n > 0 then a := a || jsonb_build_object('agent', r.agent, 'name', r.nm, 'kind', 'stuck', 'at', r.started_at); end if;
  end loop;

  if jsonb_array_length(a) > 0 then
    select string_agg(case x->>'kind'
             when 'error' then format('❌ %s: errore alle %s (it.) — %s', x->>'name', to_char((x->>'at')::timestamptz at time zone 'Europe/Rome', 'HH24:MI'), x->>'detail')
             when 'missed' then format('⏰ %s: non è partito (previsto alle %s, ora di Agropoli)', x->>'name', x->>'due_rome')
             else format('⏳ %s: avviato alle %s (it.) e mai finito', x->>'name', to_char((x->>'at')::timestamptz at time zone 'Europe/Rome', 'HH24:MI')) end, E'\n')
      into v_msg from jsonb_array_elements(a) x;
    v_msg := 'Problemi con i bot:' || E'\n' || v_msg || E'\n' || 'Dettagli: Configurazione → Bot. Un bot fermo si rilancia dalle attività programmate.';
    insert into fabula.notices (key, severity, title_it, items, expires_at)
    values ('bot_alert', 'alert', format('%s problemi con i bot', jsonb_array_length(a)), a, p_now + interval '24 hours')
    on conflict (key) do update set severity = 'alert', title_it = excluded.title_it, items = excluded.items, created_at = p_now, expires_at = excluded.expires_at, resolved_at = null;
  end if;
  return jsonb_build_object('checked_at', p_now, 'alerts', a, 'message_it', v_msg);
end $$;

-- nightly backup at 21:15 Rome time in summer and winter: pg_cron fires at 19:15 and 20:15 UTC, only the one that is
-- 21:xx in Rome sends the backup
create or replace function fabula.backup_nightly_rome(p_now timestamptz default now()) returns bigint
language plpgsql security definer set search_path = fabula, public as $$
begin
  if extract(hour from p_now at time zone 'Europe/Rome') <> 21 then return null; end if;
  return fabula.backup_export_call('nightly');
end $$;
revoke all on function fabula.backup_nightly_rome(timestamptz) from public, anon, authenticated;

select cron.schedule('fabula_backup_nightly', '15 19,20 * * *', $c$select fabula.backup_nightly_rome()$c$);
select cron.schedule('fabula_bot_fallback', '*/5 * * * *', $c$select fabula.bot_fallback()$c$);
