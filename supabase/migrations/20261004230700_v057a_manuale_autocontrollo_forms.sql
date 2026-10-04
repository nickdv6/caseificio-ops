-- v0.57a · Manuale di Autocontrollo (04/10/2026) · prima parte (sezioni 1–6, la seconda è 20261004230840_v057b)
-- Ogni registrazione HACCP rimanda al suo modulo MOD-xx, alla sezione del Manuale di Autocontrollo e alla revisione in vigore.
-- Documento: "Manuale di Autocontrollo — Caseificio di Agropoli" (link in food.manuale_url). Sostituisce il vecchio "Piano HACCP".
--  1 settings food.manuale_*, food.responsabile_autocontrollo, food.ce_approval_no, food.records_retention_years
--  2 haccp_forms: i 23 moduli di registrazione del manuale (§11), con sezione, frequenza, chi, dove si compila, stato
--  3 form_code su haccp_control_points e task_schedules · records_it dei punti di controllo con il codice modulo
--  4 nuovi controlli che il manuale richiede: valvola deviatrice (MOD-02), siero-innesto (MOD-03), salamoia (MOD-17)
--    + attività T-VALVE (ogni giorno) e T-BRINE (ogni settimana) · v_tasks_open espone il codice del punto di controllo
--  5 controllo all'arrivo merci (MOD-15): goods_receipts.inspection_* + record_receipt_check() (NC se non conforme)
--  6 haccp_register_reviews + mark_register_reviewed(): la verifica settimanale dei registri (§11, §12)
--  7 manual_ref(), haccp_register(): il registro stampabile di un modulo per periodo, con intestazione del manuale
--  8 haccp_forms_status(): stato dei registri per la console (registrazioni 30 gg, ultima, ultima verifica)
-- Nota connettore: nessun punto e virgola dentro le stringhe.

-- 1 · settings -------------------------------------------------------------------------------------------------
insert into fabula.settings (key, value, description, data_type, sort) values
  ('food.manuale_rev', '0', 'Manuale di Autocontrollo: numero di revisione in vigore (stampato su ogni registro HACCP)', 'text', 1),
  ('food.manuale_data', '2026-10-04', 'Manuale di Autocontrollo: data della revisione in vigore (AAAA-MM-GG)', 'text', 2),
  ('food.manuale_stato', 'bozza', 'Manuale di Autocontrollo: bozza oppure firmato (scrivere firmato solo dopo la firma di consulente e responsabile)', 'text', 3),
  ('food.manuale_url', 'https://claude.ai/code/artifact/0b43f173-15a4-4091-a95b-c7cdb5325a6d', 'Link al documento Manuale di Autocontrollo', 'text', 4),
  ('food.responsabile_autocontrollo', '', 'Responsabile dell''autocontrollo (nome e cognome) · firma il manuale e i registri', 'text', 5),
  ('food.ce_approval_no', '', 'Numero di riconoscimento CE dello stabilimento (Reg. CE 853/2004), stampato sui registri', 'text', 6),
  ('food.records_retention_years', '2', 'Anni di conservazione minima delle registrazioni HACCP (manuale §11)', 'number', 7)
on conflict (key) do nothing;

-- 2 · moduli di registrazione ------------------------------------------------------------------------------------
create table if not exists fabula.haccp_forms (
  code            text primary key check (code ~ '^MOD-[0-9]{2}$'),
  title_it        text not null,
  manual_section  text not null,                 -- es. '§7.8 · §8.2'
  frequency_it    text,
  responsible_it  text,
  where_it        text,                          -- dove si compila (tablet / console / carta)
  status          text not null default 'attivo' check (status in ('attivo', 'parziale', 'cartaceo', 'da_attivare')),
  register_kind   text not null default 'blank', -- come haccp_register() costruisce le righe
  sort            int  not null default 100,
  updated_at      timestamptz not null default now()
);
comment on table fabula.haccp_forms is 'Moduli di registrazione del Manuale di Autocontrollo (§11). Il codice MOD-xx compare su ogni registro a video e stampato.';

insert into fabula.haccp_forms (code, title_it, manual_section, frequency_it, responsible_it, where_it, status, register_kind, sort) values
  ('MOD-01', 'Ricevimento latte (CCP 1a temperatura, CCP 1b antibiotici)', '§7.7 · §8.2', 'Ogni conferimento', 'Operaio', 'Tablet → Arrivo latte', 'attivo', 'milk', 10),
  ('MOD-02', 'Pastorizzazione (CCP 2) e prova della valvola deviatrice', '§8.2', 'Ogni ciclo · valvola a inizio giornata', 'Casaro', 'Tablet → lotto · Sicurezza alimentare → Valvola deviatrice', 'attivo', 'ccp', 20),
  ('MOD-03', 'Scheda di lavorazione: siero-innesto e filatura (CCP 3)', '§6 · §8.2', 'Ogni lotto', 'Casaro', 'Tablet → lotto (preset) · Sicurezza alimentare → Siero-innesto', 'attivo', 'batch', 30),
  ('MOD-04', 'Ricotta: affioramento del siero (CCP 4)', '§8.2', 'Ogni lotto', 'Casaro', 'Tablet → lotto ricotta', 'attivo', 'ccp', 40),
  ('MOD-05', 'Temperature delle celle frigorifere (CCP 5)', '§7.8 · §8.2', '2 volte al giorno', 'Operaio', 'Tablet → QR della cella', 'attivo', 'ccp', 50),
  ('MOD-06', 'Sanificazione di fine turno', '§7.3', 'Fine turno', 'Operaio', 'Tablet → Pulizia fine turno', 'attivo', 'ccp', 60),
  ('MOD-07', 'Acqua: cloro residuo libero', '§7.2', 'Settimanale', 'Casaro', 'Tablet → Sicurezza alimentare → Cloro', 'attivo', 'ccp', 70),
  ('MOD-08', 'Lotta agli infestanti', '§7.4', 'Settimanale · ditta ogni 45 giorni', 'Casaro · ditta', 'Tablet → Infestanti · Console HACCP → Infestanti', 'attivo', 'pest', 80),
  ('MOD-09', 'Verifiche e tarature degli strumenti di misura', '§7.10', 'Vedi §7.10', 'Casaro', 'Tablet → verifica strumento · Console HACCP → Strumenti', 'attivo', 'calibration', 90),
  ('MOD-10', 'Formazione del personale', '§7.6', 'A ogni attestato', 'Responsabile', 'Console HACCP → Formazione', 'attivo', 'training', 100),
  ('MOD-11', 'Campionamenti e referti di laboratorio', '§8.4 · §7.2', 'Secondo il piano', 'Responsabile', 'Tablet → Campione · Console HACCP → Analisi', 'attivo', 'lab', 110),
  ('MOD-12', 'Non conformità e azioni correttive', '§9', 'A evento', 'Tutti · chiude il responsabile', 'Automatico · Console HACCP → Registro', 'attivo', 'nc', 120),
  ('MOD-13', 'Lotti bloccati e sblocchi', '§9', 'A evento', 'Responsabile', 'Automatico · Console HACCP → Registro', 'attivo', 'hold', 130),
  ('MOD-14', 'Ritiri, richiami e simulazioni di richiamo', '§10', 'A evento · simulazione mensile', 'Titolare', 'Console → Oggi · Revisione mensile', 'attivo', 'recall', 140),
  ('MOD-15', 'Accettazione merci (ingredienti, imballaggi, detergenti)', '§7.7', 'Ogni consegna', 'Operaio', 'Tablet → ricevimento ordine', 'attivo', 'receipt', 150),
  ('MOD-16', 'Sottoprodotti e reflui (siero, scotta)', '§7.9', 'Ogni ritiro', 'Operaio', 'Tablet → Reflui', 'attivo', 'effluent', 160),
  ('MOD-17', 'Salamoia e liquido di governo', '§7.12', 'Settimanale e a ogni rinnovo', 'Casaro', 'Tablet → Sicurezza alimentare → Salamoia', 'attivo', 'ccp', 170),
  ('MOD-18', 'Manutenzioni e scadenze degli impianti', '§7.1', 'A evento e a scadenza', 'Titolare', 'Console → Macchine e scadenze', 'parziale', 'maintenance', 180),
  ('MOD-19', 'Rintracciabilità dei lotti (latte → lotto → clienti)', '§10', 'Continua', 'Automatico', 'Lotti, vendite, spedizioni', 'attivo', 'trace', 190),
  ('MOD-20', 'Verifica dei registri e riesame del sistema', '§12', 'Settimanale · annuale', 'Responsabile · gruppo HACCP', 'Console HACCP → Registri → Verificato · verbale in Documenti', 'parziale', 'review', 200),
  ('MOD-21', 'Fornitori qualificati', '§7.7', 'Nuovo fornitore · ogni anno', 'Responsabile', 'Anagrafica fornitori · schede in Documenti', 'parziale', 'suppliers', 210),
  ('MOD-22', 'Visitatori e dichiarazione sullo stato di salute', '§7.5', 'A ogni visita', 'Responsabile', 'Modulo cartaceo (stampa modulo vuoto)', 'cartaceo', 'blank', 220),
  ('MOD-23', 'Etichette di vendita e shelf-life', '§7.11', 'A ogni nuova etichetta', 'Responsabile', 'Da attivare · per ora modulo cartaceo', 'da_attivare', 'blank', 230)
on conflict (code) do nothing;

insert into fabula.table_areas (table_name, area, write_level, read_open) values ('haccp_forms', 'haccp', 3, true)
on conflict (table_name) do nothing;
alter table fabula.haccp_forms enable row level security;
grant select, insert, update on fabula.haccp_forms to authenticated;
grant all on fabula.haccp_forms to service_role;
do $$
declare t text := 'haccp_forms';
begin
  if not exists (select 1 from pg_policies where schemaname = 'fabula' and tablename = t and policyname = t || '_read') then
    execute format('create policy %I on fabula.%I for select to authenticated using (true)', t || '_read', t);
    execute format('create policy %I on fabula.%I for insert to authenticated with check (true)', t || '_insert', t);
    execute format('create policy %I on fabula.%I for update to authenticated using (true)', t || '_update', t);
    execute format('create policy %I on fabula.%I as restrictive for select to authenticated using ((select fabula.can_table(%L, false)))', t || '_role_select', t, t);
    execute format('create policy %I on fabula.%I as restrictive for insert to authenticated with check ((select fabula.can_table(%L, true)))', t || '_role_insert', t, t);
    execute format('create policy %I on fabula.%I as restrictive for update to authenticated using ((select fabula.can_table(%L, true)))', t || '_role_update', t, t);
  end if;
end $$;

-- 3 · form_code su punti di controllo e attività -----------------------------------------------------------------
alter table fabula.haccp_control_points add column if not exists form_code text references fabula.haccp_forms (code);
alter table fabula.task_schedules add column if not exists form_code text references fabula.haccp_forms (code);
comment on column fabula.haccp_control_points.form_code is 'Modulo del Manuale di Autocontrollo in cui finiscono le registrazioni di questo punto (MOD-xx)';

update fabula.haccp_control_points set form_code = v.f
from (values ('CCP-MILK-TEMP', 'MOD-01'), ('CCP-MILK-ABX', 'MOD-01'), ('CCP-PAST', 'MOD-02'), ('CCP-STRETCH', 'MOD-03'), ('CCP-RIC', 'MOD-04'),
             ('CCP-COLD-1', 'MOD-05'), ('CCP-COLD-2', 'MOD-05'), ('PRP-CLEAN', 'MOD-06'), ('PRP-WATER-CL', 'MOD-07'), ('PRP-PEST', 'MOD-08')) v(c, f)
where code = v.c and form_code is null;

-- 4 · controlli richiesti dal manuale che mancavano ------------------------------------------------------------
insert into fabula.haccp_control_points (code, name, check_type, frequency, min_value, max_value, unit, active, is_ccp, ccp_no, process_step,
  hazard_it, critical_limit_it, monitoring_it, corrective_it, verification_it, records_it, warn_min, warn_max, applies_when, nc_severity, sort, form_code)
values
  ('PRP-PAST-VALVE', 'Pastorizzatore: prova della valvola deviatrice', 'other', 'per_batch', null, 0, 'esito', true, true, 'CCP 2', 'Pastorizzazione',
   'Latte non pastorizzato che passa alla caseificazione se la valvola non devia il flusso sotto temperatura',
   'La valvola devia il latte quando la temperatura scende sotto il limite: prova a inizio giornata superata (0 = funziona, 1 = NON funziona).',
   'Ogni giorno di produzione, prima del primo ciclo: prova di deviazione (caduta di temperatura simulata o pulsante di prova del costruttore). Registrazione sul tablet.',
   'Non funziona: non pastorizzare, chiamare il tecnico, NC critica · il latte trattato dall''ultima prova buona si valuta con il consulente (fosfatasi alcalina).',
   'Revisione annuale del pastorizzatore · fosfatasi alcalina mensile (MILK-ALP).',
   'MOD-02 · haccp_log', null, null, 'latte_pastorizzato', 'critical', 31, 'MOD-02'),
  ('PRP-INNESTO', 'Siero-innesto: acidità prima dell''uso', 'other', 'per_batch', null, null, '°SH', true, false, 'PRP', 'Siero-innesto naturale',
   'Acidificazione lenta della cagliata con crescita di S. aureus e formazione di enterotossine',
   'Acidità del siero-innesto nell''intervallo fissato dal casaro (DA DEFINIRE, manuale §13).',
   'Ogni giorno di produzione, prima dell''inoculo: acidità in gradi Soxhlet-Henkel (titolazione) · nella nota l''eventuale pH.',
   'Fuori intervallo: non usare, preparare un innesto nuovo o usare quello di riserva, avvisare il responsabile.',
   'Stafilococchi coagulasi-positivi sulla cagliata (MOZ-CPS) secondo il piano di campionamento.',
   'MOD-03 · haccp_log', null, null, 'sempre', 'major', 35, 'MOD-03'),
  ('PRP-BRINE', 'Salamoia: concentrazione e stato', 'other', 'weekly', null, null, '°Bé', true, false, 'PRP', 'Salatura in salamoia',
   'Ricontaminazione da Listeria o crescita microbica in una salamoia diluita, sporca o non rinnovata',
   'Concentrazione nell''intervallo fissato dal casaro (DA DEFINIRE, manuale §13) · salamoia limpida e senza odori anomali · rinnovo e filtrazione agli intervalli scritti.',
   'Ogni settimana e a ogni rinnovo: densimetro in gradi Baumé e controllo visivo · nella nota: rinnovo, filtrazione, rabbocco.',
   'Fuori intervallo: correggere con sale o acqua potabile · torbida o con odori: sostituire, sanificare la vasca, valutare il prodotto salato nel frattempo.',
   'Listeria spp. sulla salamoia ogni 3 mesi (SAL-LIS).',
   'MOD-17 · haccp_log', null, null, 'sempre', 'major', 75, 'MOD-17')
on conflict (code) do nothing;

update fabula.haccp_control_points set records_it = form_code || ' · ' || coalesce(nullif(records_it, ''), 'haccp_log')
where form_code is not null and coalesce(records_it, '') not like 'MOD-%';

insert into fabula.task_schedules (code, title_it, title_en, frequency, control_point_id, assigned_role, due_time, grace_minutes, active, form_code)
select v.code, v.t_it, v.t_en, v.freq::fabula.task_frequency, cp.id, v.role::fabula.staff_role, v.due::time, 120, true, v.form
from (values ('T-VALVE', 'Prova valvola deviatrice del pastorizzatore', 'Pasteuriser divert-valve test', 'daily', 'PRP-PAST-VALVE', 'casaro', '06:45', 'MOD-02'),
             ('T-BRINE', 'Salamoia: concentrazione e stato', 'Brine strength and condition', 'weekly', 'PRP-BRINE', 'casaro', '10:00', 'MOD-17')) v(code, t_it, t_en, freq, cp, role, due, form)
join fabula.haccp_control_points cp on cp.code = v.cp
where not exists (select 1 from fabula.task_schedules s where s.code = v.code);

update fabula.task_schedules set form_code = v.f
from (values ('T-CF1', 'MOD-05'), ('T-CF2', 'MOD-05'), ('T-CLEAN', 'MOD-06'), ('T-CL', 'MOD-07'), ('T-PEST', 'MOD-08'), ('T-CAL', 'MOD-09'), ('T-PH', 'MOD-09')) v(c, f)
where code = v.c and form_code is null;

create or replace view fabula.v_tasks_open as
select ti.id, ti.due_at, ti.status, s.code, s.title_it, s.title_en, s.assigned_role, e.code as equipment_code,
       cp.code as control_point_code, s.form_code
from fabula.task_instances ti
join fabula.task_schedules s on s.id = ti.schedule_id
left join fabula.equipment e on e.id = s.equipment_id
left join fabula.haccp_control_points cp on cp.id = s.control_point_id
where ti.status = any (array['due'::fabula.task_status, 'overdue'::fabula.task_status])
order by ti.due_at;

update fabula.compliance_deadlines set subject_it = 'Riesame annuale del Manuale di Autocontrollo (piano HACCP) · MOD-20',
       notes = 'Gruppo HACCP con il consulente · verbale firmato in Documenti · se cambia qualcosa, nuova revisione del manuale (food.manuale_rev)'
where kind = 'haccp_plan_review' and subject_it = 'Riesame annuale piano HACCP';

-- 5 · controllo all'arrivo merci (MOD-15) ----------------------------------------------------------------------
alter table fabula.goods_receipts add column if not exists inspection_ok boolean,
                                  add column if not exists inspection_note text,
                                  add column if not exists inspected_by_id uuid references fabula.staff (id);

create or replace function fabula.record_receipt_check(p_po_number text, p_ok boolean, p_note text default null, p_staff_id uuid default null, p_ddt text default null)
returns jsonb language plpgsql security definer set search_path = fabula, public as $$
declare v_gr uuid; v_nc uuid; v_sup text;
begin
  perform fabula.require_perm('magazzino', 2);
  if p_ok is null then raise exception 'Esito del controllo all''arrivo mancante'; end if;
  if not p_ok and coalesce(trim(p_note), '') = '' then raise exception 'Merce non conforme: scrivi cosa non va (es. confezione rotta, temperatura, etichetta)'; end if;
  select g.id, p.legal_name into v_gr, v_sup
  from fabula.goods_receipts g join fabula.purchase_orders po on po.id = g.purchase_order_id left join fabula.parties p on p.id = po.supplier_id
  where po.po_number = p_po_number and (p_ddt is null or g.ddt_number is not distinct from p_ddt)
  order by g.received_at desc limit 1;
  if v_gr is null then raise exception 'Ricevimento non trovato per l''ordine %', p_po_number; end if;
  update fabula.goods_receipts set inspection_ok = p_ok, inspection_note = nullif(trim(p_note), ''), inspected_by_id = p_staff_id where id = v_gr;
  if not p_ok then
    insert into fabula.non_conformities (severity, description, corrective_action, opened_by_id)
    values ('major', format('MOD-15 · Merce non conforme all''arrivo: ordine %s%s — %s', p_po_number, coalesce(' (' || v_sup || ')', ''), trim(p_note)),
            'Merce isolata con cartello, fornitore avvisato · decidere reso o distruzione', p_staff_id)
    returning id into v_nc;
  end if;
  return jsonb_build_object('receipt_id', v_gr, 'nc_id', v_nc);
end $$;
revoke execute on function fabula.record_receipt_check(text, boolean, text, uuid, text) from public, anon;
grant execute on function fabula.record_receipt_check(text, boolean, text, uuid, text) to authenticated, service_role;

-- 6 · verifica settimanale dei registri --------------------------------------------------------------------------
create table if not exists fabula.haccp_register_reviews (
  id             uuid primary key default gen_random_uuid(),
  form_code      text not null references fabula.haccp_forms (code),
  period_from    date not null,
  period_to      date not null check (period_to >= period_from),
  reviewed_at    timestamptz not null default now(),
  reviewed_by_id uuid references fabula.staff (id),
  outcome        text not null default 'ok' check (outcome in ('ok', 'con_rilievi')),
  note           text,
  manual_rev     text
);
create index if not exists haccp_register_reviews_form_idx on fabula.haccp_register_reviews (form_code, period_to desc);
insert into fabula.table_areas (table_name, area, write_level, read_open) values ('haccp_register_reviews', 'haccp', 3, false)
on conflict (table_name) do nothing;
alter table fabula.haccp_register_reviews enable row level security;
grant select, insert on fabula.haccp_register_reviews to authenticated;
grant all on fabula.haccp_register_reviews to service_role;
do $$
declare t text := 'haccp_register_reviews';
begin
  if not exists (select 1 from pg_policies where schemaname = 'fabula' and tablename = t and policyname = t || '_read') then
    execute format('create policy %I on fabula.%I for select to authenticated using (true)', t || '_read', t);
    execute format('create policy %I on fabula.%I for insert to authenticated with check (true)', t || '_insert', t);
    execute format('create policy %I on fabula.%I as restrictive for select to authenticated using ((select fabula.can_table(%L, false)))', t || '_role_select', t, t);
    execute format('create policy %I on fabula.%I as restrictive for insert to authenticated with check ((select fabula.can_table(%L, true)))', t || '_role_insert', t, t);
  end if;
end $$;

create or replace function fabula.mark_register_reviewed(p_form text, p_from date, p_to date, p_staff_id uuid default null, p_outcome text default 'ok', p_note text default null)
returns uuid language plpgsql security definer set search_path = fabula, public as $$
declare v uuid;
begin
  perform fabula.require_perm('haccp', 3);
  if p_outcome = 'con_rilievi' and coalesce(trim(p_note), '') = '' then raise exception 'Scrivi i rilievi'; end if;
  insert into fabula.haccp_register_reviews (form_code, period_from, period_to, reviewed_by_id, outcome, note, manual_rev)
  values (upper(p_form), p_from, p_to, coalesce(p_staff_id, fabula.my_staff_id()), coalesce(p_outcome, 'ok'), nullif(trim(p_note), ''),
          (select value from fabula.settings where key = 'food.manuale_rev'))
  returning id into v;
  return v;
end $$;
revoke execute on function fabula.mark_register_reviewed(text, date, date, uuid, text, text) from public, anon;
grant execute on function fabula.mark_register_reviewed(text, date, date, uuid, text, text) to authenticated, service_role;

