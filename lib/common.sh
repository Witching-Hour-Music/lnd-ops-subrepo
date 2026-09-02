#!/usr/bin/env bash
# Shared configuration and helpers for lnd-ops scripts.
#
# Source this from any script in this repo:
#
#   . "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/common.sh"
#
# It resolves every path and threshold from, in order: the existing
# environment, config/lnd-ops.env, then the built-in defaults below. The
# defaults reproduce the behaviour the scripts had when their paths were
# hardcoded, so an unconfigured checkout behaves identically on the machine
# it was written for while also running anywhere else.
#
# This library deliberately does NOT set shell options. A sourced file that
# turns on `set -e` changes the caller's control flow, which silently aborts
# any script that inspects a non-zero exit status. Each executable script
# sets its own options.

lnd_ops_repo_root() {
  local src="${BASH_SOURCE[0]}"
  cd "$(dirname "$(readlink -f "$src")")/.." && pwd
}

LND_OPS_ROOT="${LND_OPS_ROOT:-$(lnd_ops_repo_root)}"
export LND_OPS_ROOT

# --- config file ------------------------------------------------------------
# Values already present in the environment are never overwritten.
lnd_ops_load_config() {
  local file="${LND_OPS_CONFIG:-$LND_OPS_ROOT/config/lnd-ops.env}"
  [ -f "$file" ] || return 0
  local key value
  while IFS= read -r line; do
    line="${line%%#*}"
    line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -n "$line" ] || continue
    case "$line" in *=*) ;; *) continue ;; esac
    key="${line%%=*}"
    value="${line#*=}"
    case "$key" in [A-Za-z_][A-Za-z0-9_]*) ;; *) continue ;; esac
    # Only set if unset, so the environment always wins.
    if [ -z "${!key:-}" ]; then
      value="$(eval "printf '%s' \"$value\"" 2>/dev/null || printf '%s' "$value")"
      export "$key=$value"
    fi
  done < "$file"
}
lnd_ops_load_config

# --- role -------------------------------------------------------------------
LND_ROLE="${LND_ROLE:-local}"

# --- lncli ------------------------------------------------------------------
# Auto-detect unless pinned. Order matches how the two nodes were set up:
# the workstation uses a ~/bin/ln wrapper, the phunkii node uses ~/go/bin/lncli.
#
# `ln` is also GNU coreutils' link command, which is on PATH on every Linux
# box. Picking that up would send `ln getinfo` to coreutils, so every
# candidate is probed and anything identifying as coreutils is rejected.
lnd_ops_probe_lncli() {
  # 0 = verified lncli, 1 = definitely not, 2 = unknown (no usable --version)
  local candidate="$1" out
  out="$("$candidate" --version 2>&1 | head -3)" || true
  case "$out" in
    *coreutils*|*"GNU coreutils"*) return 1 ;;
    *lncli*|*lnd*)                 return 0 ;;
  esac
  return 2
}

lnd_ops_detect_lncli() {
  local candidate fallback="" rc
  for candidate in "$HOME/bin/ln" "$HOME/go/bin/lncli" "$(command -v lncli 2>/dev/null)" "$(command -v ln 2>/dev/null)"; do
    [ -n "$candidate" ] || continue
    [ -x "$candidate" ] || continue
    lnd_ops_probe_lncli "$candidate"; rc=$?
    case "$rc" in
      0) printf '%s' "$candidate"; return 0 ;;          # verified
      1) continue ;;                                     # coreutils, reject
      2) [ -n "$fallback" ] || fallback="$candidate" ;;  # unverifiable wrapper
    esac
  done
  # No candidate identified itself. Accept an unverifiable one only if it is
  # not a bare `ln` picked off PATH.
  case "$fallback" in
    ""|*/bin/ln)
      case "$fallback" in
        "$HOME/bin/ln") printf '%s' "$fallback"; return 0 ;;
        *) return 1 ;;
      esac
      ;;
    *) printf '%s' "$fallback"; return 0 ;;
  esac
}

if [ -z "${LNCLI:-}" ]; then
  LNCLI="$(lnd_ops_detect_lncli || true)"
fi
export LNCLI

# --- paths ------------------------------------------------------------------
LND_DIR="${LND_DIR:-$HOME/.lnd}"
LND_WALLET_PASS_FILE="${LND_WALLET_PASS_FILE:-$LND_DIR/wallet.pass}"
LND_SERVICE="${LND_SERVICE:-lnd.service}"
LND_PEERS_FILE="${LND_PEERS_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/lnd/watchdog-peers}"
LND_STATE_DIR="${LND_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}}"
LND_CACHE_DIR="${LND_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}}"

# --- health thresholds ------------------------------------------------------
LND_MIN_PEERS="${LND_MIN_PEERS:-3}"
if [ -z "${LND_MIN_ACTIVE_CHANNELS:-}" ]; then
  # The remote node runs fewer channels than the workstation.
  if [ "$LND_ROLE" = "remote" ]; then
    LND_MIN_ACTIVE_CHANNELS=1
  else
    LND_MIN_ACTIVE_CHANNELS=2
  fi
fi
LND_MAX_INACTIVE_CHANNELS="${LND_MAX_INACTIVE_CHANNELS:-0}"

# --- forwarding history -----------------------------------------------------
LND_FWD_LOOKBACK="${LND_FWD_LOOKBACK:-24 hours ago}"
LND_FWD_MAX_EVENTS="${LND_FWD_MAX_EVENTS:-5000}"

# --- fee autotune -----------------------------------------------------------
LND_FEE_LADDER="${LND_FEE_LADDER:-80:2 65:5 55:10 45:25 35:60 20:120 0:250}"
LND_FEE_BASE_MSAT="${LND_FEE_BASE_MSAT:-0}"
LND_FEE_TIME_LOCK_DELTA="${LND_FEE_TIME_LOCK_DELTA:-40}"
LND_FEE_APPLY="${LND_FEE_APPLY:-1}"

# --- remote node ------------------------------------------------------------
LND_REMOTE_HOST="${LND_REMOTE_HOST:-phunkii@20.127.136.37}"
LND_REMOTE_LNCLI="${LND_REMOTE_LNCLI:-/home/phunkii/go/bin/lncli}"
LND_REMOTE_SSH_TIMEOUT="${LND_REMOTE_SSH_TIMEOUT:-6}"

# --- helpers ----------------------------------------------------------------
lnd_ops_die() { printf 'lnd-ops: %s\n' "$*" >&2; exit 1; }

lnd_ops_require_lncli() {
  [ -n "${LNCLI:-}" ] || lnd_ops_die "no lncli found; set LNCLI in config/lnd-ops.env"
  [ -x "$LNCLI" ] || command -v "$LNCLI" >/dev/null 2>&1 \
    || lnd_ops_die "LNCLI is not executable: $LNCLI"
}

lnd_ops_require_jq() {
  command -v jq >/dev/null 2>&1 || lnd_ops_die "jq is required but not installed"
}

# True when a systemd user manager is actually reachable. The systemctl
# binary existing is not enough: containers and SSH sessions without a user
# bus have it on PATH but cannot talk to it.
lnd_ops_has_systemd_user() {
  command -v systemctl >/dev/null 2>&1 || return 1
  systemctl --user show-environment >/dev/null 2>&1
}

lnd_ops_state_dir() {
  local dir="$LND_STATE_DIR${1:+/$1}"
  mkdir -p "$dir"
  printf '%s' "$dir"
}

lnd_ops_log_file() {
  local file="$LND_STATE_DIR/$1"
  mkdir -p "$(dirname "$file")"
  printf '%s' "$file"
}

# Start of the forwarding-history window, as a unix timestamp.
lnd_ops_fwd_start() { date -d "$LND_FWD_LOOKBACK" +%s; }

# Map a local-balance percentage to an outbound fee in ppm using LND_FEE_LADDER.
lnd_ops_map_ppm() {
  local pct="$1" entry threshold ppm
  for entry in $LND_FEE_LADDER; do
    threshold="${entry%%:*}"
    ppm="${entry##*:}"
    if (( pct >= threshold )); then
      printf '%s' "$ppm"
      return 0
    fi
  done
  # Ladder should end at 0; fall back to its last rung if it does not.
  printf '%s' "$ppm"
}
