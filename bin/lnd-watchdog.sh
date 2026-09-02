#!/usr/bin/env bash
# Restart lnd if the unit is down or RPC is unresponsive, then reconnect
# the configured peer set.
#
# Where no systemd user manager is reachable (a container, an SSH session
# with no user bus) the restart steps are skipped and the script still runs
# its read-only RPC check and peer reconnects, so it is safe anywhere.
set -euo pipefail
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/common.sh"

lnd_ops_require_lncli

ERR_FILE="$LND_CACHE_DIR/lnd-watchdog.err"
mkdir -p "$(dirname "$ERR_FILE")"

if lnd_ops_has_systemd_user; then
  HAVE_SYSTEMD=1
else
  HAVE_SYSTEMD=0
  printf 'lnd-ops: no systemd user manager reachable; skipping service restarts\n' >&2
fi

restart_lnd() {
  [ "$HAVE_SYSTEMD" = 1 ] || return 0
  systemctl --user restart "$LND_SERVICE"
  sleep "$1"
}

ensure_lnd_running() {
  [ "$HAVE_SYSTEMD" = 1 ] || return 0
  if ! systemctl --user is-active --quiet "$LND_SERVICE"; then
    restart_lnd 3
  fi
}

ensure_rpc_health() {
  if ! "$LNCLI" getinfo >/dev/null 2>"$ERR_FILE"; then
    restart_lnd 4
  fi
}

reconnect_peers() {
  [ -f "$LND_PEERS_FILE" ] || return 0
  while IFS= read -r uri; do
    uri="${uri%%#*}"
    uri="$(echo "$uri" | xargs)"
    [ -n "$uri" ] || continue
    "$LNCLI" connect "$uri" >/dev/null 2>&1 || true
  done < "$LND_PEERS_FILE"
}

main() {
  ensure_lnd_running
  ensure_rpc_health
  reconnect_peers
}

main
