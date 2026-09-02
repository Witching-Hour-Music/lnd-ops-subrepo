#!/usr/bin/env bash
# Snapshot node health to JSON and log a line to alerts.log when a
# threshold is breached. Read-only against the node.
set -euo pipefail
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/common.sh"

lnd_ops_require_jq

OUT_DIR="$(lnd_ops_state_dir lnd-health)"
TS="$(date -Is)"

if [ -z "${LNCLI:-}" ] || ! info=$("$LNCLI" getinfo 2>/dev/null); then
  echo "$TS ${LND_ROLE}_lnd_unreachable" >> "$OUT_DIR/alerts.log"
  exit 0
fi

chans=$("$LNCLI" listchannels 2>/dev/null || echo '{"channels":[]}')
fees=$("$LNCLI" feereport 2>/dev/null || echo '{}')
printf '%s\n' "{\"timestamp\":\"$TS\",\"getinfo\":$info,\"listchannels\":$chans,\"feereport\":$fees}" > "$OUT_DIR/latest.json"

peers=$(jq -r '.num_peers // 0' <<<"$info")
active=$(jq -r '.num_active_channels // 0' <<<"$info")
inactive=$(jq -r '.num_inactive_channels // 0' <<<"$info")
sync_chain=$(jq -r '.synced_to_chain // false' <<<"$info")
sync_graph=$(jq -r '.synced_to_graph // false' <<<"$info")

if [ "$sync_chain" != "true" ] || [ "$sync_graph" != "true" ] \
   || [ "$peers" -lt "$LND_MIN_PEERS" ] \
   || [ "$active" -lt "$LND_MIN_ACTIVE_CHANNELS" ] \
   || [ "$inactive" -gt "$LND_MAX_INACTIVE_CHANNELS" ]; then
  echo "$TS peers=$peers active=$active inactive=$inactive synced_to_chain=$sync_chain synced_to_graph=$sync_graph" >> "$OUT_DIR/alerts.log"
fi
