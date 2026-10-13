#!/usr/bin/env bash
# v1.00 (audit E-24, E-25): nightly off-site copy of the backup, run by .github/workflows/offsite-backup.yml.
# The backups live in the same Supabase project they protect; this keeps an encrypted copy on GitHub for 90 days.
#
#   offsite_backup.sh prepare      pick tonight's backup (after 21:30 Rome: today's, before: yesterday's); if GitHub already
#                                  keeps a copy of it, stop (skip=1: the workflow runs three times a night because GitHub
#                                  skips scheduled runs). Otherwise fetch it (backup-export, fetch mode), check its sha256,
#                                  gzip, JSON and age, encrypt it (AES-256, passphrase BACKUP_PASSPHRASE), prove it decrypts
#                                  back to the same bytes, write $OUT/caseificio-backup-<day>.json.gz.enc + manifest.json.
#                                  The plain copy stays in $OUT/backup.json.gz for the drill; the workflow deletes it.
#                                  drill=1 when asked (DRILL=true) or when GitHub keeps no drill of this month yet.
#   offsite_backup.sh report-ok    tell the database the copy is kept (board check «Off-site backup copy»)
#   offsite_backup.sh report-fail  tell the database that the copy failed; the partners' Telegram group too on the night's
#                                  last try (LAST_TRY=true) — earlier tries are retried by the next slot
#   offsite_backup.sh drill        restore drill on the plain copy (Postgres 16, root), recorded as «Backup restore tested»;
#                                  the full log is kept only encrypted ($OUT/drill/*.enc): a failed restore can print rows
#   offsite_backup.sh drill-check  after a failed job: record a drill that never got to run
#
# Needs BACKUP_EXPORT_TOKEN (= the Vault secret backup_export_token) and BACKUP_PASSPHRASE; GH_TOKEN + GITHUB_REPOSITORY
# (set by the workflow) to look up the copies already kept. Never prints a secret or a row of the backup.
# To open a copy:  openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -md sha256 -in caseificio-backup-<day>.json.gz.enc -out backup.json.gz
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
SB="${SB:-https://ojkquhzaeypsphncjqwy.supabase.co}"
KEY="${KEY:-sb_publishable_Kl7c4NqV44tjDYs6IbpA0Q_S5ENoKq3}"   # publishable key (fabula-tablet/config.js)
OUT="${OUT:-offsite}"
MAX_AGE_HOURS="${MAX_AGE_HOURS:-30}"
CIPHER=(-aes-256-cbc -pbkdf2 -iter 600000 -md sha256)
ACTION=${1:-prepare}
mkdir -p "$OUT"

fail() { echo "::error::$1"; echo "$1" > "$OUT/error.txt" 2>/dev/null; exit 1; }
out() { [ -n "${GITHUB_OUTPUT:-}" ] && echo "$1" >> "$GITHUB_OUTPUT"; echo "$1"; }
telegram() { bash "$HERE/../watch/telegram.sh" "$1" || true; }

report() {   # $1 kind, $2 detail json · returns 1 when the database did not take it
  [ -n "${BACKUP_EXPORT_TOKEN:-}" ] || return 1
  local body; body=$(jq -nc --arg t "$BACKUP_EXPORT_TOKEN" --arg k "$1" --argjson d "$2" '{p_token: $t, p_kind: $k, p_detail: $d}')
  local code; code=$(curl -s -o /dev/null -w '%{http_code}' -m 30 -X POST "$SB/rest/v1/rpc/fabula_outside_report" \
    -H "apikey: $KEY" -H "Content-Type: application/json" -d "$body")
  [ "$code" = "200" ] || [ "$code" = "204" ] && return 0
  echo "::warning::il database non ha registrato l'esito ($code)"; return 1
}

kept() {   # $1 artifact name → 0 if GitHub keeps a non-expired artifact with that name (any run)
  [ -n "${GH_TOKEN:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ] || return 1
  local n; n=$(curl -s -m 30 -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" \
    "${GITHUB_API_URL:-https://api.github.com}/repos/$GITHUB_REPOSITORY/actions/artifacts?name=$1&per_page=20" \
    | jq '[.artifacts[]? | select(.expired == false)] | length' 2>/dev/null)
  [ "${n:-0}" -gt 0 ] 2>/dev/null
}

case "$ACTION" in
prepare)
  [ -n "${BACKUP_EXPORT_TOKEN:-}" ] || fail "manca il segreto BACKUP_EXPORT_TOKEN (GitHub → Settings → Secrets → Actions)"
  [ -n "${BACKUP_PASSPHRASE:-}" ] || fail "manca il segreto BACKUP_PASSPHRASE (GitHub → Settings → Secrets → Actions)"
  [ ${#BACKUP_PASSPHRASE} -ge 20 ] || fail "BACKUP_PASSPHRASE troppo corta: almeno 20 caratteri"
  rm -rf "$OUT"/*.enc "$OUT"/*.json "$OUT"/*.gz "$OUT"/*.txt "$OUT"/*.log "$OUT"/drill
  # tonight's backup is written at 21:15 Rome: before 21:30 the latest one is yesterday's
  if [ -n "${DAY:-}" ]; then day=$DAY
  elif [ "$(TZ=Europe/Rome date +%H%M)" -ge 2130 ]; then day=$(TZ=Europe/Rome date +%F)
  else day=$(TZ=Europe/Rome date -d '-1 day' +%F); fi
  prev=$(date -d "$day -1 day" +%F)
  if kept "caseificio-backup-$day"; then echo "La copia del backup del $day è già su GitHub: niente da fare."; out "skip=1"; exit 0; fi
  got=
  for d in "$day" "$prev"; do
    code=$(curl -s -o "$OUT/fetch.json" -w '%{http_code}' -m 120 -X POST "$SB/functions/v1/backup-export" \
      -H "x-backup-token: $BACKUP_EXPORT_TOKEN" -H "Content-Type: application/json" \
      -d "{\"mode\":\"fetch\",\"path\":\"backups/daily/$d.json.gz\"}")
    if [ "$code" = "200" ]; then got=$d; break; fi
    echo "backups/daily/$d.json.gz: risposta $code"
    rm -f "$OUT/fetch.json"
    # tonight's file is missing and last night's is already kept: nothing new to copy. The outside watcher alerts on
    # the missing nightly backup; here the board just shows it.
    if [ "$d" = "$day" ] && kept "caseificio-backup-$prev"; then
      echo "::warning::il backup di stanotte ($day) non c'è; la copia del $prev è già su GitHub"
      report offsite_backup "$(jq -nc --arg s "backup di stanotte ($(date -d "$day" +%d/%m)) non trovato: ultima copia quella del $(date -d "$prev" +%d/%m)" --arg u "${RUN_URL:-}" '{ok: false, summary: $s, run_url: $u}')" || true
      out "skip=1"; exit 0
    fi
  done
  [ -n "$got" ] || fail "backup notturno non trovato (né $day né il giorno prima): il backup del database non gira?"
  stale=false
  if [ "$got" != "$day" ]; then stale=true; echo "::warning::il backup di stanotte ($day) non c'è: copio quello del $got"; fi
  jq -r .b64 "$OUT/fetch.json" | base64 -d > "$OUT/backup.json.gz" || fail "risposta del backup non leggibile"
  want=$(jq -r .sha256 "$OUT/fetch.json"); rm -f "$OUT/fetch.json"
  have=$(sha256sum "$OUT/backup.json.gz" | cut -d' ' -f1)
  [ "$want" = "$have" ] || fail "sha256 diverso da quello del server: copia scartata"
  gzip -t "$OUT/backup.json.gz" 2>/dev/null || fail "file del backup danneggiato (gzip)"
  meta=$(gunzip -c "$OUT/backup.json.gz" | jq -c '{exported_at, mode, rome_day, tables: (.tables | length), rows: ([.tables[] | length] | add)}' 2>/dev/null) \
    || fail "il backup non è un JSON valido"
  exported=$(echo "$meta" | jq -r .exported_at)
  age_h=$(( ($(date +%s) - $(date -d "$exported" +%s)) / 3600 ))
  [ "$age_h" -le "$MAX_AGE_HOURS" ] || fail "il backup più recente ha $age_h ore (esportato $exported)"
  enc="$OUT/caseificio-backup-$got.json.gz.enc"
  openssl enc "${CIPHER[@]}" -salt -in "$OUT/backup.json.gz" -out "$enc" -pass env:BACKUP_PASSPHRASE || fail "cifratura non riuscita"
  back=$(openssl enc -d "${CIPHER[@]}" -in "$enc" -pass env:BACKUP_PASSPHRASE | sha256sum | cut -d' ' -f1)
  [ "$back" = "$have" ] || fail "la copia cifrata non si riapre uguale: scartata"
  bytes=$(stat -c %s "$OUT/backup.json.gz")
  jq -n --arg day "$got" --argjson m "$meta" --arg sha "$have" --argjson bytes "$bytes" --arg encsha "$(sha256sum "$enc" | cut -d' ' -f1)" --argjson stale "$stale" \
    '{day: $day, stale: $stale, exported_at: $m.exported_at, mode: $m.mode, tables: $m.tables, rows: $m.rows, bytes: $bytes,
      sha256_plain_gz: $sha, sha256_encrypted: $encsha,
      cipher: "openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -md sha256 (passphrase: GitHub secret BACKUP_PASSPHRASE, also in the password manager)",
      open_with: "openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -md sha256 -in <file>.enc -out backup.json.gz"}' > "$OUT/manifest.json"
  kb=$(( (bytes + 1023) / 1024 ))
  summary="backup $(date -d "$got" +%d/%m)$([ "$stale" = true ] && echo " (quello di stanotte mancava)") (esportato $(TZ=Europe/Rome date -d "$exported" +%H:%M)) · ${kb} KB · $(echo "$meta" | jq -r .tables) tabelle, $(echo "$meta" | jq -r .rows) righe · copia cifrata su GitHub (90 giorni)"
  echo "$summary" > "$OUT/summary.txt"
  out "skip=0"
  out "day=$got"
  month=${got:0:7}; out "month=$month"
  # restore drill: when asked, or once a month (the first copy of a month that has no drill kept on GitHub)
  if [ "${DRILL:-false}" = "true" ] || ! kept "caseificio-drill-$month"; then out "drill=1"; else out "drill=0"; fi
  echo "$summary"
  ;;
report-ok)
  summary=$(cat "$OUT/summary.txt" 2>/dev/null || echo "copia fuori sede fatta")
  m=$(cat "$OUT/manifest.json" 2>/dev/null || echo null)
  report offsite_backup "$(jq -nc --arg s "$summary" --arg u "${RUN_URL:-}" --argjson m "$m" '{ok: true, stale: ($m.stale // false), summary: $s, run_url: $u, manifest: $m}')" || true
  ;;
report-fail)
  why=$(cat "$OUT/error.txt" 2>/dev/null || echo "errore imprevisto: vedi il log su GitHub")
  report offsite_backup "$(jq -nc --arg s "copia fuori sede non riuscita: $why" --arg u "${RUN_URL:-}" '{ok: false, summary: $s, run_url: $u}')" || true
  if [ "${LAST_TRY:-true}" = "true" ]; then
    telegram "$(printf '⚠️ Caseificio: la copia notturna del backup fuori da Supabase non è riuscita.\n\n%s\n\nNon serve fare nulla al banco. Nick: GitHub → Actions → «Off-site backup».%s' "$why" "${RUN_URL:+

$RUN_URL}")"
  else echo "Non è l'ultimo tentativo della notte: riprova il prossimo giro (Telegram solo all'ultimo)."; fi
  ;;
drill)
  # needs root and Postgres 16 (the workflow sets them up); builds an empty database from the migrations and restores into it
  log="$OUT/drill.log"; month=$(jq -r '.day[0:7]' "$OUT/manifest.json" 2>/dev/null); day=$(jq -r .day "$OUT/manifest.json" 2>/dev/null)
  if [ ! -s "$OUT/backup.json.gz" ] || [ -z "$day" ]; then
    mkdir -p "$OUT/drill"; touch "$OUT/drill/reported"
    report restore_drill "$(jq -nc --arg u "${RUN_URL:-}" '{ok: false, summary: "Prova di ripristino su GitHub", error: "copia del backup non trovata sul server di GitHub", run_url: $u}')" || true
    echo "::error::copia del backup non trovata: prova non fatta"; exit 1
  fi
  bash "$REPO/tools/go-live/drill/run_drill.sh" "$OUT/backup.json.gz" > "$log" 2>&1; rc=$?
  # the raw log can hold rows of the backup (a failed INSERT prints them): only these lines are shown
  safe=$(grep -E '^(== [0-9]|migration failures: [0-9]+$|bootstrap failed$|restore failed$|loaded in |OK · [0-9]+ tables|NOTICE:  foreign keys checked: |NOTICE:  orphans: [a-z_.]+ → [a-z_.]+ \([0-9]+ rows\)$|ops_dashboard\(\) on the restored copy: )' "$log" \
    | sed -E 's/^NOTICE:  //')
  failed_migr=$(grep -oE '^FAIL [0-9]+_[A-Za-z0-9_]+\.sql' "$log" | head -3 | sed 's/^FAIL //' | paste -sd, -)
  echo "$safe"; [ -z "$failed_migr" ] || echo "migrazioni non riuscite: $failed_migr"
  mkdir -p "$OUT/drill"
  if [ -n "${BACKUP_PASSPHRASE:-}" ]; then
    openssl enc "${CIPHER[@]}" -salt -in "$log" -out "$OUT/drill/caseificio-drill-$month.log.enc" -pass env:BACKUP_PASSPHRASE \
      && echo "log completo cifrato: artifact caseificio-drill-$month (si apre come le copie del backup)"
  fi
  rm -f "$log"
  tables=$(grep -oE 'OK · [0-9]+ tables · row counts match the backup' <<< "$safe" | head -1)
  orphans=$(grep -oE 'foreign keys checked: [0-9]+, with orphans: [0-9]+' <<< "$safe" | head -1)
  dash=$(grep -c "ops_dashboard() on the restored copy: OK" <<< "$safe")
  when=$(TZ=Europe/Rome date +%d/%m/%Y); of=$(date -d "$day" +%d/%m)
  touch "$OUT/drill/reported"
  if [ $rc -eq 0 ] && [ -n "$tables" ] && echo "$orphans" | grep -q 'with orphans: 0$' && [ "$dash" -ge 1 ]; then
    n=$(echo "$tables" | grep -oE '[0-9]+' | head -1)
    report restore_drill "$(jq -nc --arg s "Prova di ripristino su GitHub ($when) del backup del $of: $n tabelle, righe uguali al backup, 0 righe orfane" --arg u "${RUN_URL:-}" '{ok: true, summary: $s, run_url: $u}')" || true
    echo "prova di ripristino riuscita"
  else
    if [ -n "$failed_migr" ]; then err="migrazioni non riuscite sul database vuoto: $failed_migr"
    elif grep -q '^bootstrap failed$' <<< "$safe"; then err="Postgres di prova non preparato (bootstrap)"
    elif grep -q '^restore failed$' <<< "$safe"; then err="il backup non si carica nel database vuoto (dettagli nel log cifrato)"
    elif [ -z "$tables" ] && grep -q 'loaded in' <<< "$safe"; then err="righe diverse dal backup dopo il ripristino"
    elif [ -n "$orphans" ] && ! echo "$orphans" | grep -q 'with orphans: 0$'; then err="righe orfane dopo il ripristino ($orphans)"
    elif [ "$dash" -lt 1 ] && [ -n "$tables" ]; then err="la board (ops_dashboard) non gira sulla copia ripristinata"
    else err="esito non riconosciuto (codice $rc): vedi il log cifrato"; fi
    # the database turns the failed drill into a bot message (topic infra); Telegram from here only if it can't
    report restore_drill "$(jq -nc --arg s "Prova di ripristino su GitHub ($when) del backup del $of" --arg e "$err" --arg u "${RUN_URL:-}" '{ok: false, summary: $s, error: $e, run_url: $u}')" \
      || telegram "$(printf '⚠️ Caseificio: la prova mensile di ripristino del backup non è riuscita.\n\n%s\n\nI backup ci sono, ma vanno controllati. Nick: GitHub → Actions → «Off-site backup».' "$err")"
    echo "::error::prova di ripristino non riuscita: $err"; exit 1
  fi
  ;;
drill-check)
  [ -f "$OUT/drill/reported" ] && exit 0
  err="la prova non è partita (Postgres di prova non pronto sul server di GitHub)"
  report restore_drill "$(jq -nc --arg s "Prova di ripristino su GitHub ($(TZ=Europe/Rome date +%d/%m/%Y))" --arg e "$err" --arg u "${RUN_URL:-}" '{ok: false, summary: $s, error: $e, run_url: $u}')" \
    || telegram "$(printf '⚠️ Caseificio: la prova mensile di ripristino del backup non è partita.\n\n%s\n\nNick: GitHub → Actions → «Off-site backup».' "$err")"
  ;;
*) echo "usage: $0 prepare|report-ok|report-fail|drill|drill-check"; exit 2 ;;
esac
