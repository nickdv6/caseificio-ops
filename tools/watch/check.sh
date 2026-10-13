#!/usr/bin/env bash
# v0.78 outside watcher — runs on GitHub Actions (.github/workflows/watch.yml), independent of Supabase, the bots and Claude.
# Checks: tablet site serves the app · database answers (public.fabula_health) · pg_cron ran in the last 20 min ·
# nightly backup in the last 26 h · scheduled bots ran (v0.95) · edge function farm-order refuses a request without token (403).
# A failure is re-checked after 3 minutes; only a second failure counts.
# v1.00 (audit E-22):
#   - the nightly backup counts on its own (backup_nightly_ok): the 2-hourly «latest» no longer hides a broken nightly;
#   - a confirmed problem goes to the partners' Telegram group (tools/watch/telegram.sh): once per incident, again only
#     if the set of problems changes, or every 6 h while it lasts (not at night, 22–07 Rome); «tornato tutto OK» when two
#     checks 3 minutes apart are both clean. A message Telegram did not take is retried at the next run. The state between
#     runs lives in $STATE_FILE (kept by the workflow's cache): «status epoch signature», signature = the problem codes
#     (site, db, cron, backup, bots, farm_order), not their text, so a changing count does not look like a new incident;
#   - every run reports to the database (public.fabula_outside_report, with BACKUP_EXPORT_TOKEN), which raises its own
#     alarm when the watcher goes quiet for 24 h (GitHub skipping runs, or switching the schedule off after 60 days);
#   - the run still fails on a confirmed problem, so GitHub also e-mails the repo owner.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SITE="${SITE:-https://flourishing-swan-6729c4.netlify.app}"
SB="${SB:-https://ojkquhzaeypsphncjqwy.supabase.co}"
KEY="${KEY:-sb_publishable_Kl7c4NqV44tjDYs6IbpA0Q_S5ENoKq3}"   # publishable key, the same one shipped in fabula-tablet/config.js
STATE_FILE="${STATE_FILE:-.watch-state/state}"
REALERT_HOURS="${REALERT_HOURS:-6}"
# check: one line per problem, «code<TAB>message»
check() {
  local bad=()
  curl -fsS -m 20 "$SITE/sw.js" 2>/dev/null | grep -q "perla-v" || bad+=("site	sito tablet non risponde ($SITE)")
  local h; h=$(curl -fsS -m 20 -X POST "$SB/rest/v1/rpc/fabula_health" -H "apikey: $KEY" -H "Content-Type: application/json" -d '{}' 2>/dev/null)
  if [ -z "$h" ] || [ "$(echo "$h" | jq -r .db 2>/dev/null)" != "true" ]; then bad+=("db	database non risponde")
  else
    [ "$(echo "$h" | jq -r .cron_ok)" = "true" ] || bad+=("cron	automazioni del database (pg_cron) ferme da oltre 20 minuti")
    # v1.00: the nightly backup on its own when the database reports it (older databases: any backup)
    [ "$(echo "$h" | jq -r 'if has("backup_nightly_ok") then .backup_nightly_ok else .backup_ok end')" = "true" ] || bad+=("backup	nessun backup notturno riuscito nelle ultime 26 ore")
    # v0.95 (audit E-20): scheduled bots stopped. v1.00a: a bot stays «fermo» until it runs again. older databases pass.
    [ "$(echo "$h" | jq -r 'if has("bots_ok") then .bots_ok else true end')" = "true" ] || bad+=("bots	bot programmati fermi: $(echo "$h" | jq -r '.bots_missed // "?"') senza l'ultima esecuzione prevista (Claude non parte? controlla i connettori e le attività programmate)")
  fi
  local code; code=$(curl -s -o /dev/null -w "%{http_code}" -m 20 "$SB/functions/v1/farm-order?t=monitor")
  [ "$code" = "403" ] || bad+=("farm_order	funzione farm-order: risposta $code invece di 403")
  [ ${#bad[@]} -eq 0 ] || printf '%s\n' "${bad[@]}"
}
text_of() { cut -f2- <<< "$1"; }
sig_of() { cut -f1 <<< "$1" | sort -u | paste -sd, -; }

report() {   # $1 = true|false, $2 = summary · tells the database the watcher ran (it cannot when the database is down)
  [ -n "${BACKUP_EXPORT_TOKEN:-}" ] || return 0
  local body; body=$(jq -nc --arg t "$BACKUP_EXPORT_TOKEN" --argjson ok "$1" --arg s "$2" --arg u "${RUN_URL:-}" \
    '{p_token: $t, p_kind: "watcher", p_detail: {ok: $ok, summary: $s, run_url: $u}}')
  local code; code=$(curl -s -o /dev/null -w '%{http_code}' -m 20 -X POST "$SB/rest/v1/rpc/fabula_outside_report" \
    -H "apikey: $KEY" -H "Content-Type: application/json" -d "$body")
  case "$code" in 200|204) ;; 403|401) echo "::warning::il database ha rifiutato il resoconto ($code): BACKUP_EXPORT_TOKEN su GitHub è diverso dal segreto backup_export_token del Vault?" ;;
    404) echo "::warning::il database non conosce ancora fabula_outside_report (migrazione v1.00a non applicata)" ;;
    *) [ "$1" = false ] || echo "::warning::il database non ha registrato il giro del controllo ($code)" ;; esac
}

# alert state between runs: «status epoch signature»
mkdir -p "$(dirname "$STATE_FILE")"
prev_status=ok; prev_at=0; prev_sig=
if [ -f "$STATE_FILE" ]; then read -r prev_status prev_at prev_sig < "$STATE_FILE" || true; fi
case "$prev_at" in ''|*[!0-9]*) prev_at=0 ;; esac
now=$(date +%s)
rome_hour=$((10#${WATCH_ROME_HOUR:-$(TZ=Europe/Rome date +%H)}))   # WATCH_ROME_HOUR: tests only

all_clear() {
  report true "tutto OK"
  if [ "$prev_status" = "fail" ]; then
    # keep «fail» if Telegram did not take the message: the next run says it again
    bash "$HERE/telegram.sh" "✅ Caseificio: tornato tutto OK. Il controllo esterno (GitHub) non trova più problemi (due controlli a 3 minuti di distanza)." || return 0
  fi
  echo "ok $now -" > "$STATE_FILE"
}

first=$(check)
if [ -z "$first" ] && [ "$prev_status" != "fail" ]; then echo "OK $(date -u +%FT%TZ)"; all_clear; exit 0; fi
if [ -n "$first" ]; then echo "Primo controllo:"; text_of "$first"; else echo "Primo controllo pulito: riconfermo prima di dire che è tornato tutto OK."; fi
sleep "${RECHECK_SECONDS:-180}"
second=$(check)
if [ -z "$second" ]; then
  if [ -z "$first" ]; then echo "OK confermato $(date -u +%FT%TZ)"; else echo "Rientrato al secondo controllo."; fi
  # a problem that cleared within 3 minutes is not a recovery: only two clean checks in a row are
  if [ -n "$first" ] && [ "$prev_status" = "fail" ]; then report true "tutto OK (rientrato al secondo controllo)"; exit 0; fi
  all_clear; exit 0
fi

msgs=$(text_of "$second")
summary=$(echo "$msgs" | paste -sd ';' -)
sig=$(sig_of "$second")
report false "$summary"
quiet=false; { [ "$rome_hour" -ge 22 ] || [ "$rome_hour" -lt 7 ]; } && quiet=true
if [ "$prev_status" != "fail" ] || [ "$prev_sig" != "$sig" ]; then why=new
elif [ $((now - prev_at)) -ge $((REALERT_HOURS * 3600)) ] && [ "$quiet" = false ]; then why=reminder
else why=; fi
if [ -n "$why" ]; then
  head=$([ "$why" = reminder ] && echo "⚠️ Caseificio: il problema c'è ancora (controllo esterno, GitHub)" || echo "⚠️ Caseificio: problema confermato dal controllo esterno (GitHub, fuori da Supabase)")
  msg=$(printf '%s\n\n%s\n\nControllato due volte a 3 minuti di distanza. Al banco e in produzione: foglio «Sistema giù: cosa fare». Nick: Supabase, Netlify e la board.%s' \
    "$head" "$(echo "$msgs" | sed 's/^/• /')" "${RUN_URL:+

$RUN_URL}")
  if bash "$HERE/telegram.sh" "$msg"; then echo "fail $now $sig" > "$STATE_FILE"
  else echo "Messaggio non consegnato: riprovo al prossimo giro."; fi
else
  echo "Stesso problema già segnalato su Telegram: prossimo promemoria dopo ${REALERT_HOURS} ore (non di notte)."
  echo "fail $prev_at $sig" > "$STATE_FILE"
fi
{ echo "## Caseificio: problema confermato"; echo; echo "$msgs" | sed 's/^/- /'; echo; echo "Controllato due volte a 3 minuti di distanza. Vedi Supabase, Netlify e la board."; } >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}"
echo "::error::$summary"
exit 1
