---
name: code-review
description: Review changes to this repository. Use for any pull request or diff touching bin/, lib/, scripts/, systemd units, or config — and for any change that could affect a running Lightning node.
---

# Reviewing lnd-ops-subrepo

This repository operates two real Lightning nodes holding real funds. A defect
here is not a failed build; it is a corrupt channel database, a force-close, or
a node that looks healthy and is not. Review accordingly.

Run `scripts/test.sh` before forming an opinion. It runs against a stub `lncli`
in `test/fixtures/` and needs no node, network or systemd. A reviewer who has
not run it is guessing.

## The rules that outrank everything else

**Never approve a change that could put two copies of one wallet online.**
After a node is moved and connects to peers, the source host is retired
permanently — restarting it publishes stale channel state that peers can
penalise. Any change touching backup, restore, migration, or service enablement
gets read against this first.

**Fund-moving code needs an explicit opt-in.** `bin/lnd-fee-autotune.sh` is the
only script here that changes node state. Everything else is read-only apart
from the watchdog's service restarts and peer reconnects. A change that makes a
script act by default, or that widens what it touches, is blocking. Validate
with `--dry-run` before `--apply`.

**`LND_FEE_LADDER` is a live economic setting.** It is defined in
`lib/common.sh` and changing a rung changes what the node charges. A diff that
adjusts it without the request explicitly asking for that is a finding even if
the new values look more sensible. Same for any amount, fee rate, peer,
destination, or channel size: never silently "correct" one.

**Never approve secrets.** Wallet passphrases, macaroons, TLS private keys,
seeds, tokens. `.gitignore` is a backstop, not the check. Read the diff.

## The watchdog changes what "stop the node" means

`local/systemd/lnd-watchdog-local.timer` runs `OnUnitActiveSec=60s`, and
`bin/lnd-watchdog.sh` calls `systemctl --user restart` on the lnd service. So
lnd restarts within a minute of being stopped.

Anything that stops lnd must stop and disable the `lnd-*` timers **first**.
Stopping lnd alone gets it restarted underneath whatever came next, and a data
directory copied from a running node has a corrupt `channel.db`. If a diff
reorders those steps, or stops lnd without touching the timers, that is
blocking regardless of how clean the code looks.

## Things that have actually gone wrong here

These shapes are real findings from this repository, not hypotheticals:

- **`grep` capturing more than one line.** A `grep -n` that matched several
  lines fed multiple line numbers into a numeric comparison and produced
  `[: 2\n5: integer expression expected`. Prefer `grep -n -m1`. Check every
  command substitution feeding an arithmetic or `[` test.
- **`lncli` resolving to GNU coreutils `ln`.** `ln` is coreutils' link command
  and is on PATH on every Linux box, so naive detection sent `ln getinfo` to
  coreutils. `lnd_ops_probe_lncli()` in `lib/common.sh` exists because of this:
  it probes each candidate and rejects anything identifying as coreutils.
  Anything new that discovers an executable must verify what it found.
- **A sourced library setting shell options.** `lib/common.sh` deliberately does
  not set them — a sourced file that turns on `set -e` changes its caller's
  control flow. Each executable sets its own. A diff adding `set` to the
  library is blocking.
- **Dry runs that claim to have acted.** A dry run once printed that a node had
  been stopped while touching nothing. Every message a dry run prints must be
  true of a dry run.
- **Assertions left behind after a rewording.** A test kept checking a string
  that had been removed and passed for the wrong reason. When output text
  changes, grep the suite for the old string.

## Configuration and paths

Nothing is hardcoded to a home directory. Every path and threshold resolves
from, in order: the environment, `config/lnd-ops.env`, then the default in
`lib/common.sh`. The defaults reproduce the behaviour these scripts had when
paths were baked in, so an unconfigured checkout is not a behaviour change on
the machine they were written for.

A new hardcoded `/home/...` is a finding. That coupling is the reason a
100 GB versioned home directory used to be a dependency of this repo.

`bin/` is shared by both roles deliberately. The two roles previously kept
near-identical copies of the same four scripts, differing only in hardcoded
paths. A change reintroducing a role-specific copy needs to justify itself.

`config/lnd-ops.env.example` carries every tunable with its production default.
The real `config/lnd-ops.env` is untracked; host-specific values belong there.

## Configuration pairs that must agree

Some mismatches produce a node that starts cleanly, reports healthy, and is
silently broken. Review these as pairs, never individually:

- **Both ZMQ endpoints**, wherever a Bitcoin Core config and an lnd config ship
  together. A mismatch gives a node that never sees a new block.
- **The LND version**, between hosts in any move. A newer lnd migrates
  `channel.db` on first start and that is not reversible.
- **`prune` and disk sizing**, between config and runbook. LND refetches
  discarded blocks from peers and Tor makes that slower, so a minimal
  `prune=550` is the wrong choice here.

If a change adds migration or cutover tooling, `v3_onion_private_key` must
survive the move or the onion address changes and peers cannot reach the node.
Archives holding wallet material move over scp only.

## What to report, and how

Say what breaks and under what input. "This could be clearer" is not a finding;
"a `channel.db` copied at this point is corrupt, because the watchdog restarts
lnd within 60 seconds" is.

Verify before reporting. These scripts are testable against the stub with no
node — reproduce the failure, then state it with the output. Several of the
bugs listed above were caught by running the suite, not by reading.

Do not invent severity. A style preference reported as a risk trains the author
to ignore the next real finding.

Rank blocking findings first: wallet safety, then ordering and correctness,
then tests, then everything else.
