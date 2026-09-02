#!/usr/bin/env bash
# Compare 24h routing revenue on this node and the remote node against the
# previous run, and notify when either has increased. Read-only.
set -euo pipefail
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/common.sh"

lnd_ops_require_lncli
lnd_ops_require_jq

STATE_FILE="${STATE_FILE:-$(lnd_ops_log_file lnd-fee-alert.state)}"
LOG_FILE="${LOG_FILE:-$(lnd_ops_log_file lnd-fee-alert.log)}"

start_24h="$(lnd_ops_fwd_start)"

SUM_FEES='((([.forwarding_events[].fee_msat|tonumber]|add)//0)/1000|floor)'
COUNT_FWD='(.forwarding_events|length)'

local_json="$("$LNCLI" fwdinghistory --start_time "$start_24h" --max_events "$LND_FWD_MAX_EVENTS")"
local_fee="$(jq -r "$SUM_FEES" <<<"$local_json")"
local_fwd="$(jq -r "$COUNT_FWD" <<<"$local_json")"

remote_json="$(ssh -o ConnectTimeout="$LND_REMOTE_SSH_TIMEOUT" "$LND_REMOTE_HOST" \
  "$LND_REMOTE_LNCLI fwdinghistory --start_time $start_24h --max_events $LND_FWD_MAX_EVENTS" 2>/dev/null || true)"
if [[ -n "$remote_json" ]]; then
  remote_fee="$(jq -r "$SUM_FEES" <<<"$remote_json" 2>/dev/null || echo 0)"
  remote_fwd="$(jq -r "$COUNT_FWD" <<<"$remote_json" 2>/dev/null || echo 0)"
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
  alert_msg+="Local +$((local_fee - last_local_fee)) sat (24h=${local_fee}, fwd=${local_fwd})\n"
fi
if (( remote_fee > last_remote_fee )); then
  alert_msg+="Remote +$((remote_fee - last_remote_fee)) sat (24h=${remote_fee}, fwd=${remote_fwd})\n"
fi

printf 'last_local_fee=%s\nlast_remote_fee=%s\n' "$local_fee" "$remote_fee" > "$STATE_FILE"

now="$(date -Iseconds)"
printf '%s local_fee24h=%s local_fwd24h=%s remote_fee24h=%s remote_fwd24h=%s\n' \
  "$now" "$local_fee" "$local_fwd" "$remote_fee" "$remote_fwd" >> "$LOG_FILE"

if [[ -n "$alert_msg" ]]; then
  if command -v notify-send >/dev/null 2>&1; then
    notify-send "LND routing fees increased" "$alert_msg"
  fi
  printf '%s ALERT %b\n' "$now" "$alert_msg" >> "$LOG_FILE"
fi
