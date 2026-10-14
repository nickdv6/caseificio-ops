# Bot prompts before v0.87 (12/10/2026) — rollback reference

v0.87 changed ONLY the messaging parts of the 15 scheduled bots. The data/SQL/Shopify steps were kept word for word,
so to roll a bot back: take its v0.87 prompt (tools/bots/prompts/<agent>.txt), delete the "MESSAGE RULES" block and the
bot's message step, and paste back the old message step below plus the two shared blocks at the bottom.

**v1.02 (14/10/2026):** the three Shopify tasks are paused: the database does their job (server function `shopify-sync`).
Their prompts stay in `tools/bots/prompts/` marked RETIRED, for going back (`shopify.sync_enabled = 0`). The weekly brief task
is merged into the daily brief (v0.88) and its prompt file is gone. The shared rules are copied into every prompt by
`tools/bots/sync_rules.py`; after a change the prompts are pasted into the tasks again (by Claude, with the ids below).

Scheduled task IDs:
| agent | task id | schedule (Rome) |
|---|---|---|
| shopify_customers | trig_01DUg1J5yuYoSbnJ4gMX9TQ5 | Mon–Sat 06:05 |
| shopify_orders | trig_013si27oWK882Y14TW25T4ZV | Mon–Sat 06:11 |
| procurement | trig_0184z7BRdDCTAef4vcSZ2sZA | Mon–Sat 06:20 |
| daily_brief | trig_01CZVYXc4kbpufigNzyyvx7x | Mon–Sat 06:47 |
| weekly_brief | trig_014cc9qphjuZPjScmw4bQNqV | Mon 07:08 |
| compliance_calendar | trig_011V5MH5NQyKCcjbwDqaM8mK | Tue 07:17 |
| sell_down | trig_01CwcUqyADWJaQ7zaTigd4ff | Mon–Sat 07:23 |
| shopify_inventory | trig_015bmBjK9omNq4TtupFXf6ed | Mon–Sat 07:32, 13:32 |
| monthly_review | trig_01LHiNHFpugT1jwiY3gdV7zV | 1st 07:41 |
| marketing | trig_01KiovtV7UKWnUEXezYKaxeq | Mon, Thu 07:53 |
| sales | trig_01WGFgUowagY52KskLuunHuM | Mon, Wed, Fri 08:04 |
| wholesale_orders | trig_01XPVvAL3x2knx4ibwk8vxy9 | Mon–Sat 18:20 |
| milk_planning | trig_01CyXw2bSvHbDSMjLTGMMGu5 | Mon–Sat 18:52 |
| haccp_nudge | trig_019kFnydeKpyBwTGnQV8c9fx | Mon–Sat 19:02 |
| ops_health | trig_01NDdXdq577XUhMysTG7kDYS | Mon–Sat 20:36 |
| bot_watchdog | trig_01Y5V24KHCreQasiTfYwiEbc | Mon–Sat hourly :50, 06:50–21:50 |

## Old message steps (verbatim)

### daily_brief — step 2
2. Write the brief from that JSON only. Never run additional queries to recompute numbers; never invent figures. Send it once with SendUserMessage. Format:

   **[company.name] · brief di [weekday date]** (add "· SIMULAZIONE" to the title if `is_simulation` is true)

   Then 4 to 8 short bullets in Italian, each followed by the English in parentheses, prioritised in this order, skipping anything that is fine:
   - Compliance first: any non-conformity, missing HACCP check (especially `evening_cold_checks_missing`), overdue task, open non-conformity, calibration or training due. Name the control point or equipment code.
   - Production: milk kg received and whether accepted; mozzarella output kg and yield %, compared to `yield.avg_7d` and `avg_30d`. Flag if yesterday's yield is more than 1.5 points below the 30-day average.
   - Sales: yesterday's total vs `same_weekday_avg_4w_eur` (say the % difference) and week to date. Mention the POS variance only if `pos_close.variance_eur` is not 0 or the close is missing.
   - Waste: `waste.last_7d_pct_of_output` if above 10 %, with the kg.
   - Stock: finished goods expiring today or tomorrow with kg.
   - Energy: only if `yesterday_kwh_per_kg` exceeds `avg_30d_kwh_per_kg` by more than 15 %.
   - Procurement: each item in `procurement_signals` with days of cover and the suggested reorder qty, phrased as a proposal awaiting approval, not an action taken.
   - Approvals: list `pending_approvals` with age in days if any.

   End with one line: **Oggi** — the single most important thing to do today, in Italian and English.

   Keep it under 200 words. Plain, direct, no filler, no emojis. Numbers with units (kg, °C, €, kWh/kg).
(step 1 error: "If the call errors, report the error text and stop."; step 3 summary: '<the Oggi line, single-quoted and escaped>')

### weekly_brief — step 2
2. Write the brief from that JSON only — never run other queries, never recompute, never invent. Percent changes: compute them only as (this − previous) / previous from the two numbers given, rounded to whole percent; if previous is 0 or missing, say "n/d". Send once with SendUserMessage. Format:
   **[company.name] · settimana [week_number] · [week_start]–[week_end]** (add "· SIMULAZIONE" if `is_simulation` is true)
   Italian first, English in parentheses, 6 to 10 short bullets in this order, skipping anything unremarkable:
   - **Risultato stimato**: `pnl_estimate.operating_result_eur` € on `revenue_eur` € revenue (margin `margin_pct` %), vs benchmark week `benchmark_weekly_profit_eur` €. One clause saying it is an estimate: milk and revenue real, other costs from the feasibility benchmarks.
   - **Vendite**: revenue vs previous week (%), split by channel from `by_channel_eur`; mozzarella kg sold, sell-through `sell_through_pct` %, average price €/kg.
   - **Produzione**: milk received kg, mozzarella kg and ricotta kg, yield `yield_pct` % vs `yield_30d_pct` % (flag if more than 1 point below), rejected deliveries if any.
   - **Scarti**: mozzarella waste kg and `pct_of_mozzarella_output` %, worth `value_at_milk_cost_eur` € of milk; compare with previous week. If above 10 %, say it plainly as the main lever.
   - **Piano latte**: if `milk_plans.proposed` > 0: proposed / approved / rejected, and for each `milk_plan_accuracy` row: planned vs actual milk, forecast vs actual sales. If 0, one line: no milk plans this week.
   - **Conformità**: missing HACCP checks, non-conformities opened, POS closes with variance and the € amount; open non-conformities from `open_items`.
   - **Energia**: kWh and kWh/kg vs previous week; only flag if kWh/kg changed more than 10 %.
   - **Acquisti**: POs proposed/approved and €; consumables used €; name any `unpriced_skus` as needing a supplier price.
   - **Da fare**: pending approvals (count, oldest days), calibrations due, training expiring, bot errors — only the non-zero ones.
   End with one line **Questa settimana** — the single most valuable action for the coming week, in Italian and English, drawn from the numbers above.
   Under 300 words. Plain and direct, no emojis, numbers with units (kg, €, %, kWh/kg).
(step 3 summary: '<the Questa settimana line, single-quoted and escaped>')

### monthly_review — step 2
2. Send one message with SendUserMessage, Italian first with English in parentheses, under 400 words:
   **Revisione mensile · [month_label]** (add "· SIMULAZIONE" if `is_simulation` is true)
   - **Prova di richiamo**: lot (and parent_lot if present), produced / sold / wasted / on hand kg, unaccounted kg, number of destinations and the wholesale customers by name, how many milk lots upstream, elapsed_ms as "tracciato in N ms". Then the verdict in plain words: ok = traceability works; kg_non_giustificati = kg not accounted for, check stock movements; manca_latte_a_monte = the batch has no milk lot linked, the casaro must start batches from the milk-lot scan; no_lots = nothing sold this month.
   - **Sicurezza alimentare**: the `headline_it` line; then only what needs attention: CCPs with nc > 0 (name, count, min/max), lots without CCP record, open NCs (critical first), lab non-conformities and overdue analyses (codes), pest activity inside, training gaps (person · course · status, max 4 lines then "e altri N"), instruments out of service or overdue. If the sampling plan is not active, say so in one line. If everything is clean, one line: piano HACCP rispettato nel mese. Close with "Dettaglio: console → 🛡 HACCP. Materiale per il riesame annuale del piano."
   - **Ricette**: if created > 0, one line per proposal (component, deviation %, from → to, batches) and "in attesa di approvazione sulla console". If no proposals, one line: dosaggi in linea con le ricette (or: not enough confirmed batches yet).
   - **Latte**: fat and protein vs previous month, rejected deliveries, deliveries over 4 °C; yield_by_fat if more than one band; if scc_avg is null say the Masseria is not sending SCC yet.
   - **Costo pieno**: cost_eur_per_kg with the split (milk share %, labor source actual/benchmark), average price and margin €/kg per channel, wholesale floor. One sentence on whether wholesale price is above the floor.
   - **Pacchetto commercialista**: revenue, corrispettivi, purchases, milk, inventory value, waste kg; then "Pagina pronta: console → Pacchetto mensile → Stampa/PDF." (Page ready: console → Pacchetto mensile → Print/PDF.)
   End with one line: the single most valuable action for the coming month, in Italian and English (an open food-safety issue always comes first).

### milk_planning — step 2
2. If the JSON has `skipped`, send nothing. Otherwise send one message with SendUserMessage, in Italian with English in parentheses, under 120 words. Use only numbers from the JSON; never recompute. Format:
   **Piano latte · [weekday] [date]** (add "· SIMULAZIONE" if `is_simulation` is true)
   - Latte proposto: `milk_kg` kg → ≈ `planned_output_kg` kg mozzarella, costo stimato € `est_cost_eur`.
   - Domanda prevista: `demand.retail_kg` kg banco/online + `demand.wholesale_kg` kg ingrosso (say "ordini confermati" if `demand.wholesale_confirmed_kg` > 0, otherwise "media 4 settimane"); giacenza fresca contata `carry_kg` kg; margine `safety_kg` kg.
   - Confronto: ultime 4 settimane stesso giorno latte `last_4w_same_weekday.milk_kg` kg, scarti `last_4w_same_weekday.waste_kg` kg.
   - If `capacity_hit` is true: say the demand exceeds vat capacity and some demand may go unmet. If `min_run_applied` is true: say the plan was raised to the minimum run. If `demand.history_source` is not `same_weekday_4w`: say the forecast rests on little history (`history_days` days) and should be checked by hand. If `yield_source` is `assumption`: say yield is an assumption, not measured.
   - Stima siero `est_whey_kg` kg → ricotta ≈ `est_ricotta_kg` kg.
   End with: "Approva o rifiuta dalla console entro le 06:00." (Approve or reject from the console by 06:00.)

### procurement — step 2
2. If `created` is empty and `skipped` has no `no_preferred_supplier` entries, send nothing. Otherwise send one message with SendUserMessage, in Italian with English in parentheses, under 120 words:
   **Acquisti · proposte di [date]**
   - One bullet per created PO: PO number, quantity and unit, product, supplier, total € excl. IVA, days of cover. If `price_missing` is true say the price must be confirmed with the supplier before approval.
   - One bullet per `skipped` item with reason `no_preferred_supplier`: name the product and its days of cover, and say a supplier must be set on the product before the bot can propose an order.
   - Ignore `open_po_exists` skips.
   End with: "Approva o rifiuta dalla console." (Approve or reject from the console.)

### sell_down — step 2
2. If `totals.at_risk_kg` is 0 and `totals.expired_lots` is 0, send nothing. Otherwise send one message with SendUserMessage, Italian first with English in parentheses, under 150 words:
   **Da vendere prima · [date]** (add "· SIMULAZIONE" if `is_simulation` is true)
   - One bullet per lot whose action is not "ok", oldest first: product, lot, kg on hand, kg at risk, expiry ("oggi", "domani", or the date). Then the action in plain words: "ritirare" → pull from sale and log as waste; "promo_banco" → counter promo at promo_price_eur_kg €/kg, awaiting Nick's approval; "offerta_ingrosso_e_promo" → the same plus call the wholesale customers today; "spingere_al_banco" → small quantity, just push it at the counter.
   - One line with totals: kg at risk, € at retail, € of milk; and `waste_last_7d_kg` as context.
   Add one line per promo with its Shopify code (or "codice non creato: <reason>"). End with: "Approva le promo dalla console: il codice compare sul tablet per la cassa e i post WhatsApp/Instagram si scrivono da soli." (Approve the promos from the console: the code shows on the tablet for the till and the WhatsApp/Instagram posts are written automatically.) Only say promos await approval if `totals.proposals_created` > 0 or a lot has a promo action.

### haccp_nudge — step 2
2. If (`count` is 0 or `closed_day` is true) and `lots_on_hold` is empty, send nothing. Otherwise send one short message with SendUserMessage, Italian first with English in parentheses, under 110 words:
   **Chiusura serata · [date]** (add "· SIMULAZIONE" if `is_simulation` is true)
   - Food-safety items first (codes `ccp:`, `abx`, `ph`), marked "⚠ CCP", then the others: one line per `missing` item, its `label_it`.
   - If `lots_on_hold` is not empty: one line "Lotti bloccati, non vendere: …" (Blocked lots, do not sell).
   - Final line (only if there are missing items): "Il tablet mostra la lista in rosso: basta toccare la voce per registrarla." (The tablet shows the list in red: tap an item to record it.)
   No advice, no explanations.

### compliance_calendar — step 2
2. If `counts.overdue`, `counts.due_30` and `counts.unknown` are all 0 and `food_safety` has no lots on hold, no instruments out of service and no critical NC, send nothing (due_60 alone is not worth a message). Otherwise send one message with SendUserMessage, Italian first with English in parentheses, under 300 words:
   **Manutenzioni e scadenze · [date]**
   - **Sicurezza alimentare** (only if any of these is non-empty/non-zero): lots on hold (by lot), critical NCs open, instruments out of service ("non usarli"), lab results waiting (sample code, analyte, days). Point to "console → 🛡 HACCP".
   - **Scadute**: one line per overdue item — subject (ref), due date, days overdue; name the contact if present. Group lab analyses (kind campionamento) on one line listing their codes.
   - **Entro 30 giorni**: one line per due_30 item — subject (ref), due date; lab analyses again grouped on one line.
   - **Entro 60 giorni**: just a count and the subjects, comma-separated, if any.
   - **Date da impostare**: if `unknown_dates` is not empty, say compactly (max two lines) how many items have no date yet by kind (e.g. "3 strumenti, 2 corsi, 4 adempimenti") and where to fix them: instruments and certificates in console → 🛡 HACCP → Strumenti / Formazione; deadlines in ⚙ Configurazione → Macchine e scadenze. If `food_safety.sampling_plan_active` is false, add: "Piano campionamenti non ancora attivo: inserisci laboratorio e data di avvio in Configurazione (food.*)."
   - **Messaggi pronti per il tecnico**: for each entry in `technician_drafts`, the `message_it` text verbatim in a quote block, preceded by the ref and the contact if known. Skip if empty.
   - **Richiesta al laboratorio**: if `lab_request_draft` is not null, its `subject_it` and `message_it` verbatim in a quote block, preceded by the lab name/e-mail if present. Skip if null.
   End with one line: the single most urgent thing, in Italian and English (a food-safety item — lot on hold, critical NC, instrument out of service — always beats paperwork).

### ops_health — step 3
3. If `bots_missing` is empty, `bots_errors` is 0, `issues` is 0, `unknown` is empty and every infra check is done, send nothing. Otherwise send one message with SendUserMessage, Italian first with English in parentheses, under 200 words:
   **Controllo sistema · [date]** (add "· SIMULAZIONE" if `is_simulation` is true)
   - **Sicurezza alimentare** (only if any food-safety key is present, listed first): one line per such entry — its `text` verbatim, then "(console → 🛡 HACCP)". For `held_lot_sold` add "valutare ritiro" (assess recall); for `instrument_out_of_service` add "non usarli" (do not use).
   - **Bot**: name each agent in `bots_missing` as not having run today; for each with errors > 0 give the agent and its `last_error` in one line. If all ran clean, one line: "tutti i bot hanno girato".
   - **Dati**: one line per other `data_quality` entry — its `text` verbatim. For `stock_count_never` / `stock_count_overdue` add "(tablet → Conta magazzino)"; for `tablet_silent` add "(tablet spento o senza rete?)"; for `approvals_stale` add "(console → Da approvare)".
   - **Infrastruttura** (only if something is pending): one line per infra check not done — its key and `detail` verbatim (code_pushed / repo_sync: "fare push dal Mac"; app_deployed: "controllare il deploy Netlify"; uptime: "sito o funzioni giù"; restore_tested: "prova di ripristino da rifare"); one line per `unknown` advisor lint: name, level, why, "(Supabase → Advisors → Security)".
   End with one line naming the single thing to fix first, in Italian and English (food safety first, then uptime, then security). No praise, no filler.

### bot_watchdog — whole prompt (body)
- If "alerts" is an empty array: finish immediately with the single line "Nessun problema con i bot." Nothing is noteworthy; do not send any notification.
- If "alerts" is not empty: this is noteworthy. Reply with message_it exactly as returned (Italian, one line per problem), and add at the end one short line in Italian per alert of kind "error" saying which part of the system is affected if that is obvious from the detail. Do not try to fix anything, do not re-run other bots, do not run any other SQL.

### shopify_customers — step 2 message part
   Send a message with SendUserMessage ONLY if created > 0 or deactivated > 0 or placeholders_left > 0, Italian first with English in parentheses, under 90 words:
   **Clienti Shopify · [date]** — N clienti letti, X nuovi, Y aggiornati, Z disattivati, W all'ingrosso. If placeholders_left > 0 add one line: "Cliente 1 / Cliente 2 sono ancora segnaposto: creali su Shopify con la stessa e-mail e il tag ingrosso, e verranno adottati alla prossima sincronizzazione." (They will be adopted at the next sync.) Otherwise send nothing.

### shopify_orders — STEP 5
STEP 5 — report in Italian first then English, 6 lines max: orders read (online vs POS), new/updated, till days closed from POS with totals, shipments fulfilled in Shopify, unmapped variants (name them — the owner maps them in Configurazione → Vendite → Prodotti Shopify → magazzino). If Shopify returned no orders, say so plainly; it is not an error.

### shopify_inventory — STEP 6
STEP 6 — report in Italian first then English, 5 lines max: kg available for mozzarella; for each piece size (group by kg_per_unit) what the database says vs what Shopify shows now; untracked variants; errors. In report-only mode say clearly "Solo report: Shopify non è stato modificato". The mozzarella pool is split across the variants (say whether by sales in the last 28 days or equally), so the per-variant numbers add up to the pool and do not overlap. In report-only mode with setting 2, say it starts updating Shopify by itself once the opening stock count is posted. Zero available is a legitimate result (sold out or stock not counted yet) — say so, don't treat it as a failure.
(dashboard severity note: 'warn' if Shopify shows stock the database does not have while selling is not allowed at zero; report-only by itself 'info'; title example "Solo report: 0 kg in magazzino, Shopify non modificato")

### wholesale_orders — step 2
2. If `customers` is empty, send nothing. If every customer has `already_booked = true`, send nothing. Otherwise send one message with SendUserMessage, Italian first with English in parentheses, under 160 words:
   **Ordini ingrosso · [weekday] [date]** (add "· CLIENTI SEGNAPOSTO" if `is_placeholder` is true)
   - One line: `booked` ordini prenotati, `total_kg` kg totali di mozzarella per domani (the milk plan will include them).
   - For each newly booked customer: the customer name, phone if present, order number and total €, then its `message_it` verbatim in a quote block, ready to forward on WhatsApp.
   - If `is_placeholder` is true, one final line: "Rinomina i clienti e aggiungi i telefoni nella console → Impostazioni → Fornitori e clienti." (Rename the customers and add phones in the console → Settings → Suppliers and customers.)
   No advice, no filler.

### sales — STEP 4
STEP 4 — send ONE message with SendUserMessage, Italian first, English in parentheses only for the headline lines, under 380 words:
**Vendite · [weekday date]**
- **Canali** (Channels): if `s.plan_missing`, one line: "Obiettivi non attivi: imposta la data di apertura (Configurazione → `mkt.store_opening_date`)." Otherwise one line per channel: name — kg/g mese vs obiettivo (pct%) — then the total line: kg/g, € mese vs obiettivo, latte usato L/g (pct_of_full_volume% dei 2.000 L). If `totals.capacity_warning`, add: "L'obiettivo del mese supera il 90% della capacità impianto: pianificare secondo turno o attrezzature."
- **Da contattare** (To contact): for each drafted lead: **name** (segment, town, phone if any) — next_action, due date (and "X gg di ritardo" if overdue_days > 0) — then its message verbatim in a quote block, ready to forward. Mention current_supplier when present (it is a switch, not a first purchase).
- **Degustazioni** (Tastings) this week, one line each, if any.
- **Ferme** (Stalled) — up to 5 names with days since contact; **Clienti da recuperare** (Lapsed customers) with last order date and phone, if any; **Vinti questo mese** (Won) if any, and leads linked in STEP 1.
- **Pipeline**: active_n locali aperti, ≈ open_kg_day kg/g se chiusi; counts by stage in one line; new venues added in STEP 2 by name and town.
- **Delivery app**: one line with each marketplace's status and orders in the last 30 days (only if any is not live or has 0 orders).
End with one line: the single most important sales action this week (biggest gap vs target or the highest-value deal to close).
Brand rules in anything you write: never imply other DOP producers are not 100% buffalo; never attach "Cilento" to the DOP name; no health claims.

### marketing — STEP 3
STEP 3 — send ONE message with SendUserMessage, Italian first, English in parentheses only for the headline lines, under 300 words:
**Marketing · [date]**
- **Apertura negozio**: opening date and days left, or if opening_missing: "Data di apertura non impostata: Configurazione → `mkt.store_opening_date`. Senza data le scadenze di insegne e permessi non si calcolano." Budget line: pianificato / impegnato / speso vs budget campagna.
- **Permessi da chiedere** (permits_to_request): code + title + permit, one line each. Permits are the long pole (SUAP insegna, Codice della Strada, suolo pubblico, affissioni, logo Consorzio) — say so if any is overdue.
- **Preventivi da chiedere**: for up to 3 items in quotes_needed that are overdue or planned within 21 days (or, if no opening date, the signage items SIG-01, SIG-02, SIG-03 first), write a short ready-to-send Italian quote request in a quote block (to "Gentile fornitore", from Nick, [company.name], Agropoli): what is needed from `spec`, quantity, desired delivery before the planned date, ask for price incl. IVA, installation, and help with the permit paperwork where relevant. Never invent supplier names, prices or addresses.
- **In console da approvare**: items moved in STEP 2 plus awaiting_decision, with €.
- **Attivi / risultati**: live items with orders and revenue vs cost (say "nessun dato ancora" if empty).
- **Contenuti**: one line from `content` — gaps in the next 7 days, posts to review, influencer follow-ups.
End with one line: the single most important marketing action this week.
If the local campaign is fully done (no permits, quotes, approvals, due or overdue items) and content has no gaps or reviews, send nothing.

## Shared blocks that ended every old prompt (agent name varied)

---
LAST STEP — BOT DASHBOARD (always, once, after your report is final, including when there was nothing to do or when something failed): publish the report to the dashboard in Configurazione → Bot with ONE execute_sql call and never repeat it:
select fabula.post_bot_message('<agent>', '<severity>', '<title>', $msg$<report>$msg$);
- <severity>: 'alert' if something failed or needs action today, 'warn' if something needs attention soon, otherwise 'info'.
- <title>: one short Italian line (max 80 characters) saying the outcome, e.g. "3 promo proposte su 2 lotti" or "Nessun problema".
- <report>: your final report text exactly as you write it for Nick (Italian first, English after if you write both). Keep it inside the $msg$ … $msg$ quotes and never write the sequence $msg$ inside it.
This call only writes the dashboard message: it does not replace your agent_runs logging step.
---

Company name: the trading name is the setting `company.name` in `fabula.settings` (Configurazione → Azienda; today "Selezionati da Masseria Cilentana"). Read it at the start of the run and use exactly that value wherever the company name appears in anything you write (message titles, briefs, drafts to suppliers or customers). Never use an old or hardcoded name. The domain perladelcilento.it and the handle @laperladelcilento stay as they are.

(Also changed in v0.87: the opening line "for Selezionati da Masseria Cilentana" in each role paragraph became a neutral description plus the bot's nickname, since the name now comes from company.name at run time.)
