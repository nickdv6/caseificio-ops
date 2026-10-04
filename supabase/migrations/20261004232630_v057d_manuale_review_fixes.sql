-- v0.57d · Correzioni dopo la revisione del Manuale di Autocontrollo (04/10/2026)
-- Il listino del venditore non ha un pastorizzatore a flusso continuo (solo il tino "mini caseificio") né una filatrice:
-- la verifica di inizio giornata del CCP 2 diventa neutra rispetto all'impianto. Fosfatasi = verifica, non limite critico.
-- CCP 5 con un solo limite critico (6 °C). Stafilococchi su mozzarella: Reg. 2073/2005 2.2.5 a fine lavorazione.
update fabula.haccp_control_points set
  name = 'Pastorizzatore: verifica di inizio giornata',
  hazard_it = 'Latte non pastorizzato che passa alla caseificazione se il pastorizzatore non raggiunge o non registra la temperatura',
  critical_limit_it = 'Verifica superata a inizio giornata (0 = ok, 1 = NON ok): a flusso continuo la valvola deviatrice devia sotto il limite · a tino il termometro registratore concorda con l''indicatore e il timer di sosta funziona.',
  monitoring_it = 'Ogni giorno di produzione, prima del primo ciclo: prova della valvola deviatrice (flusso continuo) oppure confronto registratore/indicatore e prova del timer (tino). Registrazione sul tablet.',
  corrective_it = 'NON ok: non pastorizzare, chiamare il tecnico, NC critica · il latte trattato dall''ultima verifica buona si valuta con il consulente (fosfatasi alcalina).'
where code = 'PRP-PAST-VALVE';
update fabula.task_schedules set title_it = 'Pastorizzatore: verifica di inizio giornata', title_en = 'Pasteuriser start-of-day check' where code = 'T-VALVE';
update fabula.haccp_forms set title_it = 'Pastorizzazione (CCP 2) e verifica del pastorizzatore', where_it = 'Tablet → lotto · Sicurezza alimentare → Verifica pastorizzatore', updated_at = now() where code = 'MOD-02';
update fabula.haccp_control_points set
  critical_limit_it = 'A tino (discontinua): ≥ 63 °C per ≥ 30 min in tutto il volume. A flusso continuo (HTST): ≥ 72 °C per ≥ 15 s con valvola deviatrice funzionante. Impianto da confermare dalla targa (Manuale §13).',
  verification_it = 'Confronto indicatore/registratore · taratura annuale del registratore · fosfatasi alcalina mensile (MILK-ALP) con il valore di riferimento del laboratorio per latte di bufala.'
where code = 'CCP-PAST';
update fabula.haccp_control_points set
  critical_limit_it = 'Limite critico 6 °C: oltre 6 °C non conformità. Obiettivo 0–4 °C · tra 4 e 6 °C allerta (ricontrollo entro 1 h). Mozzarella in liquido di governo: limite da decidere (Manuale §13).',
  monitoring_it = 'Due letture al giorno (apertura e chiusura) dal display, confermate con il termometro a sonda una volta a settimana · datalogger con allarme da installare.'
where code in ('CCP-COLD-1', 'CCP-COLD-2');
update fabula.haccp_control_points set
  corrective_it = 'Positivo: latte respinto e isolato, NC critica, avvisare subito la Masseria (registro trattamenti e tempi di sospensione) e l''ASL, conferma in laboratorio · nessuna miscelazione con altro latte.'
where code = 'CCP-MILK-ABX';
update fabula.lab_tests set limit_it = 'Negativa rispetto al valore di riferimento del laboratorio per latte di bufala (350 mU/l è il limite per il latte vaccino, Reg. UE 2019/627)',
  criterion_ref = 'Reg. CE 853/2004 All. III Sez. IX · verifica del CCP 2', updated_at = now() where code = 'MILK-ALP';
update fabula.lab_tests set criterion_ref = 'Reg. CE 2073/2005 2.2.5 (formaggi freschi da latte o siero pastorizzato)', sampling_point_it = 'Prodotto a fine lavorazione',
  limit_it = 'm 10 – M 100 ufc/g (n 5, c 2) a fine lavorazione. Oltre 10⁵ → ricerca enterotossine sul lotto', updated_at = now() where code = 'MOZ-CPS';
update fabula.lab_tests set criterion_ref = 'Verifica volontaria (il criterio 1.11 del Reg. CE 2073/2005 non si applica ai formaggi da latte pastorizzato)', updated_at = now() where code = 'MOZ-SAL';
update fabula.lab_tests set sampling_point_it = 'Fase in cui la conta è attesa più alta (cagliata prima della filatura)', updated_at = now() where code = 'MOZ-ECO';
update fabula.lab_tests set limit_it = '≤ 1.500.000 ufc/ml per latte da trattare termicamente (media geometrica mobile su 2 mesi) · fuori limite: avvisare l''ASL', updated_at = now() where code = 'LAT-CBT';
