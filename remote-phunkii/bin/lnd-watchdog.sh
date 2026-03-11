#!/usr/bin/env bash
set -euo pipefail
LNCLI="$HOME/go/bin/lncli"
LND_SERVICE="lnd.service"
PEERS_FILE="$HOME/.config/lnd/watchdog-peers"
ERR_FILE="$HOME/.cache/lnd-watchdog.err"

if ! systemctl --user is-active --quiet "$LND_SERVICE"; then
  systemctl --user restart "$LND_SERVICE"
  sleep 3
fi

if ! "$LNCLI" getinfo >/dev/null 2>"$ERR_FILE"; then
  systemctl --user restart "$LND_SERVICE"
  sleep 4
fi

if [ -f "$PEERS_FILE" ]; then
  while IFS= read -r uri; do
    uri="${uri%%#*}"
    uri="$(echo "$uri" | xargs)"
    [ -n "$uri" ] || continue
    "$LNCLI" connect "$uri" >/dev/null 2>&1 || true
  done < "$PEERS_FILE"
fi
