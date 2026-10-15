# Production autopilot test (v0.70)
```
tools/go-live/drill/infra-test/replay.sh prod_test
su postgres -c "psql -d prod_test -f tools/go-live/drill/prod-test/test_production_plan.sql" | grep -E "PASS|FAIL"
```
Run once per fresh replay. Checks `fabula.production_plan()`: only accepted milk with kg left, oldest first; equal vat loads
(1,150 kg → 2 × 575, 1,700 kg → 3 loads); product, default preset, 30 % default yield, recipe doses, whey/ricotta, 60 h
DOP deadline, milk-plan target, open batches, today's output; a started batch takes its milk out of the plan. Yield check
at close: expected yield stored, low/high flag and one message (not repeated on edits, cleared when corrected), simulation
batches skipped; expected yield learns from the preset's batches; ricotta default; grants. 05/10/2026: 19/19 PASS.
The tablet side is `tablet-test/prod_e2e.py`.

# Packing on autopilot test (v0.71)
```
tools/go-live/drill/infra-test/replay.sh pack_test
su postgres -c "psql -d pack_test -f tools/go-live/drill/prod-test/test_packing.sql" | grep -E "PASS|FAIL"
```
Stock A (expires tomorrow), B (in 4 days), C (on hold), X (expired); orders S1 online late, W1 wholesale today, W2 tomorrow.
Checks packing order, FEFO allocation with the online shelf-life minimum, split over lots, no double promise (W2 short),
blocked lots with reasons, the pick list; pack_order refuses held/expired even with confirm, asks to confirm short life /
short stock / weight with reasons, saves on confirm and notes it, gives a guest order a consignee. 05/10/2026: 14/14 PASS.

# Production guard rails test (v0.80)
```
tools/go-live/drill/infra-test/replay.sh guard_test
su postgres -c "psql -d guard_test -f tools/go-live/drill/prod-test/test_prod_guards.sql" | grep -E "PASS|FAIL"
```
`v_process_steps.ccp_code`; a batch closed without CCP 2/3 (mozzarella) or CCP 4 (ricotta) alerts once, a CCP logged in the
same transaction as the close counts, simulation batches skipped; `prod_watch` only at 19:xx Rome, open batches and milk
48 h old, one post a day; not callable by app users. 06/10/2026: 10/10 PASS.

# Audit fixes, phase 0 (v0.93)
```
tools/go-live/drill/infra-test/replay.sh audit_test     # one fresh replay per file: they add test rows
for t in food_safety weighed_sales task_times wholesale farm_shipments; do
  su postgres -c "psql -d audit_test -f tools/go-live/drill/prod-test/test_audit_$t.sql" | grep -E "PASS|FAIL"
done
```
- `test_audit_food_safety.sql`:
  - A CCP out of limit holds the lot for Banco/Spedizioni too; `log_ccp` is refused without haccp level 2.
  - A recall assessment stays pending (no expiry) and `ops_health_check` reports `recall_pending`.
  - Alerts sort first.
  - The CCP limit guard refuses a blank limit, min ≥ max, and alert thresholds outside the limits.
- `test_audit_weighed_sales.sql`:
  - A POS line with no variant but `sku` + `peso_kg` reduces stock by kg × quantity.
  - An unknown free sale goes to `shopify_unmapped_lines` and the rest of the order still syncs.
- `test_audit_task_times.sql`: daily task due times in Agropoli time in winter (CET) and summer (CEST); the default day is today in Agropoli.
- `test_audit_wholesale.sql`:
  - A change under the minimum order is refused with the reason.
  - Cut-off messages have no stray `s`.
  - «Salta» on a booked day cancels the order and its Shopify queue entry; another change there is refused.
  - A day under the minimum at booking is logged for the customer and posted to the Bot feed once.
  - `v_shipment_doc` has the delivery fields and keeps `security_invoker`.

12/10/2026: 18/18, 6/6, 4/4, 16/16 PASS. Before the fixes, 12 food-safety and 12 wholesale checks failed, the weighed sale
broke the sync and task times came out at 07:45/08:45 instead of 06:45.
- `test_audit_farm_shipments.sql` (v0.94a):
  - The farm corrects the kg of a load in transit, with a reason required; the first kg is kept and a Bot feed message is
    posted. A wrong token changes nothing.
  - The farm cancels a load, after which it can't be changed again. The farm page shows the cancellation and the
    correction.
  - The same kg re-entered after a cancel makes a new load.
  - A cancelled load is refused at intake with the reason; a received one is taken at the corrected kg and is locked
    for the farm.
  - The health check reports loads in transit for more than 36 h. Banco can't cancel; the owner must give a reason, then
    cancels and the report clears.
  - Grants.

  12/10/2026: 18/18 PASS; on v0.93 12 fail.
- `test_audit_s_items.sql` (v0.95, audit backlog items under an hour, High/Critical):
  - A-12: a queued check closes its task in the name sent with it.
  - B-02/B-05: lab outcome corrected with a reason (first outcome kept, NC and hold on a correction to NON conforme);
    sample lots upper-cased, unknown lots refused, milk lots (also with a space) accepted.
  - B-03: external calibration needs certificate + deviation or PDF, no future date; without deviation «da verificare», still
    out of service, due date unchanged; the register prints it.
  - B-04: review period cut at today, a future start refused, signed by the logged-in user.
  - D-03: a plain UPDATE lifting a hold is refused (app user and SQL); setting a hold is allowed; the release permission is
    used once and does not leak; hold changes audited.
  - D-09: a delivery cannot be over-drawn (+2 % allowed). D-12: impossible readings, empty CCPs and curd pH 52 refused; a real
    27 °C cold room recorded; sensor rows exempt; a CCP row without value does not count at batch close.
  - FARM-01: needs_confirm against today's order and, with no order, against the usual loads; confirmed loads recorded;
    under 50 kg refused; older callers (no p_confirm) unchanged; grants.
  - C-28, C-04 (time, day lists and ranges, fallback), E-20 (`bots_ok`), PRINT-03 (`company_docs_check`, street addresses).

  12/10/2026: 63/63 PASS on a fresh replay and on the database built by the SQL Editor script.
- `test_audit_critical.sql` (v0.96, the remaining Critical items):
  - A-04: a positive milk retest rejects the delivery and the farm load, writes off the raw milk left, holds the lots and the
    ricotta made from it (and a lot already held for another reason gets the milk reason added); the milk register shows the
    linked test; a delivery refused at arrival raises one alert.
  - A-03: a lot closed without CCP 2/3 is held, with the message saying so.
  - D-02: app users cannot UPDATE/DELETE the record tables; `correct_record` with reason and permission (own record within
    15 min, else level 3); a corrected value out of limit opens the NC and holds (a milk check rejects the delivery); a reading
    moved to another lot holds that lot, moves the NC, and holds the lot left without its CCP; open lots and delivery
    temperatures are not corrected directly; the register prints «CORREZIONE».
  - D-21: a second close refused with time and kg; one production output per lot.
  - A-01: PINs (own or by a manager, easy ones refused, bcrypt only, table unreadable), PIN check with tries left and 15-min
    lock, `floor_operators` without PIN data, badge in/out (a second scan does not clock out, offline time kept), operator +
    logged-in account on the record, the daily `operator_off_shift` check.
  - E-01: link codes (one use), default topics by profile, routing (HACCP responsible always for food safety; decisions wait
    for quiet hours; system at once to the owner), 3-hour dedupe, no push for warnings/simulations, the minute tick, claim
    (no double hand-out, skipped when taken or unlinked, failed after 5 tries), «Me ne occupo io» with edits, the 30-minute
    reminder (once; taking it takes the original), alert notices pushed once, NCs pushed, infra-first topics, blocked bot
    unlinked, settings, overview by permission, test message, `notify_failed`/`notify_stuck`, webhook bootstrap on first link.
  - FARM-02: over 2 % without a reason refused; with it both weights kept and the dairy's counts (stock too); within 2 % the
    farm's counts; the office notice; the farm page and its month total; MOD-01 prints both.

  13/10/2026: 89/89 PASS on a fresh replay and on the database built by the SQL Editor script.

# Audit floor flows (v0.97)
```
tools/go-live/drill/infra-test/replay.sh f_test
su postgres -c "psql -d f_test -f tools/go-live/drill/prod-test/test_audit_floor.sql" | grep -E "PASS|FAIL"
```
Task list (live overdue, today vs earlier, the 3-hour window, «Non fatta», 7-day close), follow-ups (cold room re-check, warm milk,
the 5-minute Telegram push, cleaning not done), offline times through `save_ops(p_client_at)` and the register line, a step without
a measurement keeps the pH, the next free lot letter, Italian errors, stock count against what the system holds at saving, 60 h DOP,
paper milk date, grants. 13/10/2026: 63/63 PASS.


# Audit numbers and limits (v0.98)
```
tools/go-live/drill/infra-test/replay.sh n_test
su postgres -c "psql -d n_test -f tools/go-live/drill/prod-test/test_audit_numbers.sql" | grep -E "PASS|FAIL"
```
Settings (range and unit refused with the name, comma, sì/no, dates, lists by value or label, yield min/max pair, a re-seed of an
existing key, `setting_num` on an unreadable value, the bell notice with who changed it, a bot shown as «Un bot o il sistema»), batch yield (above
the maximum refused, below the minimum needs `yield_note`, vat + 10 %, whey 95 %, simulations skipped), `correct_batch_milk` (milk
input, raw-milk adjustment, correction record, signed by the operator on a shared login, through `save_ops`), milk (rejected over CCP 1a by the
database, physical limits), recipe doses (×2 confirm + reason, 0 refused, units normalised, an item in a recipe keeps unit/active/
counted), dosing (negative, ×3/⅓ confirm, pack lot, closed lot), goods receipt (expired, 3× quantity, ±50 % price), farm page
limits, wholesale (step, the maximum for customers only and on increases only, «Confermi?» only with `can_confirm`, exceptions),
reserved prices and tiers, `trade_price` capped by the list. 13/10/2026: 89/89 PASS on a fresh replay and on the database built by
the SQL Editor script.

`test_audit_office.sql` (v0.99, audit office decisions and undo) — the milk-plan sync fix (whoever updates the approval), a decided
request can't be re-decided, re-signed or have its history wiped, a browser can't update approvals directly, `decide_approval`
(profile, «Approva con … kg», capacity, farm supply, recall and DOP notes), `revoke_approval` and what blocks it (farm saw it, order
sent or cancelled by hand, a newer order for the same items, promo posts out), deadlines (`expire_approvals`, the 10-minute cron,
messages and pushes), automatic approvals said and logged, promo posts in review, post edits refresh the card, DOP «Segna inviata»,
`milk_order_again`, catalogue orders (limit, «registra» profile, price to confirm always waits, a browser price ignored, creator),
`cancel_po`, the 7-day forecast and Vendite from the Ingrosso plans, recipes «Togli»/«Rimetti» (at once when put in today, no save on a
removed row), lot release (open or decided recall, conforming analysis), NC closing, B2B tiers (one kind, never € 0), the TRADE-06
dashboard line, and nothing new in the evening security check. 13/10/2026: 70/70 PASS on a fresh copy and on the database built by
the SQL Editor script (live-identical functions).

`test_audit_alerts.sql` (v1.00, audit alerts and operations) — names say what the bot does (nickname after, none for the database's
own senders), links only to the app's pages (an outside link replaced by the bot's page), the milk plan message opens its request and
closes when it is decided (and its Telegram stops reminding), the reminder keeps the link, read per person («Segna tutto» never an
alarm; another person still has it), «Risolto» (level 3 in Sistema, a note, signer from the login; nobody can PATCH a message; a
notice's copy is not closed by hand), a notice's copy closes with the notice, a failed run says what happens next and is not pushed
twice, notice audiences (floor / office) and links, the lot guard in Italian with a scan, trade requests without e-mails, the
incidents (missed, failed, never finished, scheduler stopped once per stoppage, a database job failing every minute = one incident
and one Telegram, a blip that recovered is not news, failing again reopens without a second Telegram, an incident that cleared
before it was sent is never sent, closed by itself saying how, older than a day), one open copy of the bots notice, the hourly job
runs the watchdog, the evening check's «già segnalato», a bot that failed is stood in for and its alarm closes, «Esegui ora»
(profile, only the stand-in bots, asks again the second time), refused saves (profiles, values without ids, HACCP flag, «Segna come
rifatta» with a note, the alarm closes when nothing is left for that tablet), the waiting-records date, grants and the security
check. 14/10/2026: 71/71 PASS on a fresh copy and on the database built by the SQL Editor script (live-identical functions).

`test_shopify_sync_digest.sql` (v1.02, audit E-18 Shopify sync in the database and E-07 morning summary / quiet nights) — the customer
copy (a list shorter than Shopify's count changes nothing, a repeat is refused, a mass disappearance deactivates nobody and lists
who is missing, a few within 5 % are deactivated, the old one-argument call still works, a browser cannot run the copy nor read the
function key nor call the sync), the order copy (count, total or a repeat that disagree write nothing; the rest as before, the POS
day closed), the clock (database jobs vs Claude tasks, the slot calls with the key, no second call within 20 minutes, one retry for a
call that never started and one for a failed run, a run in progress left alone, Sunday, switched off), one run at a time, the
messages written by the database (new customers are info, a refused copy is an error with the cause and no second Telegram, an
unlinked product then «(invariato)», a refused shipment, stock report-only then «(invariato)», a missing Shopify permission),
«Esegui ora» (profile, asks when it already ran or was just started, the name in the call), the watchdog incident text, the review
fixes (a run cut short is marked failed and called again, a call that never reached the function becomes a failed run with the
reason, the same alarm while open is «(invariato)» with no second Telegram, a stock failure with the push on is an alarm, backups
without the key), Telegram timing (a bot that did not start waits for the end of the silence, «system down» and food safety go now,
the scheduler stopped is urgent, a routine decision is «Da decidere» without reminder and says when it approves itself), the
summary (once a day at the person's time, before/after/twice, the sections, no buttons, across midnight, «Niente da segnalare»,
what a casaro may not see, an incident that cleared is not sent late, one still open is folded into the summary), the summary time
in Configurazione, and the security check. Run on a fresh replay. 14/10/2026: 43/43 PASS on a fresh copy and on the database built
by the SQL Editor script (live-identical functions).

`test_v103_security_labels.sql` (v1.03, audit C-05 secrets, FARM-04 the Masseria's two links, PRINT-08 lot labels) — the secret
settings (32 hex, the two farm keys differ; a counter login reads every other setting but no secret, also through `_setting` and
`setting_text`; not even the titolare reads, changes, adds or deletes one through the API; the format and «keys differ» checks from the
SQL editor; the Registro records a secret change with «••••» and other settings with their value; no old row keeps a value), the
customers' portal keys (not readable by a counter login, every other column still readable — a new column must be granted —, an
update asking every column back refused, the key changed only by «Nuovo link», the manager's link as before), `agent_runs` read-only
for logins, the farm (the office reminded once to print the new poster; «Chi spedisce» parsing; full link vs QR payload; each load
with who and which link, an older call without the name; the QR sees today's loads and corrects only its own within 2 hours, the
full link any load in transit, the office told who; «Visto» only from the full link; links only for Sistema = gestisce; «Genera nuovo
QR / link» switch the old key off, masked in the Registro, posted to the office), the lot labels (a closed lot's product, expiry and
copies; a lot still being worked, a milk lot, an unknown lot, other codes ignored; the reprint list order and search; with 90 lots the
list is cut after sorting; marketing sees but does not print; a reprint counted with who; no label row for a lot being worked, so its
close still inserts it; grants) and the security check. Run on a fresh replay. 14/10/2026: 28/28 PASS on a fresh copy and on the
database built by the SQL Editor script.

`test_v104_db_guards.sql` (v1.04, audit D-17 rest, D-22 + PRINT-04, D-26 rest, D-28, D-31, D-33) — paper copies (a sheet line copied
twice refused with when and how it was recorded, a different value or a later time accepted, a tablet reading then copied too
refused; a lot's check from the wrong day refused with the lot's times, within its time accepted, a ricotta lot started after the fact
keeps its line; a milk line copied twice for the same delivery refused), packing (50 kg for 5 refused even confirmed; 3 kg mozzarella
for 2 + 1 ricotta refused; a product not in the order refused; ricotta left out + 15 % asked with one reason per product; packed with a
DDT of the yearly series; «già preparato»), DDT numbers (the tablet's direct shipment and an older tablet's «DDT-<date>-4821» get the
next numbers; a job's own number kept; a new year starts at 0001; a login cannot renumber, delete, take a number, date a shipment in
another year or change its date later; the Rome date default), NCs (a floor login cannot lower the severity, rewrite the description,
change the lot once set or the opening date, but adds cause, action and a missing lot; the HACCP manager changes the severity, in the
Registro, and closes; a closed NC frozen, closing date included, until reopened; a login's new NC opened now and open), arrival checks
(«NON conforme» opens its NC linked to the receipt, cannot be re-checked «conforme», the same again opens nothing; dosing refuses the
isolated lot and asks for the lot without one, another lot recorded; the NC closed, the lot free; «conforme» later found non-conforming
opens an NC, the earlier check in the Registro), bank matching (an outgoing payment refused for a customer invoice, an order and a
payout; a second match of an invoice or order refused with where it is; an incoming payment refused for a supplier invoice; an invoice
paid otherwise refused; «importi diversi» after the typed note; after «Togli l'abbinamento» another movement can match), tasks (a cold
room calibration without a reading closes nothing; the morning reading closes the morning task, not the evening one; the only valve
check of the day counts from midnight; a task with no control point closes as before), permissions (an approval written approved or
set to approve itself; a PO from a login created approved or moved to approved; jobs still write approved POs; negative PO price) and
the security check. Run on a fresh replay. 15/10/2026: 50/50 PASS on a fresh replay and on the copy built by the SQL Editor script
(live-identical functions). `test_packing.sql` raises `ship.max_variance_pct` to 100 for its older checks (it forces 9 kg for 5);
`test_audit_floor.sql` writes each cold-room reading before closing its task (D-31) and takes the Rome day of a save made 25 minutes
ago (it failed just after midnight).

`test_v105_bots_ops.sql` (v1.05, audit E-06, E-09, E-14, E-16, E-17, E-19, E-27, E-28, E-30, E-31, E-32) — message rules (milk 48 h →
alarm and food-safety topic; a ruled database message takes the rule's severity, a bot's own keeps it; a rule without severity leaves it
to the function; a later update cannot lower it; notices too; the topic from the rule, and on title + body; every active staff member
reads the rules), alarms by area (marketing sees the sales alarm, not food safety nor the system's; the office sees all; the casaro the
food-safety one; a handled alarm leaves; an alarm notice counts in the bell of its area only), the system checks (drift in both
directions with the right remedy, in the feed copy too; Italian details; notice items get a label; database jobs missing or off named;
the Vault check; Panoramica → Sistema only with Sistema; the fingerprint), placeholders (one next step each, quoted by the evening check
and the standing orders), prompt versions (the old 7-argument call works; the drift lists old or missing versions, not the up-to-date
bot, a simulation or the database's own message under a bot's name; 11 versions, not the retired Shopify prompts), the briefs' changes,
the «Da verificare» lead, daily tasks (nothing before the start; Sunday and a closure: only cold rooms; a working Monday: everything; a
1st of the month on a Sunday → the monthly tasks on Monday the 2nd; a closed Monday → the weekly ones on Tuesday; a closed day's evening
list: cold rooms only), the evening list (yesterday's gaps as PAPER codes on yesterday's date with the lot; the Rome day; food safety
only; today's list live; a badge not passed from 19:00; the 19:02 notice; before the start only a day with production), the go-live
list (Italian labels and hints, no working notes; the office sees it, cannot sign; a note required; who and when kept; data-driven items
not tickable; no direct writes from a login; undo with a reason; the Registro; Nick's board still ticks) and the security check. Run on
a fresh replay. 15/10/2026: 62/62 PASS on a fresh replay and on the copy built by the SQL Editor script. Updated on purpose:
`test_audit_floor.sql`, `test_audit_s_items.sql` and `test_v104_db_guards.sql` set `prod.tasks_from` and no closing weekday (they
generate tasks for today and the days before); `test_prod_guards.sql` expects the 48 h milk as an alarm; `test_audit_critical.sql` R5
uses a notice that is an alarm by rule; `test_audit_alerts.sql` the 8-argument `post_bot_message`; `infra-test/test_infra.sql` and
`test_outside_watch.sql` read the Italian details.
