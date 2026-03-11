#!/usr/bin/env bash
set -euo pipefail

LNCLI=/home/fletchervaughn/bin/ln
PEERS_FILE=/home/fletchervaughn/.config/lnd/watchdog-peers
LND_SERVICE=lnd.service
ERR_FILE=/home/fletchervaughn/.cache/lnd-watchdog.err

ensure_lnd_running() {
  if ! systemctl --user is-active --quiet "$LND_SERVICE"; then
    systemctl --user restart "$LND_SERVICE"
    sleep 3
  fi
}

ensure_rpc_health() {
  if ! "$LNCLI" getinfo >/dev/null 2>"$ERR_FILE"; then
    systemctl --user restart "$LND_SERVICE"
    sleep 4
  fi
}

reconnect_peers() {
  [ -f "$PEERS_FILE" ] || return 0
  while IFS= read -r uri; do
    uri="${uri%%#*}"
    uri="$(echo "$uri" | xargs)"
    [ -n "$uri" ] || continue
    "$LNCLI" connect "$uri" >/dev/null 2>&1 || true
  done < "$PEERS_FILE"
}

main() {
  ensure_lnd_running
  ensure_rpc_health
  reconnect_peers
}

main
