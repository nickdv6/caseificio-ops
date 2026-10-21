-- v1.12 (21/10/2026) · the database stands in for every bot (re-audit 19/10, R-02)
--   From 15/10 about 18:30 to 17/10 morning no Claude bot started (Nick's Claude usage ran out during a build session). The database
--   stood in for 6 bots, but the morning brief, sales, marketing, the compliance calendar and the monthly review had no stand-in: on
--   16/10 there was no brief and no Friday sales run, and the watchdog raised «non è partito» for them.
--   Now every Claude bot has a database version (fabula.bot_fallback_agents()), so:
--   * if one does not run, ~45 minutes after its time the database writes its message from the same data function the bot reads,
--     marked «Sostituito dal database», without the bot's comment (bot_fallback, every 5 minutes, unchanged);
--   * Configurazione → Bot → «Esegui ora (versione del database)» works for them too (run_bot_fallback, unchanged);
--   * the watchdog waits 20 more minutes for them before «non è partito» (unchanged rule, it follows the list).
--   What each stand-in does, as the bot (one call, same reads, same writes):
--   * daily_brief: daily_brief(yesterday); on Monday daily_brief(Saturday) + weekly_brief(). Read-only.
--   * sales: sales_status(). Read-only: the ready messages and the search for new venues stay with the bot.
--   * marketing: the bot's one write (quotes in hand → «in_approvazione», a trigger makes the console approvals), then
--     mkt_local_status() + mkt_weekly_status(). The quote requests to suppliers stay with the bot.
--   * compliance_calendar: compliance_calendar(), with its ready messages for technicians and the lab. Read-only.
--   * monthly_review: monthly_review(), which records the recall drill and the recipe proposals, as the bot's own call does.
--   Every read is kept for «Perché?» (keep_basis, by the database: such messages are not number-checked).

-- the marketing bot's slot (Monday and Thursday 07:53) is on live, but no migration made it: a database rebuilt from the repo had no
-- marketing slot, so neither the alarm nor the stand-in knew when it was due. Same row as live; nothing changes where it exists.
insert into fabula.bot_schedule (agent, name_it, due_times, weekdays, grace_min, active, runner)
values ('marketing', 'Marketing', array['07:53'::time], array[1, 4], 45, true, 'claude')
on conflict (agent) do nothing;

create or replace function fabula.bot_fallback_agents()
 returns text[]
 language sql
 immutable
 set search_path to 'fabula', 'public'
as $function$
  select array['milk_planning', 'procurement', 'wholesale_orders', 'haccp_nudge', 'ops_health', 'sell_down', 'backup_export',
               'daily_brief', 'sales', 'marketing', 'compliance_calendar', 'monthly_review']   -- v1.12 (R-02): every Claude bot
$function$;

CREATE OR REPLACE FUNCTION fabula.bot_fallback_run(p_agent text, p_day date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'fabula', 'public'
AS $function$
declare r jsonb; x jsonb; sev text := 'warn'; ttl text; body text; summ text; n int; d date; v_fs text; v_other text;
        v_k int; v_m int; v_n2 int; v_t jsonb; v_w jsonb; v_txt text; v_txt2 text; v_txt3 text; v_nc text; v_exp text; v_when text; v_month text;
        v_todo text[]; v_lines text[]; v_num numeric; v_num2 numeric; v_cnt int; v_old text; v_open int; v_gap text;   -- v1.12 (R-02)
begin
  case p_agent
  when 'milk_planning' then
    r := fabula.plan_milk(); d := (r->>'date')::date;
    if r->>'skipped' = 'pre_opening' then   -- v1.07
      sev := 'info'; ttl := 'Nessun piano latte prima dell''avvio';
      summ := 'nessun piano prima dell''avvio';
      body := (r->>'message_it') || '.';
    elsif r ? 'skipped' then
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
            || case when coalesce((r #>> '{placeholders,count}')::int, 0) > 0 then E'\n' || (r #>> '{placeholders,line_it}') else '' end;

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
    r := r || jsonb_build_object('infra_checks', x);                 -- v1.06 («Perché?»): the system checks go with the evening check's data
    select string_agg('• ' || (q->>'text'), E'\n') into v_other from jsonb_array_elements(r->'data_quality') q;
    select string_agg(format('• %s: %s', k, v->>'detail'), E'\n') into v_fs from jsonb_each(x) e(k, v) where not coalesce((v->>'done')::boolean, false);
    n := (r->>'issues')::int + coalesce((select count(*) from jsonb_each(x) e(k, v) where not coalesce((v->>'done')::boolean, false)), 0)::int
         + jsonb_array_length(r->'bots_missing') + (r->>'bots_errors')::int;
    sev := case when exists (select 1 from jsonb_array_elements(r->'data_quality') q where q->>'key' in ('nc_critical_open', 'held_lot_sold', 'ccp_missing', 'instrument_out_of_service', 'pest_inside_7d')) then 'alert'
                when n > 0 then 'warn' else 'info' end;
    ttl := case when n = 0 then 'Nessun problema' else format('%s cose da controllare', n) end;
    summ := format('%s bot mancanti, %s errori, %s problemi dati', jsonb_array_length(r->'bots_missing'), r->>'bots_errors', r->>'issues');
    body := concat_ws(E'\n',
              case when jsonb_array_length(r->'bots_missing') > 0 then 'Bot non partiti oggi: ' || (select string_agg(fabula.bot_title(b #>> '{}') || case when r->'bots_missing_alerted' ? (b #>> '{}') then ' (già segnalato)' else '' end, ', ')
                                                from jsonb_array_elements(r->'bots_missing') b) end,
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

  -- ======================= v1.12 (R-02): the five bots that had no stand-in =======================
  -- The database writes the same facts from the same data function the bot reads, without the bot's comment; web research and
  -- ready-to-send drafts stay with the bot. The new variables are v_-prefixed: the older branches alias columns k, m, v.
  when 'daily_brief' then
    -- as the bot: Tuesday to Saturday yesterday; on Monday Saturday and the week that just closed
    d := case when extract(isodow from p_day) = 1 then p_day - 2 else p_day - 1 end;
    r := fabula.daily_brief(d);
    v_when := case when extract(isodow from p_day) = 1 then 'sabato ' || to_char(d, 'DD/MM') else 'ieri' end;
    v_todo := '{}'; v_lines := '{}';
    -- requests waiting: the milk plan first, then the oldest
    select count(*), count(*) filter (where ap->>'requested_by' = 'agent:milk_planning'),
           string_agg(format('• Decidi: %s%s', ap->>'summary',     -- age_days counts to the brief's day: from today it is p_day - d more
                             case when coalesce((ap->>'age_days')::int, 0) + (p_day - d) > 0
                                  then format(' (in attesa da %s)', fabula.it_n(coalesce((ap->>'age_days')::int, 0) + (p_day - d), 'giorno', 'giorni')) else '' end),
                      E'\n' order by rn) filter (where rn <= 3)
      into n, v_k, v_txt
      from (select ap, row_number() over (order by coalesce(ap->>'requested_by' = 'agent:milk_planning', false) desc, coalesce((ap->>'age_days')::int, 0) desc) rn
              from jsonb_array_elements(coalesce(r->'pending_approvals', '[]'::jsonb)) ap) pa;
    if n > 0 then
      v_todo := v_todo || (v_txt || case when n = 4 then E'\n• … e un''altra' when n > 4 then format(E'\n• … e altre %s', n - 3) else '' end || E'\n  Dove: Console → Da approvare');
    end if;
    -- HACCP records of the day that are missing (none are asked before the start: daily_brief empties them)
    select count(*), string_agg(coalesce(cp.name, mc #>> '{}'), ', ' order by cp.sort nulls last, mc #>> '{}')
      into v_m, v_fs
      from jsonb_array_elements(coalesce(r #> '{haccp,missing_daily_checks}', '[]'::jsonb)) mc
      left join fabula.haccp_control_points cp on cp.code = mc #>> '{}';
    if v_m > 0 then v_todo := v_todo || format('• Registra sul tablet i controlli di %s che mancano: %s', v_when, v_fs); end if;
    select string_agg(coalesce(cp.name, ec #>> '{}'), ', ' order by cp.sort nulls last)
      into v_other
      from jsonb_array_elements(coalesce(r #> '{haccp,evening_cold_checks_missing}', '[]'::jsonb)) ec
      left join fabula.haccp_control_points cp on cp.code = ec #>> '{}'
     where not (coalesce(r #> '{haccp,missing_daily_checks}', '[]'::jsonb) ? (ec #>> '{}'));
    if v_other is not null then
      v_todo := v_todo || format('• Manca la lettura serale di %s: %s', v_when, v_other);
      v_m := v_m + 1;
    end if;
    select string_agg(format('⚠ Non conformità %s di %s: %s%s%s', coalesce(cp.name, nc->>'point'), v_when,
                             case when jsonb_typeof(nc->'value') = 'number' then fabula.it_qty((nc->>'value')::numeric) else nc->>'value' end,
                             coalesce(' ' || nullif(cp.unit, ''), ''), coalesce(' · ' || nullif(nc->>'action', ''), '')), E'\n')
      into v_nc
      from jsonb_array_elements(coalesce(r #> '{haccp,non_conformities}', '[]'::jsonb)) nc
      left join fabula.haccp_control_points cp on cp.code = nc->>'point';
    -- finished goods (review 21/10): expired ones are to be withdrawn, those expiring today or tomorrow pushed at the counter; a lot on
    -- hold is never offered for sale (the HACCP channels speak about it)
    select string_agg(format('%s lotto %s, %s kg (scaduto %s)', coalesce(pr.name, sf->>'sku'), sf->>'lot', fabula.it_qty((sf->>'kg')::numeric), fabula.it_day((sf->>'expires')::date)),
                      '; ' order by sf->>'expires') filter (where (sf->>'expires')::date < p_day),
           string_agg(format('%s lotto %s, %s kg (scade %s)', coalesce(pr.name, sf->>'sku'), sf->>'lot', fabula.it_qty((sf->>'kg')::numeric), fabula.it_day((sf->>'expires')::date)),
                      '; ' order by sf->>'expires') filter (where (sf->>'expires')::date between p_day and p_day + 1)
      into v_old, v_exp
      from jsonb_array_elements(coalesce(r->'stock_finished', '[]'::jsonb)) sf left join fabula.products pr on pr.sku = sf->>'sku'
     where not exists (select 1 from fabula.v_lots_on_hold lh where lh.batch_lot = sf->>'lot');
    if v_old is not null then v_todo := v_todo || ('⚠ Scaduti, da ritirare (non venderli): ' || v_old); end if;
    if v_exp is not null then v_todo := v_todo || ('• Spingi al banco: ' || v_exp); end if;
    v_open := coalesce((r #>> '{tasks,open_non_conformities}')::int, 0);
    if v_open > 0 then
      v_todo := v_todo || format('⚠ %s (Autocontrollo → Non conformità)', fabula.it_n(v_open, 'non conformità ancora aperta', 'non conformità ancora aperte'));
    end if;
    if jsonb_array_length(coalesce(r->'procurement_signals', '[]'::jsonb)) > 0 then
      v_todo := v_todo || format('• Scorte: %s sotto la soglia (l''ordine proposto è in Console → Da approvare, se il fornitore c''è)',
                                 fabula.it_n(jsonb_array_length(r->'procurement_signals'), 'materiale', 'materiali'));
    end if;
    -- in short
    select string_agg(format('%s %s kg%s', pd->>'product', fabula.it_qty((pd->>'output_kg')::numeric),
                             case when pd->>'yield_pct' is not null then format(' (resa %s %%)', fabula.it_num((pd->>'yield_pct')::numeric, 1)) else '' end), ', ')
      into v_txt
      from jsonb_array_elements(coalesce(r->'production', '[]'::jsonb)) pd;
    if v_txt is not null then
      v_lines := v_lines || format('• Produzione di %s: %s · latte ricevuto %s kg%s%s', v_when, v_txt,
        fabula.it_qty((select coalesce(sum((mi->>'kg')::numeric), 0) from jsonb_array_elements(coalesce(r->'milk', '[]'::jsonb)) mi where coalesce((mi->>'accepted')::boolean, false))),
        (select case when count(*) > 0 then ', ' || fabula.it_n(count(*)::numeric, 'consegna rifiutata', 'consegne rifiutate') else '' end
           from jsonb_array_elements(coalesce(r->'milk', '[]'::jsonb)) mi where not coalesce((mi->>'accepted')::boolean, true)),
        case when (r #>> '{changes,yield_vs_30d_points}')::numeric < -1.5
             then format(' · resa sotto la media di 30 giorni di %s punti', fabula.it_num(abs((r #>> '{changes,yield_vs_30d_points}')::numeric), 1)) else '' end);
    end if;
    if coalesce((r #>> '{sales_trend,yesterday_eur}')::numeric, 0) > 0 or coalesce((r #>> '{sales_trend,week_to_date_eur}')::numeric, 0) > 0 then
      v_lines := v_lines || format('• Vendite di %s € %s%s · settimana € %s', v_when, fabula.it_num((r #>> '{sales_trend,yesterday_eur}')::numeric, 0),
        case when r #>> '{changes,sales_vs_same_weekday_pct}' is not null
             then format(' (%s%s %% sullo stesso giorno delle 4 settimane prima)', case when (r #>> '{changes,sales_vs_same_weekday_pct}')::numeric > 0 then '+' else '' end,
                         fabula.it_num((r #>> '{changes,sales_vs_same_weekday_pct}')::numeric, 0)) else '' end,
        fabula.it_num((r #>> '{sales_trend,week_to_date_eur}')::numeric, 0));
    end if;
    if coalesce((r #>> '{pos_close,variance_eur}')::numeric, 0) <> 0 then
      v_lines := v_lines || format('• Chiusura di cassa: differenza di € %s', fabula.it_num((r #>> '{pos_close,variance_eur}')::numeric, 2));
    end if;
    if (r #>> '{waste,last_7d_pct_of_output}')::numeric > 10 then
      v_lines := v_lines || format('• Scarti degli ultimi 7 giorni: %s kg, %s %% della produzione', fabula.it_qty((r #>> '{waste,last_7d_kg}')::numeric),
                                   fabula.it_num((r #>> '{waste,last_7d_pct_of_output}')::numeric, 1));
    end if;
    if (r #>> '{changes,energy_kwh_per_kg_vs_30d_pct}')::numeric > 15 then
      v_lines := v_lines || format('• Energia: %s kWh per kg, %s %% sopra la media di 30 giorni', fabula.it_num((r #>> '{energy,yesterday_kwh_per_kg}')::numeric, 2),
                                   fabula.it_num((r #>> '{changes,energy_kwh_per_kg_vs_30d_pct}')::numeric, 0));
    end if;
    if jsonb_array_length(coalesce(r->'production', '[]'::jsonb)) = 0 and coalesce((r #>> '{sales_trend,yesterday_eur}')::numeric, 0) = 0 then
      v_lines := v_lines || format('• %s nessuna produzione né vendita%s', upper(left(v_when, 1)) || substr(v_when, 2),
                                   coalesce(' · ' || (r #>> '{pre_opening,note_it}'), ''));
    end if;
    v_n2 := jsonb_array_length(coalesce(r #> '{tasks,overdue}', '[]'::jsonb));
    if v_n2 > 0 then
      v_lines := v_lines || format('• %s · elenco sul tablet', case when v_n2 = 1 then '1 attività scaduta' else v_n2 || ' attività scadute' end);
    end if;
    if jsonb_array_length(coalesce(r #> '{tasks,calibration_due}', '[]'::jsonb)) > 0 then
      v_lines := v_lines || format('• Tarature entro 14 giorni: %s (Autocontrollo → Strumenti)', jsonb_array_length(r #> '{tasks,calibration_due}'));
    end if;
    if jsonb_array_length(coalesce(r #> '{tasks,training_expiring}', '[]'::jsonb)) > 0 then
      v_lines := v_lines || format('• Attestati HACCP in scadenza entro 30 giorni: %s (Autocontrollo → Formazione)', jsonb_array_length(r #> '{tasks,training_expiring}'));
    end if;
    ttl := case when v_nc is not null then format('⚠ Non conformità HACCP di %s: vedi Autocontrollo', v_when)
                when v_old is not null then '⚠ Prodotti scaduti in magazzino: ritirali'
                when v_open > 0 then format('⚠ %s da chiudere (Autocontrollo)', fabula.it_n(v_open, 'non conformità aperta', 'non conformità aperte'))
                when v_k > 0 then 'Approva il piano latte (Console → Da approvare)'
                when v_m > 0 then format('Registra i controlli HACCP di %s (%s)', v_when, fabula.it_n(v_m, 'mancante', 'mancanti'))
                when n > 0 then format('%s da decidere (Console → Da approvare)', fabula.it_n(n, 'richiesta', 'richieste'))
                when v_exp is not null then 'Spingi al banco i prodotti in scadenza'
                else format('%s tutto in ordine', upper(left(v_when, 1)) || substr(v_when, 2)) end;
    sev := case when v_nc is not null or v_old is not null or v_open > 0 or v_k > 0
                     or (v_m > 0 and jsonb_array_length(coalesce(r->'production', '[]'::jsonb)) > 0) then 'alert'
                when n > 0 or v_m > 0 or v_exp is not null then 'warn' else 'info' end;
    if coalesce((r->>'is_simulation')::boolean, false) then ttl := 'SIMULAZIONE · ' || ttl; end if;
    summ := ttl;
    body := concat_ws(E'\n\n', v_nc,
                      case when cardinality(v_todo) > 0 then E'Da fare:\n' || array_to_string(v_todo, E'\n') end,
                      case when cardinality(v_lines) > 0 then E'In breve:\n' || array_to_string(v_lines, E'\n') end);
    if extract(isodow from p_day) = 1 then
      v_w := fabula.keep_basis('daily_brief', 'weekly_brief', fabula.weekly_brief(), 'database');
      v_t := v_w->'this_week';
      if coalesce((v_t #>> '{production,batches}')::numeric, 0) = 0 and coalesce((v_t #>> '{sales,revenue_eur}')::numeric, 0) = 0 then
        v_txt := '• Nessuna produzione né vendita registrata nella settimana';
      else
        v_txt := concat_ws(E'\n',
          format('• Risultato stimato € %s su € %s di ricavi; settimana di riferimento € %s%s (stima: latte e ricavi reali, altri costi da benchmark)',
                 fabula.it_num((v_w #>> '{pnl_estimate,operating_result_eur}')::numeric, 0), fabula.it_num((v_w #>> '{pnl_estimate,revenue_eur}')::numeric, 0),
                 fabula.it_num((v_w #>> '{pnl_estimate,benchmark_weekly_profit_eur}')::numeric, 0),
                 case when coalesce((v_w #>> '{pnl_estimate,revenue_eur}')::numeric, 0) >= 500 and v_w #>> '{pnl_estimate,margin_pct}' is not null
                      then format(', margine %s %%', fabula.it_num((v_w #>> '{pnl_estimate,margin_pct}')::numeric, 0)) else '' end),
          format('• Vendite € %s%s · mozzarella venduta %s kg', fabula.it_num((v_t #>> '{sales,revenue_eur}')::numeric, 0),
                 case when v_w #>> '{changes,sales,revenue_eur}' is not null
                      then format(' (%s%s %% sulla settimana prima)', case when (v_w #>> '{changes,sales,revenue_eur}')::numeric > 0 then '+' else '' end,
                                  fabula.it_num((v_w #>> '{changes,sales,revenue_eur}')::numeric, 0)) else '' end,
                 fabula.it_qty((v_t #>> '{sales,mozzarella_sold_kg}')::numeric)),
          format('• Produzione: latte %s kg, mozzarella %s kg, ricotta %s kg%s', fabula.it_qty((v_t #>> '{production,milk_processed_kg}')::numeric),
                 fabula.it_qty((v_t #>> '{production,mozzarella_kg}')::numeric), fabula.it_qty((v_t #>> '{production,ricotta_kg}')::numeric),
                 case when v_t #>> '{production,yield_pct}' is not null then format(', resa %s %%', fabula.it_num((v_t #>> '{production,yield_pct}')::numeric, 1)) else '' end),
          case when (v_t #>> '{waste,pct_of_mozzarella_output}')::numeric > 10
               then format('• Scarti %s kg, %s %% della mozzarella', fabula.it_qty((v_t #>> '{waste,mozzarella_kg}')::numeric),
                           fabula.it_num((v_t #>> '{waste,pct_of_mozzarella_output}')::numeric, 1)) end);
      end if;
      body := concat_ws(E'\n\n', body, format(E'La settimana (%s – %s):\n%s', fabula.it_day((v_w->>'week_start')::date), fabula.it_day((v_w->>'week_end')::date), v_txt));
      summ := 'lun+sett: ' || ttl;
    end if;

  when 'sales' then
    -- the numbers and the contacts due; the ready messages and the search for new venues stay with the bot
    r := fabula.sales_status(p_day);
    select count(*), count(*) filter (where coalesce((ad->>'overdue_days')::int, 0) > 0),
           string_agg(format('• %s (%s, %s%s) · %s%s', ad->>'name', case ad->>'segment' when 'bnb' then 'B&B' else ad->>'segment' end, ad->>'town',
                             coalesce(', ' || nullif(ad->>'phone', ''), ''),
                             coalesce(nullif(ad->>'next_action', ''), 'da contattare'),
                             case when coalesce((ad->>'overdue_days')::int, 0) > 0 then format(' · %s di ritardo', fabula.it_n((ad->>'overdue_days')::int, 'giorno', 'giorni')) else '' end),
                      E'\n' order by rn) filter (where rn <= 6)
      into n, v_k, v_txt
      from jsonb_array_elements(coalesce(r->'actions_due', '[]'::jsonb)) with ordinality al(ad, rn);
    -- sales_status lists at most 15: the counts come from the leads themselves (same rule: open stage, action due by tomorrow)
    select greatest(n, count(*)::int), greatest(v_k, (count(*) filter (where sl.next_action_date < p_day))::int) into n, v_k
      from fabula.sales_leads sl where sl.stage in ('nuovo', 'contattato', 'degustazione', 'offerta') and sl.next_action_date <= p_day + 1;
    v_lines := array[case when coalesce((r->>'plan_missing')::boolean, false) then '• Obiettivi non attivi: manca la data di apertura (Configurazione → Parametri → Marketing)'
                          when (r->>'plan_start')::date > p_day then format('• Obiettivi dal %s · vendite del mese € %s', fabula.it_day((r->>'plan_start')::date),
                                                                             fabula.it_num((r #>> '{totals,mtd_revenue_eur}')::numeric, 0))
                          else format('• Totale del mese: %s kg al giorno, obiettivo %s · € %s su € %s', fabula.it_num((r #>> '{totals,mtd_kg_day}')::numeric, 1),
                                      fabula.it_num((r #>> '{totals,target_kg_day}')::numeric, 1), fabula.it_num((r #>> '{totals,mtd_revenue_eur}')::numeric, 0),
                                      fabula.it_num((r #>> '{totals,month_target_eur}')::numeric, 0)) end];
    select '• Locali aperti: ' || coalesce(r #>> '{pipeline,active_n}', '0') || coalesce(' (' || string_agg(format('%s %s', bs->>'n',
             case bs->>'stage' when 'nuovo' then case when (bs->>'n')::int = 1 then 'nuovo' else 'nuovi' end
                               when 'contattato' then case when (bs->>'n')::int = 1 then 'contattato' else 'contattati' end
                               when 'degustazione' then 'in degustazione' else 'con offerta' end), ', ') || ')', '')
      into v_txt2 from jsonb_array_elements(coalesce(r #> '{pipeline,by_stage}', '[]'::jsonb)) bs
     where bs->>'stage' in ('nuovo', 'contattato', 'degustazione', 'offerta');
    v_lines := v_lines || v_txt2;
    select '• Fermi da riprendere: ' || string_agg(format('%s (%s)', st->>'name',
             case when st->>'days_since_contact' is null then 'mai sentito' else fabula.it_n((st->>'days_since_contact')::int, 'giorno', 'giorni') end), ', ' order by rn) filter (where rn <= 5)
      into v_txt2 from jsonb_array_elements(coalesce(r->'stale', '[]'::jsonb)) with ordinality sl(st, rn);
    if v_txt2 is not null then v_lines := v_lines || v_txt2; end if;
    select '• Clienti da recuperare: ' || string_agg(format('%s (ultimo ordine %s%s)', la->>'customer', fabula.it_day((la->>'last_order')::date),
                                                             coalesce(', ' || nullif(la->>'phone', ''), '')), '; ')
      into v_txt2 from jsonb_array_elements(coalesce(r #> '{accounts,lapsed}', '[]'::jsonb)) la;
    if v_txt2 is not null then v_lines := v_lines || v_txt2; end if;
    select '• Degustazioni nei prossimi 7 giorni: ' || string_agg(format('%s, %s (%s)', tg->>'name', tg->>'town', fabula.it_day((tg->>'date')::date)), '; ')
      into v_txt2 from jsonb_array_elements(coalesce(r->'tastings_next_7d', '[]'::jsonb)) tg;
    if v_txt2 is not null then v_lines := v_lines || v_txt2; end if;
    select '• Vinti questo mese: ' || string_agg(wn->>'name', ', ') into v_txt2 from jsonb_array_elements(coalesce(r->'won_this_month', '[]'::jsonb)) wn;
    if v_txt2 is not null then v_lines := v_lines || v_txt2; end if;
    ttl := case when n > 0 then format('%s da contattare%s', fabula.it_n(n, 'locale', 'locali'), case when v_k > 0 then format(' (%s in ritardo)', v_k) else '' end)
                else 'Nessun contatto in scadenza' end;
    sev := case when v_k > 0 or jsonb_array_length(coalesce(r #> '{accounts,lapsed}', '[]'::jsonb)) > 0 then 'warn' else 'info' end;
    summ := format('da contattare %s, in ritardo %s, locali aperti %s', n, v_k, coalesce(r #>> '{pipeline,active_n}', '0'));
    body := concat_ws(E'\n\n',
                      case when n > 0 then 'Da contattare' || case when n > 6 then format(' (i primi 6 di %s)', n) else '' end || E':\n' || v_txt end,
                      E'In breve:\n' || array_to_string(v_lines, E'\n'),
                      'Senza il bot mancano i messaggi pronti da mandare e la ricerca di nuovi locali.');

  when 'marketing' then
    -- the bot's one write, the same here: quotes in hand go to the console (a trigger makes one approval each; nothing is ordered until approved)
    with moved as (update fabula.mkt_local_items set status = 'in_approvazione' where status = 'preventivo' and quote_eur is not null returning title_it, quote_eur)
    select count(*), string_agg(format('%s (€ %s)', title_it, fabula.it_num(quote_eur, 0)), '; '), sum(quote_eur) into v_k, v_txt2, v_num2 from moved;
    r := jsonb_build_object('local', fabula.mkt_local_status(p_day), 'content', fabula.mkt_weekly_status(p_day), 'moved_to_approval', v_k);
    n := jsonb_array_length(coalesce(r #> '{local,overdue}', '[]'::jsonb));
    v_m := jsonb_array_length(coalesce(r #> '{local,permits_to_request}', '[]'::jsonb));
    select count(*), sum(coalesce((aw->>'eur')::numeric, 0)) into v_n2, v_num from jsonb_array_elements(coalesce(r #> '{local,awaiting_decision}', '[]'::jsonb)) aw;
    v_n2 := v_n2 - v_k; v_num := coalesce(v_num, 0) - coalesce(v_num2, 0);     -- the ones just moved are listed once, under «Decidi»
    select count(*), string_agg(qn->>'title', '; ' order by qn->>'planned_on') into v_cnt, v_txt3
      from jsonb_array_elements(coalesce(r #> '{local,quotes_needed}', '[]'::jsonb)) qn
     where coalesce((r #>> '{local,opening_missing}')::boolean, false) or (qn->>'planned_on')::date <= p_day + 21;
    v_todo := '{}'; v_lines := '{}';
    if n > 0 then
      v_todo := v_todo || (select '• In ritardo: ' || string_agg(format('%s (previsto %s)', ov->>'title', fabula.it_day((ov->>'planned_on')::date)), '; ' order by ov->>'planned_on')
                             from jsonb_array_elements(r #> '{local,overdue}') ov);
    end if;
    if v_k > 0 then v_todo := v_todo || ('• Decidi i preventivi arrivati (Console → Da approvare): ' || v_txt2); end if;
    if v_n2 > 0 then v_todo := v_todo || format('• In attesa di decisione: %s, € %s (Console → Da approvare)', v_n2, fabula.it_num(v_num, 0)); end if;
    if v_cnt > 0 then v_todo := v_todo || format('• Preventivi da chiedere entro 3 settimane (%s): %s', v_cnt, v_txt3); end if;
    if v_m > 0 then
      v_todo := v_todo || (select format('• Permessi da chiedere: %s%s%s', v_m,
                                         case when min((pt->>'planned_on')::date) is not null then ', il primo serve entro ' || fabula.it_day(min((pt->>'planned_on')::date)) else '' end,
                                         case when v_m <= 3 then ' (' || string_agg(pt->>'title', '; ') || ')' else '' end)
                             from jsonb_array_elements(r #> '{local,permits_to_request}') pt);
    end if;
    if coalesce((r #>> '{local,opening_missing}')::boolean, false) then
      v_todo := v_todo || '• Imposta la data di apertura (Configurazione → Parametri → Marketing): senza data le scadenze di insegne e permessi non si calcolano.'::text;
    else
      v_lines := v_lines || case when (r #>> '{local,days_to_opening}')::int > 0
                                 then format('• Apertura %s, tra %s', fabula.it_day((r #>> '{local,opening_date}')::date), fabula.it_n((r #>> '{local,days_to_opening}')::int, 'giorno', 'giorni'))
                                 when (r #>> '{local,days_to_opening}')::int = 0 then '• Apertura oggi'
                                 else format('• Aperto dal %s', fabula.it_day((r #>> '{local,opening_date}')::date)) end;
    end if;
    v_lines := v_lines || (select format('• Budget della campagna € %s: impegnati € %s, spesi € %s', fabula.it_num(coalesce(sum((cg->>'planned_eur')::numeric), 0), 0),
                                         fabula.it_num(coalesce(sum((cg->>'committed_eur')::numeric), 0), 0), fabula.it_num(coalesce(sum((cg->>'spent_eur')::numeric), 0), 0))
                             from jsonb_array_elements(coalesce(r #> '{local,campaigns}', '[]'::jsonb)) cg);
    if jsonb_array_length(coalesce(r #> '{local,due_14d}', '[]'::jsonb)) > 0 then
      v_lines := v_lines || format('• Voci della campagna previste entro 14 giorni: %s', jsonb_array_length(r #> '{local,due_14d}'));
    end if;
    if jsonb_array_length(coalesce(r #> '{local,live}', '[]'::jsonb)) > 0 then
      v_lines := v_lines || (select format('• Azioni attive: %s, %s, € %s di vendite su € %s di costo', count(*),
                                           fabula.it_n(coalesce(sum((lv->>'orders')::numeric), 0), 'ordine', 'ordini'),
                                           fabula.it_num(coalesce(sum((lv->>'revenue_eur')::numeric), 0), 0), fabula.it_num(coalesce(sum((lv->>'cost_eur')::numeric), 0), 0))
                               from jsonb_array_elements(r #> '{local,live}') lv);
    end if;
    v_lines := v_lines || format('• Contenuti: %s nei prossimi 7%s%s', fabula.it_n(coalesce((r #>> '{content,content_gaps}')::int, 7), 'giorno senza post', 'giorni senza post'),
                                 case when coalesce((r #>> '{content,to_review}')::int, 0) > 0 then format(', %s da rivedere', r #>> '{content,to_review}') else '' end,
                                 case when jsonb_array_length(coalesce(r #> '{content,influencers_follow_up}', '[]'::jsonb)) > 0
                                      then format(', %s da risentire', fabula.it_n(jsonb_array_length(r #> '{content,influencers_follow_up}'), 'influencer', 'influencer')) else '' end);
    ttl := case when n > 0 then format('Campagna locale: %s in ritardo', fabula.it_n(n, 'voce', 'voci'))
                when v_k > 0 then format('%s da decidere', fabula.it_n(v_k, 'preventivo arrivato', 'preventivi arrivati'))
                when v_cnt > 0 then format('Chiedi %s', fabula.it_n(v_cnt, 'preventivo', 'preventivi'))
                when coalesce((r #>> '{local,opening_missing}')::boolean, false) then 'Imposta la data di apertura'
                when v_m > 0 then (select format('Permessi da chiedere: %s%s', v_m,
                                                 case when min((pt->>'planned_on')::date) is not null then format(' (il primo entro %s)', fabula.it_day(min((pt->>'planned_on')::date))) else '' end)
                                   from jsonb_array_elements(r #> '{local,permits_to_request}') pt)
                when v_n2 > 0 then format('%s da decidere (Console → Da approvare)', fabula.it_n(v_n2, 'voce', 'voci'))
                when jsonb_array_length(coalesce(r #> '{local,due_14d}', '[]'::jsonb)) > 0
                     then format('Campagna locale: %s entro 14 giorni', fabula.it_n(jsonb_array_length(r #> '{local,due_14d}'), 'voce', 'voci'))
                when coalesce((r #>> '{content,content_gaps}')::int, 0) > 0
                     then format('Contenuti: %s nei prossimi 7', fabula.it_n((r #>> '{content,content_gaps}')::int, 'giorno senza post', 'giorni senza post'))
                when coalesce((r #>> '{content,to_review}')::int, 0) > 0
                     then format('Contenuti: %s da rivedere', fabula.it_n((r #>> '{content,to_review}')::int, 'post', 'post'))
                else 'Niente da fare questa settimana' end;
    sev := case when n > 0 and coalesce((r #>> '{local,days_to_opening}')::int, 999) <= 60 then 'alert'
                when n > 0 or v_k > 0 or v_cnt > 0 then 'warn' else 'info' end;
    summ := format('permessi %s, preventivi %s, in approvazione %s, attivi %s, giorni all''apertura %s', v_m, v_cnt, v_k + v_n2,
                   jsonb_array_length(coalesce(r #> '{local,live}', '[]'::jsonb)), coalesce(r #>> '{local,days_to_opening}', 'n.d.'));
    body := concat_ws(E'\n\n',
                      case when cardinality(v_todo) > 0 then E'Da fare:\n' || array_to_string(v_todo, E'\n') end,
                      E'In breve:\n' || array_to_string(v_lines, E'\n'),
                      'Senza il bot mancano le richieste di preventivo pronte da mandare ai fornitori.');

  when 'compliance_calendar' then
    r := fabula.compliance_calendar(p_day);
    x := r->'food_safety';
    v_todo := '{}'; v_lines := '{}';
    if jsonb_array_length(coalesce(x->'lots_on_hold', '[]'::jsonb)) > 0 then
      v_todo := v_todo || (select '⚠ Lotti bloccati, non venderli: ' || string_agg(lh #>> '{}', ', ') from jsonb_array_elements(x->'lots_on_hold') lh);
    end if;
    if jsonb_array_length(coalesce(x->'instruments_out_of_service', '[]'::jsonb)) > 0 then
      v_todo := v_todo || (select '⚠ Strumenti fuori servizio, non usarli: ' || string_agg(coalesce(eq.name || ' (' || eq.code || ')', io #>> '{}'), ', ')
                             from jsonb_array_elements(x->'instruments_out_of_service') io left join fabula.equipment eq on eq.code = io #>> '{}');
    end if;
    if coalesce((x->>'nc_critical_open')::int, 0) > 0 then
      v_todo := v_todo || format('⚠ Non conformità critiche aperte: %s (Autocontrollo)', x->>'nc_critical_open');
    end if;
    if jsonb_array_length(coalesce(x->'lab_results_pending', '[]'::jsonb)) > 0 then
      v_todo := v_todo || format('• Esiti di laboratorio in attesa: %s (Autocontrollo → Laboratorio)', jsonb_array_length(x->'lab_results_pending'));
    end if;
    select count(*), string_agg(format('• %s%s%s · scadenza %s, %s fa%s',
                                       case it->>'kind' when 'calibration' then 'Taratura ' when 'maintenance' then 'Manutenzione ' when 'training' then 'Attestato ' when 'campionamento' then 'Analisi ' else '' end,
                                       it->>'subject', coalesce(' (' || nullif(it->>'ref', '') || ')', ''), to_char((it->>'due_on')::date, 'DD/MM'),
                                       fabula.it_n(abs((it->>'days')::int), 'giorno', 'giorni'), coalesce(' · ' || nullif(it->>'contact', ''), '')),
                                E'\n' order by rn) filter (where rn <= 8)
      into n, v_txt from jsonb_array_elements(coalesce(r->'overdue', '[]'::jsonb)) with ordinality od(it, rn);
    if n > 0 then v_todo := v_todo || (E'Scadute:\n' || v_txt || case when n = 9 then E'\n• … e un''altra' when n > 9 then format(E'\n• … e altre %s', n - 8) else '' end); end if;
    select count(*), string_agg(format('• %s%s%s · scadenza %s, %s%s',
                                       case it->>'kind' when 'calibration' then 'Taratura ' when 'maintenance' then 'Manutenzione ' when 'training' then 'Attestato ' when 'campionamento' then 'Analisi ' else '' end,
                                       it->>'subject', coalesce(' (' || nullif(it->>'ref', '') || ')', ''), to_char((it->>'due_on')::date, 'DD/MM'),
                                       case when (it->>'days')::int = 0 then 'oggi' else 'tra ' || fabula.it_n((it->>'days')::int, 'giorno', 'giorni') end,
                                       coalesce(' · ' || nullif(it->>'contact', ''), '')),
                                E'\n' order by rn) filter (where rn <= 8)
      into v_k, v_txt from jsonb_array_elements(coalesce(r->'due_30', '[]'::jsonb)) with ordinality du(it, rn);
    if v_k > 0 then v_lines := v_lines || (E'Entro 30 giorni:\n' || v_txt || case when v_k = 9 then E'\n• … e un''altra' when v_k > 9 then format(E'\n• … e altre %s', v_k - 8) else '' end); end if;
    if jsonb_array_length(coalesce(r->'due_60', '[]'::jsonb)) > 0 then
      v_lines := v_lines || format('• Entro 60 giorni: %s', jsonb_array_length(r->'due_60'));
    end if;
    select string_agg(format('%s %s', cnt, case kd when 'calibration' then case when cnt = 1 then 'taratura' else 'tarature' end
                                                 when 'maintenance' then case when cnt = 1 then 'manutenzione' else 'manutenzioni' end
                                                 when 'verifica' then case when cnt = 1 then 'verifica' else 'verifiche' end
                                                 when 'training' then case when cnt = 1 then 'attestato' else 'attestati' end
                                                 when 'campionamento' then 'analisi'
                                                 else case when cnt = 1 then 'altra scadenza' else 'altre scadenze' end end), ', '
                      order by array_position(array['calibration', 'maintenance', 'verifica', 'training', 'campionamento', 'altro'], kd))
      into v_txt2
      from (select case when uk->>'kind' in ('calibration', 'maintenance', 'verifica', 'training', 'campionamento') then uk->>'kind' else 'altro' end kd, count(*) cnt
              from jsonb_array_elements(coalesce(r->'unknown_dates', '[]'::jsonb)) uk group by 1) ug;
    if v_txt2 is not null then
      v_lines := v_lines || ('• Senza data: ' || v_txt2 || '. Il calendario non può avvisare finché mancano (Autocontrollo → Strumenti / Formazione; Configurazione → Macchine e scadenze)');
    end if;
    if not coalesce((x->>'sampling_plan_active')::boolean, false) then
      v_lines := v_lines || '• Piano campionamenti non attivo (Configurazione → Parametri → Sicurezza alimentare e DOP)'::text;
    end if;
    if x->>'pest_last_internal' is null and x->>'pest_last_company' is null then
      v_lines := v_lines || '• Nessun controllo infestanti registrato'::text;
    end if;
    select string_agg(format(E'Per %s%s:\n> %s', coalesce(eq.name || ' (' || eq.code || ')', td->>'ref'), coalesce(', ' || nullif(td->>'contact', ''), ''), td->>'message_it'), E'\n\n')
      into v_txt3 from jsonb_array_elements(coalesce(r->'technician_drafts', '[]'::jsonb)) td left join fabula.equipment eq on eq.code = td->>'ref';
    if jsonb_typeof(r->'lab_request_draft') = 'object' then
      v_txt3 := concat_ws(E'\n\n', v_txt3, format(E'Al laboratorio%s:\n> %s\n> %s', coalesce(' ' || coalesce(r #>> '{lab_request_draft,lab}', r #>> '{lab_request_draft,to}'), ''),
                                                   r #>> '{lab_request_draft,subject_it}', r #>> '{lab_request_draft,message_it}'));
    end if;
    ttl := case when jsonb_array_length(coalesce(x->'lots_on_hold', '[]'::jsonb)) > 0 then format('⚠ Lotti bloccati: %s', jsonb_array_length(x->'lots_on_hold'))
                when jsonb_array_length(coalesce(x->'instruments_out_of_service', '[]'::jsonb)) > 0 then format('⚠ Strumenti fuori servizio: %s', jsonb_array_length(x->'instruments_out_of_service'))
                when coalesce((x->>'nc_critical_open')::int, 0) > 0 then format('⚠ Non conformità critiche aperte: %s', x->>'nc_critical_open')
                when jsonb_array_length(coalesce(x->'lab_results_pending', '[]'::jsonb)) > 0
                     then format('⚠ Esiti di laboratorio in attesa: %s', jsonb_array_length(x->'lab_results_pending'))
                when n = 1 then 'Scadenza superata: ' || (r #>> '{overdue,0,subject}')
                when n > 1 then format('%s scadenze superate', n)
                when v_k > 0 then format('%s entro 30 giorni', fabula.it_n(v_k, 'scadenza', 'scadenze'))
                else 'Nessuna scadenza entro 30 giorni' || case when coalesce((r #>> '{counts,unknown}')::int, 0) > 0
                                                                then format(' · %s ancora da impostare', fabula.it_n((r #>> '{counts,unknown}')::int, 'data', 'date')) else '' end end;
    sev := case when jsonb_array_length(coalesce(x->'lots_on_hold', '[]'::jsonb)) > 0 or jsonb_array_length(coalesce(x->'instruments_out_of_service', '[]'::jsonb)) > 0
                     or coalesce((x->>'nc_critical_open')::int, 0) > 0 or jsonb_array_length(coalesce(x->'lab_results_pending', '[]'::jsonb)) > 0 then 'alert'
                when n > 0 or v_k > 0 then 'warn' else 'info' end;
    summ := format('%s scadute, %s entro 30 gg, %s senza data, %s analisi da prenotare', coalesce(r #>> '{counts,overdue}', '0'), coalesce(r #>> '{counts,due_30}', '0'),
                   coalesce(r #>> '{counts,unknown}', '0'), coalesce(jsonb_array_length(r #> '{lab_request_draft,tests}'), 0));
    body := concat_ws(E'\n\n',
                      case when cardinality(v_todo) > 0 then E'Da fare:\n' || array_to_string(v_todo, E'\n') end,
                      case when cardinality(v_lines) > 0 then E'In breve:\n' || array_to_string(v_lines, E'\n') end,
                      case when v_txt3 is not null then E'Messaggi pronti:\n' || v_txt3 end);

  when 'monthly_review' then
    -- the month that just ended; like the bot's own call it records the recall drill and the recipe proposals (approvals)
    r := fabula.monthly_review();
    x := r->'food_safety';
    v_month := (array['Gennaio', 'Febbraio', 'Marzo', 'Aprile', 'Maggio', 'Giugno', 'Luglio', 'Agosto', 'Settembre', 'Ottobre', 'Novembre', 'Dicembre'])[split_part(r->>'month', '-', 2)::int]
               || ' ' || split_part(r->>'month', '-', 1);
    v_k := coalesce((r #>> '{recipe_tuning,created}')::int, 0);
    n := coalesce((x #>> '{non_conformities,critical_open}')::int, 0);
    v_todo := '{}'; v_lines := '{}';
    if n > 0 then v_todo := v_todo || format('⚠ Chiudi le non conformità critiche aperte: %s (Autocontrollo)', n); end if;
    if jsonb_array_length(coalesce(x->'lots_on_hold', '[]'::jsonb)) > 0 then
      -- food_safety_summary lists the lots as objects (lot, reason, kg_on_hand)
      v_todo := v_todo || (select '⚠ Lotti bloccati: ' || string_agg(coalesce(lh->>'lot', lh #>> '{}') || coalesce(' (' || nullif(lh->>'reason', '') || ')', ''), ', ')
                             from jsonb_array_elements(x->'lots_on_hold') lh);
    end if;
    if jsonb_array_length(coalesce(x #> '{instruments,out_of_service}', '[]'::jsonb)) > 0 then
      v_todo := v_todo || (select '⚠ Strumenti fuori servizio: ' || string_agg(coalesce(eq.name || ' (' || eq.code || ')', io #>> '{}'), ', ')
                             from jsonb_array_elements(x #> '{instruments,out_of_service}') io left join fabula.equipment eq on eq.code = io #>> '{}');
    end if;
    -- the other food-safety gaps of the month (review 21/10: the bot's prompt makes them a «warn», never «info»)
    v_gap := concat_ws(', ',
      (select case when sum(coalesce((cc->>'nc')::int, 0)) > 0 then fabula.it_n(sum(coalesce((cc->>'nc')::int, 0)), 'valore CCP fuori limite', 'valori CCP fuori limite') end
         from jsonb_array_elements(coalesce(x->'ccp', '[]'::jsonb)) cc),
      case when jsonb_array_length(coalesce(x->'batches_without_ccp', '[]'::jsonb)) > 0
           then fabula.it_n(jsonb_array_length(x->'batches_without_ccp'), 'lotto senza registrazione CCP', 'lotti senza registrazione CCP') end,
      case when jsonb_array_length(coalesce(x #> '{lab,non_conformi}', '[]'::jsonb)) > 0
           then fabula.it_n(jsonb_array_length(x #> '{lab,non_conformi}'), 'analisi non conforme', 'analisi non conformi') end,
      case when jsonb_array_length(coalesce(x #> '{lab,overdue}', '[]'::jsonb)) > 0
           then fabula.it_n(jsonb_array_length(x #> '{lab,overdue}'), 'analisi in ritardo', 'analisi in ritardo') end);
    v_gap := nullif(v_gap, '');
    if v_gap is not null then v_todo := v_todo || ('• Rivedi in Autocontrollo: ' || v_gap); end if;
    if v_k > 0 then v_todo := v_todo || format('• Decidi %s (Console → Da approvare)', fabula.it_n(v_k, 'proposta di ricetta', 'proposte di ricetta')); end if;
    v_todo := v_todo || '• Pacchetto per il commercialista: Console → Pacchetto mensile → Stampa/PDF'::text;
    if coalesce((r #>> '{milk_quality,deliveries}')::int, 0) = 0 and coalesce((r #>> '{unit_cost,mozzarella_kg}')::numeric, 0) = 0
       and coalesce((r #>> '{package_headline,revenue_eur}')::numeric, 0) = 0 then
      v_lines := v_lines || '• Mese senza produzione, consegne né vendite'::text;
    end if;
    v_lines := v_lines || format('• Prova di richiamo%s: %s', coalesce(' sul lotto ' || (r #>> '{recall_drill,lot}'), ''),
      case r #>> '{recall_drill,result}' when 'ok' then 'la tracciabilità funziona'
           when 'kg_non_giustificati' then format('%s kg non giustificati, controllare i movimenti di magazzino', fabula.it_qty((r #>> '{recall_drill,unaccounted_kg}')::numeric))
           when 'manca_latte_a_monte' then 'il lotto non ha latte collegato: il casaro deve avviare i lotti dalla scansione del latte'
           when 'no_lots' then 'nessun lotto venduto, prova non eseguita'
           else coalesce(r #>> '{recall_drill,result}', 'n/d') end);
    v_lines := v_lines || ('• Sicurezza alimentare: ' || coalesce(x->>'headline_it', 'n/d'));
    if v_k > 0 then
      v_lines := v_lines || (select '• Ricette: ' || string_agg(format('%s da %s a %s%s', coalesce(pr.name, rp->>'component_sku'),
                                   case when jsonb_typeof(rp->'from') = 'number' then fabula.it_qty((rp->>'from')::numeric) else rp->>'from' end,
                                   case when jsonb_typeof(rp->'to') = 'number' then fabula.it_qty((rp->>'to')::numeric) else rp->>'to' end,
                                   coalesce(' ' || nullif(rp->>'unit', ''), '')), '; ')
                               from jsonb_array_elements(coalesce(r #> '{recipe_tuning,proposals}', '[]'::jsonb)) rp left join fabula.products pr on pr.sku = rp->>'component_sku');
    end if;
    if coalesce((r #>> '{milk_quality,deliveries}')::int, 0) > 0 then
      v_lines := v_lines || format('• Latte: %s, %s; grasso %s %% (mese prima %s), proteine %s %% (mese prima %s)',
        fabula.it_n((r #>> '{milk_quality,deliveries}')::int, 'consegna', 'consegne'), fabula.it_n(coalesce((r #>> '{milk_quality,rejected}')::int, 0), 'rifiutata', 'rifiutate'),
        fabula.it_num((r #>> '{milk_quality,fat_pct}')::numeric, 2), fabula.it_num((r #>> '{milk_quality,fat_pct_prev}')::numeric, 2),
        fabula.it_num((r #>> '{milk_quality,protein_pct}')::numeric, 2), fabula.it_num((r #>> '{milk_quality,protein_pct_prev}')::numeric, 2));
    end if;
    if r #>> '{unit_cost,cost_eur_per_kg}' is not null then
      v_lines := v_lines || format('• Costo pieno € %s al kg (latte %s %%, lavoro %s)', fabula.it_num((r #>> '{unit_cost,cost_eur_per_kg}')::numeric, 2),
        fabula.it_num((r #>> '{unit_cost,milk_share_pct}')::numeric, 0), case r #>> '{unit_cost,labor_source}' when 'actual' then 'dalle ore timbrate' else 'da benchmark' end);
    end if;
    if coalesce((r #>> '{package_headline,revenue_eur}')::numeric, 0) > 0 or coalesce((r #>> '{package_headline,purchases_eur}')::numeric, 0) > 0 then
      v_lines := v_lines || format('• Pacchetto: ricavi € %s, corrispettivi € %s, acquisti € %s, latte € %s, magazzino € %s, scarti %s kg',
        fabula.it_num((r #>> '{package_headline,revenue_eur}')::numeric, 0), fabula.it_num((r #>> '{package_headline,corrispettivi_eur}')::numeric, 0),
        fabula.it_num((r #>> '{package_headline,purchases_eur}')::numeric, 0), fabula.it_num((r #>> '{package_headline,milk_eur}')::numeric, 0),
        fabula.it_num((r #>> '{package_headline,inventory_eur}')::numeric, 0), fabula.it_qty((r #>> '{package_headline,waste_kg}')::numeric));
    end if;
    ttl := case when n > 0 then format('⚠ %s: chiudi le non conformità critiche (%s)', v_month, n)
                when jsonb_array_length(coalesce(x->'lots_on_hold', '[]'::jsonb)) > 0 then format('⚠ %s: lotti bloccati', v_month)
                when jsonb_array_length(coalesce(x #> '{instruments,out_of_service}', '[]'::jsonb)) > 0 then format('⚠ %s: strumenti fuori servizio', v_month)
                when r #>> '{recall_drill,result}' in ('kg_non_giustificati', 'manca_latte_a_monte') then format('%s: la prova di richiamo non torna', v_month)
                when v_gap is not null then format('%s: rivedi la sicurezza alimentare (Autocontrollo)', v_month)
                when v_k > 0 then format('%s: %s da approvare', v_month, fabula.it_n(v_k, 'proposta di ricetta', 'proposte di ricetta'))
                else v_month || ' chiuso' end;
    if coalesce((r->>'is_simulation')::boolean, false) then ttl := 'SIMULAZIONE · ' || ttl; end if;
    sev := case when n > 0 or jsonb_array_length(coalesce(x->'lots_on_hold', '[]'::jsonb)) > 0 or jsonb_array_length(coalesce(x #> '{instruments,out_of_service}', '[]'::jsonb)) > 0
                     or r #>> '{recall_drill,result}' in ('kg_non_giustificati', 'manca_latte_a_monte') then 'alert'
                when v_k > 0 or v_gap is not null then 'warn' else 'info' end;
    summ := format('%s: richiamo %s, NC critiche %s, %s proposte ricetta, costo %s', v_month, coalesce(r #>> '{recall_drill,result}', 'n/d'), n, v_k,
                   case when r #>> '{unit_cost,cost_eur_per_kg}' is not null then '€ ' || fabula.it_num((r #>> '{unit_cost,cost_eur_per_kg}')::numeric, 2) || '/kg' else 'n/d' end);
    body := concat_ws(E'\n\n', E'Da fare:\n' || array_to_string(v_todo, E'\n'), E'In breve:\n' || array_to_string(v_lines, E'\n'));

  else
    raise exception 'Nessun ripiego per il bot %', p_agent;
  end case;
  -- v1.06 («Perché?»): what the database read goes with the message its caller posts next (bot_fallback, run_bot_fallback)
  if r is not null then
    perform fabula.keep_basis(p_agent, case p_agent when 'milk_planning' then 'plan_milk' when 'procurement' then 'propose_purchase_orders'
                                                    when 'wholesale_orders' then 'confirm_standing_orders' when 'haccp_nudge' then 'haccp_evening_status'
                                                    when 'ops_health' then 'ops_health_check' when 'sell_down' then 'sell_down_signals'
                                                    when 'sales' then 'sales_status' when 'marketing' then 'mkt_status' else p_agent end, r, 'database');
  end if;
  return jsonb_build_object('severity', sev, 'title', ttl, 'body', body, 'summary', summ, 'result', r);
end $function$;

CREATE OR REPLACE FUNCTION fabula.run_bot_fallback(p_agent text, p_confirm boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'fabula', 'public'
AS $function$
declare v_day date := (now() at time zone 'Europe/Rome')::date; v_who text; v_due timestamptz; v_last record; o jsonb; v_run uuid; v_msg bigint; v_err text; v_recent timestamptz;
begin
  perform fabula.require_perm('sistema', 2);
  if p_agent = any (fabula.shopify_sync_agents()) then return fabula.shopify_sync_now(p_agent, p_confirm); end if;   -- v1.02a: a database job, run now
  if not (p_agent = any (fabula.bot_fallback_agents())) then
    raise exception using errcode = '22023', message = format('«%s» non ha una versione del database: si rilancia dalle attività programmate di Claude', fabula.bot_title(p_agent));
  end if;
  v_who := coalesce((select full_name from fabula.staff where id = fabula.my_staff_id()), 'sistema');
  -- the latest slot of today that has already come (for the record and so the automatic stand-in does not run it again)
  select (v_day + t.due) at time zone 'Europe/Rome' into v_due from fabula.bot_schedule bs cross join unnest(bs.due_times) t(due)
   where bs.agent = p_agent and bs.active and extract(isodow from v_day) = any (bs.weekdays) and (bs.month_day is null or extract(day from v_day) = bs.month_day)
     and v_day + t.due <= (now() at time zone 'Europe/Rome') order by t.due desc limit 1;
  -- v1.12 (review): a monthly bot (the monthly review, the 1st) asks again any day of the month after its slot, not only on the 1st
  if v_due is null then
    select (make_date(extract(year from v_day)::int, extract(month from v_day)::int, bs.month_day) + t.due) at time zone 'Europe/Rome' into v_due
      from fabula.bot_schedule bs cross join unnest(bs.due_times) t(due)
     where bs.agent = p_agent and bs.active and bs.month_day is not null and bs.month_day <= extract(day from v_day)
       and make_date(extract(year from v_day)::int, extract(month from v_day)::int, bs.month_day) + t.due <= (now() at time zone 'Europe/Rome')
     order by t.due desc limit 1;
  end if;
  select ar.started_at, ar.status, coalesce(ar.details->>'via', '') via into v_last from fabula.agent_runs ar
   where ar.agent = p_agent and ar.status = 'ok' and ar.started_at >= coalesce(v_due, (v_day::timestamp) at time zone 'Europe/Rome') - interval '30 minutes'
     and (ar.agent <> 'backup_export' or ar.details->>'mode' = 'nightly')          -- the 2-hourly «latest» backups are not the nightly one
   order by ar.started_at desc limit 1;
  -- started in the last 15 minutes and not logged yet (the backup logs its own run when it finishes): a second click asks too
  select max(ran_at) into v_recent from fabula.bot_fallback_runs where agent = p_agent and ran_at > now() - interval '15 minutes';
  if (v_last.started_at is not null or v_recent is not null) and not coalesce(p_confirm, false) then
    raise exception using errcode = '22023', hint = 'confirm',
      message = case when v_recent is not null and (v_last.started_at is null or v_recent > v_last.started_at)
                     then format('%s è stato avviato alle %s: rifarlo adesso?', fabula.bot_title(p_agent), to_char(v_recent at time zone 'Europe/Rome', 'HH24:MI'))
                     else format('%s ha già girato %s alle %s%s: rifarlo adesso?', fabula.bot_title(p_agent),
                                 case when (v_last.started_at at time zone 'Europe/Rome')::date = v_day then 'oggi' else fabula.it_day((v_last.started_at at time zone 'Europe/Rome')::date) end,
                                 to_char(v_last.started_at at time zone 'Europe/Rome', 'HH24:MI'),
                                 case when v_last.via = 'db_fallback' then ' (versione del database)' else '' end) end;
  end if;
  begin
    o := fabula.bot_fallback_run(p_agent, v_day);
  exception when others then
    v_err := sqlerrm;               -- nothing is recorded: the person who pressed the button sees the error now
    raise exception using errcode = '22023', message = format('%s non riuscito: %s', fabula.bot_title(p_agent), left(v_err, 300));
  end;
  if p_agent <> 'backup_export' then        -- the backup logs its own run when it finishes
    insert into fabula.agent_runs (agent, started_at, finished_at, status, summary, details)
    values (p_agent, now(), clock_timestamp(), 'ok', format('Eseguito ora da %s (versione del database): %s', v_who, coalesce(o->>'summary', '')),
            jsonb_build_object('via', 'db_fallback', 'manual', true, 'by', v_who, 'due', v_due, 'result', o->'result'))
    returning id into v_run;
  end if;
  v_msg := fabula.post_bot_message(p_agent, coalesce(o->>'severity', 'info'), left('Eseguito ora · ' || coalesce(o->>'title', fabula.bot_title(p_agent)), 120),
             format(E'Eseguito ora da %s con la versione del database (i numeri del database, senza il commento del bot).\n\n%s', v_who, coalesce(o->>'body', '')), v_run);
  -- the ledger: today's slot (so the automatic stand-in does not run it again) or, before the first slot, this minute
  insert into fabula.bot_fallback_runs (agent, slot, status, summary, result) values (p_agent, coalesce(v_due, date_trunc('minute', now())), 'ok', o->>'summary', o->'result')
  on conflict (agent, slot) do update set status = 'ok', summary = excluded.summary, result = excluded.result, ran_at = now();
  perform fabula.bot_watchdog();            -- the incident (missed/failed) closes now
  return jsonb_build_object('agent', p_agent, 'title', o->>'title', 'summary', o->>'summary', 'severity', o->>'severity', 'message_id', v_msg);
end $function$;

CREATE OR REPLACE FUNCTION fabula._basis_call_it(p_call text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'fabula', 'public'
AS $function$
  select case p_call when 'plan_milk' then 'il calcolo del piano latte' when 'propose_purchase_orders' then 'il controllo delle scorte'
                     when 'sell_down_signals' then 'i lotti in scadenza' when 'confirm_standing_orders' then 'gli ordini fissi dell''ingrosso'
                     when 'haccp_evening_status' then 'le registrazioni della sera' when 'daily_brief' then 'i numeri del giorno'
                     when 'weekly_brief' then 'i numeri della settimana' when 'ops_health_check' then 'il controllo della sera'
                     when 'infra_checks' then 'i controlli del sistema' when 'compliance_calendar' then 'le scadenze'
                     when 'monthly_review' then 'i numeri del mese' when 'auto_approve' then 'la regola di approvazione'
                     when 'batch_ccp' then 'il registro HACCP del lotto' when 'milk_reject' then 'la consegna di latte respinta'
                     when 'prod_watch' then 'i lotti e il latte della sera'
                     when 'sales_status' then 'i numeri delle vendite' when 'mkt_status' then 'la campagna locale e i contenuti' else 'i dati' end
$function$;

insert into fabula.settings (key, value, description) values
 ('bots.db_fallback', '1', 'Se un bot non parte, il database fa il suo lavoro con i propri numeri, senza il commento del bot (tutti i bot; ricerche e messaggi pronti li fa solo il bot)')
on conflict (key) do update set description = excluded.description;
comment on function fabula.bot_fallback_run(text, date) is 'v1.12 (R-02): the database version of every Claude bot, called by bot_fallback (automatic) and run_bot_fallback («Esegui ora»)';
