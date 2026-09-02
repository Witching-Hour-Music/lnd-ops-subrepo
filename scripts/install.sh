#!/usr/bin/env bash
# Install lnd-ops scripts and systemd user units for one role.
#
#   scripts/install.sh --role local
#   scripts/install.sh --role remote --enable
#   scripts/install.sh --role local --dry-run
#
# Scripts are symlinked (not copied) from this checkout into ~/.local/bin so
# they keep resolving lib/common.sh and config/lnd-ops.env from the repo.
# Keep the checkout at a stable path.
set -euo pipefail
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/common.sh"

ROLE=""
ENABLE=0
DRY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --role)    ROLE="${2:-}"; shift 2 ;;
    --enable)  ENABLE=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) lnd_ops_die "unknown argument: $1" ;;
  esac
done

case "$ROLE" in
  local)  UNIT_DIR="$LND_OPS_ROOT/local/systemd" ;;
  remote) UNIT_DIR="$LND_OPS_ROOT/remote-phunkii/systemd" ;;
  *) lnd_ops_die "--role must be 'local' or 'remote'" ;;
esac

BIN_DIR="$HOME/.local/bin"
SYSTEMD_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

run() {
  if [ "$DRY" = 1 ]; then
    printf '  would run: %s\n' "$*"
  else
    "$@"
  fi
}

write_file() {
  # write_file <dest> <content>
  if [ "$DRY" = 1 ]; then
    printf '  would write: %s\n' "$1"
  else
    printf '%s' "$2" > "$1"
  fi
}

echo "lnd-ops install (role=$ROLE, checkout=$LND_OPS_ROOT)"

# --- config ---------------------------------------------------------------
CONFIG="$LND_OPS_ROOT/config/lnd-ops.env"
if [ ! -f "$CONFIG" ]; then
  echo "config: creating $CONFIG from example"
  run cp "$LND_OPS_ROOT/config/lnd-ops.env.example" "$CONFIG"
  if [ "$ROLE" = remote ] && [ "$DRY" = 0 ]; then
    sed -i 's/^LND_ROLE=.*/LND_ROLE=remote/' "$CONFIG"
  fi
else
  echo "config: $CONFIG already exists, leaving it alone"
fi

# --- scripts --------------------------------------------------------------
echo "scripts: symlinking into $BIN_DIR"
run mkdir -p "$BIN_DIR"
for src in "$LND_OPS_ROOT"/bin/*.sh; do
  name="$(basename "$src")"
  # fee-alert compares against the remote node; it belongs on the local node.
  if [ "$ROLE" = remote ] && [ "$name" = "lnd-fee-alert.sh" ]; then
    continue
  fi
  echo "  $name"
  run ln -sfn "$src" "$BIN_DIR/$name"
done

# --- systemd units --------------------------------------------------------
echo "units: installing into $SYSTEMD_DIR"
run mkdir -p "$SYSTEMD_DIR"

LND_BIN_RESOLVED="${LND_BIN:-$(command -v lnd 2>/dev/null || true)}"
FLIP_REBALANCE_BIN="${FLIP_REBALANCE_BIN:-$HOME/bin/flip_rebalance.sh}"

for src in "$UNIT_DIR"/*; do
  name="$(basename "$src")"
  case "$name" in
    *.in)
      unit="${name%.in}"
      case "$unit" in
        lnd.service)
          if [ -z "$LND_BIN_RESOLVED" ]; then
            echo "  SKIP $unit — no lnd binary found; set LND_BIN and re-run"
            continue
          fi
          echo "  $unit (lnd=$LND_BIN_RESOLVED)"
          rendered="$(sed -e "s#@LND_BIN@#$LND_BIN_RESOLVED#g" \
                          -e "s#@LND_WALLET_PASS_FILE@#$LND_WALLET_PASS_FILE#g" "$src")"
          write_file "$SYSTEMD_DIR/$unit" "$rendered"
          ;;
        lnd-flip-rebalance.service)
          if [ ! -x "$FLIP_REBALANCE_BIN" ]; then
            echo "  SKIP $unit — $FLIP_REBALANCE_BIN not present (see README, Known gaps)"
            continue
          fi
          echo "  $unit"
          rendered="$(sed -e "s#@LNCLI@#$LNCLI#g" \
                          -e "s#@FLIP_REBALANCE_BIN@#$FLIP_REBALANCE_BIN#g" "$src")"
          write_file "$SYSTEMD_DIR/$unit" "$rendered"
          ;;
        *)
          echo "  $unit (template)"
          write_file "$SYSTEMD_DIR/$unit" "$(cat "$src")"
          ;;
      esac
      ;;
    *)
      echo "  $name"
      run cp "$src" "$SYSTEMD_DIR/$name"
      ;;
  esac
done

run systemctl --user daemon-reload

# --- enable ---------------------------------------------------------------
if [ "$ENABLE" = 1 ]; then
  echo "enable: starting timers"
  for timer in "$UNIT_DIR"/*.timer; do
    [ -e "$timer" ] || continue
    run systemctl --user enable --now "$(basename "$timer")"
  done
else
  echo
  echo "Timers installed but not enabled. To start them:"
  echo "  scripts/install.sh --role $ROLE --enable"
  echo "Or enable individually, e.g.:"
  echo "  systemctl --user enable --now lnd-health-report.timer"
fi

echo
echo "Next: scripts/preflight.sh"
