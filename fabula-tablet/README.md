# Fabula tablet — app di scansione per il caseificio

Static PWA (no build step). Vanilla JS + supabase-js + html5-qrcode. Works offline: writes queue in the browser and flush when the network is back.

## Files
- `index.html`, `app.js` — the app (Italian UI, one screen per scan point from SOP-01)
- `config.js` — Supabase URL + publishable key + device name (edit this)
- `labels.html` — prints the QR labels for equipment, cleaning sign, meter
- `manifest.json`, `sw.js`, `icon.svg` — PWA shell

## Setup (once)
1. **Create the Supabase project** (eu-central / Frankfurt is closest to Agropoli).
2. **Apply the migrations** in order: `../supabase/migrations/20261001_fabula_core_schema.sql`, then `20261002_fabula_sop_capture.sql` (SQL editor, or `supabase db push`).
3. **Expose the schema to the API**: Project Settings → API → *Exposed schemas* → add `fabula`.
4. **Storage**: create a private bucket named `documents` (DDT and Z-report photos go there).
5. **Users**: Authentication → add one email/password user per partner/operator. Then insert a `fabula.staff` row per user with `auth_user_id` = that user's id, e.g.
   ```sql
   insert into fabula.staff (auth_user_id, full_name, role, badge_code)
   values ('<uuid from auth.users>', 'Giuseppe', 'casaro', 'STAFF:GIU');
   ```
6. **Milk supplier**: insert Masseria Cilentana into `fabula.parties` with `is_milk_supplier = true` (the milk form lists only those).
7. **Daily tasks cron**: Database → Cron (pg_cron) →
   `select cron.schedule('fabula_tasks', '0 5 * * *', $$select fabula.generate_daily_tasks()$$);`
   and, once sensors exist, `select cron.schedule('fabula_sensors', '0 */12 * * *', $$select fabula.rollup_sensor_haccp()$$);`
8. **Edit `config.js`** with the project URL and publishable key.
9. **Host** the folder anywhere static over HTTPS (camera needs HTTPS): Netlify drop, Cloudflare Pages, GitHub Pages, or Supabase Storage public bucket. 
10. On the tablet/phone: open the URL in Safari/Chrome → *Add to Home Screen*. Allow camera on first scan.
11. Open `labels.html`, print the QR sheet, stick the labels on the machines, the lab door (CLEAN) and the meter.

## QR payload formats
| Code | Where | What the app does |
|---|---|---|
| `EQ:CF-01` | on each machine | temperature check → `haccp_log` (+ non-conformity if out of range), closes the task |
| `EQ:RT-01` | on the till | Z report total → `pos_daily_closings` |
| `CLEAN` | lab door | cleaning checklist → `haccp_log` PRP-CLEAN |
| `METER:elec_main` | meter | reading → `meter_readings` |
| `DDT:<numero>` | on the milk DDT (or typed) | milk intake form → `milk_intake` + milk lot label |
| `LOT:<lotto latte>` | milk lot label | 1st scan: start batch (creates `L<yyyymmdd>-A`), 2nd scan: end batch (kg out, yield, stock, labels) |
| `LOT:<lotto prodotto>` | finished-goods label | counter sale (`sales_orders` + stock out) or shipment (`shipments` + lines) |

If a code is not printed yet, type it in the field under the camera.

## Security note
RLS policies in v0.1/v0.2 allow any authenticated user to read/write everything. Fine for a 3-person team; tighten per role before adding seasonal staff.
