#!/usr/bin/env bash
# Set each channel's outbound fee from its local-balance ratio, using the
# ladder in LND_FEE_LADDER.
#
# This is the one script here that changes node state. Set LND_FEE_APPLY=0
# (or pass --dry-run) to log the intended policy for every channel without
# calling updatechanpolicy.
set -euo pipefail
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/common.sh"

for arg in "$@"; do
  case "$arg" in
    --dry-run) LND_FEE_APPLY=0 ;;
    --apply)   LND_FEE_APPLY=1 ;;
    *) lnd_ops_die "unknown argument: $arg (expected --dry-run or --apply)" ;;
  esac
done

lnd_ops_require_lncli
lnd_ops_require_jq

LOG="${LOG:-$(lnd_ops_log_file lnd-fee-autotune.log)}"

while IFS=$'\t' read -r chan_point local_bal remote_bal; do
  total=$((local_bal + remote_bal))
  if (( total <= 0 )); then
    pct=50
  else
    pct=$((100 * local_bal / total))
  fi
  ppm="$(lnd_ops_map_ppm "$pct")"

  if [ "$LND_FEE_APPLY" = "1" ]; then
    if "$LNCLI" updatechanpolicy \
         --base_fee_msat="$LND_FEE_BASE_MSAT" \
         --fee_rate_ppm="$ppm" \
         --time_lock_delta="$LND_FEE_TIME_LOCK_DELTA" \
         --chan_point="$chan_point" >/dev/null 2>&1; then
      status=ok
    else
      status=failed
    fi
  else
    status=dry-run
  fi

  printf '%s chan=%s local=%s remote=%s local_pct=%s ppm=%s status=%s\n' \
    "$(date -Iseconds)" "$chan_point" "$local_bal" "$remote_bal" "$pct" "$ppm" "$status" >> "$LOG"
done < <("$LNCLI" listchannels | jq -r '.channels[] | [.channel_point, (.local_balance|tonumber), (.remote_balance|tonumber)] | @tsv')
