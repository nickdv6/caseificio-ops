-- Go-live board re-audit, 13/10/2026 (after v0.96). Doc: claude/golive-reaudit-2026-10-13.md
-- 1. ops_dashboard(): test customers count as placeholders; first_shipment ignores test customers;
--    two new auto checks (trial_start, alerts_linked). Patched in place from the live definition;
--    every anchor must match exactly once, otherwise the migration stops.
-- 2. dash_checks: fix_first re-scoped to the 12/10 audit; notes refreshed; two new rows.
-- 3. dash_areas: new baseline (prev = the scores this audit replaces).

do $mig$
declare
  d text := pg_get_functiondef('fabula.ops_dashboard()'::regprocedure);
  a text;
  r text;
  pairs text[][] := array[
    [$a1$'detail', case when count(*) = 0 then null else count(*) || ' placeholder names left' end)$a1$,
     $r1$'detail', case when count(*) = 0 then null else concat_ws(' · ',
            nullif(count(*) filter (where not x.is_test), 0) || ' placeholder names left',
            nullif(count(*) filter (where x.is_test), 0) || ' test customers left, with '
              || (select count(*) from fabula.sales_orders o join fabula.parties tp on tp.id = o.customer_id
                   where o.status <> 'cancelled'
                     and (coalesce(tp.legal_name, '') ~* '^prova |\(test\)|da cancellare'
                          or coalesce(tp.email, '') ~* '@example\.(com|org|net)$|^trade-test@'))
              || ' test orders not cancelled (trade-portal tests: cancel them on Shopify, end the test plan, then remove the customers)') end)$r1$],
    [$a2$from fabula.parties where active and (notes = 'placeholder' or source = 'placeholder')),$a2$,
     $r2$from (select (coalesce(p.notes, '') = 'placeholder' or coalesce(p.source, '') = 'placeholder') as is_ph,
                     (coalesce(p.legal_name, '') ~* '^prova |\(test\)|da cancellare'
                      or coalesce(p.email, '') ~* '@example\.(com|org|net)$|^trade-test@') as is_test
                from fabula.parties p where p.active) x
       where x.is_ph or x.is_test),$r2$],
    [$a3$from fabula.shipments where packed_at is not null)$a3$,
     $r3$from fabula.shipments sh where sh.packed_at is not null
          and not exists (select 1 from fabula.parties tp where tp.id = sh.customer_id
                            and (coalesce(tp.legal_name, '') ~* '^prova |\(test\)|da cancellare'
                                 or coalesce(tp.email, '') ~* '@example\.(com|org|net)$|^trade-test@')))$r3$],
    [$a4$v_auto := v_auto || fabula.infra_checks();$a4$,
     $r4$v_auto := v_auto || jsonb_build_object(   -- go-live re-audit 13/10/2026
    'trial_start', jsonb_build_object('done', coalesce((select value from fabula.settings where key = 'trial.start'), '') <> '',
        'detail', coalesce('Trial week from ' || nullif((select value from fabula.settings where key = 'trial.start'), '')
                             || ' (' || coalesce((select value from fabula.settings where key = 'trial.days'), '?') || ' days)',
                  'Not set: Configurazione → Parametri · trial.start (suggested Mon 25/01/2027). The trial-week check and its report run only once it is set')),
    'alerts_linked', (select jsonb_build_object(
        'done', count(*) > 0 and count(*) filter (where t.active and t.linked_at is not null) = count(*),
        'detail', count(*) filter (where t.active and t.linked_at is not null) || ' of ' || count(*) || ' partners get alerts on Telegram'
               || coalesce(' · still to link: ' || string_agg(s.full_name, ', ') filter (where not coalesce(t.active and t.linked_at is not null, false)), '')
               || ' · Configurazione → Utenti → Avvisi su Telegram')
        from fabula.staff s left join fabula.notify_targets t on t.staff_id = s.id
       where s.active and s.role in ('owner', 'partner')));
  v_auto := v_auto || fabula.infra_checks();$r4$]
  ];
  i int;
begin
  for i in 1 .. array_length(pairs, 1) loop
    a := pairs[i][1];
    r := pairs[i][2];
    if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then
      raise exception 'ops_dashboard re-audit patch: anchor % not found exactly once', i;
    end if;
    d := replace(d, a, r);
  end loop;
  execute d;
end $mig$;

-- 2. Go-live checks
insert into fabula.dash_checks (key, sort, label, kind, done, note, updated_at) values
  ('fix_first', 35, 'Audit fix-first bugs closed (12/10 audit: phase 0 + Critical)', 'manual', false,
   $n$12/10 audit (213 findings): 16 of the 17 phase-0 bugs and 11 of the 14 Critical are fixed live (v0.93–v0.96). Still open: CCP 2 method (D-11/A-30), waiting for the HACCP consultant: until it is decided every vat pasteurisation raises an NC. A-02 rest: print a batch label when the batch starts. POS-01/02/03: fixed in the repo, they go live with the till install. The earlier list (04/10 bug report, 11 items) was closed 05/10. Backlog: claude/audit-backlog-2026-10-13.md$n$, now()),
  ('trial_start', 26, 'Trial week date set (trial.start)', 'auto', false, null, now()),
  ('alerts_linked', 27, 'Food-safety alerts reach every partner on Telegram', 'auto', false, null, now())
on conflict (key) do update set label = excluded.label, sort = excluded.sort, kind = excluded.kind,
  done = excluded.done, note = excluded.note, updated_at = excluded.updated_at;

insert into fabula.dash_checks (key, sort, label, kind, done, note, updated_at) values
  ('placeholders', 12, 'Real supplier and customer names (no placeholders or test customers)', 'auto', false, null, now())
on conflict (key) do update set label = excluded.label;

insert into fabula.dash_checks (key, sort, label, kind, done, note, updated_at) values
  ('labels', 18, 'Sales labels approved (final brand, DOP mark, shelf-life)', 'manual', false,
   $n$Brand settled 08/10: Caseificio Bubalina (mark «bubalina», bubalina.it); producer on the label: Società Agricola Masseria Cilentana S.S. Before printing: attorney trademark search in classes 29/35/43 (a plain word mark may be refused as descriptive, so file a figurative mark); no «Cilento» next to the DOP name; «…DOP affumicata» on smoked; allergens and nutrition (Reg. 1169/2011); shelf-life from the MOZ-SHELF study; activate MOD-23. DOP mark only with the RINA caseificio code and the Consorzio's label approval.$n$, now()),
  ('shopify_catalog', 17, 'Shopify catalog decisions made', 'manual', false,
   $n$Classica sizes fixed 09/10 (one «Peso» option). Still open: Ricotta price and bundle copy; unpublish the 5 old collections and the 4 «Fornitura» packages; «Abbonamento» titles; Ciliegine «25g» sold in 250/500/800 g. 6 dairy product titles still say «DOP»: take it off before the store password comes off, unless the RINA caseificio code is in (claude/collections-restructure-2026-10-09.md).$n$, now()),
  ('outside_watcher', 42, 'Outside watcher running on GitHub', 'manual', true,
   $n$Runs on GitHub and e-mails Nick on a failed run. Scheduled every 30 min, but GitHub ran it 27 times in the 7 days to 13/10 (2–5 a day, all green; longest gap about 10 h on 12/10). It tells only the repo owner and checks neither the bots nor the nightly backup (audit E-22): planned as a dead-man's switch through the Telegram dispatcher.$n$, now())
on conflict (key) do update set note = excluded.note, updated_at = excluded.updated_at;

-- 3. Area scores: new baseline
insert into fabula.dash_areas (area, sort, built, reliable, automated, usable, evidence, next_step, usable_why, updated_at) values
  ('Reports & briefs', 1, 93, 72, 90, 70,
   $e$Re-audit 13/10: 141 bot runs since 06/10, 0 errors (bot health 73/73, 6–12 Oct); the weekly brief ran 12/10; v0.87 message rules, v0.88 merged morning and weekly brief, and since v0.96 alerts also go out on Telegram. Still only on empty data. The 12/10 audit found the report guard rails weak: the LLM still does arithmetic and judges «invariato» (E-19), routine warnings never clear (72 unread messages, E-05), and nothing checks that the scheduled prompts match the repo (E-17).$e$,
   $e$Shared «numbers verbatim from the JSON» rule and SQL-computed deltas in every report prompt (E-19); routine warnings that clear themselves (E-05); then check the first brief built on a real week (trial week) against the till and the tablet$e$,
   $e$Briefs arrive by themselves and alerts reach Telegram with «Ho visto / Me ne occupo io». Messages still link nowhere (E-08), 23 nicknames hide which part of the system is speaking (E-13), and 72 unread messages already sit in the bell before opening. A BI tool adds drill-down charts and one-tap filters.$e$, now()),
  ('Sales & orders', 2, 88, 64, 83, 61,
   $e$Re-audit 13/10: Shopify order, customer and stock syncs ran clean every day. Since 06/10: weighed counter sales reach stock through the order sync (POS-06), till middleware and scale integration written and tested on the simulator with the double-charge and change-short fixes (not installed: no till computer yet, RT printer not ordered), storefront rebranded to Bubalina behind the store password, GA4 with one consent banner, shipping, refund and delivery pages. Against it: no real order; the 3 orders on file are trade-portal tests that are also real unpaid Shopify orders (#1001, A1002, A1003) and the test plan keeps booking more; 6 dairy titles still say «DOP»; the order and customer sync is an LLM copying money and customer data with no server-side check (E-18, High); till POS-04/05 (High) open.$e$,
   $e$Cancel the 3 Shopify test orders and end the PROVA test plan; order the Epson RT printer in Masseria's name; move the Shopify order and customer sync to a deterministic edge function (E-18); take «DOP» off the 6 product titles before the store password comes off (unless the RINA code is in)$e$,
   $e$Web orders ride on Shopify's own checkout (benchmark-grade) and the storefront is rebranded. The counter screen (CashDro + scale + RT) exists only as code tested on a simulator, so the cashier flow has never been tried on the hardware.$e$, now()),
  ('B2B sales pipeline', 3, 90, 58, 62, 60,
   $e$Re-audit 13/10: trade portal live since 06/10 (v0.83): application form, weekly plans with quantities per day, skips and pauses, tier pricing, nightly booking into Da spedire and a B2B order on Shopify net terms, Console → Ingrosso. v0.93 fixed the silent under-minimum skip, «Salta» on a booked order and the garbled cut-off message. Open High from the 12/10 audit: no upper bound or step on trade quantities (TRADE-01); «Invia a Shopify» pushes prices with no preview or plausibility check (B-22); a removed tier stays on Shopify (B-23). Customers: 3 test parties only. Leads: 45, 1 contacted, 0 activities logged; sales.plan_start empty.$e$,
   $e$Price-push preview and tier removal (B-22/B-23) and trade quantity bounds (TRADE-01) before the first real customer; remove the 3 test customers; set sales.plan_start; log the first calls and tastings in Vendite$e$,
   $e$Customers manage their own weekly plan in the portal (skips, pauses, live price), which Shopify B2B doesn't do out of the box. The office side still acts on one tap in places (Sospendi accesso, Nuovo link, Pausa senza data: B-24, TRADE-06), and leads are logged by hand with no one-tap logging from phone or e-mail as in Pipedrive-class CRMs.$e$, now()),
  ('Inventory & lots', 4, 91, 68, 77, 64,
   $e$Re-audit 13/10: FEFO, held and expired lots refused at packing and on the tablet. Since 06/10 a raw-milk lot can't be over-drawn (D-09), a food-safety hold can only be lifted by the HACCP release (D-03), a positive milk check holds every lot made from it (A-04), and a lot can't be closed twice. Open from the 12/10 audit: the stock count adjusts from its opening snapshot, so moves during the count are counted twice (D-05, High: this is the opening count itself); lot labels can only be reprinted by typing the code (PRINT-08, High). A count opened 06/10 was never posted; 0 stock moves.$e$,
   $e$Fix D-05 (adjust against live stock when the count is posted) before the opening count; then post the opening stock count on the tablet (it also starts the Shopify stock sync)$e$,
   $e$QR labels, FEFO picks itself, held and expired lots refused even offline. Reprinting a label means typing its code (PRINT-08), and no staff count has been done yet.$e$, now()),
  ('Milk plan & intake', 5, 96, 72, 80, 72,
   $e$Re-audit 13/10: since 06/10 the farm's kg is checked against the day's order (FARM-01), the load is confirmed from the driver's paper (A-10/FARM-03), the farm can correct or cancel a load and the dairy's scale weight counts above 2 % (FARM-02), and a positive antibiotic retest rejects the milk and holds its lots (A-04). The nightly plan ran every day, but on an assumed 30 % yield and with the trade-portal test orders as demand; the Masseria has seen 0 plans and 0 real loads arrived. Open High: intake has no kg or temperature bounds and the tablet decides acceptance (D-07); the 60 h DOP limit is reported a month late (D-08); plan cards hide the farm and capacity warnings and can't be approved with a different kg (B-09); auto-approval is invisible (E-10); one permanent link controls the farm page (FARM-04).$e$,
   $e$D-07 and D-08 in v0.98; «Approva con … kg» on milk plans (B-09); print the shipment QR for the farm and send it the page link; first real load in the trial week$e$,
   $e$Shipment QR, farm page with a single Visto tap, the load confirmed from the driver's paper, and wrong loads corrected or cancelled with a reason. Intake still asks several typed values (antibiotic test, temperature) with no bounds, where top systems read them from the device.$e$, now()),
  ('Procurement', 6, 90, 55, 62, 63,
   $e$Re-audit 13/10: v0.89 supply catalogue and v0.90 ordering screens (Ordina mode, below-threshold proposals, pack rounding, one PO per supplier); the Acquisti bot ran clean every day with nothing to propose. Open: catalogue POs are created already approved, €0 allowed, no creator and no way to cancel (B-18, High); goods receipts have no bounds (D-18); the 4 v0.89 database functions behind the catalogue were never security-reviewed, so the board's security check has been red since 12/10. 2 placeholder suppliers, 23 of 28 items without a supplier, 0 purchase orders.$e$,
   $e$Review and accept (or fix) add_supply_item, create_manual_po, link_supplier_item and unlink_supplier_item; cancel_po and a total confirmation (B-18); replace the 2 placeholder suppliers and give the other 23 items a supplier$e$,
   $e$v0.90 catalogue: Ordina mode, Proponi i sotto soglia, minimum order warned and pack multiples rounded as you type, one PO per supplier with a jump to Invia. A PO can't be cancelled once created (B-18), orders still go out by mailto or WhatsApp, and nothing has been ordered for real.$e$, now()),
  ('Compliance & HACCP', 7, 95, 64, 70, 63,
   $e$Re-audit 13/10: v0.93–v0.96 closed the audit's food-safety criticals: a failed CCP holds the lot for every profile (D-01), CCP limits can't be blanked (B-01), legal records are append-only with a «Correggi» path and an audit trail (D-02/A-06), every record carries the operator from badge or PIN (A-01), a positive milk check holds its lots (A-04), and food-safety alerts go out on Telegram with escalation (E-01). Farm in RINA as allevatore since 12/10. Opening gates all open: Manuale unsigned (rev 0 bozza, still names DQA), 0 training records (6 courses), 4 machines uncalibrated, no CE approval or RINA caseificio adhesion, no lab result. Blocked: the CCP 2 limit (72 °C) contradicts the vat method (63 °C × 30 min), so every pasteurisation will raise an NC until the consultant decides (D-11). Only Nick receives the Telegram alerts: Nicola, the HACCP responsible, is not linked yet.$e$,
   $e$HACCP consultant: decide the CCP 2 method (D-11) and sign the Manuale (DQA → RINA); Nicola and Emilio link Telegram; HACCP training for the three partners; calibrate the pasteuriser, 2 scales and the reference thermometer; CE approval/SCIA and RINA caseificio adhesion on deed day; MOZ-DOP sample in the trial week$e$,
   $e$CCP steps can't be skipped, a lot closed without its records is held, a mistyped record is corrected with a reason instead of SQL, and the operator is set by badge or PIN instead of a shared login. Out-of-limit values still save on one tap with the corrective action in a 2.6 s toast (A-07, A-15), and 23 MOD forms across six tabs is heavy next to FoodDocs or Jolt.$e$, now()),
  ('Marketing', 8, 82, 52, 60, 52,
   $e$Re-audit 13/10: brand chosen 08/10 (Caseificio Bubalina, bubalina.it), storefront theme and logo live behind the store password, GA4 + Search Console + Merchant Center linked, tagged links for every channel and the 18 local QR codes, opening date 15/02/2027 set, launch posts ready to seed. Still nothing published (0 posts in the content calendar), all 18 local-campaign items «da preventivare», 1 of 27 storefront items done, and no trademark search yet for «bubalina» (a plain word mark may be refused as descriptive).$e$,
   $e$Attorney trademark search (classes 29/35/43) before signage or labels; quotes for the 18 local-campaign items; seed and approve the launch posts; open the social accounts as @caseificiobubalina$e$,
   $e$Module built and the brand settled, but nothing published yet. Posts still go out by hand through Predis, without the schedule-and-forget calendar of a dedicated social tool, and the Marketing page lacks the Console's unsaved-change guard (B-32).$e$, now()),
  ('Fulfilment & shipping', 9, 92, 68, 68, 72,
   $e$Re-audit 13/10: packing pre-filled by FEFO with refusals, DDT, Shopify fulfilment, direct shipment offline. Since 06/10 the DDT prints the delivery address, window, instructions and the customer's PO (PRINT-01), company data is checked before printing (PRINT-03), and trade-portal orders land in Da spedire by themselves. Open from the audit: DDT numbers use two schemes and are not one progressive series (D-22/PRINT-04), «Colli» counts lines rather than parcels (PRINT-02), and a direct shipment makes up its DDT number (A-28). 0 real shipments; the 3 orders in Da spedire are tests.$e$,
   $e$One progressive DDT series (D-22/PRINT-04) and a real parcel count before the first real DDT; pack one real order in the trial week$e$,
   $e$Packing pre-filled by FEFO, scan the lot label to confirm (held or expired lots refused), weight read from the scale, DDT printed with the delivery address, Shopify fulfilled in one pass, works offline. Missing next to ShipStation: batch label printing and a carrier label in the same flow. 0 real shipments.$e$, now()),
  ('Staff & rota', 10, 92, 60, 54, 56,
   $e$Re-audit 13/10: Nick and Nicola sign in (Nicola since 06/10). Emilio was invited again 12/10 and the 24 h link expired unused, so he has never signed in. v0.96 added the operator chip: all 3 have a 4-digit PIN and a printed badge, badge-in clocks the shift, and Telegram is linked from Configurazione (only Nick so far). 0 rota entries, 0 shifts, 0 training records. Open from the audit: badge codes are guessable and printed in clear, and since v0.96 a badge signs HACCP records (C-24/PRINT-13, raised); someone who leaves keeps an open shift and keys (C-14); an e-mail edit plus reset creates a second account (C-13).$e$,
   $e$Send Emilio a new invite on a day he can open it at once; random badge codes (C-24) before badges sign real records; Nicola and Emilio link Telegram; HACCP training records for all three; first rota (it copies itself every Saturday from then on)$e$,
   $e$Switching person on the floor is now a badge scan or a PIN instead of an e-mail and password with wet gloves. Getting into the system is still the weak step: invite links last 24 h and Emilio's lapsed unused; the rota is typed shorthand (B-26) and nobody has used it yet.$e$, now()),
  ('Finance & e-invoicing', 11, 55, 42, 45, 40,
   $e$Re-audit 13/10: unchanged since v0.82 (06/10): Incassi import and nightly matching built and tested; invoices and the SDI link still spec only, waiting on the commercialista (IVA regime, numbering); PEC and SDI code empty. The 12/10 audit found that re-importing a statement under a slightly different account name duplicates every movement with no undo (B-27), and that manual matching accepts the wrong direction and double matches (D-28). 0 bank rows, 0 payouts, 0 invoices.$e$,
   $e$Commercialista answers the IVA regime and numbering questions; PEC and SDI code; Fatture in Cloud in Masseria's name, then build the invoicing bot. Fix B-27 and D-28 before the first real bank import$e$,
   $e$Bank and Shopify payment files are uploaded by hand as CSV and matched in a review list, and a wrong import can't be undone (B-27). Invoicing and SDI are still spec only, where Fatture in Cloud does both from one screen.$e$, now()),
  ('Production floor', 12, 96, 62, 56, 60,
   $e$Re-audit 13/10: since 06/10 the start sequence can be paused and resumed without losing CCP 2 (A-03), the close asks for every missing CCP and holds a lot closed without them, a lot can't be closed twice (D-21), two open lots on one tank ask «Quale lotto?» (A-02), task times are in Rome time (A-05), and records carry the operator (A-01). Open High from the 12/10 audit (releases v0.97/v0.98): out-of-limit values save on one tap (A-07), measured fields arrive prefilled (A-09), refused saves are hard to see and wiped by a second tap (A-11), follow-ups live only in a toast (A-15), no number bounds or Italian number parser (A-13), no yield bounds at close (D-06), recipe doses change on one Salva (B-14), offline HACCP checks get the upload time (D-04); CCP 2 method blocked (D-11). 0 real batches, all 6 doses placeholders, both tablets last seen 06/10 on perla-v50 (live is v64), nightly task job paused until the building is ours.$e$,
   $e$v0.97 floor flows and v0.98 number bounds before the trial week (25–29/01); the casaro confirms the 6 doses and times one real 310 kg cycle; set trial.start; open the app on the floor tablet so it checks in on the latest version$e$,
   $e$Fully offline, presets, CCP values asked in the right order, «Continua più tardi» on the start sequence, operator by badge or PIN, mistyped records corrected with a reason. Still open from the audit's floor-flow fixes: one-tap saves of out-of-limit values, prefilled measured fields, refused saves in small English text (A-07, A-09, A-11). The casaro has not run a real cycle on the tablet.$e$, now()),
  ('Infra & security', 13, 97, 84, 94, 55,
   $e$Re-audit 13/10: backups every 2 h and nightly (60 runs since 06/10, 0 errors), hourly probes, site and functions up, restore drilled 05/10. v0.96 added the Telegram dispatcher with escalation (E-01), a guarded restore that refuses to wipe newer live data (E-23) and the partners' «Sistema giù» card. Against it: the security check has been red since 12/10 12:43 UTC (4 v0.89 functions never reviewed); no off-site copy of the backups (E-24, High); every staff account can read the masked secrets (C-05, High); the bots still run on Nick's personal account (E-20, High, partly done); the outside watcher ran 27 times in 7 days (2–5 a day, gaps up to about 10 h) instead of every 30 min (E-22); no CI for the ~300 tests (E-29); several live changes went through SQL Editor scripts because the connector cancelled them and the Mac CLI is broken.$e$,
   $e$Review the 4 v0.89 functions (turns the security check green); nightly off-site copy of the backups (E-24); secrets out of reach of staff accounts (C-05); dead-man's switch through the Telegram dispatcher (E-22); CI on every push (E-29); next restore drill 5 Jan 2027$e$,
   $e$Health and backups watch themselves and alerts reach Telegram. Changes still need a git push from the Mac and SQL migrations (often pasted into the SQL Editor), and partners get a one-page card rather than tools. Managed SaaS needs no owner effort here.$e$, now())
on conflict (area) do update set
  prev = jsonb_build_object('built', dash_areas.built, 'reliable', dash_areas.reliable, 'automated', dash_areas.automated,
                            'usable', dash_areas.usable, 'at', dash_areas.updated_at),
  built = excluded.built, reliable = excluded.reliable, automated = excluded.automated, usable = excluded.usable,
  evidence = excluded.evidence, next_step = excluded.next_step, usable_why = excluded.usable_why, updated_at = now();
