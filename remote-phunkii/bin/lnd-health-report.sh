#!/usr/bin/env bash
set -euo pipefail
OUT_DIR="$HOME/.local/state/lnd-health"
mkdir -p "$OUT_DIR"
TS="$(date -Is)"
if ! info=$($HOME/go/bin/lncli getinfo 2>/dev/null); then
  echo "$TS remote_lnd_unreachable" >> "$OUT_DIR/alerts.log"
  exit 0
fi
chans=$($HOME/go/bin/lncli listchannels 2>/dev/null || echo '{"channels":[]}')
fees=$($HOME/go/bin/lncli feereport 2>/dev/null || echo '{}')
printf "%s\n" "{\"timestamp\":\"$TS\",\"getinfo\":$info,\"listchannels\":$chans,\"feereport\":$fees}" > "$OUT_DIR/latest.json"
peers=$(jq -r '.num_peers // 0' <<<"$info")
active=$(jq -r '.num_active_channels // 0' <<<"$info")
inactive=$(jq -r '.num_inactive_channels // 0' <<<"$info")
sync_chain=$(jq -r '.synced_to_chain // false' <<<"$info")
sync_graph=$(jq -r '.synced_to_graph // false' <<<"$info")
if [ "$sync_chain" != "true" ] || [ "$sync_graph" != "true" ] || [ "$peers" -lt 3 ] || [ "$active" -lt 1 ] || [ "$inactive" -gt 0 ]; then
  echo "$TS peers=$peers active=$active inactive=$inactive synced_to_chain=$sync_chain synced_to_graph=$sync_graph" >> "$OUT_DIR/alerts.log"
fi
