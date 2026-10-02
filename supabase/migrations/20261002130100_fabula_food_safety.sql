-- v0.28 · Sicurezza alimentare: piano HACCP strutturato (CCP con limiti, monitoraggio, azioni correttive, verifica),
-- piano di campionamento e analisi (prodotto, latte, acqua, ambiente), disinfestazione (postazioni + ispezioni),
-- formazione (corsi, attestati, matrice per ruolo), tarature e verifiche strumenti, blocco lotti.
-- Collegato a: tablet (CCP:, CAL:, PEST:, SAMPLE:), console haccp.html, compliance_calendar(), haccp_evening_status(),
-- ops_health_check(), monthly_review() → food_safety_summary().
-- Nessuna istruzione distruttiva: solo create/alter/insert/update.

-- ============ 0. enum additions ============
alter type fabula.document_kind add value if not exists 'lab_report';
alter type fabula.document_kind add value if not exists 'training_cert';
alter type fabula.document_kind add value if not exists 'calibration_cert';
alter type fabula.document_kind add value if not exists 'pest_report';

-- ============ 1. HACCP plan columns on control points ============
alter table fabula.haccp_control_points
  add column if not exists is_ccp boolean not null default false,
  add column if not exists ccp_no text,
  add column if not exists process_step text,
  add column if not exists hazard_it text,
  add column if not exists critical_limit_it text,
  add column if not exists monitoring_it text,
  add column if not exists corrective_it text,
  add column if not exists verification_it text,
  add column if not exists records_it text,
  add column if not exists warn_min numeric,
  add column if not exists warn_max numeric,
  add column if not exists applies_when text not null default 'sempre',
  add column if not exists nc_severity fabula.nc_severity not null default 'major',
  add column if not exists sort int not null default 100,
  add column if not exists updated_at timestamptz not null default now();

alter table fabula.process_steps add column if not exists ccp_code text;

alter table fabula.production_batches
  add column if not exists food_safety_hold boolean not null default false,
  add column if not exists hold_reason text,
  add column if not exists hold_nc_id uuid references fabula.non_conformities(id),
  add column if not exists hold_released_at timestamptz,
  add column if not exists hold_released_by_id uuid references fabula.staff(id),
  add column if not exists hold_at timestamptz;

-- equipment: internal verification (vs external calibration), tolerance, out of service
alter table fabula.equipment
  add column if not exists check_interval_days int,
  add column if not exists last_checked_on date,
  add column if not exists tolerance numeric,
  add column if not exists tolerance_unit text,
  add column if not exists out_of_service boolean not null default false,
  add column if not exists reference_instrument boolean not null default false,
  add column if not exists calibration_cert_ref text,
  add column if not exists notes text;

-- settings
insert into fabula.settings (key, value, description, data_type, sort) values
  ('food.milk_process', 'crudo', 'Latte lavorato: crudo (tradizionale DOP) o pastorizzato — decide se il CCP pastorizzazione è richiesto ogni lotto', 'text', 10),
  ('food.sampling_start', '', 'Data di avvio del piano campionamenti (AAAA-MM-GG). Vuota = piano non ancora attivo, nessun promemoria', 'text', 11),
  ('food.lab_name', '', 'Laboratorio analisi (accreditato Accredia o IZSM Portici)', 'text', 12),
  ('food.lab_email', '', 'E-mail del laboratorio per le richieste di campionamento', 'text', 13),
  ('food.haccp_consultant', '', 'Consulente HACCP (nome e contatto)', 'text', 14),
  ('food.pest_company', '', 'Ditta disinfestazione (ragione sociale e contatto)', 'text', 15)
on conflict (key) do nothing;

-- ============ 2. CCP / PRP definitions (Italian, verbatim in the plan) ============
update fabula.haccp_control_points set
  is_ccp = true, ccp_no = 'CCP 1a', sort = 10, process_step = 'Ricevimento latte crudo di bufala',
  max_value = 8, warn_max = 6, nc_severity = 'major', check_type = 'receiving',
  hazard_it = 'Biologico: moltiplicazione di patogeni del latte crudo (S. aureus e sue enterotossine, L. monocytogenes, Salmonella, E. coli STEC).',
  critical_limit_it = 'Latte all''arrivo ≤ 8 °C (raccolta giornaliera). Dopo l''accettazione: lavorazione entro 4 h oppure stoccaggio in tank a ≤ 6 °C (Reg. CE 853/2004, All. III, Sez. IX). Latte non refrigerato solo se lavorato entro 2 h dalla mungitura o con autorizzazione ASL per motivi tecnologici.',
  monitoring_it = 'Ogni conferimento: temperatura con termometro a sonda tarato, ora di arrivo, DDT. Registrazione sul tablet (Arrivo latte).',
  corrective_it = '6–8 °C: accettare solo se la lavorazione inizia entro 2 h, avvisare la Masseria. > 8 °C: respingere o destinare a uso non alimentare · aprire NC · verificare la catena del freddo alla stalla e nel trasporto.',
  verification_it = 'Riesame settimanale dei registri · taratura mensile del termometro · carica batterica e cellule somatiche del fornitore 2 volte al mese.',
  records_it = 'milk_intake, haccp_log, DDT con foto'
where code = 'CCP-MILK-TEMP';

update fabula.haccp_control_points set
  is_ccp = true, ccp_no = 'CCP 2', sort = 30, process_step = 'Pastorizzazione (solo se il latte è pastorizzato)',
  min_value = 72, warn_min = 73, nc_severity = 'critical', applies_when = 'latte_pastorizzato',
  hazard_it = 'Biologico: sopravvivenza di patogeni vegetativi (Listeria, Salmonella, E. coli STEC, Campylobacter).',
  critical_limit_it = '≥ 72 °C per ≥ 15 s (HTST) oppure ≥ 63 °C per ≥ 30 min (discontinuo). Valvola deviatrice funzionante. Fosfatasi alcalina negativa.',
  monitoring_it = 'Ogni ciclo: termometro registratore + lettura del termometro indicatore all''avvio e ogni ora · controllo della deviazione del flusso a inizio giornata.',
  corrective_it = 'Sotto limite: il latte torna in testa al ciclo o viene ripastorizzato · lotti prodotti fuori limite bloccati · NC critica · tecnico per il pastorizzatore.',
  verification_it = 'Confronto giornaliero indicatore/registratore · taratura annuale del registratore · fosfatasi alcalina mensile.',
  records_it = 'tracciato del registratore (foto), haccp_log'
where code = 'CCP-PAST';

update fabula.haccp_control_points set
  is_ccp = true, ccp_no = 'CCP 5', sort = 60, process_step = 'Conservazione refrigerata prodotto finito',
  min_value = 0, max_value = 6, warn_max = 4, nc_severity = 'major',
  hazard_it = 'Biologico: moltiplicazione di L. monocytogenes e di altri patogeni nel prodotto pronto al consumo.',
  critical_limit_it = 'Cella 0–4 °C. Tra 4 e 6 °C = allerta (ricontrollo entro 1 h). Oltre 6 °C, o sopra 4 °C per più di 2 h = non conformità.',
  monitoring_it = 'Due letture al giorno (apertura e chiusura) dal display, confermate con il termometro a sonda una volta a settimana.',
  corrective_it = 'Spostare il prodotto nell''altra cella · verificare porta/guarnizioni/sbrinamento · misurare la temperatura al cuore del prodotto: se > 8 °C valutare il blocco dei lotti · chiamare il frigorista.',
  verification_it = 'Verifica trimestrale del display contro il termometro di riferimento · manutenzione semestrale.',
  records_it = 'haccp_log, sensor_readings, NC'
where code in ('CCP-COLD-1', 'CCP-COLD-2');

update fabula.haccp_control_points set sort = 90, process_step = 'Sanificazione',
  hazard_it = 'Biologico (contaminazione crociata, Listeria ambientale) · chimico (residui di detergenti).',
  critical_limit_it = 'Tutte le aree della checklist sanificate a fine turno secondo la procedura · risciacquo completo.',
  monitoring_it = 'Checklist sul tablet a fine turno.', corrective_it = 'Ripetere la sanificazione prima della ripresa della produzione.',
  verification_it = 'Tamponi ambientali mensili (Listeria spp., carica totale) · ispezione visiva del responsabile.'
where code = 'PRP-CLEAN';

update fabula.haccp_control_points set sort = 95, process_step = 'Lotta agli infestanti',
  hazard_it = 'Fisico/biologico: roditori, insetti, volatili.',
  critical_limit_it = 'Nessuna attività di infestanti all''interno dei locali di lavorazione e deposito.',
  monitoring_it = 'Giro settimanale interno delle postazioni (tablet → Infestanti) · visita della ditta ogni 45 giorni.',
  corrective_it = 'Attività interna: NC, pulizia straordinaria, chiusura dei punti di accesso, intervento della ditta entro 48 h · valutare il prodotto esposto.',
  verification_it = 'Rapporti della ditta con trend · riesame annuale del piano con la planimetria.'
where code = 'PRP-PEST';

insert into fabula.haccp_control_points (code, name, check_type, frequency, min_value, max_value, unit, active, is_ccp, ccp_no, sort, process_step,
  warn_min, warn_max, nc_severity, applies_when, hazard_it, critical_limit_it, monitoring_it, corrective_it, verification_it, records_it, equipment_id)
select * from (values
  ('CCP-MILK-ABX', 'Latte: test residui inibenti (antibiotici)', 'receiving'::fabula.haccp_check_type, 'per_batch', null::numeric, 0::numeric, 'esito', true, true, 'CCP 1b', 20,
   'Ricevimento latte crudo di bufala', null::numeric, null::numeric, 'critical'::fabula.nc_severity, 'sempre',
   'Chimico: residui di farmaci veterinari (beta-lattamici, tetracicline) oltre i limiti (Reg. UE 37/2010).',
   'Test rapido NEGATIVO su ogni conferimento (0 = negativo, 1 = positivo). Positivo = latte non accettato.',
   'Ogni conferimento, prima dello scarico: kit rapido (es. beta-lattamici + tetracicline), esito sul tablet.',
   'Positivo: latte respinto e isolato, NC critica, avvisare subito la Masseria (registro trattamenti e tempi di sospensione), conferma in laboratorio · nessuna miscelazione con altro latte.',
   'Analisi mensile di conferma in laboratorio · controllo delle date di scadenza dei kit · riesame del registro trattamenti della Masseria.',
   'haccp_log, milk_intake, foto del kit', null::uuid),
  ('CCP-STRETCH', 'Filatura: temperatura della pasta', 'temperature', 'per_batch', 58, null, '°C', true, true, 'CCP 3', 40,
   'Filatura', 60, null, 'critical', 'sempre',
   'Biologico: sopravvivenza di patogeni vegetativi del latte crudo nella pasta filata (L. monocytogenes, Salmonella, E. coli STEC).',
   'Temperatura al cuore della pasta filata ≥ 58 °C (obiettivo 60–65 °C) con acqua di filatura ≥ 85 °C. LIMITE DA VALIDARE con il consulente HACCP/IZSM sulla linea reale.',
   'Ogni lotto: sonda al cuore della pasta all''uscita della filatrice (o dal mastello), registrazione sul tablet con il numero di lotto.',
   'Sotto 58 °C: rifilare la pasta con acqua più calda fino al limite · se non possibile, lotto bloccato e NC critica · valutazione con il consulente (analisi Listeria/Salmonella prima del rilascio).',
   'Taratura mensile del termometro alta temperatura · tamponi e analisi di prodotto (Listeria, Salmonella, stafilococchi) secondo piano.',
   'haccp_log con lotto, batch_step_logs', null),
  ('CCP-RIC', 'Ricotta: temperatura di affioramento del siero', 'temperature', 'per_batch', 80, null, '°C', true, true, 'CCP 4', 50,
   'Trattamento termico del siero (ricotta)', 85, null, 'critical', 'sempre',
   'Biologico: sopravvivenza di patogeni vegetativi nel siero/scotta.',
   'Siero portato a ≥ 80 °C (obiettivo 85–90 °C) prima dell''affioramento e della raccolta nelle fuscelle.',
   'Ogni lotto di ricotta: sonda nel TINO al momento dell''affioramento, registrazione sul tablet.',
   'Sotto 80 °C: proseguire il riscaldamento · se la ricotta è già stata raccolta, lotto bloccato e NC critica.',
   'Taratura mensile del termometro · Listeria e stafilococchi su ricotta secondo piano.',
   'haccp_log con lotto', null),
  ('PRP-WATER-CL', 'Acqua: cloro residuo libero al rubinetto', 'other', 'weekly', 0.05, 0.5, 'mg/l', true, false, 'PRP', 80,
   'Approvvigionamento idrico', 0.1, 0.2, 'minor', 'sempre',
   'Biologico/chimico: acqua non potabile nell''impianto interno (D.Lgs. 18/2023).',
   'Cloro residuo libero presente (≥ 0,05 mg/l) · valore di riferimento ≤ 0,2 mg/l al rubinetto.',
   'Una volta a settimana con kit DPD al rubinetto della sala di lavorazione.',
   'Assente: ripetere su altro rubinetto, avvisare il gestore idrico, analisi microbiologica straordinaria · sospendere l''uso per acqua a contatto col prodotto finché non è conforme.',
   'Analisi di laboratorio annuale/semestrale (H2O-*).',
   'haccp_log', null)
) v(code, name, check_type, frequency, min_value, max_value, unit, active, is_ccp, ccp_no, sort, process_step, warn_min, warn_max, nc_severity, applies_when,
    hazard_it, critical_limit_it, monitoring_it, corrective_it, verification_it, records_it, equipment_id)
where not exists (select 1 from fabula.haccp_control_points c where c.code = v.code);

-- link presets: a dedicated paste-temperature step after Filatura, and ricotta affioramento
update fabula.process_steps set ccp_code = 'CCP-RIC' where name_it = 'Affioramento' and ccp_code is null;
insert into fabula.process_steps (preset_id, phase, step_order, name_it, target_temp_c, temp_min_c, temp_max_c, record_metric, instruction_it, ccp_code, active)
select ps.preset_id, 'make', 35, 'Temperatura pasta filata (CCP 3)', 62, 58, 68, 'temp',
       'Sonda al cuore della pasta appena filata. Sotto 58 °C: rifilare. È un punto critico: il valore va sempre registrato.', 'CCP-STRETCH', true
from fabula.process_steps ps
where ps.name_it = 'Filatura'
  and not exists (select 1 from fabula.process_steps x where x.preset_id = ps.preset_id and x.ccp_code = 'CCP-STRETCH');

-- ============ 3. CCP logging core ============
create or replace function fabula.ccp_eval(p_min numeric, p_max numeric, p_wmin numeric, p_wmax numeric, v numeric)
returns fabula.haccp_result language sql immutable as $$
  select case when v is null then 'warning'::fabula.haccp_result
              when (p_min is not null and v < p_min) or (p_max is not null and v > p_max) then 'non_conformity'
              when (p_wmin is not null and v < p_wmin) or (p_wmax is not null and v > p_wmax) then 'warning'
              else 'ok' end
$$;

create or replace function fabula.log_ccp(p_cp_code text, p_value numeric, p_staff_id uuid default null, p_batch_lot text default null,
                                          p_action text default null, p_source text default 'tablet', p_equipment_code text default null)
returns jsonb language plpgsql as $$
declare cp fabula.haccp_control_points%rowtype; v_res fabula.haccp_result; v_batch uuid; v_log uuid; v_nc uuid; v_staff text; v_eq uuid; v_hold boolean := false;
begin
  select * into cp from fabula.haccp_control_points where code = p_cp_code and active;
  if cp.id is null then raise exception 'Punto di controllo sconosciuto o non attivo: %', p_cp_code; end if;
  if p_batch_lot is not null and p_batch_lot <> '' then
    select id into v_batch from fabula.production_batches where batch_lot = p_batch_lot;
    if v_batch is null then raise exception 'Lotto sconosciuto: %', p_batch_lot; end if;
  end if;
  select full_name into v_staff from fabula.staff where id = p_staff_id;
  v_eq := coalesce((select id from fabula.equipment where code = p_equipment_code), cp.equipment_id);
  v_res := fabula.ccp_eval(cp.min_value, cp.max_value, cp.warn_min, cp.warn_max, p_value);
  insert into fabula.haccp_log (control_point_id, measured_value, result, batch_id, equipment_id, operator, operator_id, corrective_action, source)
  values (cp.id, p_value, v_res, v_batch, v_eq, v_staff, p_staff_id, p_action, coalesce(p_source, 'tablet')) returning id into v_log;
  if v_res = 'non_conformity' then
    insert into fabula.non_conformities (severity, description, haccp_log_id, batch_id, lot_number, equipment_id, corrective_action, opened_by_id)
    values (cp.nc_severity,
            format('%s%s: %s %s fuori dal limite critico. Limite: %s', coalesce(cp.ccp_no || ' · ', ''), cp.name, p_value, coalesce(cp.unit, ''), coalesce(cp.critical_limit_it, '')),
            v_log, v_batch, nullif(p_batch_lot, ''), v_eq, p_action, p_staff_id)
    returning id into v_nc;
    if v_batch is not null and cp.is_ccp then
      update fabula.production_batches set food_safety_hold = true, hold_at = now(), hold_reason = format('%s fuori limite (%s %s)', coalesce(cp.ccp_no, cp.code), p_value, coalesce(cp.unit, '')), hold_nc_id = v_nc,
             hold_released_at = null, hold_released_by_id = null
      where id = v_batch;
      v_hold := true;
    end if;
  end if;
  return jsonb_build_object('result', v_res, 'haccp_log_id', v_log, 'nc_id', v_nc, 'lot_on_hold', v_hold,
                            'corrective_it', case when v_res <> 'ok' then cp.corrective_it end, 'limit_it', cp.critical_limit_it, 'ccp', coalesce(cp.ccp_no, cp.code));
end $$;

-- preset step → CCP log automatically
create or replace function fabula.trg_step_log_ccp() returns trigger language plpgsql as $$
declare v_ccp text; v_lot text;
begin
  select ccp_code into v_ccp from fabula.process_steps where id = new.step_id;
  if v_ccp is null or new.actual_value is null then return new; end if;
  if tg_op = 'UPDATE' and old.actual_value is not distinct from new.actual_value then return new; end if;
  select batch_lot into v_lot from fabula.production_batches where id = new.batch_id;
  perform fabula.log_ccp(v_ccp, new.actual_value, new.staff_id, v_lot, new.note, 'preset');
  return new;
end $$;
do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'batch_step_log_ccp') then
    create trigger batch_step_log_ccp after insert or update of actual_value on fabula.batch_step_logs for each row execute function fabula.trg_step_log_ccp();
  end if;
end $$;

-- held lots cannot be packed/sold from the tablet
create or replace function fabula.trg_block_held_lot_sale() returns trigger language plpgsql as $$
declare r record;
begin
  if new.move_type = 'sale' and new.lot_number is not null and coalesce(new.source, '') = 'tablet' then
    select batch_lot, hold_reason into r from fabula.production_batches where batch_lot = new.lot_number and food_safety_hold;
    if r.batch_lot is not null then raise exception 'Lotto % BLOCCATO per sicurezza alimentare (%): non si può vendere né spedire finché il responsabile non lo sblocca', r.batch_lot, r.hold_reason; end if;
  end if;
  return new;
end $$;
do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'stock_moves_block_held') then
    create trigger stock_moves_block_held before insert on fabula.stock_moves for each row execute function fabula.trg_block_held_lot_sale();
  end if;
end $$;

create or replace function fabula.release_lot_hold(p_lot text, p_staff_id uuid, p_note text) returns text language plpgsql as $$
begin
  if coalesce(trim(p_note), '') = '' then raise exception 'Serve una motivazione (es. esito analisi conforme, valutazione del consulente)'; end if;
  update fabula.production_batches set food_safety_hold = false, hold_released_at = now(), hold_released_by_id = p_staff_id,
         notes = concat_ws(E'\n', notes, format('[%s] sblocco: %s', to_char(now() at time zone 'Europe/Rome', 'DD/MM HH24:MI'), p_note))
  where batch_lot = p_lot and food_safety_hold;
  if not found then raise exception 'Lotto % non bloccato', p_lot; end if;
  return 'released';
end $$;

create or replace function fabula.hold_lot(p_lot text, p_reason text, p_staff_id uuid default null) returns text language plpgsql as $$
begin
  update fabula.production_batches set food_safety_hold = true, hold_at = now(), hold_reason = p_reason, hold_released_at = null, hold_released_by_id = null where batch_lot = p_lot;
  if not found then raise exception 'Lotto sconosciuto: %', p_lot; end if;
  return 'held';
end $$;

create or replace view fabula.v_lots_on_hold as
select b.batch_lot, b.batch_date, p.name as product, b.output_kg, b.hold_reason, b.hold_nc_id,
       coalesce((select sum(qty) from fabula.stock_moves sm where sm.lot_number = b.batch_lot), 0) as kg_on_hand,
       coalesce((select -sum(qty) from fabula.stock_moves sm where sm.lot_number = b.batch_lot and sm.move_type = 'sale'), 0) as kg_sold
from fabula.production_batches b join fabula.products p on p.id = b.product_id
where b.food_safety_hold;

create or replace view fabula.v_haccp_plan as
select cp.sort, cp.ccp_no, cp.code, cp.name, cp.is_ccp, cp.process_step, cp.applies_when, cp.hazard_it, cp.critical_limit_it,
       cp.min_value, cp.max_value, cp.warn_min, cp.warn_max, cp.unit, cp.frequency, cp.monitoring_it, cp.corrective_it, cp.verification_it, cp.records_it,
       cp.nc_severity, cp.active, e.code as equipment_code,
       (select count(*) from fabula.haccp_log l where l.control_point_id = cp.id and l.logged_at > now() - interval '30 days') as logs_30d,
       (select count(*) from fabula.haccp_log l where l.control_point_id = cp.id and l.logged_at > now() - interval '30 days' and l.result = 'non_conformity') as nc_30d,
       (select max(logged_at) from fabula.haccp_log l where l.control_point_id = cp.id) as last_logged_at
from fabula.haccp_control_points cp left join fabula.equipment e on e.id = cp.equipment_id
order by cp.sort, cp.code;
update fabula.haccp_control_points set ccp_no = 'PRP' where code in ('PRP-CLEAN','PRP-PEST') and ccp_no is null;

-- ============ 4. Sampling plan & lab results ============
create table if not exists fabula.lab_tests (
  id uuid primary key default gen_random_uuid(),
  code text unique not null,
  matrix text not null check (matrix in ('mozzarella','ricotta','latte_crudo','acqua','ambiente','salamoia_governo')),
  kind text not null check (kind in ('sicurezza','igiene_processo','qualita_dop','acqua','ambiente','latte')),
  analyte_it text not null,
  criterion_ref text, n int, c int, m_limit numeric, big_m_limit numeric, unit text,
  limit_it text, stage_it text, sampling_point_it text, method_it text,
  frequency_days int not null,
  responsible text default 'partner',
  lab text,
  active boolean not null default true,
  sort int not null default 100,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now());

create table if not exists fabula.lab_samples (
  id uuid primary key default gen_random_uuid(),
  test_id uuid not null references fabula.lab_tests(id),
  sample_code text unique not null,
  taken_on date not null default (now() at time zone 'Europe/Rome')::date,
  taken_by_id uuid references fabula.staff(id),
  lot_number text,
  batch_id uuid references fabula.production_batches(id),
  sampling_point text,
  lab text,
  sent_on date,
  report_no text, report_date date,
  result_value numeric, result_it text,
  outcome text not null default 'in_attesa' check (outcome in ('in_attesa','conforme','attenzione','non_conforme','annullato')),
  document_id uuid references fabula.documents(id),
  nc_id uuid references fabula.non_conformities(id),
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now());
create index if not exists lab_samples_test_idx on fabula.lab_samples (test_id, taken_on desc);

insert into fabula.lab_tests (code, matrix, kind, analyte_it, criterion_ref, n, c, m_limit, big_m_limit, unit, limit_it, stage_it, sampling_point_it, method_it, frequency_days, responsible, sort, notes) values
 ('MOZ-LM','mozzarella','sicurezza','Listeria monocytogenes','Reg. CE 2073/2005 All. I cap. 1, 1.2 (mod. Reg. UE 2024/2895)',5,0,null,null,'ufc/g',
  'Non rilevata in 25 g per tutta la shelf-life, salvo dimostrazione (studio di shelf-life) che resti ≤ 100 ufc/g fino alla scadenza','Prodotto finito, prima dell''uscita e a fine shelf-life (1 volta su 4)','Confezione finita dal lotto del giorno','ISO 11290-1',30,'partner',10,
  'Prodotto pronto al consumo che consente la crescita di Listeria (pH > 4,4, aw > 0,92). Per un micro-caseificio n=5 si può comporre in un pool, da concordare con il laboratorio.'),
 ('MOZ-SAL','mozzarella','sicurezza','Salmonella spp.','Reg. CE 2073/2005 1.11 (formaggi a latte crudo o trattato sotto la pastorizzazione)',5,0,null,null,'25 g',
  'Non rilevata in 25 g','Prodotto immesso sul mercato durante la shelf-life','Confezione finita','ISO 6579-1',90,'partner',11,'Obbligatorio se il latte non è pastorizzato.'),
 ('MOZ-CPS','mozzarella','igiene_processo','Stafilococchi coagulasi-positivi','Reg. CE 2073/2005 2.2.3 (latte crudo) · 2.2.4/2.2.5 se pastorizzato',5,2,10000,100000,'ufc/g',
  'Latte crudo: m 10⁴ – M 10⁵ ufc/g (pastorizzato: m 10 – M 100 a fine produzione). Oltre 10⁵ → ricerca enterotossine sul lotto','Durante la lavorazione, quando la carica è massima (cagliata matura prima della filatura)','Cagliata pronta per la filatura','ISO 6888-1/2',30,'partner',12,null),
 ('MOZ-ENT','mozzarella','sicurezza','Enterotossine stafilococciche','Reg. CE 2073/2005 1.21',5,0,null,null,'25 g',
  'Non rilevate in 25 g','Prodotto in shelf-life','Confezione finita','EN ISO 19020',365,'partner',13,'Annuale come verifica · SUBITO se gli stafilococchi superano 10⁵ ufc/g.'),
 ('MOZ-ECO','mozzarella','igiene_processo','Escherichia coli','Reg. CE 2073/2005 2.2.2 (se latte trattato termicamente) / indicatore di igiene',5,2,100,1000,'ufc/g',
  'm 100 – M 1.000 ufc/g','Durante la lavorazione, quando la carica attesa è minima (dopo la filatura)','Pasta filata/prodotto finito','ISO 16649-2',90,'partner',14,null),
 ('MOZ-DOP','mozzarella','qualita_dop','Umidità e grasso sulla sostanza secca','Disciplinare Mozzarella di Bufala Campana DOP',1,0,null,null,'%',
  'Umidità ≤ 65 % · grasso sulla s.s. ≥ 52 % (verificare sul disciplinare vigente)','Prodotto finito dopo 24 h in liquido di governo','Pezzo da 250 g','metodi ufficiali',90,'partner',15,'La prova del 29/09 ha dato ~65 % a 30 h: tenere sotto controllo.'),
 ('MOZ-SHELF','mozzarella','sicurezza','Studio di shelf-life / challenge test Listeria','Reg. CE 2073/2005 All. II · Reg. UE 2024/2895',1,0,null,null,null,
  'Dimostra che Listeria resta ≤ 100 ufc/g fino alla data di scadenza dichiarata','Una tantum e a ogni cambio di ricetta, confezione o shelf-life','3 lotti a inizio, metà e fine shelf-life','EURL Lm technical guidance',365,'partner',16,'Senza questo studio il criterio applicabile è l''assenza in 25 g per tutta la shelf-life.'),
 ('RIC-LM','ricotta','sicurezza','Listeria monocytogenes','Reg. CE 2073/2005 1.2',5,0,null,null,'ufc/g',
  'Non rilevata in 25 g (salvo studio di shelf-life)','Prodotto finito','Fuscella dal lotto del giorno','ISO 11290-1',30,'partner',20,'La ricotta è a rischio di ricontaminazione dopo il trattamento termico: priorità alta.'),
 ('RIC-CPS','ricotta','igiene_processo','Stafilococchi coagulasi-positivi','Reg. CE 2073/2005 2.2.5 (formaggi freschi da siero trattato termicamente)',5,2,10,100,'ufc/g',
  'm 10 – M 100 ufc/g','Fine produzione','Fuscella','ISO 6888',90,'partner',21,null),
 ('RIC-ECO','ricotta','igiene_processo','Escherichia coli','Reg. CE 2073/2005 2.2.2',5,2,100,1000,'ufc/g',
  'm 100 – M 1.000 ufc/g','Durante la lavorazione','Fuscella','ISO 16649-2',90,'partner',22,null),
 ('LAT-CBT','latte_crudo','latte','Carica batterica a 30 °C','Reg. CE 853/2004 All. III Sez. IX (latte di altre specie)',null,null,500000,null,'ufc/ml',
  '≤ 500.000 ufc/ml (latte crudo per prodotti senza trattamento termico · altrimenti ≤ 1.500.000) — media geometrica mobile su 2 mesi','Latte alla stalla/all''arrivo','Campione dal tank della Masseria','ISO 4833 / metodi strumentali',15,'Masseria',30,'Almeno 2 campioni al mese: di norma li fa l''allevatore (APA/ARA), ricevere copia dei referti.'),
 ('LAT-SCC','latte_crudo','latte','Cellule somatiche','Indicatore mastiti (nessun limite UE per la bufala)',null,null,null,null,'cell/ml',
  'Trend mensile · obiettivo aziendale da fissare con la Masseria','Latte alla stalla','Tank','ISO 13366',15,'Masseria',31,null),
 ('LAT-INIB','latte_crudo','latte','Residui inibenti (conferma di laboratorio)','Reg. UE 37/2010',null,null,null,null,'esito',
  'Negativo','Latte all''arrivo','Campione di un conferimento','metodo microbiologico di screening',30,'partner',32,'Conferma mensile del test rapido giornaliero (CCP 1b).'),
 ('LAT-AFM1','latte_crudo','latte','Aflatossina M1','Reg. UE 2023/915',null,null,0.050,null,'µg/kg',
  '≤ 0,050 µg/kg','Latte all''arrivo','Campione di un conferimento','HPLC',90,'partner',33,'Più a rischio con mais/insilati in estate: aumentare la frequenza in estate e al cambio di razione.'),
 ('H2O-MIC-PROC','acqua','acqua','Microbiologico acqua a contatto col prodotto (E. coli, enterococchi, coliformi, conta 22 °C)','D.Lgs. 18/2023 All. I',null,null,0,null,'ufc/100 ml',
  'E. coli 0/100 ml · enterococchi 0/100 ml · coliformi totali 0/100 ml · conta a 22 °C senza variazioni anomale','Punto d''uso','Rubinetto che alimenta rassodamento, liquido di governo e salamoia','ISO 9308 / 7899 / 6222',180,'partner',40,'Ripetere dopo ogni intervento sull''impianto idrico o rottura del contatore.'),
 ('H2O-MIC-LAV','acqua','acqua','Microbiologico acqua di lavaggio','D.Lgs. 18/2023 All. I',null,null,0,null,'ufc/100 ml',
  'E. coli 0/100 ml · enterococchi 0/100 ml · coliformi totali 0/100 ml','Punto d''uso','Lavello lavaggio attrezzature / lavamani','ISO 9308 / 7899',365,'partner',41,null),
 ('H2O-CHIM','acqua','acqua','Chimico di routine (pH, conducibilità, torbidità, ammonio, nitriti, nitrati, ferro, manganese, cloro residuo)','D.Lgs. 18/2023 All. I',null,null,null,null,null,
  'Entro i valori di parametro dell''All. I','Punto d''uso','Rubinetto sala lavorazione','metodi ufficiali',365,'partner',42,'Se l''acqua è di pozzo: analisi completa e frequenza maggiore, serve il giudizio di idoneità ASL.'),
 ('H2O-LEG','acqua','acqua','Legionella (acqua calda sanitaria)','D.Lgs. 18/2023 (valutazione del rischio dell''impianto interno) · Linee guida Legionellosi 2015',null,null,1000,null,'ufc/l',
  '< 1.000 ufc/l (soglia di intervento delle linee guida)','Acqua calda','Boiler / doccia spogliatoio','ISO 11731',365,'partner',43,null),
 ('ENV-LIS','ambiente','ambiente','Listeria spp. su superfici (tamponi)','Reg. CE 2073/2005 art. 5(2) · ISO 18593',null,null,null,null,'presenza',
  'Assente. Positivo → pulizia straordinaria e nuovo tampone entro 7 giorni · se L. monocytogenes, analisi del prodotto','Durante la produzione, almeno 3 h dopo l''inizio','5 punti a rotazione: scarichi a pavimento, tavolo/formatrice, vasca rassodamento, guarnizioni cella, lavelli/stivali','ISO 11290-1 su tamponi',30,'partner',50,'Obbligatorio per chi produce alimenti pronti che possono veicolare Listeria.'),
 ('ENV-SAN','ambiente','ambiente','Verifica sanificazione (conta totale/Enterobatteri o ATP su superfici a contatto)','Verifica PRP sanificazione',null,null,null,null,'ufc/cm²',
  'Secondo i limiti concordati con il laboratorio (es. conta totale < 10 ufc/cm², Enterobatteri assenti)','Dopo la sanificazione, prima della produzione','Tina, formatrice, vasca, fuscelle, coltelli','ISO 18593',30,'partner',51,null),
 ('SAL-LIS','salamoia_governo','ambiente','Listeria spp. nella salamoia / liquido di governo','Verifica PRP',null,null,null,null,'25 ml',
  'Assente','Salamoia in uso','Vasca salamoia','ISO 11290-1',90,'partner',60,'La salamoia riutilizzata è un punto noto di persistenza di Listeria: rinnovo e filtrazione da documentare.')
on conflict (code) do nothing;

create or replace view fabula.v_lab_plan_status as
with last as (
  select t.id, max(s.taken_on) filter (where s.outcome <> 'annullato') as last_taken,
         count(*) filter (where s.outcome = 'in_attesa') as pending,
         (array_agg(s.outcome order by s.taken_on desc) filter (where s.outcome not in ('in_attesa','annullato')))[1] as last_outcome
  from fabula.lab_tests t left join fabula.lab_samples s on s.test_id = t.id group by t.id),
start as (select nullif(fabula.setting_text('food.sampling_start', ''), '')::date as d)
select t.id, t.code, t.matrix, t.kind, t.analyte_it, t.criterion_ref, t.limit_it, t.sampling_point_it, t.frequency_days, t.responsible,
       coalesce(t.lab, nullif(fabula.setting_text('food.lab_name', ''), '')) as lab, t.sort, t.notes, t.n, t.c, t.m_limit, t.big_m_limit, t.unit, t.stage_it, t.method_it,
       l.last_taken, l.pending, l.last_outcome,
       case when (select d from start) is null then null
            else greatest(coalesce(l.last_taken + t.frequency_days, (select d from start)), (select d from start)) end as next_due,
       (select d from start) is not null as plan_active
from fabula.lab_tests t join last l on l.id = t.id
where t.active
order by t.sort;

create or replace view fabula.v_lab_samples_recent as
select s.id, s.sample_code, s.taken_on, t.code as test_code, t.matrix, t.analyte_it, s.lot_number, s.sampling_point, s.lab, s.sent_on,
       s.report_no, s.report_date, s.result_value, s.result_it, s.outcome, s.document_id, s.nc_id, s.notes, st.full_name as taken_by,
       (now() at time zone 'Europe/Rome')::date - s.taken_on as days_waiting
from fabula.lab_samples s join fabula.lab_tests t on t.id = s.test_id left join fabula.staff st on st.id = s.taken_by_id
where s.taken_on > (now() at time zone 'Europe/Rome')::date - 400
order by s.taken_on desc, s.sample_code desc;

create or replace function fabula.record_sample_taken(p_test_code text, p_lot text default null, p_point text default null, p_staff_id uuid default null, p_notes text default null, p_on date default null)
returns jsonb language plpgsql as $$
declare t fabula.lab_tests%rowtype; v_on date := coalesce(p_on, (now() at time zone 'Europe/Rome')::date); v_code text; n int; v_batch uuid; v_id uuid;
begin
  select * into t from fabula.lab_tests where code = p_test_code;
  if t.id is null then raise exception 'Analisi sconosciuta: %', p_test_code; end if;
  if p_lot is not null and p_lot <> '' then select id into v_batch from fabula.production_batches where batch_lot = p_lot; end if;
  select count(*) + 1 into n from fabula.lab_samples where taken_on = v_on;
  v_code := 'C' || to_char(v_on, 'YYYYMMDD') || '-' || lpad(n::text, 2, '0');
  insert into fabula.lab_samples (test_id, sample_code, taken_on, taken_by_id, lot_number, batch_id, sampling_point, lab, notes)
  values (t.id, v_code, v_on, p_staff_id, nullif(p_lot, ''), v_batch, coalesce(nullif(p_point, ''), t.sampling_point_it), coalesce(t.lab, nullif(fabula.setting_text('food.lab_name', ''), '')), p_notes)
  returning id into v_id;
  return jsonb_build_object('sample_code', v_code, 'id', v_id, 'test', t.code, 'analyte', t.analyte_it,
    'label_it', format('%s · %s · %s%s', v_code, t.analyte_it, to_char(v_on, 'DD/MM/YYYY'), coalesce(' · lotto ' || nullif(p_lot, ''), '')));
end $$;

create or replace function fabula.record_lab_result(p_sample_code text, p_outcome text, p_value numeric default null, p_text text default null,
                                                    p_report_no text default null, p_report_date date default null, p_document_id uuid default null, p_staff_id uuid default null)
returns jsonb language plpgsql as $$
declare s fabula.lab_samples%rowtype; t fabula.lab_tests%rowtype; v_nc uuid; v_sev fabula.nc_severity; v_dist jsonb := '[]'; v_actions text[] := '{}';
begin
  if p_outcome not in ('conforme','attenzione','non_conforme','annullato') then raise exception 'Esito non valido: %', p_outcome; end if;
  select * into s from fabula.lab_samples where sample_code = p_sample_code;
  if s.id is null then raise exception 'Campione sconosciuto: %', p_sample_code; end if;
  select * into t from fabula.lab_tests where id = s.test_id;
  update fabula.lab_samples set outcome = p_outcome, result_value = coalesce(p_value, result_value), result_it = coalesce(p_text, result_it),
         report_no = coalesce(p_report_no, report_no), report_date = coalesce(p_report_date, report_date, (now() at time zone 'Europe/Rome')::date),
         document_id = coalesce(p_document_id, document_id), updated_at = now()
  where id = s.id;
  if p_outcome = 'non_conforme' and s.nc_id is null then
    v_sev := case when t.kind = 'sicurezza' then 'critical' when t.kind = 'acqua' and t.code like 'H2O-MIC%' then 'critical' else 'major' end;
    insert into fabula.non_conformities (severity, description, lot_number, batch_id, corrective_action, opened_by_id)
    values (v_sev, format('Analisi %s NON CONFORME (%s, campione %s%s): %s', t.code, t.analyte_it, s.sample_code, coalesce(', lotto ' || s.lot_number, ''), coalesce(p_text, p_value::text, '')),
            s.lot_number, s.batch_id, null, p_staff_id) returning id into v_nc;
    update fabula.lab_samples set nc_id = v_nc where id = s.id;
    if t.kind = 'sicurezza' then
      if s.lot_number is not null then
        perform fabula.hold_lot(s.lot_number, format('Analisi %s non conforme (%s)', t.code, s.sample_code), p_staff_id);
        select coalesce(jsonb_agg(to_jsonb(d)), '[]') into v_dist from fabula.v_lot_distribution d where d.lot_number = s.lot_number;
      end if;
      v_actions := array['Lotto bloccato: non vendere','Valutare ritiro/richiamo (art. 19 Reg. CE 178/2002) e informare l''ASL Salerno — SIAN/Servizio Veterinario','Campionare i lotti prodotti dopo','Pulizia straordinaria + tamponi ambientali','Rivedere CCP filatura/ricotta e conservazione'];
      insert into fabula.approvals (kind, requested_by, summary, payload, status, expires_at)
      values ('other', 'agent:food_safety', format('⚠ Valutare ritiro/richiamo · %s non conforme su lotto %s', t.analyte_it, coalesce(s.lot_number, 'n/d')),
              jsonb_build_object('type', 'recall_assessment', 'sample_code', s.sample_code, 'test', t.code, 'lot', s.lot_number, 'distribution', v_dist, 'nc_id', v_nc), 'pending', now() + interval '2 days');
    elsif t.kind = 'ambiente' then
      v_actions := array['Pulizia e sanificazione straordinaria del punto positivo e della zona','Nuovo tampone entro 7 giorni (stesso punto + 4 vicini)','Se L. monocytogenes: analisi Listeria sul prodotto dei lotti in giacenza'];
    elsif t.kind = 'acqua' then
      v_actions := array['Non usare l''acqua per contatto col prodotto finché non è conforme','Avvisare il gestore idrico','Flussaggio/sanificazione dell''impianto interno e ricampionamento','Valutare il prodotto fatto con quell''acqua'];
    else
      v_actions := array['Analisi delle cause (latte, igiene di lavorazione, tempi/temperature)','Ricampionamento sul lotto successivo','Rivedere la procedura con il casaro'];
    end if;
  end if;
  return jsonb_build_object('sample_code', s.sample_code, 'test', t.code, 'outcome', p_outcome, 'nc_id', v_nc, 'actions_it', to_jsonb(v_actions), 'distribution', v_dist,
                            'lot_on_hold', v_nc is not null and t.kind = 'sicurezza' and s.lot_number is not null);
end $$;

-- ============ 5. Pest control ============
create table if not exists fabula.pest_stations (
  id uuid primary key default gen_random_uuid(),
  code text unique not null,
  kind text not null check (kind in ('esca_esterna','trappola_meccanica','trappola_collante','lampada_uv','feromoni','altro')),
  location_it text not null,
  inside boolean not null default true,
  active boolean not null default true,
  installed_on date,
  notes text,
  created_at timestamptz not null default now());

create table if not exists fabula.pest_inspections (
  id uuid primary key default gen_random_uuid(),
  inspected_on date not null default (now() at time zone 'Europe/Rome')::date,
  by_kind text not null check (by_kind in ('interno','ditta')),
  company text, technician text, report_no text,
  document_id uuid references fabula.documents(id),
  staff_id uuid references fabula.staff(id),
  findings jsonb not null default '[]',
  activity_found boolean not null default false,
  activity_inside boolean not null default false,
  products_used text, actions_it text,
  nc_id uuid references fabula.non_conformities(id),
  created_at timestamptz not null default now());

insert into fabula.pest_stations (code, kind, location_it, inside, notes) values
  ('ESC-01','esca_esterna','Perimetro esterno · ingresso latte (lato strada)', false, 'Contenitore chiuso a chiave, fissato. Esca rodenticida SOLO all''esterno.'),
  ('ESC-02','esca_esterna','Perimetro esterno · scarico siero / zona effluenti', false, null),
  ('ESC-03','esca_esterna','Perimetro esterno · retro, area rifiuti', false, null),
  ('ESC-04','esca_esterna','Perimetro esterno · ingresso spaccio', false, null),
  ('TRP-01','trappola_meccanica','Sala lavorazione · vicino alla porta di carico', true, 'All''interno solo trappole a cattura senza esca tossica.'),
  ('TRP-02','trappola_meccanica','Deposito imballi e consumabili', true, null),
  ('TRP-03','trappola_meccanica','Corridoio celle frigo', true, null),
  ('TRP-04','trappola_meccanica','Locale detergenti', true, null),
  ('UV-01','lampada_uv','Sala lavorazione · lontano dal prodotto esposto (piastra collante, non a griglia elettrica)', true, null),
  ('UV-02','lampada_uv','Spaccio / retrobanco', true, null),
  ('FER-01','feromoni','Deposito sale, acido citrico, imballi', true, 'Insetti delle derrate.')
on conflict (code) do nothing;

update fabula.compliance_deadlines set interval_days = 45,
  notes = 'Contratto con ditta autorizzata: 8 visite/anno (ogni 45 gg), planimetria numerata delle postazioni, schede tecniche e di sicurezza dei biocidi, rapporto di intervento firmato → caricarlo in haccp.html → Infestanti'
where kind = 'pest_control' and done_on is null;

create or replace function fabula.record_pest_inspection(p_by text, p_findings jsonb, p_staff_id uuid default null, p_company text default null,
                                                         p_report_no text default null, p_actions text default null, p_products text default null,
                                                         p_document_id uuid default null, p_on date default null)
returns jsonb language plpgsql as $$
declare v_on date := coalesce(p_on, (now() at time zone 'Europe/Rome')::date); v_act boolean; v_in boolean; v_id uuid; v_nc uuid; v_cp uuid; v_txt text; v_dl uuid;
begin
  if p_by not in ('interno','ditta') then raise exception 'p_by deve essere interno o ditta'; end if;
  select bool_or(f->>'status' in ('consumo','cattura','insetti','tracce')),
         bool_or(f->>'status' in ('consumo','cattura','insetti','tracce') and coalesce(ps.inside, true)),
         string_agg(format('%s %s%s', f->>'station', f->>'status', coalesce(' (' || nullif(f->>'note', '') || ')', '')), ', ') filter (where f->>'status' <> 'ok')
    into v_act, v_in, v_txt
  from jsonb_array_elements(coalesce(p_findings, '[]')) f left join fabula.pest_stations ps on ps.code = f->>'station';
  v_act := coalesce(v_act, false); v_in := coalesce(v_in, false);
  insert into fabula.pest_inspections (inspected_on, by_kind, company, report_no, document_id, staff_id, findings, activity_found, activity_inside, products_used, actions_it)
  values (v_on, p_by, p_company, p_report_no, p_document_id, p_staff_id, coalesce(p_findings, '[]'), v_act, v_in, p_products, p_actions) returning id into v_id;
  if v_in then
    insert into fabula.non_conformities (severity, description, corrective_action, opened_by_id)
    values ('major', 'Infestanti: attività all''interno — ' || coalesce(v_txt, ''), p_actions, p_staff_id) returning id into v_nc;
    update fabula.pest_inspections set nc_id = v_nc where id = v_id;
  end if;
  select id into v_cp from fabula.haccp_control_points where code = 'PRP-PEST';
  insert into fabula.haccp_log (control_point_id, result, operator_id, operator, corrective_action, source)
  values (v_cp, case when v_in then 'non_conformity' when v_act then 'warning' else 'ok' end::fabula.haccp_result, p_staff_id,
          coalesce((select full_name from fabula.staff where id = p_staff_id), p_company), coalesce(p_actions, v_txt), case when p_by = 'ditta' then 'ditta' else 'tablet' end);
  if p_by = 'interno' then
    update fabula.task_instances ti set status = 'done', completed_at = now(), completed_by_id = p_staff_id
    from fabula.task_schedules s where s.id = ti.schedule_id and s.code = 'T-PEST' and ti.status in ('due','overdue') and ti.due_at::date between v_on - 7 and v_on;
  else
    select id into v_dl from fabula.compliance_deadlines where kind = 'pest_control' and done_on is null order by due_on nulls first limit 1;
    if v_dl is not null then perform fabula.complete_deadline(v_dl, v_on, 'Visita ditta ' || coalesce(p_report_no, '')); end if;
  end if;
  return jsonb_build_object('id', v_id, 'activity_found', v_act, 'activity_inside', v_in, 'nc_id', v_nc, 'summary_it', coalesce(v_txt, 'tutte le postazioni ok'));
end $$;

create or replace view fabula.v_pest_status as
select ps.code, ps.kind, ps.location_it, ps.inside, ps.active,
       last.inspected_on as last_inspected_on, last.status as last_status, last.by_kind as last_by,
       (select count(*) from fabula.pest_inspections pi, jsonb_array_elements(pi.findings) f
         where f->>'station' = ps.code and f->>'status' <> 'ok' and pi.inspected_on > (now() at time zone 'Europe/Rome')::date - 90) as findings_90d
from fabula.pest_stations ps
left join lateral (select pi.inspected_on, pi.by_kind, f->>'status' as status from fabula.pest_inspections pi, jsonb_array_elements(pi.findings) f
                   where f->>'station' = ps.code order by pi.inspected_on desc, pi.created_at desc limit 1) last on true
order by ps.inside desc, ps.code;

-- ============ 6. Training ============
create table if not exists fabula.training_courses (
  code text primary key,
  name_it text not null,
  category text not null check (category in ('alimentare','sicurezza_lavoro','interna')),
  hours_first numeric, hours_refresh numeric,
  validity_days int,
  roles fabula.staff_role[] not null default '{}',
  legal_ref text, notes text, sort int not null default 100);

create table if not exists fabula.training_records (
  id uuid primary key default gen_random_uuid(),
  staff_id uuid references fabula.staff(id),
  person_name text,
  course_code text not null references fabula.training_courses(code),
  provider text, hours numeric,
  completed_on date not null,
  expires_on date,
  certificate_document_id uuid references fabula.documents(id),
  notes text,
  created_at timestamptz not null default now(),
  check (staff_id is not null or person_name is not null));

insert into fabula.training_courses (code, name_it, category, hours_first, hours_refresh, validity_days, roles, legal_ref, notes, sort) values
 ('ALIM-R2','Alimentarista rischio 2 — lavorazione latte e formaggi','alimentare',8,3,1095,'{casaro,operaio}','Reg. CE 852/2004 All. II cap. XII · Regione Campania (D.D. 2018 requisiti formazione alimentaristi)','Attestato da ente riconosciuto · aggiornamento triennale.',10),
 ('ALIM-R1','Alimentarista rischio 1 — vendita al banco','alimentare',4,3,1095,'{commesso}','Reg. CE 852/2004 · Regione Campania','Chi affetta/porziona al banco: valutare il rischio 2 con il consulente.',11),
 ('RESP-HACCP','Responsabile dell''industria alimentare / piano HACCP','alimentare',12,6,1095,'{owner,partner}','Reg. CE 852/2004 art. 5 · Regione Campania','Almeno il titolare o chi firma il piano di autocontrollo.',12),
 ('INT-SOP','Formazione interna: piano HACCP aziendale, CCP, SOP, allergeni, igiene personale','interna',2,2,365,'{owner,partner,casaro,operaio,commesso}','Reg. CE 852/2004 All. II cap. XII (formazione proporzionata alle mansioni)','Annuale e a ogni modifica del piano · verbale firmato con argomenti e presenti.',13),
 ('SIC-LAV','Sicurezza lavoratori: generale + specifica rischio medio','sicurezza_lavoro',12,6,1825,'{casaro,operaio,commesso}','D.Lgs. 81/2008 art. 37 · Accordo Stato-Regioni','Aggiornamento 6 h ogni 5 anni.',20),
 ('PRIMO-SOCC','Addetto primo soccorso (gruppo B/C)','sicurezza_lavoro',12,4,1095,'{}','D.M. 388/2003','Almeno un addetto per turno.',21),
 ('ANTINC','Addetto antincendio (livello 1 o 2)','sicurezza_lavoro',4,2,1825,'{}','D.M. 2/9/2021','Almeno un addetto per turno · livello da valutazione rischio incendio.',22)
on conflict (code) do nothing;

create or replace function fabula.trg_training_defaults() returns trigger language plpgsql as $$
begin
  if new.expires_on is null then
    select new.completed_on + validity_days into new.expires_on from fabula.training_courses where code = new.course_code;
  end if;
  return new;
end $$;
create or replace function fabula.trg_training_sync_staff() returns trigger language plpgsql as $$
begin
  if new.staff_id is not null then
    update fabula.staff s set haccp_training_expires = (
      select max(r.expires_on) from fabula.training_records r join fabula.training_courses c on c.code = r.course_code
      where r.staff_id = new.staff_id and c.category = 'alimentare')
    where s.id = new.staff_id;
  end if;
  return new;
end $$;
do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'training_defaults') then
    create trigger training_defaults before insert or update on fabula.training_records for each row execute function fabula.trg_training_defaults();
  end if;
  if not exists (select 1 from pg_trigger where tgname = 'training_sync_staff') then
    create trigger training_sync_staff after insert or update on fabula.training_records for each row execute function fabula.trg_training_sync_staff();
  end if;
end $$;

create or replace view fabula.v_training_matrix as
select s.id as staff_id, s.full_name, s.badge_code, s.role, c.code as course_code, c.name_it as course_name, c.category, c.validity_days, c.sort,
       r.completed_on, r.expires_on, r.provider, r.certificate_document_id,
       case when r.expires_on is null and r.completed_on is null then 'mancante'
            when r.expires_on < (now() at time zone 'Europe/Rome')::date then 'scaduto'
            when r.expires_on <= (now() at time zone 'Europe/Rome')::date + 60 then 'in_scadenza'
            else 'valido' end as status
from fabula.staff s
join fabula.training_courses c on s.role = any(c.roles)
left join lateral (select * from fabula.training_records r where r.staff_id = s.id and r.course_code = c.code order by r.completed_on desc limit 1) r on true
where s.active
order by s.full_name, c.sort;

-- ============ 7. Instruments: verification & calibration ============
create table if not exists fabula.calibration_checks (
  id uuid primary key default gen_random_uuid(),
  equipment_id uuid not null references fabula.equipment(id),
  checked_at timestamptz not null default now(),
  kind text not null check (kind in ('verifica_interna','taratura_esterna')),
  method text not null check (method in ('ghiaccio_fondente','acqua_bollente','confronto_riferimento','tamponi_ph','pesi_campione','certificato_lab','confronto_display')),
  points jsonb not null default '[]',
  max_deviation numeric, tolerance numeric,
  result text not null check (result in ('ok','ko')),
  adjusted boolean not null default false,
  provider text, certificate_no text,
  certificate_document_id uuid references fabula.documents(id),
  staff_id uuid references fabula.staff(id),
  note text,
  nc_id uuid references fabula.non_conformities(id),
  created_at timestamptz not null default now());
create index if not exists calibration_checks_eq_idx on fabula.calibration_checks (equipment_id, checked_at desc);

-- instrument register (codes stay editable in the console)
update fabula.equipment set name = 'Termometro a sonda (ricevimento latte, celle)', check_interval_days = 30, tolerance = 0.5, tolerance_unit = '°C',
       calibration_interval_days = null,
       notes = 'Verifica interna mensile a 2 punti (ghiaccio fondente 0 °C + confronto col termometro di riferimento a ~60 °C). Fuori tolleranza ±0,5 °C → fuori servizio.'
where code = 'TERM-01';
update fabula.equipment set check_interval_days = 90, tolerance = 1.0, tolerance_unit = '°C', notes = 'Display della cella: confronto trimestrale con TERM-01 in un bicchiere d''acqua stabilizzato nella cella (±1 °C).' where code in ('CF-01','CF-02');
update fabula.equipment set check_interval_days = 30, tolerance = 0.5, tolerance_unit = '°C',
       notes = 'Registratore/indicatore: taratura annuale dal tecnico (certificato) · confronto mensile con il termometro di riferimento. Se il latte è pastorizzato: confronto indicatore/registratore ogni giorno.' where code = 'PAST-01';
update fabula.equipment set calibration_interval_days = 1095, check_interval_days = 7, tolerance = 0.2, tolerance_unit = '% del peso campione',
       notes = 'Se il peso del latte determina il pagamento: verificazione periodica metrologica (D.M. 93/2017, ogni 3 anni, bollino verde). Controllo settimanale con pesi campione.' where code = 'BIL-01';

insert into fabula.equipment (code, name, kind, location, calibration_interval_days, check_interval_days, tolerance, tolerance_unit, reference_instrument, notes) values
 ('TERM-REF','Termometro di riferimento (certificato di taratura LAT/Accredia)','thermometer','ufficio · custodito, non usato in produzione',365,null,0.2,'°C',true,
  'Si usa SOLO per verificare gli altri termometri. Taratura annuale in un centro LAT (ISO/IEC 17025) almeno a 0, 60 e 90 °C · conservare il certificato.'),
 ('TERM-02','Termometro a sonda alta temperatura (filatura, ricotta, pastorizzazione)','thermometer','sala lavorazione',null,30,0.5,'°C',false,
  'Verifica mensile: acqua bollente (≈100 °C a livello del mare) e confronto con TERM-REF a ~90 °C. Serve per CCP 3 e CCP 4.'),
 ('PH-01','pH-metro da banco/portatile','other','sala lavorazione',null,1,0.05,'pH',false,
  'Calibrazione ogni giorno di produzione con tamponi 4,01 e 7,00 (pendenza 95–105 %) · tamponi freschi, data di apertura sul flacone · elettrodo conservato in KCl 3M.'),
 ('BIL-02','Bilancia banco vendita','scale','spaccio',1095,7,null,null,false,
  'Usata per vendita a peso: verificazione periodica obbligatoria (D.M. 93/2017, ogni 3 anni) + libretto metrologico · controllo settimanale con peso campione.')
on conflict (code) do nothing;

create or replace view fabula.v_instruments as
select e.id, e.code, e.name, e.kind, e.location, e.reference_instrument, e.out_of_service, e.tolerance, e.tolerance_unit,
       e.check_interval_days, e.last_checked_on, case when e.last_checked_on is not null and e.check_interval_days is not null then e.last_checked_on + e.check_interval_days end as next_check_on,
       e.calibration_interval_days, e.last_calibrated_on, e.next_calibration_on, e.calibration_cert_ref, e.technician_contact, e.notes,
       lc.checked_at as last_check_at, lc.result as last_result, lc.max_deviation as last_deviation, lc.method as last_method
from fabula.equipment e
left join lateral (select * from fabula.calibration_checks c where c.equipment_id = e.id order by checked_at desc limit 1) lc on true
where e.active and (e.check_interval_days is not null or e.calibration_interval_days is not null or e.kind in ('thermometer','scale'))
order by e.reference_instrument desc, e.code;

create or replace function fabula.record_calibration_check(p_code text, p_kind text, p_method text, p_points jsonb, p_staff_id uuid default null,
                                                           p_provider text default null, p_certificate_no text default null, p_document_id uuid default null,
                                                           p_note text default null, p_adjusted boolean default false, p_on date default null)
returns jsonb language plpgsql as $$
declare e fabula.equipment%rowtype; v_dev numeric; v_res text; v_id uuid; v_nc uuid; v_since timestamptz; v_affected int := 0; v_on date := coalesce(p_on, (now() at time zone 'Europe/Rome')::date);
begin
  select * into e from fabula.equipment where code = p_code;
  if e.id is null then raise exception 'Strumento sconosciuto: %', p_code; end if;
  -- deviation = max |reading - reference| over the points, pH slope point is checked separately if given
  select max(abs((pt->>'reading')::numeric - (pt->>'ref')::numeric)) into v_dev
  from jsonb_array_elements(coalesce(p_points, '[]')) pt where pt ? 'ref' and pt ? 'reading';
  v_res := case when p_kind = 'taratura_esterna' and v_dev is null then 'ok'
                when v_dev is null then 'ko'
                when e.tolerance is not null and v_dev > e.tolerance then 'ko'
                when exists (select 1 from jsonb_array_elements(coalesce(p_points, '[]')) pt where pt ? 'slope' and ((pt->>'slope')::numeric < 95 or (pt->>'slope')::numeric > 105)) then 'ko'
                else 'ok' end;
  insert into fabula.calibration_checks (equipment_id, checked_at, kind, method, points, max_deviation, tolerance, result, adjusted, provider, certificate_no, certificate_document_id, staff_id, note)
  values (e.id, case when p_on is null then now() else (p_on + time '12:00') at time zone 'Europe/Rome' end, p_kind, p_method, coalesce(p_points, '[]'), v_dev, e.tolerance, v_res, p_adjusted, p_provider, p_certificate_no, p_document_id, p_staff_id, p_note)
  returning id into v_id;
  if v_res = 'ok' then
    update fabula.equipment set out_of_service = false,
           last_checked_on = case when p_kind = 'verifica_interna' then v_on else coalesce(last_checked_on, v_on) end,
           last_calibrated_on = case when p_kind = 'taratura_esterna' then v_on else last_calibrated_on end,
           calibration_cert_ref = case when p_kind = 'taratura_esterna' then coalesce(p_certificate_no, calibration_cert_ref) else calibration_cert_ref end
    where id = e.id;
  else
    select max(checked_at) into v_since from fabula.calibration_checks where equipment_id = e.id and result = 'ok';
    select count(*) into v_affected from fabula.haccp_log l where l.equipment_id = e.id and l.logged_at >= coalesce(v_since, now() - interval '30 days');
    update fabula.equipment set out_of_service = true where id = e.id;
    insert into fabula.non_conformities (severity, description, equipment_id, corrective_action, opened_by_id)
    values (case when e.code in ('TERM-01','TERM-02','PAST-01') then 'major' else 'minor' end::fabula.nc_severity,
            format('%s (%s) fuori tolleranza: scarto %s %s (tolleranza %s). Strumento fuori servizio. Rivalutare %s registrazioni HACCP dal %s.',
                   e.name, e.code, coalesce(round(v_dev, 2)::text, 'n/d'), coalesce(e.tolerance_unit, ''), coalesce(e.tolerance::text, 'n/d'), v_affected,
                   coalesce(to_char(v_since at time zone 'Europe/Rome', 'DD/MM/YYYY'), 'ultimi 30 giorni')),
            e.id, 'Usare un altro strumento verificato · sostituire o far tarare · valutare i lotti misurati con questo strumento', p_staff_id)
    returning id into v_nc;
    update fabula.calibration_checks set nc_id = v_nc where id = v_id;
  end if;
  return jsonb_build_object('id', v_id, 'code', e.code, 'result', v_res, 'max_deviation', v_dev, 'tolerance', e.tolerance, 'nc_id', v_nc, 'records_to_review', v_affected);
end $$;

-- ============ 8. Tasks ============
insert into fabula.task_schedules (code, title_it, title_en, frequency, equipment_id, control_point_id, assigned_role, due_time, grace_minutes, active)
select 'T-PH', 'Calibrazione pH-metro (tamponi 4 e 7)', 'pH meter calibration', 'daily', (select id from fabula.equipment where code = 'PH-01'), null, 'casaro', '07:00', 120, true
where not exists (select 1 from fabula.task_schedules where code = 'T-PH');
insert into fabula.task_schedules (code, title_it, title_en, frequency, equipment_id, control_point_id, assigned_role, due_time, grace_minutes, active)
select 'T-CL', 'Cloro residuo acqua (kit DPD)', 'Residual chlorine', 'weekly', null, (select id from fabula.haccp_control_points where code = 'PRP-WATER-CL'), 'casaro', '09:30', 120, true
where not exists (select 1 from fabula.task_schedules where code = 'T-CL');
update fabula.task_schedules set title_it = 'Verifica termometri (TERM-01, TERM-02) col riferimento' where code = 'T-CAL';

-- water analysis is now driven by the sampling plan (H2O-*): close the generic deadline without opening a new one
update fabula.compliance_deadlines set done_on = (now() at time zone 'Europe/Rome')::date, done_note = 'Sostituita dal piano campionamenti v0.28 (H2O-MIC-PROC, H2O-MIC-LAV, H2O-CHIM, H2O-LEG)'
where kind = 'water_analysis' and done_on is null;

-- ============ 9. RLS & grants ============
do $$ declare t text; begin
  foreach t in array array['lab_tests','lab_samples','pest_stations','pest_inspections','training_courses','training_records','calibration_checks'] loop
    execute format('alter table fabula.%I enable row level security', t);
    if not exists (select 1 from pg_policies where schemaname = 'fabula' and tablename = t and policyname = t || '_authenticated_all') then
      execute format('create policy %I on fabula.%I for all to authenticated using (true) with check (true)', t || '_authenticated_all', t);
    end if;
    execute format('grant select, insert, update on fabula.%I to authenticated', t);
    execute format('grant all on fabula.%I to service_role', t);
  end loop;
end $$;
grant select on fabula.v_lots_on_hold, fabula.v_haccp_plan, fabula.v_lab_plan_status, fabula.v_lab_samples_recent, fabula.v_pest_status, fabula.v_training_matrix, fabula.v_instruments to authenticated;
grant execute on function fabula.log_ccp(text, numeric, uuid, text, text, text, text), fabula.record_sample_taken(text, text, text, uuid, text, date),
  fabula.record_lab_result(text, text, numeric, text, text, date, uuid, uuid), fabula.record_pest_inspection(text, jsonb, uuid, text, text, text, text, uuid, date),
  fabula.record_calibration_check(text, text, text, jsonb, uuid, text, text, uuid, text, boolean, date), fabula.release_lot_hold(text, uuid, text), fabula.hold_lot(text, text, uuid) to authenticated;
