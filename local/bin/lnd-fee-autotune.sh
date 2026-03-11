#!/usr/bin/env bash
set -euo pipefail
LNCLI="${LNCLI:-/home/fletchervaughn/bin/ln}"
LOG="${LOG:-$HOME/.local/state/lnd-fee-autotune.log}"
mkdir -p "$(dirname "$LOG")"

map_ppm() {
  local pct="$1"
  if (( pct >= 80 )); then echo 2
  elif (( pct >= 65 )); then echo 5
  elif (( pct >= 55 )); then echo 10
  elif (( pct >= 45 )); then echo 25
  elif (( pct >= 35 )); then echo 60
  elif (( pct >= 20 )); then echo 120
  else echo 250
  fi
}

"$LNCLI" listchannels | jq -r '.channels[] | [.channel_point, (.local_balance|tonumber), (.remote_balance|tonumber)] | @tsv' |
while IFS=$'\t' read -r chan_point local remote; do
  total=$((local + remote))
  if (( total <= 0 )); then
    pct=50
  else
    pct=$((100 * local / total))
  fi
  ppm="$(map_ppm "$pct")"
  "$LNCLI" updatechanpolicy --base_fee_msat=0 --fee_rate_ppm="$ppm" --time_lock_delta=40 --chan_point="$chan_point" >/dev/null
  printf '%s chan=%s local=%s remote=%s local_pct=%s ppm=%s\n' "$(date -Iseconds)" "$chan_point" "$local" "$remote" "$pct" "$ppm" >> "$LOG"
done
