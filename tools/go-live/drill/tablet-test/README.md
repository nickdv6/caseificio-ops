# Tablet reliability tests (v0.62)

Runs the real tablet app (fabula-tablet) in headless Chromium against a local copy of the database with the real role
policies, so atomic saves, exactly-once re-sends and the offline flows can be checked without touching the live system.

1. `../run_drill.sh latest.json.gz` — builds `restore_drill` from every migration and loads a backup.
2. `su postgres -c "psql -d restore_drill -f setup.sql"` — test login (Test Casaro, role produzione) and auth stubs. Since v1.05 it also sets `prod.tasks_from` = 2026-01-01 and no closing weekday, so the daily tasks and the evening list exist on any day.
3. PostgREST 12 (static binary from github.com/PostgREST/postgrest/releases): `postgrest pgrst.conf` (port 3000).
4. `su postgres -c "psql -d restore_drill -f test_save_ops.sql"` — SQL tests: one transaction, re-send with the same id,
   a failing step leaves nothing, update must match one row, whitelist, role policy refusal (a Banco user).
5. `python3 e2e.py` (Playwright) — expect `FAILURES: none`.

6. `python3 prod_e2e.py` (v0.70) — production card on Home: two 575 kg loads from a 1,150 kg delivery, one tap fills the batch
   start, more milk than is left asks to confirm, the second load starts offline from the kept plan, both reach the database,
   closing shows the expected kg and a normal yield saves at once. Expect `FAILURES: none`.

If the backup is older than the latest tables, the restore step of `run_drill.sh` stops after building the database from
every migration: the tests still run, after adding one milk supplier
(`insert into fabula.parties (type, legal_name, is_milk_supplier) values ('supplier', 'Masseria (test)', true)`).

7. `python3 pack_e2e.py` (v0.71) — Da spedire: pick list, packing order, late/short flags; the pack form opens with the lots
   allocated (two rows for a split line); scanning a held lot is refused; a short order asks to confirm with the reason.

   Run it on a fresh database (or first): stock left by e2e/prod_e2e changes its allocations.

8. `python3 device_e2e.py` (v0.74) — the tablet checks in with its label and app version, a refused offline save reaches
   `fabula.tablet_rejects` and the bell once, the pending line says it was reported, an older app shows "Aggiorna ora".

9. `python3 paper_e2e.py` (v0.77) — 🛡 → Ricopia da foglio di carta: sheet time kept (Agropoli), source paper, who wrote it;
   offline it queues and keeps the sheet time; out of limit opens the NC; older than 7 days refused.

10. `python3 offline_e2e.py` (v0.78) — batch started and closed with no network, both arrive in order; task list shown
    offline; direct shipment offline with the kept customers; a held lot refused.

11. `python3 guard_e2e.py` (v0.80) — **run last** (it moves today's valve checks back a day): CCP step asks for the value
    and refuses "Salta"; first batch asks for the valve check, a failed valve stops the batch; CCP 2 on start and CCP 3/4
    on close when missing; a batch closed with a skipped CCP raises the Zio Ciro alert.

12. `DB=<db> python3 recon_e2e.py` (v0.82) — Console → Incassi as the owner: the Shopify payments CSV (Italian admin) is
    recognised while "Estratto conto" is selected and switches by itself; a bank CSV in Windows encoding with a preamble and
    a footer; payout matched to the Shopify credit, bank fee by rule; an unknown credit classified "Altro" (refused without a
    note); a card order with no payment marked as checked; a production login does not see the tab. Needs a replay with
    v0.82a (no backup needed). 06/10/2026: 18/18.

13. `python3 audit_e2e.py` (v0.93, port 8768) — scanning a tank label when two open lots share the milk asks which lot (no
    preselection, oldest first with its start time), refuses Salva without a choice, opens the lot picked; milk arrival with
    two loads in transit preselects nothing, shows "partita N h fa" for each, a choice locks its kg and lot, «nessuna»
    unlocks them. 12/10/2026: 10/10.
    v0.94 adds the paper check:
    - with a choice, the list and card hide lot/DDT and the 40 h load sits behind «mostra»;
    - the other load's lot or an unknown value is refused with the reason on screen;
    - the last 3 DDT digits save the load at the farm's kg and lot;
    - one fresh load left is preselected with no check;
    - `DDT:<number>` from a QR picks its load.
    12/10/2026: 22/22.

14. `python3 farm_amend_e2e.py` (v0.94a, port 8772; needs v094a in the DB) — farm page on a phone:
    - registers a load and the lot is shown big;
    - «Correggi o annulla» needs a reason and a second tap, then the corrected kg and the first one are shown;
    - a load registered twice is cancelled and shown «Annullata» with the reason, and the office gets both messages.

    Tablet: the cancelled load is not offered, and the corrected one comes at 1.050 kg.
    Console → Oggi as the owner: every load in transit is listed and the 40 h one is flagged; «annulla» asks for a
    reason, cancels it with the owner's name, and the list updates. 12/10/2026: 16/16.

15. `python3 s_items_e2e.py` (v0.95, port 8773; needs v095a/b in the DB) — the audit backlog items under an hour:
    - tablet: a milk vat offers no ricotta, says the milk still left and refuses more; curd pH 52 refused before saving;
      batch close asks ricotta Sì/No (required; «No» stored as whey 0); Home «Avvia ricotta» starts the R-lot from that whey;
      Esci refused with records waiting, a second tap logs out;
    - farm page: 105 kg against the order spelled out in the red box; «1.0xx» read with the thousands dot; under 50 kg refused;
    - Autocontrollo as the owner: no default outcome, result required, «Correggi esito» with reason; «Prelevato» lot picker
      (Enter means OK; unknown lot refused in the dialog); register review dialog (dates up to today, count, required tick,
      signed by the owner); calibration needs certificate + deviation;
    - Configurazione: kg per piece pre-filled 0,25 from the title, grams shown, 250 refused; delivery days seven boxes,
      cut-off a time field; DDT without P.IVA: red banner and printing disabled, back to normal once filled in.
    12/10/2026: 41/41. The tablet tests that close a batch (e2e, guard_e2e, offline_e2e, prod_e2e) now answer the ricotta
    choice; guard_e2e uses a test product without preset for the CCP 2 field (ricotta is no longer offered from milk);
    prod_e2e expects the over-draw to be refused. On the long-used restore_drill copy pack_e2e, prod_e2e and paper_e2e
    have failures caused by data left by earlier runs (same failures with the v0.94 code).

16. `python3 operator_e2e.py` (v0.96, port 8774; needs v096a-d) — who is recording (A-01) and the Telegram card (E-01):
    «Chi registra?» chip and gate, name + PIN (tries left, shift box), badge of another person (clocks in, signs the next
    record, the logged-in account kept), same badge again → «Fine turno» card, 15 idle minutes (reload) and a form left open
    (fake clock) ask again, offline PIN (only one already used on this tablet), paper signer list, the evening «badge di
    uscita» item closes that shift, Configurazione «PIN» button, Telegram card (link + QR, people, link for someone else,
    topics / time zone saved).
17. `python3 farm_weight_e2e.py` (v0.96, port 8775) — FARM-02: «kg pesati qui» next to the Masseria's kg, within 2 % / over
    2 % with a reason, both weights saved, result card, stock, office notice, the farm page.
18. `python3 notify_fn_e2e.py` (v0.96) — the edge function `notify` run locally with Deno (DENO=…/deno; `npm i deno`) against
    PostgREST and a fake Telegram on :8790: wrong webhook secret 403, /start links, dispatch registers the webhook and sends
    HTML with the two buttons, «Me ne occupo io» edits the copies, a blocked bot unlinks, /stop, no errors in the log.
    13/10/2026: 37/37, 11/11, 12/12. The other e2e tests now store the operator like a login (`e2e_op.py`), fill «kg pesati
    qui» when a farm load is picked, and record the start steps of batches they create in SQL (A-03 resumes them otherwise).

Last run 13/10/2026 (v0.97), fresh replay (no backup) + setup.sql + one milk supplier, in this order: pack_e2e 17/17, e2e 23/23,
prod_e2e 13/13, audit_e2e 18/18, operator_e2e 37/37, s_items_e2e 38/38 (needs the owner row operator_e2e creates), offline_e2e 11/11,
paper_e2e 9/9, device_e2e 9/9, farm_amend_e2e 16/16, farm_test 12/12, farm_weight_e2e 11/11, notify_fn_e2e 12/12, floor_e2e 38/38,
guard_e2e 18/18 (last). Rerunning on the same day: delete today's T-CF1 tasks first (offline_e2e adds them at fixed times).
Last run 13/10/2026 (v0.98), fresh replay of all 175 migrations + setup.sql + one milk supplier, same order with numbers_e2e 39/39
before guard_e2e: all 16 suites `FAILURES: none`.
Last run 13/10/2026 (v0.99), same setup with the 177 migrations, same order with office_e2e 42/42 after numbers_e2e and before
guard_e2e: all 17 suites `FAILURES: none`.

19. `python3 floor_e2e.py` (v0.97, audit floor flows) — red «È giusto?» before an out-of-limit value (cold room, milk), the NC card,
    the re-check as a red box with the minutes left, «Annulla» asks, cleaning item not done, «Non fatta…» on an earlier task, stock
    count with nothing prefilled, refused saves banner + «Rifai», a dependent record held back, an offline check keeps its time,
    two tablets with the same lot letter, a double tap in dosing ignored, 60 h DOP, milk arrival from the paper sheet.
    Expect `FAILURES: none` (38 checks). Confirmations are now a question on screen: tests answer them with `e2e_op.answer_ask`.

20. `python3 numbers_e2e.py` (v0.98, audit numbers and limits; port 8778, browser in it-IT) — «4,5» saved as 4.5 with the echo line,
    «1.200» and 450 °C refused before saving; a 3100 kg vat refused; a 200 % yield corrected in the same save (milk kg, reason,
    correction record) and a low yield with its reason; dosing ×10 asks and keeps the pack lot; a DDT price ×100 asks; Console →
    Ricette per-vat preview, Enter does not save, ×10 asks with a reason; Configurazione range, unit, refusal, high-impact question and
    bell notice, list for the manual status; farm page temperature warnings; Ingrosso «1150» refused, «11,90» saved.
    Expect `FAILURES: none` (39 checks). Run it before guard_e2e. Number fields are text with `inputmode=decimal` now: tests type
    «12,5» or «12.5» (both read the same).

21. `python3 office_e2e.py` (v0.99, audit office decisions and undo + A-02; port 8779, browser in it-IT, the trade-portal function
    mocked) — Console → Oggi by urgency, an expired card grey without «Approva», the milk card's farm warning, «Approva con 400 kg»
    asked and reaching the farm, «Annulla» in «Decise di recente», «Rifiuta» then «Ordina 450 kg», DOP checks then «Segna inviata»,
    the post card's link and picture, a catalogue order over the limit as one card, «Annulla ordine» (also once sent, with the
    WhatsApp text), the old «Ordini fissi» grid gone, an unpriced line stopped until «prezzo da confermare» and then waiting for
    approval, Ricette «Togli»/«Rimetti», a preset target «94,5», lot release with the analysis, NC «Riapri», Ingrosso exceptions,
    stop buttons asked, «da inviare» marks, the Shopify preview before sending, Marketing `#post=`, and the tablet's lot label at
    batch start. Expect `FAILURES: none` (42 checks). Run it before guard_e2e.

22. `python3 alerts_e2e.py` (v1.00, audit alerts and operations; port 8780, browser in it-IT) — Configurazione → Bot: cards say what
    the bot does with the nickname under it (none for the database's own senders), the bell shows the open alarms first, a message's
    button (an outside link never reaches the page), «Segna come letta» only for me (another person still has it and sees «Visto
    da»), «Risolto…» asks what was done and closes the alarm for everyone (not offered to a «vede» profile), «Segna tutto» leaves
    the alarms open, «Esegui ora» names its effect, asks again the second time, is recorded with the name and is not offered to a
    «vede» profile, `#bots&fermi` opens «Bot fermi: cosa fare»; Console: `#oggi&appr=<id>` highlights the request (a decided one
    says so), «proposto da Piano latte · Zio Gennaro», «Avvisi aperti» with links and «Risolto…»; the tablet shows only the floor's
    notices; Autocontrollo «Registrazioni rifiutate» and «Segna come rifatta». Expect `FAILURES: none` (30 checks). Run it last: it
    closes the messages and notices the other suites left.

Last run 14/10/2026 (v1.00), same setup with the 181 migrations (v1.01a included), all 18 suites in a row with alerts_e2e last:
`FAILURES: none`. Three suites no longer depend on the hour they run (they failed before 06:00 Rome, also on v0.99): offline_e2e
(the morning cold-room check is due already), office_e2e (tomorrow's milk plan is urgent only within 24 h of its deadline),
operator_e2e (the «badge di uscita» item is in a floor notice).

23. `python3 shopify_sync_fn_e2e.py` (v1.02, audit E-18) — the edge function `shopify-sync` run locally with Deno (DENO=…/deno) against
    PostgREST and a fake Shopify Admin API on :8791: no key or a wrong key 403, «status» lists the missing permissions, customers
    (every page, Shopify's count, the run record and the «info» message from the database), orders (both written, the till day, the
    shipping address kept, one fixed window sorted by id, a packed shipment confirmed with its tracking and marked in the database),
    orders that do not match Shopify's count (the run fails, nothing written, the alarm says why), stock report-only (Shopify
    untouched, an untracked product listed), stock switched on (without the permission nothing sent; with it only the tracked
    products that differ, with an idempotency key), no errors in the log. Expect `FAILURES: none` (12 checks).
24. `python3 sync_e2e.py` (v1.02, audit E-18/E-07; port 8781, browser in it-IT) — Configurazione → Bot: the Shopify jobs say «dal
    database» and offer «Esegui ora»; the sync message with the products page; the run card (no «versione del database»), asks first,
    calls the function with the name, says the result comes in a couple of minutes, asks again when pressed again; Utenti → Avvisi
    Telegram: the system topic waits for the silence unless the system is down, the summary time saved and cleared. Expect
    `FAILURES: none` (10 checks).

Last run 14/10/2026 (v1.02), same setup with the 184 migrations, all 20 suites in a row (the 18 above in the same order, then
shopify_sync_fn_e2e, sync_e2e, alerts_e2e last): `FAILURES: none`. shopify_sync_fn_e2e sets the stock push itself, since the
suites before it post a stock count (which switches the push on).

25. `python3 v103_e2e.py` (v1.03, audit C-05 / FARM-04 / PRINT-08; port 8782, browser in it-IT) — the real edge function `farm-order`
    run with Deno (DENO=…/deno) behind a proxy to PostgREST. The QR key: «Chi spedisce» from the names (a name typed under «Un altro»
    and then «scegli» counts as nobody), no month or orders, the load saved with the name and «farm_qr», remembered on the phone, its
    own load corrected within 2 hours with the office told who; the full link: month, orders, the name; it refuses to become a poster,
    the QR key prints it. Configurazione «Link della Masseria» (owner): links, WhatsApp text, «Genera nuovo QR» asks and switches the
    old QR off, «Chi spedisce» saved; the office profile sees no links; Console → Oggi: the poster from the QR key for the owner,
    nothing for production; a Console save on a customer still works (`UI.upd`). Tablet «🖨 Ristampa etichette lotto»: search, the
    lot's copies, «Prepara l'etichetta», the link from the database, the reprint counted; labels.html: checked lots, a wrong expiry
    corrected, an unknown lot red and not printed unless it waits in the tablet's queue, a close still in the queue printed as the
    tablet wrote it, no login «NON controllati». Expect `FAILURES: none`.

Last run 14/10/2026 (v1.03), same setup with the 187 migrations, all 21 suites in a row (the 20 above, with v103_e2e after sync_e2e
and alerts_e2e last): `FAILURES: none` in each, v103_e2e 30/30. farm_amend_e2e, farm_test and s_items_e2e now set «Chi spedisce» on the farm page, and
farm_test prints the poster with the QR key.

26. `python3 v104_e2e.py` (v1.04, audit D-17 / D-22 + PRINT-04 / D-31; port 8783, browser in it-IT) — the pack form says the 30 %
    limit; 50 kg weighed for 5 → the red card «Non si spedisce così» with the reason, after «Correggo» the form stays and nothing is
    shipped; weighed right → a DDT of the yearly series (DDT-<year>-NNNN); a direct shipment from a lot → the toast carries the next
    number; «Ricopia da foglio di carta» the same line twice → «già nel registro … già ricopiata», one row; «CAL:CF-01» (cold room display
    check) saved without ticking «Temperatura cella 1». Expect `FAILURES: none`.

Last run 15/10/2026 (v1.04), same setup with the 190 migrations, all 22 suites in a row (the 21 above, with v104_e2e after v103_e2e
and alerts_e2e last): `FAILURES: none` in each, v104_e2e 12/12. pack_e2e reads the per-product reason («pesati 2 kg contro 4 ordinati (-50 %)»).

27. `python3 v105_e2e.py` (v1.05, audit E-31 / E-09 / E-14 / E-28 / E-30; port 8784, browser in it-IT, the tablet's clock set to
    09:30 and 15:30 Rome) — 09:30: «Ieri non registrato» with yesterday's lot, its item opens «Ricopia da foglio di carta» on yesterday's
    date with the lot; 15:30: «Prima di chiudere» shown once; «Fine turno: esco» asks («Li registro adesso» keeps the shift, «Esco lo
    stesso» closes it); a marketing profile's bell «Avvisi» → Console → Oggi with its alarms, not food safety; Panoramica → Sistema in
    Italian; «Verso l'apertura»: a note required, who and when, «Annulla…» with a reason; the office sees no buttons. Expect
    `FAILURES: none`. `operator_e2e.py` answers the badge-out question when it comes and clicks the first of two «badge di uscita»
    items; `v103_e2e.py` clicks the reprint search result (the morning box can name the same lot).

Last run 15/10/2026 (v1.05), same setup with the 193 migrations, all 23 suites in a row (the 22 above, with v105_e2e after v104_e2e
and alerts_e2e last): `FAILURES: none` in each, v105_e2e 18/18, v103_e2e 30/30.

28. `python3 v106_e2e.py` (v1.06, «Perché?»; port 8786, browser in it-IT) — Configurazione → Bot as the titolare: «Perché?» only under
    the messages with data; the milk plan opens «Perché 900 kg di latte per ven 16/10» with its steps, the cost, the number check naming
    the invented number («lo vede solo chi gestisce il sistema») and «Dati grezzi»; a second tap hides it; on a phone (390 px) nothing
    scrolls sideways. Console → Oggi «Avvisi aperti» as the cheesemaker: the food-safety alarm's «Perché?» with the CCP values, no raw
    data, no check. `console.html#oggi&perche=<id>` (the Telegram link) opens it as a sheet, Esc closes it and the address goes back to
    #oggi; a marketing profile gets «Il tuo profilo non vede questo messaggio». Expect `FAILURES: none` (12 checks).

29. `python3 v107_e2e.py` (v1.07, «Prima dell'avvio»; port 8787) — Console → Oggi «Conformità ieri» as the titolare: when the brief says
    `pre_opening` the card says the day's HACCP checks are not asked, as a grey status line (not red, not counted as a problem) and with
    no «Controllo mancante» line; without `pre_opening` the line is not there. The earlier suites leave real lots and milk in
    restore_drill, so the page gets the database's own brief with `pre_opening` added on the first load (what the database sends on a
    quiet day is covered by prod-test/test_v107_quiet.sql). Expect `FAILURES: none` (5 checks).

30. `python3 v108b_e2e.py` (v1.08b, the app moves to https://app.bubalina.it) — both addresses are served from the local files through
    Playwright routes, so nothing reaches Netlify, GitHub or Supabase; the new address's `sw.js` is served as v74 («before the
    approval»), not at all («offline») or v75 («ready»). Before the approval and offline nothing moves and no bar shows. Once ready, a
    Console page on the old address goes to the same page on app.bubalina.it with ?query and #hash; the tablet with nothing waiting goes
    at once as the same tablet (name and id carried, the id taken on the new address and removed from the address bar); with records
    waiting it stays and says what is waiting, does not move by itself after they are sent, and moves on a tap of «Passa al nuovo
    indirizzo»; a refused save (even one reported) and a photo hold it back; a Console page with a record waiting stays and keeps the
    old address's cache; `//other-site/index.html` still lands on app.bubalina.it; on the new address an id there is kept while that
    address has work waiting, else replaced. Expect `FAILURES: none` (18 checks).
31. `python3 v109_e2e.py` (v1.09 «Persone») — against restore_drill with v109a and PostgREST on :3000, with the REAL server functions
    `invite-user` and `welcome` run by Deno (DENO=…) behind a small fake Supabase on :8791 that forwards /rest/v1 to PostgREST and plays
    the auth admin API on auth.users. People as cards with the checklist, fitting a phone; «Aggiungi una persona» shows the access link
    with the WhatsApp and e-mail messages (company, expiry date, the profile's page); the same e-mail again; the job role follows the
    profile and Titolare asks; «Cambia email» changes the login too; a password link for someone with a password; the welcome page:
    greeting, password checks, a password Supabase finds too common, save → login created and linked, Telegram, the profile's page, the
    link used and replaced; «Disattiva» lists, then closes shift and future rota and blocks the login, with a summary; «Riattiva»;
    «Cambia password» in a casaro's menu; the rota editor (night shift only when ticked, break, area, «Anche questi giorni», riposo,
    saved and shown again, the week label, the unsaved-week question); review fixes: an e-mail that is someone else's login is refused
    when adding, and a link made by hand for it cannot set that login's password; a dead link tells nothing about the person; the link
    leaves the address bar at once; a «nuova password» link sets the same login; «Cambia password» with the right password.
    Expect `FAILURES: none` (43 checks).

Last run 15/10/2026 (v1.07), same setup with the 197 migrations, all 25 suites in the usual order (the 24 above with v106_e2e after
v105_e2e, then alerts_e2e, then v107_e2e; resumed after sync_e2e on the same database once the local server restarted):
`FAILURES: none` in each, v107_e2e 5/5.
32. `python3 v110_e2e.py` (v1.10 «Sicurezza e salvataggi»; pages on :8789, fake Supabase on :8792, the REAL `invite-user` and `welcome`
    under Deno on :8803/:8804) — the quality test of 20/10/2026: a CCP reading whose reply is lost after the database wrote it is
    written once (the old app wrote 2 rows); with the storage full an offline save says «Memoria del tablet piena», not «Salvato offline»;
    a product name with HTML is shown as text in «Arrivo merce»; Autocontrollo «Correggi» reads «1.050» kg as 1050; a socio sees
    the app's address as text in Configurazione, the titolare can edit it; with the setting naming another site the access link is
    still on app.bubalina.it; a password refused for its kinds of character says so; «Cambia email» moves a login left on the old
    address; the welcome page with no link says where links come from. Expect `FAILURES: none` (13 checks). Run it after v109_e2e.
