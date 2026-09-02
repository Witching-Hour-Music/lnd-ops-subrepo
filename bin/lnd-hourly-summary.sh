#!/usr/bin/env bash
# Append a one-line 24h summary: peers, active channels, forwards, fees.
set -euo pipefail
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/common.sh"

lnd_ops_require_lncli
lnd_ops_require_jq

LOG="${LOG:-$(lnd_ops_log_file lnd-hourly-summary.log)}"
now="$(date -Iseconds)"
start="$(lnd_ops_fwd_start)"

info_json="$("$LNCLI" getinfo)"
fwd_json="$("$LNCLI" fwdinghistory --start_time "$start" --max_events "$LND_FWD_MAX_EVENTS")"

peers="$(jq -r '.num_peers' <<<"$info_json")"
active="$(jq -r '.num_active_channels' <<<"$info_json")"
forwards="$(jq -r '(.forwarding_events|length)' <<<"$fwd_json")"
fee_sat="$(jq -r '((([.forwarding_events[].fee_msat|tonumber]|add)//0)/1000|floor)' <<<"$fwd_json")"

printf '%s peers=%s active=%s fwd24h=%s fee24h_sat=%s\n' \
  "$now" "$peers" "$active" "$forwards" "$fee_sat" >> "$LOG"
