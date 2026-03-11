#!/usr/bin/env bash
set -euo pipefail

LOCAL_LNCLI="${LOCAL_LNCLI:-/home/fletchervaughn/bin/ln}"
REMOTE_HOST="${REMOTE_HOST:-phunkii@20.127.136.37}"
REMOTE_LNCLI="${REMOTE_LNCLI:-/home/phunkii/go/bin/lncli}"
STATE_FILE="${STATE_FILE:-$HOME/.local/state/lnd-fee-alert.state}"
LOG_FILE="${LOG_FILE:-$HOME/.local/state/lnd-fee-alert.log}"

mkdir -p "$(dirname "$STATE_FILE")"
mkdir -p "$(dirname "$LOG_FILE")"

start_24h="$(date -d '24 hours ago' +%s)"

local_fee="$($LOCAL_LNCLI fwdinghistory --start_time "$start_24h" --max_events 5000 | jq -r '((([.forwarding_events[].fee_msat|tonumber]|add)//0)/1000|floor)')"
local_fwd="$($LOCAL_LNCLI fwdinghistory --start_time "$start_24h" --max_events 5000 | jq -r '(.forwarding_events|length)')"

remote_json="$(ssh -o ConnectTimeout=6 "$REMOTE_HOST" "$REMOTE_LNCLI fwdinghistory --start_time $start_24h --max_events 5000" 2>/dev/null || true)"
if [[ -n "$remote_json" ]]; then
  remote_fee="$(echo "$remote_json" | jq -r '((([.forwarding_events[].fee_msat|tonumber]|add)//0)/1000|floor)' 2>/dev/null || echo 0)"
  remote_fwd="$(echo "$remote_json" | jq -r '(.forwarding_events|length)' 2>/dev/null || echo 0)"
else
  remote_fee=0
  remote_fwd=0
fi

last_local_fee=0
last_remote_fee=0
if [[ -f "$STATE_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$STATE_FILE" || true
fi

alert_msg=""
if (( local_fee > last_local_fee )); then
  inc=$((local_fee - last_local_fee))
  alert_msg+="Local +${inc} sat (24h=${local_fee}, fwd=${local_fwd})\n"
fi
if (( remote_fee > last_remote_fee )); then
  inc=$((remote_fee - last_remote_fee))
  alert_msg+="Remote +${inc} sat (24h=${remote_fee}, fwd=${remote_fwd})\n"
fi

printf 'last_local_fee=%s\nlast_remote_fee=%s\n' "$local_fee" "$remote_fee" > "$STATE_FILE"

now="$(date -Iseconds)"
printf '%s local_fee24h=%s local_fwd24h=%s remote_fee24h=%s remote_fwd24h=%s\n' "$now" "$local_fee" "$local_fwd" "$remote_fee" "$remote_fwd" >> "$LOG_FILE"

if [[ -n "$alert_msg" ]]; then
  if command -v notify-send >/dev/null 2>&1; then
    notify-send "LND routing fees increased" "$alert_msg"
  fi
  printf '%s ALERT %b\n' "$now" "$alert_msg" >> "$LOG_FILE"
fi
