#!/usr/bin/env bash
# Quiesce this node so its ~/.lnd can be copied to another host.
#
#   bin/lnd-migrate-freeze.sh              # dry run, shows the plan, changes nothing
#   bin/lnd-migrate-freeze.sh --confirm    # actually stop the node and archive
#
# Order matters. The watchdog timer restarts lnd within a minute, so every
# lnd-* timer is stopped and disabled BEFORE lnd itself. Stopping lnd first
# just gets it restarted underneath you.
#
# This does not move funds and does not touch channel state. It stops a
# service and reads files. But the node is offline when it finishes, which is
# the point: two copies of one wallet must never run at once.
set -euo pipefail
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/common.sh"

CONFIRM=0
OUT_DIR="${OUT_DIR:-$HOME/lnd-migration}"

while [ $# -gt 0 ]; do
  case "$1" in
    --confirm) CONFIRM=1; shift ;;
    --out)     OUT_DIR="${2:?--out needs a directory}"; shift 2 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) lnd_ops_die "unknown argument: $1" ;;
  esac
done

say()  { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
act()  {
  if [ "$CONFIRM" = 1 ]; then "$@"; else printf '   would run: %s\n' "$*"; fi
}

[ -d "$LND_DIR" ] || lnd_ops_die "no lnd directory at $LND_DIR"

say "lnd-ops migration freeze"
say "lnd dir:  $LND_DIR"
say "output:   $OUT_DIR"
if [ "$CONFIRM" = 1 ]; then
  say "mode:     CONFIRM — the node will be stopped"
else
  say "mode:     dry run — nothing will change"
fi

# --- 1. record what the node looks like while it is still up ---------------
step "1. Capture pre-stop state"
if [ -n "${LNCLI:-}" ] && "$LNCLI" getinfo >/dev/null 2>&1; then
  if [ "$CONFIRM" = 1 ]; then
    mkdir -p "$OUT_DIR"
    "$LNCLI" getinfo      > "$OUT_DIR/pre-getinfo.json"      2>/dev/null || true
    "$LNCLI" listchannels > "$OUT_DIR/pre-listchannels.json" 2>/dev/null || true
    say "   saved getinfo and listchannels to $OUT_DIR"
  else
    say "   would save getinfo and listchannels"
  fi
  if command -v jq >/dev/null 2>&1; then
    info="$("$LNCLI" getinfo 2>/dev/null || echo '{}')"
    say "   pubkey:   $(jq -r '.identity_pubkey // "?"' <<<"$info")"
    say "   channels: $(jq -r '.num_active_channels // 0' <<<"$info") active, $(jq -r '.num_inactive_channels // 0' <<<"$info") inactive"
    say "   uris:     $(jq -r '(.uris // []) | join(", ")' <<<"$info")"
  fi
else
  say "   node is not reachable; skipping live capture"
fi

# --- 2. timers first, or the watchdog undoes step 3 ------------------------
step "2. Stop and disable lnd-* timers"
if lnd_ops_has_systemd_user; then
  units="$(systemctl --user list-unit-files --no-legend 'lnd-*' 2>/dev/null | awk '{print $1}' || true)"
  if [ -z "$units" ]; then
    say "   no lnd-* units found"
  else
    for u in $units; do
      case "$u" in
        *.timer) say "   $u"; act systemctl --user disable --now "$u" ;;
      esac
    done
  fi
else
  say "   no systemd user manager reachable; nothing to stop"
fi

# --- 3. now lnd itself -----------------------------------------------------
step "3. Stop $LND_SERVICE"
if lnd_ops_has_systemd_user; then
  act systemctl --user disable --now "$LND_SERVICE"
else
  say "   no systemd user manager reachable"
  say "   stop lnd by hand before continuing"
fi

# --- 4. prove it is actually down ------------------------------------------
step "4. Verify the node is down"
if [ "$CONFIRM" = 1 ]; then
  ok=1
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if pgrep -x lnd >/dev/null 2>&1; then sleep 2; else ok=0; break; fi
  done
  if [ "$ok" != 0 ]; then
    lnd_ops_die "lnd is STILL RUNNING. Do not copy the data directory. Investigate first."
  fi
  say "   no lnd process"
  if [ -n "${LNCLI:-}" ] && "$LNCLI" getinfo >/dev/null 2>&1; then
    lnd_ops_die "lnd RPC still answering. Something restarted it. Stop and investigate."
  fi
  say "   RPC is closed"
else
  say "   would poll for the lnd process to exit, then confirm RPC is closed"
  say "   would abort the whole run if either check still succeeded"
fi

# --- 5. manifest -----------------------------------------------------------
step "5. Checksum the data directory"
if [ "$CONFIRM" = 1 ]; then
  mkdir -p "$OUT_DIR"
  ( cd "$LND_DIR" && find . -type f -print0 | sort -z | xargs -0 sha256sum ) > "$OUT_DIR/lnd-manifest.sha256"
  say "   $(wc -l < "$OUT_DIR/lnd-manifest.sha256") files checksummed"
  du -sh "$LND_DIR" | awk '{print "   size: " $1}'
else
  say "   would write sha256 for every file under $LND_DIR"
  du -sh "$LND_DIR" 2>/dev/null | awk '{print "   size: " $1}'
fi

# --- 6. archive ------------------------------------------------------------
step "6. Archive"
ARCHIVE="$OUT_DIR/lnd-$(date +%Y%m%d-%H%M%S).tar.gz"
if [ "$CONFIRM" = 1 ]; then
  tar -czf "$ARCHIVE" -C "$(dirname "$LND_DIR")" "$(basename "$LND_DIR")"
  sha256sum "$ARCHIVE" > "$ARCHIVE.sha256"
  say "   $ARCHIVE"
  say "   $(cut -d' ' -f1 "$ARCHIVE.sha256")"
else
  say "   would write $OUT_DIR/lnd-<timestamp>.tar.gz and its sha256"
fi

printf '\n%s\n' "------------------------------------------------------------------"
cat <<'WARN'
This archive contains wallet material: the seed-derived wallet.db,
channel state, macaroons, the TLS key, and the Tor onion key.

Move it over scp or another end-to-end encrypted channel. Do not put
it in cloud storage, email, chat, or any git repository.
WARN

if [ "$CONFIRM" = 1 ]; then
  cat <<'WARN'

The node on THIS host is now stopped and disabled. Once the copy on
the new host starts and connects to peers, this one is dead. Starting
it again after that publishes stale channel state, which your peers
can penalise. Do not restart it.
WARN
else
  cat <<'WARN'

Nothing has been stopped. On a --confirm run the node on this host
would be left stopped and disabled, and once the copy on the new host
started and connected to peers, this one would be dead: restarting it
after that publishes stale channel state, which peers can penalise.
WARN
fi
printf '%s\n' "------------------------------------------------------------------"

if [ "$CONFIRM" != 1 ]; then
  say ""
  say "Dry run only. Nothing changed. Re-run with --confirm when ready."
fi
