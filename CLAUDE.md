# lnd-ops-subrepo

Operational scripts and systemd user units for the two LND nodes: the
workstation (`local`) and the phunkii node (`remote`).

## Layout

```
bin/                     the scripts, shared by both roles
cloud/                   migration runbook, gated cutover checklist, configs
lib/common.sh            config resolution and helpers, sourced by every script
config/lnd-ops.env.example  every tunable, with the production defaults
local/systemd/           unit set for the workstation
remote-phunkii/systemd/  unit set for the phunkii node
scripts/install.sh       symlink scripts, render and install units
scripts/preflight.sh     read-only readiness check
scripts/test.sh          full suite against a stub lncli, no node needed
test/fixtures/lncli-stub canned lncli responses
```

`bin/` is shared deliberately. The two roles previously kept near-identical
copies of the same four scripts that differed only in hardcoded paths.

## Commands

```
scripts/test.sh                      # the full suite, needs no node or network
scripts/preflight.sh                 # what is configured, what is missing
scripts/install.sh --role local --dry-run
scripts/install.sh --role local --enable
bin/lnd-fee-autotune.sh --dry-run    # show intended fee policy, change nothing
```

Run `scripts/test.sh` after touching anything in `bin/` or `lib/`.

## Configuration

Nothing is hardcoded to a home directory. Every path and threshold resolves
from, in order: the environment, `config/lnd-ops.env`, then the default in
`lib/common.sh`. The defaults reproduce the behaviour these scripts had when
their paths were baked in, so an unconfigured checkout is not a behaviour
change on the machine they were written for.

`lib/common.sh` does not set shell options. A sourced file that turns on
`set -e` changes its caller's control flow. Each executable sets its own.

## Wallet and transaction safety

- `bin/lnd-migrate-freeze.sh` stops a live node. It is dry-run by default and
  needs `--confirm` to act. It aborts rather than continue if lnd is still
  running after the stop, because copying a live data directory produces a
  corrupt channel database.
- Never run two copies of one wallet. After a migrated node connects to peers,
  the source host is retired permanently; restarting it publishes stale
  channel state that peers can penalise.
- `bin/lnd-fee-autotune.sh` is the only script here that changes node state.
  Everything else is read-only apart from the watchdog's service restarts and
  peer reconnects. Validate with `--dry-run` before `--apply`.
- Never change an amount, fee rate, peer, destination, or channel size from
  what the user specified, even where another value looks more correct. Ask
  first.
- Only execute a fund-moving action when the user asks for that specific
  action. A general go-ahead does not carry to a new amount or destination.
- The fee ladder in `LND_FEE_LADDER` is a live economic setting. Changing a
  rung changes what the node charges. Do not tune it without being asked.

## Known gaps

- `flip_rebalance.sh` is not in this repo. `lnd-flip-rebalance.service` needs
  it at `$HOME/bin/flip_rebalance.sh`; the installer skips the unit when it is
  absent. It should be moved into `bin/` so the rebalancer is version
  controlled like everything else.
- The remote host has no default, in `lib/common.sh` or in
  `config/lnd-ops.env.example`. This repository is public: a `user@address`
  default is an SSH target published to every reader, and `scripts/install.sh`
  copies the example into `config/lnd-ops.env`, so even a placeholder would be
  non-empty and make `bin/lnd-fee-alert.sh` ssh to a host that does not exist.
  Set `LND_REMOTE_HOST` in the untracked `config/lnd-ops.env` on the **local**
  node (fee-alert runs there; the installer skips it for `--role remote`), and
  never commit it.

## Never commit

Wallet passphrases, macaroons, TLS private keys, seeds, tokens. `.gitignore`
blocks the obvious filenames; that is a backstop, not a substitute for
checking `git diff` before committing.
