#!/usr/bin/env bash
# Read-only audit for the production cloud node. No service restart, wallet
# unlock, policy update, peer connection, payment or channel RPC is performed.
set -uo pipefail
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/common.sh"

FAIL=0
WARN=0
ok()   { printf '  ok    %s\n' "$*"; }
warn() { printf '  warn  %s\n' "$*"; WARN=$((WARN+1)); }
bad()  { printf '  FAIL  %s\n' "$*"; FAIL=$((FAIL+1)); }

echo "lnd cloud audit (read-only)"
echo "timestamp: $(date -Is)"
echo

echo "host"
command -v uname >/dev/null 2>&1 && ok "kernel $(uname -sr)" || bad "uname missing"
if command -v df >/dev/null 2>&1; then
  root_use=$(df -P / | awk 'NR==2 {gsub(/%/,"",$5); print $5}')
  [ "${root_use:-100}" -lt 80 ] && ok "root disk ${root_use}% used" || bad "root disk ${root_use:-unknown}% used (limit 79%)"
else
  bad "df missing"
fi
if command -v free >/dev/null 2>&1; then
  avail_mb=$(free -m | awk '/^Mem:/ {print $7}')
  [ "${avail_mb:-0}" -ge 512 ] && ok "memory available ${avail_mb} MiB" || warn "memory available ${avail_mb:-unknown} MiB (target >=512 MiB)"
else
  warn "free missing"
fi
echo

echo "services"
for unit in bitcoind.service lnd.service; do
  if command -v systemctl >/dev/null 2>&1; then
    systemctl is-active --quiet "$unit" 2>/dev/null && ok "$unit active" || warn "$unit not active as a system service (may be a user service)"
  fi
done
if lnd_ops_has_systemd_user; then
  systemctl --user is-active --quiet "$LND_SERVICE" && ok "$LND_SERVICE active (user)" || bad "$LND_SERVICE inactive (user)"
else
  warn "systemd user manager unavailable in this session"
fi
echo

echo "lightning"
if [ -z "${LNCLI:-}" ]; then
  bad "lncli not found"
else
  info="$("$LNCLI" getinfo 2>/dev/null)" || info=""
  if [ -z "$info" ]; then
    bad "getinfo failed"
  elif ! command -v jq >/dev/null 2>&1; then
    bad "jq missing"
  else
    ok "getinfo responded"
    chain=$(jq -r '.synced_to_chain // false' <<<"$info")
    graph=$(jq -r '.synced_to_graph // false' <<<"$info")
    peers=$(jq -r '.num_peers // 0' <<<"$info")
    active=$(jq -r '.num_active_channels // 0' <<<"$info")
    inactive=$(jq -r '.num_inactive_channels // 0' <<<"$info")
    [ "$chain" = true ] && ok "synced to chain" || bad "not synced to chain"
    [ "$graph" = true ] && ok "synced to graph" || bad "not synced to graph"
    [ "$peers" -ge "$LND_MIN_PEERS" ] && ok "peers=$peers" || warn "peers=$peers (target >=$LND_MIN_PEERS)"
    [ "$active" -ge "$LND_MIN_ACTIVE_CHANNELS" ] && ok "active channels=$active" || bad "active channels=$active (target >=$LND_MIN_ACTIVE_CHANNELS)"
    [ "$inactive" -le "$LND_MAX_INACTIVE_CHANNELS" ] && ok "inactive channels=$inactive" || warn "inactive channels=$inactive (target <=$LND_MAX_INACTIVE_CHANNELS)"
  fi
fi
echo

echo "network exposure"
if command -v ss >/dev/null 2>&1; then
  if ss -lnt 2>/dev/null | awk 'NR>1 {print $4}' | grep -Eq '(^|:)(10009|8080)$'; then
    warn "LND RPC/REST is listening; verify it is bound only to loopback or WireGuard"
  else
    ok "no LND RPC/REST listener detected on TCP 10009/8080"
  fi
  if ss -lnt 2>/dev/null | awk 'NR>1 {print $4}' | grep -Eq '(^|:)(8332|28332|28333)$'; then
    warn "Bitcoin RPC/ZMQ listener detected; verify loopback-only binding"
  else
    ok "no public-looking Bitcoin RPC/ZMQ listener detected"
  fi
else
  warn "ss missing; could not inspect listening sockets"
fi
echo

echo "backup"
SCB="$LND_DIR/data/chain/bitcoin/mainnet/channel.backup"
if [ -s "$SCB" ]; then
  age_seconds=$(( $(date +%s) - $(stat -c %Y "$SCB") ))
  age_hours=$(( age_seconds / 3600 ))
  [ "$age_hours" -le 24 ] && ok "static channel backup present (${age_hours}h old)" || warn "static channel backup is ${age_hours}h old"
else
  bad "static channel backup missing or empty: $SCB"
fi

echo
printf 'audit: %d failure(s), %d warning(s)\n' "$FAIL" "$WARN"
[ "$FAIL" = 0 ]
