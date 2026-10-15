-- v1.05c · Audit 12/10/2026, area E:
--   * E-31 (Medium) the evening HACCP list is live on the tablet from 14:00 (not only from the 19:02 bot to 05:00): what is still to
--     record today, item by item. In the morning the tablet shows «Ieri non registrato» with yesterday's food-safety gaps, each
--     opening «Ricopia da foglio di carta» on yesterday's date. Badge-out after 14:00 asks first when food-safety items remain.
--     fabula.haccp_open_list() reads it without posting anything; haccp_evening_status() keeps the 19:02 notice and now counts the
--     Rome day (it used the UTC date: a reading at 00:30 counted for the day before). With E-32: nothing is asked before the tasks
--     start (unless milk or a lot was really worked), a closed day asks only the cold rooms, and a badge not passed is listed from
--     19:00 (before, it is someone still at work).
--   * E-30 (Low) the go-live checklist in Italian in Configurazione → Panoramica («Verso l'apertura»), for the titolare and the soci
--     (no longer only Nick's English board): each item with how it closes. A gate ticked by hand needs a note (what was done, where
--     the document is) and a confirmation, and records who and when; undoing it needs a note too. Every change is in the Registro.
--     That note is kept apart (sign_note): the working notes of Nick's board (note, English, with deal details) are not shown there.

-- ============================== E-31 the evening list, live ==============================
create or replace function fabula._haccp_evening_items(p_date date) returns jsonb
language plpgsql stable set search_path = fabula, public, extensions as $$
declare items jsonb := '[]'; n_ship int; n_milk int; n_abx int; v_real_prod boolean; v_start date := fabula.tasks_start_date();
begin
  v_real_prod := exists (select 1 from fabula.production_batches where batch_date = p_date and source <> 'simulation');
  -- v1.05 (audit E-32): nothing is asked before the tasks start, unless milk or a lot was really worked that day (food safety first)
  if v_start is not null and p_date < v_start and not v_real_prod
     and not exists (select 1 from fabula.milk_intake where intake_date = p_date and source <> 'simulation') then
    return items;
  end if;
  -- the Rome day (v1.05: logged_at::date was the UTC date)
  select coalesce(jsonb_agg(jsonb_build_object('code', 'cold:' || cp.code, 'label_it', 'Temperatura serale ' || coalesce(e.code, cp.name), 'scan', 'EQ:' || e.code) order by cp.code), '[]') into items
  from fabula.haccp_control_points cp left join fabula.equipment e on e.id = cp.equipment_id
  where cp.active and cp.frequency = 'twice_daily'
    and not exists (select 1 from fabula.haccp_log l where l.control_point_id = cp.id and (l.logged_at at time zone 'Europe/Rome')::date = p_date
                                                         and (l.logged_at at time zone 'Europe/Rome')::time >= time '15:00');
  -- the end-of-shift cleaning, not on a closed day with no production (only the cold rooms are checked then)
  if not (fabula.is_closed_day(p_date) and not v_real_prod)
     and not exists (select 1 from fabula.haccp_log l join fabula.haccp_control_points cp on cp.id = l.control_point_id
                  where cp.code = 'PRP-CLEAN' and (l.logged_at at time zone 'Europe/Rome')::date = p_date) then
    items := items || jsonb_build_object('code', 'clean', 'label_it', 'Sanificazione fine turno', 'scan', 'CLEAN:');
  end if;
  if exists (select 1 from fabula.production_batches where batch_date = p_date) or exists (select 1 from fabula.sales_orders where order_date = p_date) then
    if not exists (select 1 from fabula.meter_readings where meter = 'elec_main' and (read_at at time zone 'Europe/Rome')::date = p_date) then
      items := items || jsonb_build_object('code', 'kwh', 'label_it', 'Lettura contatore', 'scan', 'METER:elec_main'); end if;
  end if;
  if v_real_prod and not exists (select 1 from fabula.effluent_log where log_date = p_date) then
    items := items || jsonb_build_object('code', 'effluent', 'label_it', 'Reflui del giorno (scotta, acque di lavaggio)', 'scan', 'EFFL:');
  end if;
  -- food safety: CCP per real batch (filatura for mozzarella, affioramento for ricotta, pasteurisation when the milk is pasteurised)
  select items || coalesce(jsonb_agg(jsonb_build_object('code', 'ccp:' || cp.code || ':' || b.batch_lot,
                                                        'label_it', cp.ccp_no || ' ' || cp.name || ' · lotto ' || b.batch_lot,
                                                        'scan', 'CCP:' || cp.code || ':' || b.batch_lot) order by b.batch_lot, cp.sort), '[]') into items
  from fabula.production_batches b
  join fabula.haccp_control_points cp on cp.active and (
         cp.code = case when b.input_kind = 'whey' then 'CCP-RIC' else 'CCP-STRETCH' end
      or (cp.code = 'CCP-PAST' and b.input_kind <> 'whey' and fabula.setting_text('food.milk_process', 'crudo') = 'pastorizzato'))
  where b.batch_date = p_date and b.source <> 'simulation'
    and not exists (select 1 from fabula.haccp_log l where l.batch_id = b.id and l.control_point_id = cp.id);
  select count(*) into n_milk from fabula.milk_intake where intake_date = p_date and source <> 'simulation';
  select count(*) into n_abx from fabula.haccp_log l join fabula.haccp_control_points cp on cp.id = l.control_point_id
   where cp.code = 'CCP-MILK-ABX' and (l.logged_at at time zone 'Europe/Rome')::date = p_date;
  if n_milk > n_abx then
    items := items || jsonb_build_object('code', 'abx', 'label_it', format('CCP 1b test antibiotici: %s conferimenti di latte senza esito', n_milk - n_abx), 'scan', 'CCP:CCP-MILK-ABX');
  end if;
  if v_real_prod and not exists (select 1 from fabula.calibration_checks c join fabula.equipment e on e.id = c.equipment_id
                                 where e.code = 'PH-01' and (c.checked_at at time zone 'Europe/Rome')::date = p_date) then
    items := items || jsonb_build_object('code', 'ph', 'label_it', 'Calibrazione pH-metro (tamponi 4 e 7)', 'scan', 'CAL:PH-01');
  end if;
  select count(*) into n_ship from fabula.v_orders_to_ship where channel = 'shopify';
  if n_ship > 0 then
    items := items || jsonb_build_object('code', 'ship', 'label_it', n_ship || ' ordini online pagati da spedire', 'scan', 'SHIP:');
  end if;
  select items || coalesce(jsonb_agg(jsonb_build_object('code', 'batch:' || batch_lot, 'label_it', 'Lotto ' || batch_lot || ' non chiuso (kg prodotto)', 'scan', 'LOT:' || batch_lot)), '[]') into items
  from fabula.production_batches where batch_date = p_date and output_kg is null and source <> 'simulation';
  select items || coalesce(jsonb_agg(jsonb_build_object('code', 'shift:' || st.badge_code, 'label_it', st.full_name || ': badge di uscita non passato', 'scan', st.badge_code)), '[]') into items
  from fabula.shifts s join fabula.staff st on st.id = s.staff_id where s.clock_out is null and (s.clock_in at time zone 'Europe/Rome')::date = p_date;
  return items;
end $$;
revoke all on function fabula._haccp_evening_items(date) from public, anon;
grant execute on function fabula._haccp_evening_items(date) to authenticated, service_role;   -- invoker: haccp_evening_status runs as its caller

create or replace function fabula.haccp_evening_status(p_date date default ((now() at time zone 'Europe/Rome'::text))::date)
 returns jsonb
 language plpgsql
 set search_path to 'fabula', 'public', 'extensions'
as $function$
declare items jsonb := fabula._haccp_evening_items(p_date); v_key text := 'haccp_evening:' || p_date; n int;
begin
  n := jsonb_array_length(items);
  if n > 0 then
    insert into fabula.notices (key, severity, title_it, items, expires_at)
    values (v_key, 'alert', format('Prima di chiudere: %s cose da registrare', n), items, ((p_date + 1)::timestamp + time '05:00') at time zone 'Europe/Rome')
    on conflict (key) do update set items = excluded.items, title_it = excluded.title_it, resolved_at = null;
  else
    update fabula.notices set resolved_at = now() where key = v_key and resolved_at is null;
  end if;
  return jsonb_build_object('date', p_date, 'missing', items, 'count', n,
    'lots_on_hold', (select coalesce(jsonb_agg(batch_lot), '[]') from fabula.v_lots_on_hold),
    'is_simulation', exists (select 1 from fabula.simulation_runs where p_date between from_date and to_date),
    'closed_day', not (exists (select 1 from fabula.production_batches where batch_date = p_date) or exists (select 1 from fabula.sales_orders where order_date = p_date)));
end $function$;

-- the tablet's live list: today's (from the tasks start) and yesterday's food-safety gaps, which open the paper copy on yesterday's date
create or replace function fabula.haccp_open_list() returns jsonb
language plpgsql stable security definer set search_path = fabula, public as $$
declare v_today date := (now() at time zone 'Europe/Rome')::date; t jsonb; y jsonb := '[]';
begin
  if greatest(fabula.perm_level('haccp'), fabula.perm_level('produzione')) < 1 then
    raise exception 'Il tuo profilo non vede le registrazioni HACCP' using errcode = '42501';
  end if;
  -- before the tasks start the items are empty (unless something was really produced); a badge not passed is asked from 19:00, not
  -- while the person is still working
  select coalesce(jsonb_agg(i order by o), '[]'::jsonb) into t
    from jsonb_array_elements(fabula._haccp_evening_items(v_today)) with ordinality x(i, o)
   where not (i ->> 'code' like 'shift:%' and extract(hour from now() at time zone 'Europe/Rome') < 19);
  -- yesterday's food-safety gaps, each opening the paper copy on yesterday's date
  select coalesce(jsonb_agg(i || jsonb_build_object('scan', 'PAPER:' || case
             when i ->> 'code' like 'cold:%' then substr(i ->> 'code', 6)
             when i ->> 'code' = 'clean' then 'PRP-CLEAN'
             when i ->> 'code' = 'abx' then 'CCP-MILK-ABX'
             else split_part(i ->> 'code', ':', 2) end
           || '@' || (v_today - 1)::text
           || case when i ->> 'code' like 'ccp:%' then '@' || split_part(i ->> 'code', ':', 3) else '' end) order by o), '[]'::jsonb)
    into y
    from jsonb_array_elements(fabula._haccp_evening_items(v_today - 1)) with ordinality x(i, o)
   where i ->> 'code' ~ '^(cold:|ccp:|clean$|abx$)';
  return jsonb_build_object('date', v_today, 'items', t, 'count', jsonb_array_length(t),
    'food_safety', (select count(*) from jsonb_array_elements(t) i where i ->> 'code' ~ '^(cold:|ccp:|clean$|abx$)'),
    'yesterday', jsonb_build_object('date', v_today - 1, 'items', y, 'count', jsonb_array_length(y)));
end $$;
revoke all on function fabula.haccp_open_list() from public, anon;
grant execute on function fabula.haccp_open_list() to authenticated;

-- ============================== E-30 the go-live checklist in Italian, signed ==============================
alter table fabula.dash_checks add column if not exists label_it text;
alter table fabula.dash_checks add column if not exists hint_it text;
alter table fabula.dash_checks add column if not exists done_by_id uuid references fabula.staff(id);
alter table fabula.dash_checks add column if not exists done_at timestamptz;
alter table fabula.dash_checks add column if not exists sign_note text;
comment on column fabula.dash_checks.sign_note is 'v1.05 (audit E-30): the note written when the item was ticked or unticked in Configurazione → Panoramica «Verso l''apertura» (what was done, where the document is / why undone). note stays the working note of tools/go-live/golive-board.html.';
update fabula.dash_checks c set label_it = v.l, hint_it = v.h from (values
  ('deal_signed', 'Atto di acquisto firmato dopo la due diligence', 'Si segna a mano a atto firmato, con il riferimento nella nota.'),
  ('lease_signed', 'Contratto d''affitto firmato e registrato a nome della Masseria', 'Si segna a mano a contratto registrato.'),
  ('ce_approval', 'Attività alimentare a nome della Masseria (riconoscimento CE, SCIA)', 'Si chiude da solo quando il numero di riconoscimento è in Configurazione → Sicurezza alimentare.'),
  ('dop_control', 'DOP: inseriti nel controllo RINA, marchi del Consorzio ordinati', 'Si segna a mano.'),
  ('haccp_training', 'Formazione HACCP valida per tutti quelli in produzione', 'Si chiude da solo quando ogni persona attiva ha l''attestato valido (Console → Personale).'),
  ('manuale_signed', 'Manuale di Autocontrollo firmato', 'Si chiude da solo quando la versione del manuale non è più «bozza» (Configurazione → Sicurezza alimentare).'),
  ('einvoicing', 'Fatturazione elettronica pronta (Fatture in Cloud, PEC, codice SDI)', 'Si segna a mano.'),
  ('rt_printer', 'Registratore telematico installato', 'Si segna a mano.'),
  ('company_docs', 'Dati della società su DDT e ordini (ragione sociale, P.IVA, indirizzo)', 'Si chiude da solo con ragione sociale, P.IVA e via in Configurazione → Azienda.'),
  ('opening_date', 'Data di apertura impostata', 'Si chiude da solo con la data in Configurazione → Marketing.'),
  ('stock_count', 'Conta di magazzino di apertura registrata', 'Si chiude da solo dopo la prima conta registrata dal tablet.'),
  ('placeholders', 'Nomi veri di fornitori e clienti (niente nomi provvisori o clienti di prova)', 'Si chiude da solo quando non restano nomi provvisori: Console → Anagrafiche.'),
  ('recipes', 'Dosi delle ricette confermate dal casaro', 'Si chiude da solo quando nessuna dose è più provvisoria: Console → Ricette.'),
  ('vat_capacity', 'Capacità della caldaia Fortino confermata', 'Si segna a mano dopo averla misurata (Configurazione → Produzione).'),
  ('compliance_dates', 'Ogni scadenza ha una data', 'Si chiude da solo quando tutte le scadenze hanno una data: Configurazione → Scadenze.'),
  ('equipment_dates', 'Data di taratura su ogni macchina', 'Si chiude da solo quando ogni macchina ha la data: Configurazione → Macchine.'),
  ('shopify_catalog', 'Decisioni sul catalogo Shopify prese', 'Si segna a mano.'),
  ('labels', 'Etichette di vendita approvate (marchio, logo DOP, scadenza)', 'Si segna a mano.'),
  ('bots_activated', 'Bot del caseificio accesi', 'Si segna a mano il giorno in cui si entra nel caseificio, dopo aver controllato i bot in Configurazione → Bot.'),
  ('tablet_checkin', 'Tablet di produzione aggiornato all''ultima app', 'Si chiude da solo quando il tablet si collega con l''ultima versione.'),
  ('first_milk', 'Primo latte vero ricevuto', 'Si chiude da solo al primo arrivo di latte registrato.'),
  ('first_batch', 'Primo lotto vero registrato', 'Si chiude da solo al primo lotto registrato.'),
  ('moisture_test', 'Analisi DOP superata (umidità ≤ 65 %)', 'Si chiude da solo con un esito conforme in Autocontrollo → Laboratorio.'),
  ('first_shipment', 'Primo ordine vero preparato con il suo DDT', 'Si chiude da solo alla prima spedizione vera.'),
  ('paper_fallback', 'Fogli di carta pronti per quando il tablet o il Wi-Fi non vanno', 'Si segna a mano dopo averli stampati (Autocontrollo → Registri → foglio vuoto).'),
  ('trial_start', 'Data della settimana di prova impostata', 'Si chiude da solo con la data in Configurazione → Settimana di prova.'),
  ('alerts_linked', 'Gli avvisi di sicurezza alimentare arrivano a ogni socio su Telegram', 'Si chiude da solo quando ogni socio ha collegato Telegram (Configurazione → Utenti e accessi).'),
  ('badges_printed', 'Badge stampati e passati una volta sul tablet', 'Si chiude da solo quando ogni persona ha passato il badge.'),
  ('sim_purged', 'Dati della simulazione cancellati', 'Si chiude da solo quando non restano dati simulati.'),
  ('code_pushed', 'Ultimo codice su GitHub', 'Si chiude da solo (controllo orario).'),
  ('app_deployed', 'App del tablet pubblicata = ultima su GitHub', 'Si chiude da solo (controllo orario).'),
  ('repo_sync', 'Migrazioni del repo uguali al database', 'Si chiude da solo (controllo orario).'),
  ('leaked_pw', 'Protezione delle password già trapelate attiva', 'Si segna a mano dopo averla attivata su Supabase → Authentication.'),
  ('fix_first', 'Correzioni urgenti dell''audit chiuse (fase 0 e critiche)', 'Si segna a mano.'),
  ('second_login', 'Una seconda persona riesce ad accedere', 'Si chiude da solo quando due persone hanno fatto l''accesso.'),
  ('pitr', 'Backup fuori dal database nelle ultime 26 ore', 'Si chiude da solo.'),
  ('restore_tested', 'Ripristino del backup provato (ultimi 100 giorni)', 'Si chiude da solo con la prova mensile automatica.'),
  ('bots_clean', 'Nessun errore dei bot nelle ultime 24 ore', 'Si chiude da solo.'),
  ('advisors_clean', 'Nessuna nuova segnalazione di sicurezza del database', 'Si chiude da solo.'),
  ('uptime', 'Sito del tablet e funzioni del server attivi', 'Si chiude da solo (controllo orario).'),
  ('outside_watcher', 'Monitor esterno attivo (GitHub, ultimo giro < 24 h)', 'Si chiude da solo.'),
  ('offsite_backup', 'Copia del backup fuori sede nelle ultime 2 notti', 'Si chiude da solo.')) v(k, l, h)
 where c.key = v.k;

-- a manual gate is ticked (or unticked) only with a note, by the titolare or a socio, and says who and when
create or replace function fabula.dash_set_check(p_key text, p_done boolean, p_note text default null::text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'fabula', 'public', 'extensions'
as $function$
declare r fabula.dash_checks; v_note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if auth.uid() is not null then
    perform fabula.require_perm('sistema', 3);
    if v_note is null or length(v_note) < 3 then
      raise exception using errcode = '22023', message = case when p_done then 'Scrivi una nota: cosa è stato fatto e dove sta il documento'
                                                              else 'Scrivi perché si annulla' end;
    end if;
  end if;
  -- a login writes the signing note; Nick's board (SQL, no login) keeps writing its working note as before, and its tick says so
  update fabula.dash_checks
     set done = p_done, updated_at = now(),
         note = case when auth.uid() is null then coalesce(v_note, note) else note end,
         sign_note = case when auth.uid() is not null then v_note when p_done then 'Segnato dalla lavagna tecnica di Nick' end,
         done_by_id = case when p_done then fabula.my_staff_id() end, done_at = case when p_done then now() end
   where key = p_key and kind = 'manual'
  returning * into r;
  if r.key is null then
    raise exception using errcode = '22023', message = format('«%s» non si segna a mano: si aggiorna da solo dai dati', p_key);
  end if;
  return to_jsonb(r);
end $function$;
revoke all on function fabula.dash_set_check(text, boolean, text) from public, anon;
grant execute on function fabula.dash_set_check(text, boolean, text) to authenticated;

-- a login changes the list only through dash_set_check (a definer function: there current_user is the owner, not «authenticated»)
create or replace function fabula.trg_dash_checks_guard() returns trigger
language plpgsql set search_path = fabula, public as $$
begin
  if current_user not in ('authenticated', 'anon') then return coalesce(new, old); end if;
  if tg_op = 'UPDATE' and (to_jsonb(new) - 'updated_at') = (to_jsonb(old) - 'updated_at') then return new; end if;
  raise exception using errcode = '42501', message = 'La lista per l''apertura si segna da Configurazione → Panoramica → Verso l''apertura, con una nota';
end $$;
drop trigger if exists dash_checks_guard on fabula.dash_checks;
create trigger dash_checks_guard before insert or update or delete on fabula.dash_checks for each row execute function fabula.trg_dash_checks_guard();
drop trigger if exists dash_checks_audit on fabula.dash_checks;
create trigger dash_checks_audit after update or delete on fabula.dash_checks for each row execute function fabula.trg_audit();

create or replace function fabula.golive_checklist() returns jsonb
language plpgsql stable security definer set search_path = fabula, public as $$
declare d jsonb;
begin
  if not fabula.can('sistema', 1) then raise exception 'Il tuo profilo non vede la lista per l''apertura' using errcode = '42501'; end if;
  d := coalesce(fabula.ops_dashboard() -> 'checks', '[]'::jsonb);
  return jsonb_build_object('can_sign', fabula.can('sistema', 3), 'items',
    (select coalesce(jsonb_agg(jsonb_build_object('key', c.key, 'label', coalesce(c.label_it, c.label), 'kind', c.kind,
              'done', coalesce((x ->> 'done')::boolean, c.done), 'hint', c.hint_it, 'note', case when c.kind = 'manual' then c.sign_note end,
              'done_at', c.done_at, 'done_by', s.full_name) order by c.sort), '[]'::jsonb)
       from fabula.dash_checks c
       left join lateral (select e as x from jsonb_array_elements(d) e where e ->> 'key' = c.key limit 1) dd on true
       left join fabula.staff s on s.id = c.done_by_id));
end $$;
revoke all on function fabula.golive_checklist() from public, anon;
grant execute on function fabula.golive_checklist() to authenticated;

insert into fabula.security_accepted (key, reason) values
  ('authenticated_security_definer_function_executable:fabula.haccp_open_list()', 'by design (v1.05c, audit E-31): the tablet''s live evening list and yesterday''s food-safety gaps; haccp or produzione ≥ vede'),
  ('authenticated_security_definer_function_executable:fabula.dash_set_check(p_key text, p_done boolean, p_note text)', 'by design (v1.05c, audit E-30): a go-live gate ticked with a note; Sistema = gestisce'),
  ('authenticated_security_definer_function_executable:fabula.golive_checklist()', 'by design (v1.05c, audit E-30): the go-live list in Italian for Panoramica; Sistema ≥ vede')
on conflict (key) do nothing;
