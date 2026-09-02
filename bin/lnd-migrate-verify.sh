#!/usr/bin/env bash
# Verify a restored ~/.lnd on the destination host before starting lnd.
#
#   bin/lnd-migrate-verify.sh --manifest ~/lnd-migration/lnd-manifest.sha256
#
# Read-only. Checks that every file arrived intact, that the pieces the node
# needs to keep its identity are present, and that nothing is already running.
set -uo pipefail
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/common.sh"

MANIFEST=""
while [ $# -gt 0 ]; do
  case "$1" in
    --manifest) MANIFEST="${2:?--manifest needs a file}"; shift 2 ;;
    -h|--help)  sed -n '2,8p' "$0"; exit 0 ;;
    *) lnd_ops_die "unknown argument: $1" ;;
  esac
done

FAIL=0
pass() { printf '  ok    %s\n' "$*"; }
warn() { printf '  warn  %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; FAIL=1; }

echo "lnd-ops migration verify"
echo "lnd dir: $LND_DIR"
echo

echo "nothing running"
if pgrep -x lnd >/dev/null 2>&1; then
  bad "an lnd process is already running here; stop it before restoring"
else
  pass "no lnd process on this host"
fi
echo

echo "data directory"
[ -d "$LND_DIR" ] && pass "$LND_DIR exists" || bad "$LND_DIR is missing"

# Identity-critical files. Losing any of these changes who the node is, or
# loses the channels outright.
for rel in \
  "data/chain/bitcoin/mainnet/wallet.db" \
  "data/chain/bitcoin/mainnet/channel.db" \
  "data/chain/bitcoin/mainnet/channel.backup" \
  "tls.cert" "tls.key"
do
  if [ -f "$LND_DIR/$rel" ]; then
    pass "$rel ($(du -h "$LND_DIR/$rel" | cut -f1))"
  else
    bad "$rel is MISSING"
  fi
done

# Tor identity. Only critical if the node advertises an onion address.
if [ -f "$LND_DIR/v3_onion_private_key" ]; then
  pass "v3_onion_private_key present — the onion address is preserved"
else
  warn "v3_onion_private_key absent; if this node used Tor its address will change"
  warn "and peers will not find it, which eventually costs you the channels"
fi

if [ -f "$LND_WALLET_PASS_FILE" ]; then
  pass "wallet passphrase file present at $LND_WALLET_PASS_FILE"
else
  warn "no wallet passphrase file at $LND_WALLET_PASS_FILE; lnd will not auto-unlock"
fi
echo

echo "integrity"
if [ -z "$MANIFEST" ]; then
  warn "no --manifest given; skipping checksum comparison"
elif [ ! -f "$MANIFEST" ]; then
  bad "manifest not found: $MANIFEST"
else
  missing=0; changed=0; checked=0
  while read -r sum path; do
    [ -n "${sum:-}" ] || continue
    checked=$((checked+1))
    f="$LND_DIR/${path#./}"
    if [ ! -f "$f" ]; then
      missing=$((missing+1))
    elif [ "$(sha256sum "$f" | cut -d' ' -f1)" != "$sum" ]; then
      changed=$((changed+1))
      echo "        changed: ${path#./}"
    fi
  done < "$MANIFEST"
  if [ "$missing" = 0 ] && [ "$changed" = 0 ]; then
    pass "all $checked files match the source manifest"
  else
    bad "$checked checked, $missing missing, $changed changed"
  fi
fi
echo

echo "backend"
CONF="$LND_DIR/lnd.conf"
if [ -f "$CONF" ]; then
  backend="$(grep -E '^\s*bitcoin\.node\s*=' "$CONF" | tail -1 | cut -d= -f2 | tr -d '[:space:]' || true)"
  if [ -n "$backend" ]; then
    pass "lnd.conf declares bitcoin.node=$backend"
    if [ "$backend" = "bitcoind" ]; then
      warn "this host must be able to reach that bitcoind, or lnd will not start"
      warn "switching to neutrino? edit lnd.conf before the first start, not after"
    fi
  else
    warn "lnd.conf does not set bitcoin.node"
  fi
else
  warn "no lnd.conf in $LND_DIR"
fi

echo
if [ "$FAIL" = 0 ]; then
  echo "verify: ok — safe to start lnd on this host"
  echo
  echo "Once it starts and connects, the source node is permanently retired."
else
  echo "verify: FAILED — do not start lnd until the failures above are resolved"
fi
exit "$FAIL"
