# Fabula tablet — app di scansione per il caseificio

Static PWA (no build step). Vanilla JS + supabase-js + html5-qrcode, both vendored in `vendor/` and cached by the service worker, so the app also starts with no internet.

Offline start (v0.59): the last profile seen on each device is saved per user, so the tablet opens with no network (even with an expired login); the first login on a device still needs internet. Startup calls give up after a few seconds instead of waiting ~50 s for supabase-js to retry the login.

Offline queue (v0.39): writes queue in the browser and flush when the network is back (and every minute). Every insert carries an id generated on the tablet, so a re-send after a lost reply never duplicates a record. Records the database refuses are set aside ("N rifiutate dal database" — tap the line to see the first error, tap again within 5 s to discard them) instead of retrying forever. Expired logins are refreshed before re-sending.

Atomic saves (v0.62): a save with several steps (scan event + rows + RPCs: milk intake, batch start/close, shipment, goods receipt, effluent…) runs on the server in one transaction through `fabula.save_ops(p_ops, p_qid)`: every step is written or none ("Passo 3 di 4 (stock_moves): …" says which one was refused). The queue id travels with the save, so a re-send after a lost reply returns the first result instead of writing again (also for single dosing/step/CCP RPCs). The queue is sent strictly in order and stops at the first network failure, so a batch's steps never reach the database before the batch. A save made online while older records are still queued waits behind them.

Offline lots (v0.62): recent milk lots (10 days), open and recent batches, their milk inputs and done steps, products, recipes and process presets are kept on the device (after login, after online saves, after each flush, every 5 minutes); whatever is still in the queue is laid over that copy. So with no network, or Wi-Fi without internet, a milk lot received offline can start a batch, run its dosing and process steps and close it; all of it is sent in order when the network is back. Still online-only: direct shipment from a closed lot, closing a ricotta started offline, stock count, packing orders.

Several tablets: open the app once with `?device=tablet-2` (remembered on that device) so scans show which tablet recorded them.

## Files
- `index.html`, `app.js` — the app (Italian UI, one screen per scan point from SOP-01)
- `config.js` — Supabase URL + publishable key + device name (edit this)
- `labels.html` — prints QR labels: equipment, cleaning sign, meter, badges (`STAFF:…`), station codes (`DDT:`, `COUNT`, `SHIP`, `EFFL`, `HACCP:`), lot labels via `?code=LOT:…&name=…&sub=…&n=…` (opened by the tablet after milk intake and batch close), lab-sample labels (v0.53) and any list via repeated `?l=CODE|Nome|Nota` (Configurazione › Utenti uses it for badges)
- `haccp.html`, `haccp.js` — Sicurezza alimentare console; tab Registri (v0.57) lists the Manuale di Autocontrollo forms MOD-01…MOD-23
- `registro.html`, `registro.js` — printable HACCP register of one MOD form for a period, with the manual header and signature box; `&blank=1` = empty paper form (v0.57)
- `console.html`, `console.js` — owner console (Oggi · Operazioni · Andamento · Anagrafiche · Ricette · Personale)
- `admin.html`, `admin.js` — Configurazione (Parametri · Macchine e scadenze · Prodotti Shopify · Bot · Utenti e accessi · Registro modifiche)
- `ui.js`, `ui.css` — shared shell for console and Configurazione since v0.51: login, header (page links, Bot bell, user menu with hide-hints and logout), lazy tabs with #hash, formatting helpers, unsaved-change guard (edited rows turn orange, Enter saves, leaving asks first)
- `manifest.json`, `sw.js`, `icon.svg` — PWA shell

## Setup (once)
1. **Create the Supabase project** (eu-central / Frankfurt is closest to Agropoli).
2. **Apply the migrations**: `supabase link --project-ref <ref>` then `supabase db push` from the repo root (all files in `../supabase/migrations`, in version order; the first one switches on pg_cron, pg_net, pgcrypto and uuid-ossp).
3. **Expose the schema to the API**: Project Settings → API → *Exposed schemas* → add `fabula`.
4. **Storage**: create a private bucket named `documents` (DDT and Z-report photos go there).
5. **Users**: Authentication → add one email/password user per partner/operator. Then insert a `fabula.staff` row per user with `auth_user_id` = that user's id, e.g.
   ```sql
   insert into fabula.staff (auth_user_id, full_name, role, badge_code)
   values ('<uuid from auth.users>', 'Giuseppe', 'casaro', 'STAFF:GIU');
   ```
6. **Milk supplier**: insert Masseria Cilentana into `fabula.parties` with `is_milk_supplier = true` (the milk form lists only those).
7. **Daily tasks cron**: Database → Cron (pg_cron) →
   `select cron.schedule('fabula_daily_tasks', '0 4 * * *', $$select fabula.generate_daily_tasks()$$);` (UTC — already scheduled on the live project)
   and, once sensors exist, `select cron.schedule('fabula_sensors', '0 */12 * * *', $$select fabula.rollup_sensor_haccp()$$);`
8. **Edit `config.js`** with the project URL and publishable key.
9. **Host** the folder anywhere static over HTTPS (camera needs HTTPS): Netlify drop, Cloudflare Pages, GitHub Pages, or Supabase Storage public bucket. 
10. On the tablet/phone: open the URL in Safari/Chrome → *Add to Home Screen*. Allow camera on first scan.
11. Open `labels.html`, print the QR sheet, stick the labels on the machines, the lab door (CLEAN) and the meter.

## QR payload formats
| Code | Where | What the app does |
|---|---|---|
| `EQ:CF-01` | on each machine | temperature check → `haccp_log` (+ non-conformity if out of range), closes the task |
| `EQ:RT-01` | on the till | read-only: "La cassa è Shopify POS" with today's synced total (the Ordini Shopify bot closes the day) |
| `CLEAN` | lab door | cleaning checklist → `haccp_log` PRP-CLEAN |
| `METER:elec_main` | meter | reading → `meter_readings` |
| `DDT:<numero>` or `DDT:` | on the milk DDT, or the station QR at the intake point (v0.53: the DDT number is typed in its own field) | milk intake (temperature CCP 1a, antibiotic test CCP 1b) → `milk_intake` + milk-lot label, printable from the result card (v0.52) |
| `LOT:<lotto latte>` | milk lot label | 1st scan: start batch (creates `L<yyyymmdd>-A`); then scan the batch lot for the working steps and the close (kg out, yield, stock, printable lot labels) |
| `LOT:<lotto prodotto>` | finished-goods label | open batch → working steps / close · closed batch → direct shipment without an order. Counter sales are on Shopify POS; orders are packed from 🚚 Da spedire |

If a code is not printed yet, type it in the field under the camera.

## Security
Since v0.37 every table has row-level security per access profile (Configurazione → Utenti e accessi). Anonymous users can read or call nothing.
