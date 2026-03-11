#!/usr/bin/env bash
set -euo pipefail
LNCLI="${LNCLI:-/home/fletchervaughn/bin/ln}"
LOG="${LOG:-$HOME/.local/state/lnd-hourly-summary.log}"
mkdir -p "$(dirname "$LOG")"
now="$(date -Iseconds)"
start="$(date -d '24 hours ago' +%s)"
info_json="$($LNCLI getinfo)"
fwd_json="$($LNCLI fwdinghistory --start_time "$start" --max_events 5000)"
peers="$(echo "$info_json" | jq -r '.num_peers')"
active="$(echo "$info_json" | jq -r '.num_active_channels')"
forwards="$(echo "$fwd_json" | jq -r '(.forwarding_events|length)')"
fee_sat="$(echo "$fwd_json" | jq -r '((([.forwarding_events[].fee_msat|tonumber]|add)//0)/1000|floor)')"
printf '%s peers=%s active=%s fwd24h=%s fee24h_sat=%s\n' "$now" "$peers" "$active" "$forwards" "$fee_sat" >> "$LOG"
