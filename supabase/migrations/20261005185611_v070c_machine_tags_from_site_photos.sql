-- v0.70c (05/10/2026) · Machine tags from Nick's site photos (source of truth). The Fortino 800 L offer in the project
-- (Off. 249/2025, 06/11/2025) is a reference quote for new equipment, NOT the machine in the sale.
-- - "TINO" vat = the FORTINO mini caseificio ("FOR" worn off the steel): make known, model / capacity / serial / year not
--   yet read. prod.vat_kg stays 800 only as a placeholder until its capacity is known.
-- - Tecnolat machine (green-lined hopper): plate worn, only the maker is readable. Filed on FORM-01 (formatrice) to confirm.
-- - Gas burner 34.5 kW (new row BRU-01) with its full label; the label says "UTILIZZARE SOLO ALL'APERTO".
-- - pH meter: XS Instruments portable, pH 7 series (pH/mV/°C), with pH 7.00 and 4.01 buffers.

insert into fabula.settings(key, value, description, data_type, sort) values
 ('prod.vat_kg', '800', 'Latte per lotto (kg) = capacità del mini caseificio Fortino ("TINO"). DA CONFERMARE: capacità non ancora letta; 800 è solo provvisorio (l''800 L era un preventivo Fortino, non la macchina in vendita)', 'number', 40)
on conflict (key) do update set description = excluded.description;

insert into fabula.equipment (code, name, kind, serial_number, location, notes, maintenance_interval_days) values
 ('TINO-01', 'Mini caseificio Fortino ("TINO") riscaldato con agitatore', 'vat', null, 'caseificio',
  'Marca Fortino Srl (San Valentino Torio, SA): la scritta "TINO" è FORTINO con "FOR" consumato. È il "mini caseificio con bollitore con display LCD" della lista del venditore: pastorizzazione, coagulazione, rottura cagliata, ricotta. Coperchio con sonda di temperatura (testa arancione, etichetta da leggere), scarico di fondo con valvola a sfera. DA RILEVARE: modello, matricola, anno, capacità in litri (targa non fotografata) — chiedere a Fortino (081 3145726, info@fortinoinox.it) con foto e matricola. Il preventivo Fortino MCC80 800 L del 06/11/2025 è solo un riferimento.',
  180),
 ('FORM-01', 'Formatrice Tecnolat', 'other', null, 'caseificio',
  'Tecnolat, Nocera Inferiore (SA), marcata CE. Targa con modello, matricola, anno, pressione, portata L/h e capacità consumata/illeggibile (foto 05/10/2026). Identificata dalla tramoggia verde (formatrice con 3 rulli della lista del venditore) — da confermare. Chiedere a Tecnolat i dati dalla foto della targa; grammatura dei 3 rulli da rilevare.',
  180),
 ('BRU-01', 'Bruciatore a gas 34,5 kW (GPL)', 'other', '001184', 'caseificio',
  'Etichetta: PIN 51BP2793 · Cod. FGC73585/TE · cat. II2H3+ · predisposto G30/G31 (GPL) 28-30/37 mbar, consumo 2510 g/h; G20 (metano) 20 mbar, 3,316 m³/h · potenza 34,5 kW · n° serie 001184 · data 372024 (probabile settimana 37/2024) · Made in Italy · CE 0051-24. L''etichetta dice "UTILIZZARE SOLO ALL''APERTO - EXTERNAL USE ONLY": verificare con il venditore dove e come è installato e far controllare l''impianto gas da un tecnico abilitato (dichiarazione di conformità DM 37/2008, aerazione, bombole). Probabilmente scalda il mini caseificio (da confermare).',
  365),
 ('PH-01', 'pH-metro portatile XS pH 7 (pH/mV/°C)', 'other', null, 'caseificio',
  'XS Instruments, serie pH 7 portatile (pH/mV/°C), in valigetta con tamponi pH 7,00 e 4,01 e conservazione elettrodo (foto 05/10/2026); suffisso del modello e matricola da leggere sul retro. Calibrazione ogni giorno di produzione con tamponi 4,01 e 7,00 (pendenza 95–105 %) · tamponi freschi, data di apertura sul flacone · elettrodo conservato in KCl 3M.',
  null)
on conflict (code) do update
   set name = excluded.name, notes = excluded.notes, serial_number = coalesce(excluded.serial_number, equipment.serial_number), updated_at = now();

insert into fabula.dash_areas(area, sort, built, reliable, automated, next_step, evidence, updated_at) values
 ('Production floor', 12, 93, 76, 50,
  'Read the Fortino mini caseificio ("TINO") plate or ask Fortino for its capacity → set prod.vat_kg (800 is a placeholder); casaro confirms the 6 placeholder doses and the presets; record the first real batch from the Home card',
  '', now())
on conflict (area) do update set next_step = excluded.next_step, updated_at = excluded.updated_at;
