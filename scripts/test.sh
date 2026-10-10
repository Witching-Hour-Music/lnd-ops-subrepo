#!/usr/bin/env bash
# Run the ops scripts against a stub lncli in a throwaway HOME.
# Requires no Lightning node, no network, and no systemd.
set -uo pipefail
REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"

PASS=0
FAIL=0
ok()   { printf '  ok    %s\n' "$*"; PASS=$((PASS+1)); }
no()   { printf '  FAIL  %s\n' "$*"; FAIL=$((FAIL+1)); }
check() { if [ "$1" = 0 ]; then ok "$2"; else no "$2"; fi; }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

export HOME="$SANDBOX/home"
export XDG_STATE_HOME="$HOME/.local/state"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_CACHE_HOME="$HOME/.cache"
mkdir -p "$HOME"

export LNCLI="$REPO/test/fixtures/lncli-stub"
export STUB_CALL_LOG="$SANDBOX/calls.log"
: > "$STUB_CALL_LOG"
# Do not pick up a real config from the checkout.
export LND_OPS_CONFIG="$SANDBOX/none.env"

echo "lnd-ops tests"
echo "sandbox: $SANDBOX"
echo

echo "syntax"
for f in "$REPO"/bin/*.sh "$REPO"/lib/*.sh "$REPO"/scripts/*.sh; do
  bash -n "$f" 2>/dev/null; check $? "$(basename "$f")"
done
echo

echo "fee ladder"
# shellcheck disable=SC1091
. "$REPO/lib/common.sh"
set +e  # belt and braces: a library must not change our control flow
ladder_ok=0
for pair in 100:2 80:2 79:5 65:5 64:10 55:10 54:25 45:25 44:60 35:60 34:120 20:120 19:250 0:250; do
  got="$(lnd_ops_map_ppm "${pair%%:*}")"
  [ "$got" = "${pair##*:}" ] || { no "pct=${pair%%:*} expected ${pair##*:} got $got"; ladder_ok=1; }
done
check "$ladder_ok" "14 boundary values map to the documented ppm"
echo

echo "health report"
"$REPO/bin/lnd-health-report.sh"; check $? "runs"
[ -f "$XDG_STATE_HOME/lnd-health/latest.json" ]; check $? "writes latest.json"
jq -e . "$XDG_STATE_HOME/lnd-health/latest.json" >/dev/null 2>&1; check $? "latest.json is valid JSON"
# The stub is healthy, so nothing should be alerted.
[ ! -s "$XDG_STATE_HOME/lnd-health/alerts.log" ]; check $? "healthy node logs no alert"

# Now force a breach via thresholds rather than by editing the stub.
LND_MIN_PEERS=99 "$REPO/bin/lnd-health-report.sh"
grep -q 'peers=5' "$XDG_STATE_HOME/lnd-health/alerts.log" 2>/dev/null; check $? "threshold breach logs an alert"
echo

echo "hourly summary"
"$REPO/bin/lnd-hourly-summary.sh"; check $? "runs"
SUMMARY="$XDG_STATE_HOME/lnd-hourly-summary.log"
grep -q 'peers=5 active=3 fwd24h=3 fee24h_sat=5' "$SUMMARY" 2>/dev/null
check $? "sums 1500+2500+1000 msat to 5 sat over 3 forwards"
echo

echo "fee autotune"
: > "$STUB_CALL_LOG"
"$REPO/bin/lnd-fee-autotune.sh" --dry-run; check $? "dry run exits clean"
! grep -q updatechanpolicy "$STUB_CALL_LOG"; check $? "dry run does NOT call updatechanpolicy"
AUTOTUNE="$XDG_STATE_HOME/lnd-fee-autotune.log"
grep -q 'chan=aaaa:0 .*local_pct=90 ppm=2 status=dry-run'   "$AUTOTUNE"; check $? "90% local -> 2 ppm"
grep -q 'chan=bbbb:1 .*local_pct=50 ppm=25 status=dry-run'  "$AUTOTUNE"; check $? "50% local -> 25 ppm"
grep -q 'chan=cccc:2 .*local_pct=5 ppm=250 status=dry-run'  "$AUTOTUNE"; check $? "5% local -> 250 ppm"
grep -q 'chan=dddd:3 .*local_pct=50 ppm=25 status=dry-run'  "$AUTOTUNE"; check $? "zero-balance channel treated as 50%"

: > "$STUB_CALL_LOG"
"$REPO/bin/lnd-fee-autotune.sh" --apply >/dev/null 2>&1; check $? "apply run exits clean"
[ "$(grep -c updatechanpolicy "$STUB_CALL_LOG")" = 4 ]; check $? "apply run updates all 4 channels"
grep -q -- '--base_fee_msat=0 --fee_rate_ppm=2 --time_lock_delta=40' "$STUB_CALL_LOG"
check $? "policy flags match the historical values"
echo

echo "watchdog"
# No systemctl in most containers; the watchdog should still reach the node.
: > "$STUB_CALL_LOG"
mkdir -p "$(dirname "$XDG_CONFIG_HOME/lnd/watchdog-peers")"
printf '02abc@1.2.3.4:9735\n# a comment\n\n' > "$XDG_CONFIG_HOME/lnd/watchdog-peers"
"$REPO/bin/lnd-watchdog.sh" >/dev/null 2>&1; check $? "runs without a systemd user bus"
grep -q 'connect 02abc@1.2.3.4:9735' "$STUB_CALL_LOG"; check $? "reconnects configured peers"
[ "$(grep -c '^connect ' "$STUB_CALL_LOG")" = 1 ]; check $? "skips comments and blank lines"
grep -q '^getinfo$' "$STUB_CALL_LOG"; check $? "performs the RPC health check"
echo

echo "lncli detection"
# Helper: print the LNCLI that common.sh resolves, under the caller's env.
cat > "$SANDBOX/show-lncli" <<SHOW
#!/usr/bin/env bash
. "$REPO/lib/common.sh"
printf '%s' "\${LNCLI:-}"
SHOW
chmod +x "$SANDBOX/show-lncli"

DETECT="$SANDBOX/detect"; mkdir -p "$DETECT/bin" "$DETECT/go/bin"
# A decoy that behaves exactly like GNU coreutils ln.
cat > "$DETECT/bin/ln" <<'DECOY'
#!/usr/bin/env bash
[ "${1:-}" = --version ] && { echo "ln (GNU coreutils) 9.4"; exit 0; }
echo "ln: missing file operand" >&2; exit 1
DECOY
cat > "$DETECT/go/bin/lncli" <<'REAL'
#!/usr/bin/env bash
[ "${1:-}" = --version ] && { echo "lncli version 0.20.1-beta"; exit 0; }
exit 0
REAL
chmod +x "$DETECT/bin/ln" "$DETECT/go/bin/lncli"

got="$(env HOME="$DETECT" LNCLI= "$SANDBOX/show-lncli")"
[ "$got" = "$DETECT/go/bin/lncli" ]
check $? "prefers real lncli over a coreutils ln decoy (got ${got:-<none>})"

rm -f "$DETECT/go/bin/lncli"
got="$(env HOME="$DETECT" LNCLI= PATH="$DETECT/bin:$PATH" "$SANDBOX/show-lncli")"
[ -z "$got" ]
check $? "never selects coreutils ln (got ${got:-<none>})"

got="$(env LNCLI=/opt/custom/lncli "$SANDBOX/show-lncli")"
[ "$got" = /opt/custom/lncli ]
check $? "an explicit LNCLI is used verbatim (got ${got:-<none>})"
echo

echo "config precedence"
CFG="$SANDBOX/custom.env"
printf 'LND_MIN_PEERS=42\nLND_FEE_BASE_MSAT=7\n' > "$CFG"
got="$(LND_OPS_CONFIG="$CFG" bash -c '. "'"$REPO"'/lib/common.sh"; echo "$LND_MIN_PEERS/$LND_FEE_BASE_MSAT"')"
[ "$got" = "42/7" ]; check $? "config file is read (got $got)"
got="$(LND_OPS_CONFIG="$CFG" LND_MIN_PEERS=9 bash -c '. "'"$REPO"'/lib/common.sh"; echo "$LND_MIN_PEERS"')"
[ "$got" = "9" ]; check $? "environment overrides the config file (got $got)"
got="$(LND_ROLE=remote bash -c '. "'"$REPO"'/lib/common.sh"; echo "$LND_MIN_ACTIVE_CHANNELS"')"
[ "$got" = "1" ]; check $? "remote role defaults to 1 active channel (got $got)"
got="$(LND_ROLE=local bash -c '. "'"$REPO"'/lib/common.sh"; echo "$LND_MIN_ACTIVE_CHANNELS"')"
[ "$got" = "2" ]; check $? "local role defaults to 2 active channels (got $got)"
echo

echo "migration freeze (dry run)"
FAKE="$SANDBOX/fakelnd"
mkdir -p "$FAKE/.lnd/data/chain/bitcoin/mainnet"
echo wallet   > "$FAKE/.lnd/data/chain/bitcoin/mainnet/wallet.db"
echo channels > "$FAKE/.lnd/data/chain/bitcoin/mainnet/channel.db"
echo scb      > "$FAKE/.lnd/data/chain/bitcoin/mainnet/channel.backup"
echo cert     > "$FAKE/.lnd/tls.cert"
echo key      > "$FAKE/.lnd/tls.key"
echo onion    > "$FAKE/.lnd/v3_onion_private_key"
printf 'bitcoin.node=bitcoind\n' > "$FAKE/.lnd/lnd.conf"

FREEZE_OUT="$(env HOME="$FAKE" LND_DIR="$FAKE/.lnd" OUT_DIR="$SANDBOX/mig" \
  "$REPO/bin/lnd-migrate-freeze.sh" 2>&1)"; check $? "dry run exits clean"
grep -q "mode:     dry run" <<<"$FREEZE_OUT"; check $? "announces dry-run mode"
grep -q "Nothing changed" <<<"$FREEZE_OUT"; check $? "states nothing changed"
[ ! -d "$SANDBOX/mig" ]; check $? "dry run creates no output directory"

# The ordering trap: timers must be disabled before lnd is stopped, or the
# watchdog restarts it underneath the copy.
# -m1 so each marker yields exactly one line number; without it a repeated
# phrase produces a multi-line value and the numeric comparison below errors.
first_line_of() { grep -n -m1 -- "$1" <<<"$2" | cut -d: -f1; }
timers_line=$(first_line_of "Stop and disable lnd-" "$FREEZE_OUT")
lnd_line=$(first_line_of "3. Stop" "$FREEZE_OUT")
[ -n "$timers_line" ] && [ -n "$lnd_line" ] && [ "$timers_line" -lt "$lnd_line" ]
check $? "timers are stopped BEFORE lnd (watchdog trap)"
grep -q "wallet material" <<<"$FREEZE_OUT"; check $? "warns the archive holds wallet material"
grep -q "Nothing has been stopped" <<<"$FREEZE_OUT"; check $? "dry run does not claim the node was stopped"
grep -q "stale channel state" <<<"$FREEZE_OUT"; check $? "warns against restarting the source"
echo

echo "migration verify"
VERIFY_OUT="$(env HOME="$FAKE" LND_DIR="$FAKE/.lnd" "$REPO/bin/lnd-migrate-verify.sh" 2>&1)"
vrc=$?
[ "$vrc" = 0 ]; check $? "passes on a complete data directory"
grep -q "v3_onion_private_key present" <<<"$VERIFY_OUT"; check $? "detects the onion key"
grep -q "bitcoin.node=bitcoind" <<<"$VERIFY_OUT"; check $? "reads the backend from lnd.conf"
grep -q "zmqpubrawblock and zmqpubrawtx match" <<<"$VERIFY_OUT"
check $? "warns that both ZMQ endpoints must match bitcoin.conf"
grep -q "makes a failure" <<<"$VERIFY_OUT"
check $? "warns against changing backend and host together"

# Losing the onion key changes the node address; must be called out.
mv "$FAKE/.lnd/v3_onion_private_key" "$FAKE/.lnd/onion.bak"
VERIFY_OUT="$(env HOME="$FAKE" LND_DIR="$FAKE/.lnd" "$REPO/bin/lnd-migrate-verify.sh" 2>&1)"
grep -q "its address will change" <<<"$VERIFY_OUT"; check $? "warns when the onion key is missing"
mv "$FAKE/.lnd/onion.bak" "$FAKE/.lnd/v3_onion_private_key"

# A missing channel.db is fatal, not a warning.
mv "$FAKE/.lnd/data/chain/bitcoin/mainnet/channel.db" "$FAKE/.lnd/chan.bak"
env HOME="$FAKE" LND_DIR="$FAKE/.lnd" "$REPO/bin/lnd-migrate-verify.sh" >/dev/null 2>&1
[ $? -ne 0 ]; check $? "fails when channel.db is missing"
mv "$FAKE/.lnd/chan.bak" "$FAKE/.lnd/data/chain/bitcoin/mainnet/channel.db"

# Checksum mismatch must be caught, not waved through.
( cd "$FAKE/.lnd" && find . -type f -print0 | sort -z | xargs -0 sha256sum ) > "$SANDBOX/man.sha256"
env HOME="$FAKE" LND_DIR="$FAKE/.lnd" "$REPO/bin/lnd-migrate-verify.sh" --manifest "$SANDBOX/man.sha256" >/dev/null 2>&1
check $? "passes with a matching manifest"
echo corrupted > "$FAKE/.lnd/data/chain/bitcoin/mainnet/channel.db"
env HOME="$FAKE" LND_DIR="$FAKE/.lnd" "$REPO/bin/lnd-migrate-verify.sh" --manifest "$SANDBOX/man.sha256" >/dev/null 2>&1
[ $? -ne 0 ]; check $? "fails when a file does not match the manifest"
echo

echo "cloud configs"
BC="$REPO/cloud/bitcoin.conf.example"
LB="$REPO/cloud/lnd.conf.bitcoind.example"
LN="$REPO/cloud/lnd.conf.neutrino.example"
for f in "$BC" "$LB" "$LN" "$REPO/cloud/CUTOVER-CHECKLIST.md" "$REPO/cloud/MIGRATION.md" \
         "$REPO/cloud/FAST-PATH.md"; do
  [ -f "$f" ]; check $? "$(basename "$f") exists"
done

# LND needs both ZMQ endpoints, and they must agree across the two files.
for ep in zmqpubrawblock zmqpubrawtx; do
  bc=$(grep -E "^$ep=" "$BC" | cut -d= -f2-)
  lnd=$(grep -E "^bitcoind\.$ep=" "$LB" | cut -d= -f2-)
  [ -n "$bc" ] && [ "$bc" = "$lnd" ]
  check $? "$ep matches between bitcoin.conf and lnd.conf (${bc:-unset} vs ${lnd:-unset})"
done

grep -q '^txindex=0' "$BC"; check $? "bitcoin.conf keeps txindex=0, required with pruning"
grep -qE '^prune=[0-9]+' "$BC"; check $? "bitcoin.conf sets a prune target"
prune=$(grep -oE '^prune=[0-9]+' "$BC" | cut -d= -f2)
[ "${prune:-0}" -gt 550 ]; check $? "prune target is above the 550 minimum (got ${prune:-unset})"
grep -q 'pruned-node-max-peers' "$LB"; check $? "bitcoind example sets pruned-node-max-peers"
grep -q 'bitcoin.node=bitcoind' "$LB"; check $? "bitcoind example selects the bitcoind backend"
grep -q 'bitcoin.node=neutrino' "$LN"; check $? "neutrino example selects the neutrino backend"
grep -q 'v3_onion_private_key' "$LB"; check $? "bitcoind example flags the onion key dependency"
# RPC must never be reachable from outside the host.
grep -q '^rpcbind=127.0.0.1' "$BC"; check $? "bitcoin.conf binds RPC to localhost"

FP="$REPO/cloud/FAST-PATH.md"
grep -q 'v0.20.1-beta' "$FP"; check $? "fast path pins the LND version"
grep -q 'ROLLBACK BOUNDARY' "$FP"; check $? "fast path marks the rollback boundary"
grep -q 'v3_onion_private_key' "$FP"; check $? "fast path flags the onion key"
grep -q -- '--confirm' "$FP"; check $? "fast path uses the opt-in freeze flag"
# dbcache is raised for the sync and must be lowered again before LND starts.
grep -q 'dbcache=1500' "$FP"; check $? "fast path raises dbcache for the sync"
grep -q 'dbcache=450' "$FP"; check $? "fast path lowers dbcache again before LND"
bc_cache=$(grep -oE '^dbcache=[0-9]+' "$BC" | cut -d= -f2)
[ "${bc_cache:-0}" = 450 ]; check $? "bitcoin.conf steady-state dbcache matches (got ${bc_cache:-unset})"
echo

echo "no hardcoded home directories"
# No absolute home path is permitted anywhere. The remote node's lncli used to
# be exempt; it is a placeholder now, so the exemption is gone and a real path
# cannot creep back in under that name.
SCAN=$(grep -rn '/home/fletchervaughn' "$REPO/bin" "$REPO/lib" "$REPO/scripts" \
        "$REPO/local" "$REPO/remote-phunkii" "$REPO/config" 2>/dev/null | grep -v 'scripts/test\.sh')
[ -z "$SCAN" ]; check $? "no /home/fletchervaughn anywhere${SCAN:+ (found: $SCAN)}"
SCAN=$(grep -rn '/home/phunkii' "$REPO/bin" "$REPO/lib" "$REPO/scripts" \
        "$REPO/local" "$REPO/remote-phunkii" "$REPO/config" 2>/dev/null \
        | grep -v 'scripts/test\.sh')
[ -z "$SCAN" ]; check $? "no /home/phunkii anywhere${SCAN:+ (found: $SCAN)}"
echo

echo "committed example ships no remote target"
# scripts/install.sh copies config/lnd-ops.env.example to config/lnd-ops.env on
# a fresh install, so any non-empty LND_REMOTE_HOST here -- a real address or a
# placeholder -- satisfies the guard in bin/lnd-fee-alert.sh and makes every run
# ssh to it. The example must ship it empty.
EXAMPLE_HOST=$(sed -n 's/^[[:space:]]*LND_REMOTE_HOST=//p' "$REPO/config/lnd-ops.env.example" | head -n 1)
[ -z "$EXAMPLE_HOST" ]; check $? "example leaves LND_REMOTE_HOST empty${EXAMPLE_HOST:+ (found: $EXAMPLE_HOST)}"
SCAN=$(grep -nE '^[[:space:]]*LND_REMOTE_HOST=.*@' "$REPO/config/lnd-ops.env.example" "$REPO/lib/common.sh" 2>/dev/null)
[ -z "$SCAN" ]; check $? "no user@address committed as a remote host${SCAN:+ (found: $SCAN)}"
echo

echo "installer"
"$REPO/scripts/install.sh" --role local --dry-run >/dev/null 2>&1;  check $? "dry-run install (local) exits clean"
"$REPO/scripts/install.sh" --role remote --dry-run >/dev/null 2>&1; check $? "dry-run install (remote) exits clean"
"$REPO/scripts/install.sh" --role bogus --dry-run >/dev/null 2>&1
[ $? -ne 0 ]; check $? "rejects an unknown role"
echo

printf 'tests: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
