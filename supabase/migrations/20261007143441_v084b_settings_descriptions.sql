-- v0.84b (07/10/2026) · Parametri readable by the owner.
-- 1. settings.kind tells the page which field to draw (flag = Sì/No, date, month); before, the page guessed it from
--    "(1 = sì" and "(AAAA-MM-GG)" inside the description, so those hints could never be removed.
-- 2. Every description rewritten in plain Italian: what the value is, the unit, what it changes — no key names, no format
--    hints, no history notes. "Vuoto = …" stays where an empty value is a documented choice (the page then does not flag it);
--    "da confermare" stays on values still waiting for a real bill, tariff or contract (the page tags them).
-- Audit and touch triggers are off during the rewrite: no value changes, so no 133 "modificato" rows in the Registro.

alter table fabula.settings add column if not exists kind text check (kind in ('flag', 'date', 'month'));
comment on column fabula.settings.kind is 'v0.84b: field type for Configurazione → Parametri (flag = Sì/No select, date, month); null = by data_type (number / text)';

alter table fabula.settings disable trigger settings_audit;
alter table fabula.settings disable trigger settings_touch;

update fabula.settings s set kind = v.kind from (values
  ('approve.auto_milk_plan', 'flag'), ('approve.auto_promo', 'flag'), ('bots.db_fallback', 'flag'), ('milk.cap_to_farm', 'flag'),
  ('trade.enabled', 'flag'), ('trade.allow_link_access', 'flag'), ('trade.discounts_combine', 'flag'),
  ('food.manuale_data', 'date'), ('food.sampling_start', 'date'), ('mkt.store_opening_date', 'date'), ('opex.lease_step_from', 'date'), ('trial.start', 'date'),
  ('sales.plan_start', 'month')
) as v(key, kind) where s.key = v.key;

update fabula.settings s set description = v.d from (values
  -- Azienda
  ('company.name', 'Nome commerciale: intestazione di ordini, documenti e di tutte le pagine'),
  ('company.legal_name', 'Ragione sociale'),
  ('company.piva', 'Partita IVA della nostra azienda (l''acquirente del latte, non il venditore)'),
  ('company.address', 'Indirizzo del caseificio (via, CAP, comune)'),
  ('company.registered_office', 'Sede legale, se diversa dal caseificio'),
  ('company.email', 'Email per ordini e amministrazione'),
  ('company.phone', 'Telefono / WhatsApp aziendale'),
  ('company.pec', 'PEC'),
  ('company.sdi', 'Codice destinatario SDI per la fatturazione elettronica'),
  ('company.receiving_hours', 'Orario di ricevimento merce stampato sugli ordini ai fornitori'),
  -- Produzione e latte
  ('milk.price_eur_kg', 'Prezzo del latte di bufala, €/kg IVA esclusa: vale per ogni conferimento senza prezzo e per tutti i costi'),
  ('milk.raw_shelf_days', 'Giorni entro cui il latte conferito va lavorato'),
  ('milk.capacity_kg', 'Capacità della caldaia: kg di latte lavorabili al giorno'),
  ('milk.min_run_kg', 'Lotto minimo di latte che vale la pena avviare (kg)'),
  ('milk.round_kg', 'Arrotondamento del piano latte (kg)'),
  ('milk.safety_pct', 'Margine di sicurezza sulla domanda prevista (%)'),
  ('milk.carry_pct', 'Quanto pesa la mozzarella fresca già in giacenza contro la domanda (%)'),
  ('milk.cap_to_farm', 'Limita il piano latte a quanto la Masseria ha disponibile (No = solo avviso)'),
  ('milk.farm_token', 'Chiave del link privato della Masseria per ordini e spedizioni latte: cambiarla disattiva il link vecchio'),
  ('milk.farm_supplier_id', 'Fornitore (anagrafica) a cui vanno le spedizioni registrate dalla pagina della Masseria'),
  ('farm.default_kg_per_day', 'Latte disponibile dalla Masseria quando non c''è un dato per quel giorno (kg)'),
  ('prod.vat_kg', 'Latte per lotto (kg): capacità del mini caseificio'),
  ('prod.yield_tolerance_pts', 'Scostamento di resa (punti %) oltre cui il tablet chiede conferma e la console avvisa'),
  ('prod.ricotta_yield_pct', 'Resa ricotta sul siero (%) usata finché non ci sono abbastanza lotti veri'),
  -- Approvazioni automatiche
  ('approve.auto_delay_min', 'Minuti di attesa prima che una richiesta di routine si approvi da sola (nel frattempo puoi decidere tu)'),
  ('approve.auto_milk_plan', 'Piano latte nella norma approvato da solo'),
  ('approve.milk_tolerance_pct', 'Scostamento massimo (%) dagli ultimi 4 stessi giorni perché il piano latte conti come "nella norma"'),
  ('approve.auto_po_max_eur', 'Ordini ai fornitori di routine approvati da soli fino a questo importo (€); 0 = sempre a mano'),
  ('approve.auto_promo', 'Promo scorte standard al banco approvate da sole'),
  ('approve.promo_max_kg', 'Kg a rischio massimi perché una promo scorte si approvi da sola'),
  ('bots.db_fallback', 'Se un bot non parte, il database fa il suo lavoro (piano latte, ordini, avvisi HACCP)'),
  -- Acquisti
  ('purchasing.cover_buffer_days', 'Giorni di scorta oltre il tempo di consegna prima di proporre un ordine'),
  ('purchasing.default_lead_days', 'Giorni di consegna usati quando il fornitore non ha un tempo impostato'),
  -- Vendite e prezzi
  ('price.retail_moz_eur_kg', 'Prezzo al banco della mozzarella, €/kg (riferimento per i ricarichi)'),
  ('price.wholesale_moz_eur_kg', 'Prezzo ingrosso della mozzarella, €/kg (proposto negli ordini fissi)'),
  ('sell.horizon_days', 'Giorni di anticipo con cui segnalare i lotti in scadenza'),
  ('sell.min_kg_for_promo', 'Sotto questi kg a rischio non si propone nessuna promo'),
  ('sell.promo_pct', 'Sconto proposto al banco sui lotti a rischio (%)'),
  ('sell.wholesale_min_kg', 'Da questi kg a rischio in su si suggerisce anche un''offerta ingrosso'),
  ('sales.plan_start', 'Primo mese del piano vendite. Vuoto = parte dal mese di apertura del negozio'),
  ('sales.target_milk_l_day', 'Latte della Masseria da trasformare a regime (litri al giorno)'),
  ('sales.yield_pct', 'Resa mozzarella sul latte (%) per convertire i kg venduti in litri di latte'),
  ('sales.lead_stale_days', 'Giorni senza contatto dopo cui una trattativa aperta è "ferma"'),
  ('sales.min_active_leads', 'Sotto questo numero di contatti aperti il bot Vendite cerca nuovi locali'),
  ('sales.research_per_run', 'Nuovi locali che il bot Vendite può aggiungere a ogni giro'),
  ('sales.lapsed_days', 'Giorni senza ordini dopo cui un cliente ristorazione o hotel è "perso"'),
  ('sales.whey_sku_regex', 'Codici dei prodotti da siero (non consumano latte), esclusi dal calcolo dei litri'),
  -- Professionisti · ingrosso B2B
  ('trade.enabled', 'Sezione professionisti (ristoranti, pizzerie, hotel) attiva sul sito'),
  ('trade.min_order_kg', 'Ordine minimo per consegna (kg): sotto, il portale non accetta il piano o la modifica'),
  ('trade.cutoff_time', 'Ora limite del giorno prima per modificare o saltare una consegna; dopo è confermata'),
  ('trade.delivery_days', 'Giorni di consegna: 1 = lunedì … 7 = domenica, separati da virgola'),
  ('trade.windows', 'Fasce orarie di consegna offerte, es. 07:00-09:00,09:00-11:00'),
  ('trade.default_window', 'Fascia oraria proposta quando il cliente non ne sceglie una'),
  ('trade.recurring_discount_pct', 'Sconto % sulle consegne di un piano attivo (0 = nessuno); non vale per gli ordini extra'),
  ('trade.discounts_combine', 'Sconto ricorrente e scaglione quantità si sommano (No = vale solo il migliore dei due)'),
  ('trade.tier_basis', 'Base degli scaglioni quantità: delivery = kg della singola consegna, week = kg settimanali del piano'),
  ('trade.horizon_days', 'Giorni futuri mostrati nel portale e nel calendario consegne'),
  ('trade.payment_terms_days', 'Giorni di pagamento proposti alle aziende nuove'),
  ('trade.allow_link_access', 'Portale apribile anche dal link personale senza login Shopify (No = solo clienti collegati)'),
  ('trade.shopify_market_id', 'Mercato B2B Shopify "Ho.Re.Ca. Italia" (identificativo)'),
  ('trade.shopify_catalog_id', 'Catalogo B2B Shopify "Listino Ho.Re.Ca." (identificativo)'),
  ('trade.shopify_price_list_id', 'Listino prezzi del catalogo B2B Shopify (identificativo)'),
  ('trade.edge_url', 'Indirizzo del servizio portale professionisti (approvazioni e ordini Shopify)'),
  ('trade.job_secret', 'Chiave con cui il database chiama il servizio per creare gli ordini Shopify: cambiarla disattiva la vecchia'),
  ('trade.store_url', 'Indirizzo del sito Shopify usato nei messaggi ai clienti'),
  -- Shopify, ritiri e spedizioni
  ('shopify.push_inventory', 'Giacenze su Shopify: 0 = solo report · 1 = aggiorna sempre · 2 = aggiorna da solo dopo la conta di apertura'),
  ('shopify.reserve_kg', 'Kg di mozzarella da non offrire online (riserva per il banco)'),
  ('shopify.mix_weight', 'Quota della mozzarella divisa tra le varianti Shopify in base alle vendite degli ultimi 28 giorni (0–1); il resto in parti uguali'),
  ('pickup.cutoff_hour', 'Ora limite per preordinare il ritiro del giorno dopo'),
  ('pickup.slots', 'Fasce di ritiro in negozio, es. 09:00-11:00,11:00-13:00'),
  ('pickup.slot_capacity_orders', 'Ordini massimi per fascia di ritiro'),
  ('pickup.walkin_share_pct', 'Quota delle vendite al banco che resta senza preordine nel piano latte (%)'),
  ('ship.tolerance_pct', 'Scostamento ammesso tra kg ordinati e kg pesati prima di chiedere una seconda conferma (%)'),
  ('ship.default_carrier', 'Vettore predefinito per le spedizioni online'),
  ('ship.wholesale_carrier', 'Vettore predefinito per le consegne ingrosso'),
  ('ship.min_days_left_online', 'Giorni minimi di vita residua del lotto per gli ordini online: sotto, il lotto non viene proposto'),
  ('ship.min_days_left_wholesale', 'Giorni minimi di vita residua del lotto per le consegne ingrosso'),
  -- Incassi e banca
  ('recon.payout_days', 'Giorni entro cui un versamento Shopify deve comparire in banca prima di segnalarlo'),
  ('recon.order_days', 'Giorni dopo cui un ordine pagato con carta senza transazione nel file pagamenti viene segnalato'),
  ('recon.bank_account', 'Nome del conto degli estratti importati, es. BCC Aquara 1234. Vuoto = chiesto a ogni importazione'),
  -- Marketing
  ('mkt.brand_line', 'Claim di marca usato nelle bozze'),
  ('mkt.hashtags', 'Hashtag di base'),
  ('mkt.store_opening_date', 'Data di apertura del negozio di Agropoli: da qui si calcolano le scadenze di insegne e pubblicità'),
  ('mkt.local_site_url', 'Pagina a cui puntano i QR di insegne, volantini e manifesti'),
  ('mkt.local_radius_km', 'Raggio della pubblicità locale a pagamento (km da Agropoli)'),
  ('mkt.ai_provider', 'Servizio AI per le bozze dei contenuti'),
  ('mkt.predis_brand_id', 'Identificativo del brand su Predis.ai (la chiave API sta nei segreti del server, non qui)'),
  ('mkt.output_language', 'Lingua delle bozze AI'),
  -- Sicurezza alimentare e DOP
  ('food.manuale_rev', 'Manuale di Autocontrollo: numero della revisione in vigore (stampato su ogni registro)'),
  ('food.manuale_data', 'Manuale di Autocontrollo: data della revisione in vigore'),
  ('food.manuale_stato', 'Manuale di Autocontrollo: bozza oppure firmato (firmato solo dopo la firma di consulente e responsabile)'),
  ('food.manuale_url', 'Link al documento del Manuale di Autocontrollo'),
  ('food.responsabile_autocontrollo', 'Responsabile dell''autocontrollo (nome e cognome): firma il manuale e i registri'),
  ('food.ce_approval_no', 'Numero di riconoscimento CE dello stabilimento, stampato sui registri'),
  ('food.records_retention_years', 'Anni minimi di conservazione delle registrazioni HACCP'),
  ('food.milk_process', 'Latte lavorato: pastorizzato oppure crudo (pastorizzato = il CCP 2 è richiesto a ogni lotto di mozzarella)'),
  ('food.sampling_start', 'Primo giorno del piano campionamenti: da qui partono le richieste al laboratorio. Vuoto = piano non ancora attivo'),
  ('food.lab_name', 'Laboratorio analisi (accreditato Accredia o IZSM Portici)'),
  ('food.lab_email', 'Email del laboratorio per le richieste di campionamento'),
  ('food.haccp_consultant', 'Consulente HACCP (nome e contatto)'),
  ('food.pest_company', 'Ditta di disinfestazione (ragione sociale e contatto)'),
  ('dop.consorzio_eur_kg', 'Contributo al Consorzio DOP, €/kg di mozzarella certificata — stima, da confermare con il Consorzio'),
  ('dop.rina_eur_kg', 'Quota variabile RINA, €/kg di mozzarella controllata'),
  -- Utenze e reflui
  ('energy.eur_per_kwh', 'Energia elettrica, €/kWh medio (entra nel costo pieno al kg)'),
  ('energy.water_eur_m3', 'Acqua potabile, €/m³ — da confermare con la bolletta'),
  ('energy.sewer_eur_m3', 'Fognatura e depurazione, €/m³ — da confermare con la bolletta'),
  ('energy.gas_eur_smc', 'Gas, €/Smc — da confermare con la bolletta'),
  ('effluent.whey_pct_of_milk', 'Siero prodotto, in % del latte lavorato'),
  ('effluent.wash_water_l_per_kg_milk', 'Acque di lavaggio stimate, litri per kg di latte lavorato'),
  ('effluent.disposal_eur_m3', 'Smaltimento reflui, €/m³ se ritirati da un trasportatore (0 = fognatura o allevamento)'),
  -- Lavoro
  ('labor.hourly_cost_eur', 'Costo orario medio del lavoro, lordo più contributi (€)'),
  ('labor.max_shift_hours', 'Oltre queste ore un turno aperto si chiude da solo (badge dimenticato)'),
  ('labor.contract_hours_week', 'Ore settimanali da contratto, se la persona non ne ha di proprie'),
  ('labor.overtime_daily_hours', 'Straordinario anche oltre queste ore al giorno (0 = conta solo il limite settimanale)'),
  ('labor.overtime_premium_pct', 'Maggiorazione dello straordinario (%) — da confermare con il consulente del lavoro'),
  -- Benchmark economici
  ('benchmark.annual_profit_eur', 'Utile operativo annuo di piano, primo anno (€): riferimento del brief settimanale'),
  ('opex.labor_eur_year', 'Costo del lavoro annuo di piano (€)'),
  ('opex.utilities_eur_year', 'Utenze annue di piano (€)'),
  ('opex.consumables_eur_year', 'Consumabili e imballi annui di piano (€), usati solo se mancano i listini'),
  ('opex.marketing_eur_year', 'Marketing annuo di piano (€)'),
  ('opex.lease_eur_year', 'Affitto annuo del primo anno (€)'),
  ('opex.lease_eur_year_step', 'Affitto annuo dal secondo anno (€)'),
  ('opex.lease_step_from', 'Data da cui vale l''affitto del secondo anno'),
  ('opex.pos_hardware_eur_year', 'Cassa e hardware annui (€): verifica fiscale, carta scontrini, piano Shopify, fondo sostituzione tablet e bilancia'),
  ('opex.einvoicing_eur_year', 'Fatturazione elettronica, €/anno IVA esclusa'),
  ('opex.internet_eur_year', 'Connessione internet, €/anno IVA esclusa — ipotesi, da sostituire con il contratto'),
  -- Settimana di prova
  ('trial.days', 'Durata della settimana di prova (giorni)'),
  ('trial.start', 'Primo giorno della settimana di prova. Vuoto = nessuna prova in corso'),
  -- Sistema
  ('infra.site_url', 'Indirizzo del sito del tablet: il monitor esterno controlla ogni ora che risponda'),
  ('infra.github_repo', 'Repository GitHub del sistema, confrontato dal monitor con database e sito'),
  ('infra.sw_seen', 'Versione dell''app in linea e da quando (aggiornata dal sistema)'),
  ('auth.link_hours', 'Validità in ore dei link di invito e di reset password'),
  ('scale.ble_service', 'Servizio Bluetooth della bilancia (weight_scale = standard)')
) as v(key, d) where s.key = v.key;

alter table fabula.settings enable trigger settings_touch;
alter table fabula.settings enable trigger settings_audit;

do $$ declare n int; begin
  select count(*) into n from fabula.settings where description is null or description ~ '\(AAAA-MM|\(1\s*=\s*s|[a-z]+\.[a-z_]+_[a-z]+';
  if n > 0 then raise notice 'v084b: % descriptions still carry a key or a format hint', n; end if;
end $$;
