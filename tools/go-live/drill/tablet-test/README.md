# Tablet reliability tests (v0.62)

Runs the real tablet app (fabula-tablet) in headless Chromium against a local copy of the database with the real role
policies, so atomic saves, exactly-once re-sends and the offline flows can be checked without touching the live system.

1. `../run_drill.sh latest.json.gz` — builds `restore_drill` from every migration and loads a backup.
2. `su postgres -c "psql -d restore_drill -f setup.sql"` — test login (Test Casaro, role produzione) and auth stubs.
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
