#!/usr/bin/env bash
# v0.78 outside watcher — runs on GitHub Actions (.github/workflows/watch.yml), independent of Supabase, the bots and Claude.
# Checks: tablet site serves the app · database answers (public.fabula_health) · pg_cron ran in the last 20 min ·
# nightly backup in the last 26 h · edge function farm-order refuses a request without token (403).
# A failure is re-checked after 3 minutes; only a second failure fails the job (GitHub then e-mails the repo owner).
set -u
SITE="${SITE:-https://flourishing-swan-6729c4.netlify.app}"
SB="${SB:-https://ojkquhzaeypsphncjqwy.supabase.co}"
KEY="${KEY:-sb_publishable_Kl7c4NqV44tjDYs6IbpA0Q_S5ENoKq3}"   # publishable key, the same one shipped in fabula-tablet/config.js
check() {
  local bad=()
  curl -fsS -m 20 "$SITE/sw.js" | grep -q "perla-v" || bad+=("sito tablet non risponde ($SITE)")
  local h; h=$(curl -fsS -m 20 -X POST "$SB/rest/v1/rpc/fabula_health" -H "apikey: $KEY" -H "Content-Type: application/json" -d '{}' 2>/dev/null)
  if [ -z "$h" ]; then bad+=("database non risponde")
  else
    [ "$(echo "$h" | jq -r .db)" = "true" ] || bad+=("database non risponde")
    [ "$(echo "$h" | jq -r .cron_ok)" = "true" ] || bad+=("automazioni del database (pg_cron) ferme da oltre 20 minuti")
    [ "$(echo "$h" | jq -r .backup_ok)" = "true" ] || bad+=("nessun backup riuscito nelle ultime 26 ore")
  fi
  local code; code=$(curl -s -o /dev/null -w "%{http_code}" -m 20 "$SB/functions/v1/farm-order?t=monitor")
  [ "$code" = "403" ] || bad+=("funzione farm-order: risposta $code invece di 403")
  printf '%s\n' "${bad[@]}"
}
first=$(check)
if [ -z "$first" ]; then echo "OK $(date -u +%FT%TZ)"; exit 0; fi
echo "Primo controllo:"; echo "$first"; sleep "${RECHECK_SECONDS:-180}"
second=$(check)
if [ -z "$second" ]; then echo "Rientrato al secondo controllo."; exit 0; fi
{ echo "## Caseificio: problema confermato"; echo; echo "$second" | sed 's/^/- /'; echo; echo "Controllato due volte a 3 minuti di distanza. Vedi Supabase, Netlify e la board."; } >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}"
echo "::error::$(echo "$second" | paste -sd ';' -)"
exit 1
