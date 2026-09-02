#!/usr/bin/env bash
# Read-only readiness check. Never changes node or system state.
#
# Reports what is configured, what is missing, and — when a node is
# reachable — what the fee autotuner would do, via a forced dry run.
# Exit codes: 0 all good, 1 something required is missing.
set -uo pipefail
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/common.sh"

FAIL=0
pass() { printf '  ok    %s\n' "$*"; }
warn() { printf '  warn  %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; FAIL=1; }

echo "lnd-ops preflight"
echo "checkout: $LND_OPS_ROOT"
echo "role:     $LND_ROLE"
echo

echo "tooling"
command -v jq   >/dev/null 2>&1 && pass "jq $(jq --version)"   || bad "jq not installed"
command -v date >/dev/null 2>&1 && pass "date"                 || bad "date not found"
if date -d '24 hours ago' +%s >/dev/null 2>&1; then
  pass "date -d supports relative times (GNU date)"
else
  bad "date -d '24 hours ago' failed; GNU date is required"
fi
command -v systemctl >/dev/null 2>&1 && pass "systemctl" || warn "systemctl not found (fine in a container; units cannot be installed)"
command -v ssh >/dev/null 2>&1 && pass "ssh" || warn "ssh not found (fee-alert cannot poll the remote node)"
echo

echo "config"
if [ -f "$LND_OPS_ROOT/config/lnd-ops.env" ]; then
  pass "config/lnd-ops.env present"
else
  warn "config/lnd-ops.env absent; built-in defaults in use"
fi
pass "state dir      $LND_STATE_DIR"
pass "peers file     $LND_PEERS_FILE $([ -f "$LND_PEERS_FILE" ] || echo '(absent — watchdog will skip reconnects)')"
pass "wallet pass    $LND_WALLET_PASS_FILE $([ -f "$LND_WALLET_PASS_FILE" ] || echo '(absent)')"
pass "fee ladder     $LND_FEE_LADDER"
pass "thresholds     peers>=$LND_MIN_PEERS active>=$LND_MIN_ACTIVE_CHANNELS inactive<=$LND_MAX_INACTIVE_CHANNELS"
echo

echo "scripts"
for f in "$LND_OPS_ROOT"/bin/*.sh; do
  if bash -n "$f" 2>/dev/null; then pass "$(basename "$f") parses"; else bad "$(basename "$f") has a syntax error"; fi
done
echo

echo "node"
if [ -z "${LNCLI:-}" ]; then
  warn "no lncli found (looked in ~/bin/ln, ~/go/bin/lncli, PATH)"
  warn "this is expected in a cloud session with no node attached"
else
  pass "lncli $LNCLI"
  if info="$("$LNCLI" getinfo 2>/dev/null)"; then
    pass "getinfo responded"
    if command -v jq >/dev/null 2>&1; then
      printf '        peers=%s active=%s inactive=%s synced_chain=%s synced_graph=%s\n' \
        "$(jq -r '.num_peers // 0' <<<"$info")" \
        "$(jq -r '.num_active_channels // 0' <<<"$info")" \
        "$(jq -r '.num_inactive_channels // 0' <<<"$info")" \
        "$(jq -r '.synced_to_chain // false' <<<"$info")" \
        "$(jq -r '.synced_to_graph // false' <<<"$info")"
    fi
    echo
    echo "fee autotune (dry run — no policy is changed)"
    LND_FEE_APPLY=0 LOG=/dev/stdout "$LND_OPS_ROOT/bin/lnd-fee-autotune.sh" --dry-run 2>&1 | sed 's/^/        /'
  else
    warn "lncli present but getinfo failed (node down, locked, or wrong network)"
  fi
fi

echo
if [ "$FAIL" = 0 ]; then
  echo "preflight: ok"
else
  echo "preflight: something required is missing (see FAIL above)"
fi
exit "$FAIL"
