#!/usr/bin/env bash
# v1.00 (audit E-22): send one plain-text message to the partners' Telegram group, from GitHub, without Supabase.
# Needs TELEGRAM_BOT_TOKEN (the dairy's bot, the same token as the Supabase function «notify») and TELEGRAM_ALERT_CHAT_ID
# (the group's id, e.g. -1001234567890). Without them it only prints the message and succeeds.
# Exit 0 = sent (or Telegram not configured), 1 = Telegram refused or did not answer (after one retry): the caller keeps
# its state so the next run tries again. Never prints the token (curl -s, no -v; the URL is not echoed).
# usage: bash tools/watch/telegram.sh "text"        (TELEGRAM_API can point at a test server)
set -u
text=${1:-}
[ -n "$text" ] || exit 0
if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_ALERT_CHAT_ID:-}" ]; then
  echo "Telegram non configurato (segreti TELEGRAM_BOT_TOKEN / TELEGRAM_ALERT_CHAT_ID): messaggio non inviato"
  exit 0
fi
api=${TELEGRAM_API:-https://api.telegram.org}
resp=$(mktemp)
for attempt in 1 2; do
  code=$(curl -s -o "$resp" -w '%{http_code}' -m 20 -X POST "$api/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_ALERT_CHAT_ID}" --data-urlencode "text=${text}" \
    --data-urlencode "disable_web_page_preview=true")
  if [ "$code" = "200" ]; then rm -f "$resp"; echo "Telegram: messaggio inviato al gruppo"; exit 0; fi
  # 429: Telegram says how long to wait (parameters.retry_after); otherwise a short pause
  wait=$(jq -r '.parameters.retry_after // 5' "$resp" 2>/dev/null || echo 5)
  case "$wait" in ''|*[!0-9]*) wait=5 ;; esac
  [ "$wait" -le 30 ] || wait=30
  [ "$attempt" = 1 ] && sleep "$wait"
done
desc=$(jq -r '.description // empty' "$resp" 2>/dev/null | cut -c1-120)
rm -f "$resp"
echo "::warning::Telegram ha risposto $code${desc:+ ($desc)}: messaggio non inviato"
exit 1
