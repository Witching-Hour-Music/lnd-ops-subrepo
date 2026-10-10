# LND Ops Subrepo

Operational scripts and systemd user units for local and remote LND nodes.

Everything here runs from a checkout at any path, under any user account. No
Lightning node, network access, or systemd session is needed to run the tests.

## Quick start

```bash
scripts/test.sh                            # the full suite, against a stub node
scripts/preflight.sh                       # what is configured, what is missing
cp config/lnd-ops.env.example config/lnd-ops.env
scripts/install.sh --role local --dry-run  # show what would be installed
scripts/install.sh --role local            # install, timers left disabled
scripts/install.sh --role local --enable   # install and start the timers
```

Use `--role remote` on the phunkii node.

## What each script does

| Script | Changes state? | Purpose |
|---|---|---|
| `bin/lnd-health-report.sh` | no | Snapshot `getinfo`, `listchannels`, `feereport` to JSON; log an alert when a threshold is breached |
| `bin/lnd-hourly-summary.sh` | no | One line per hour: peers, active channels, 24h forwards and fees |
| `bin/lnd-fee-alert.sh` | no | Compare 24h routing revenue here and on the remote node against the last run |
| `bin/lnd-watchdog.sh` | restarts, reconnects | Restart lnd if down or RPC-unresponsive, then reconnect configured peers |
| `bin/lnd-fee-autotune.sh` | **yes** | Set each channel's outbound fee from its local-balance ratio |
| `bin/lnd-migrate-freeze.sh` | stops the node | Quiesce this host so `~/.lnd` can be copied elsewhere. Dry run by default. |
| `bin/lnd-migrate-verify.sh` | no | Verify a restored `~/.lnd` on the destination before starting lnd |

`lnd-fee-autotune.sh` is the only script that changes channel policy. Run it
with `--dry-run` to log what it would do and call nothing.

## Layout

```
bin/                        scripts, shared by both roles
cloud/                      migration runbook, gated checklist, backend configs
lib/common.sh               config resolution and helpers
config/lnd-ops.env.example  every tunable, with production defaults
local/systemd/              unit set for the workstation
remote-phunkii/systemd/     unit set for the phunkii node
scripts/                    install, preflight, test
test/fixtures/lncli-stub    canned lncli responses
```

## Production cloud operations

The production node now runs on DigitalOcean. The paid Droplet is the only
paid infrastructure assumed by the operations plan; supporting components are
free/open-source and self-hosted. Read [the FOSS cloud plan](cloud/FOSS-CLOUD-PLAN.md)
before adding a monitoring, backup, networking or integration dependency.

Run the read-only audit on the cloud host before making changes:

```bash
bash scripts/cloud-audit.sh
```

It checks host headroom, service visibility, LND sync/peers/channels, listening
sockets and static-channel-backup freshness. It never restarts a service or
calls a state-changing Lightning RPC.

## Moving the node to another host

For the shortest route, [`cloud/FAST-PATH.md`](cloud/FAST-PATH.md): one host,
no staging tier, three sittings. For the thorough staged version, read
[`cloud/MIGRATION.md`](cloud/MIGRATION.md) then execute the gated
[`cloud/CUTOVER-CHECKLIST.md`](cloud/CUTOVER-CHECKLIST.md). Either way:

```bash
bin/lnd-migrate-freeze.sh            # dry run, read the plan
bin/lnd-migrate-freeze.sh --confirm  # stop timers, then lnd, then archive
# scp the archive and manifest across
bin/lnd-migrate-verify.sh --manifest ~/lnd-manifest.sha256
```

Backend configuration references live alongside the runbook:

| File | Used for |
|---|---|
| `cloud/bitcoin.conf.example` | pruned Bitcoin Core, staging and permanent host |
| `cloud/lnd.conf.bitcoind.example` | the real cutover, pruned bitcoind backend |
| `cloud/lnd.conf.neutrino.example` | the disposable rehearsal wallet only |

Two copies of one wallet must never run at once. `freeze` stops every `lnd-*`
timer before stopping lnd, because the watchdog otherwise restarts it within a
minute, and it refuses to continue if the process or its RPC is still alive.
`verify` checks the restored directory against the source checksums and
confirms the identity-critical files arrived, `v3_onion_private_key` included.
The selected plan uses Azure only to stage a stopped pruned Bitcoin Core data
set, then moves LND directly from the workstation to the permanent VPS. Open
LND channels cannot be imported into Core Lightning; that later transition
requires closing LND channels and opening new CLN channels.

## Configuration

Copy `config/lnd-ops.env.example` to `config/lnd-ops.env` (gitignored) and
edit. Every value resolves from, in order: the environment, that file, then
the default in `lib/common.sh`.

The defaults reproduce what the scripts did when their paths were hardcoded,
so an unedited checkout behaves identically on the machine they were written
for, while also running anywhere else.

`LNCLI` is auto-detected: `~/bin/ln`, then `~/go/bin/lncli`, then `lncli` or
`ln` on PATH. Each candidate is probed with `--version`, and anything that
identifies as GNU coreutils is rejected, so the coreutils `ln` present on
every Linux box is never mistaken for `lncli`. Set `LNCLI` to pin one.

### Fee ladder

`LND_FEE_LADDER` maps local-balance percentage to outbound fee in ppm, read as
"at or above PCT, charge PPM":

```
80:2  65:5  55:10  45:25  35:60  20:120  0:250
```

A channel with no capacity on either side is treated as 50%. This is a live
economic setting; changing a rung changes what the node charges.

## Installation model

`scripts/install.sh` symlinks `bin/*.sh` into `~/.local/bin` rather than
copying, so the scripts keep resolving `lib/common.sh` and
`config/lnd-ops.env` from this checkout. Keep the checkout at a stable path.

Two units hardcode absolute paths that systemd cannot take from a variable,
so they ship as `.in` templates and the installer renders them:

- `lnd.service` — needs the `lnd` binary path (`LND_BIN`, else `lnd` on PATH)
- `lnd-flip-rebalance.service` — needs `flip_rebalance.sh`

Both are skipped with a message when their target is missing.

## Excluded (safety)

Wallet passphrases and files, macaroons, TLS private keys, any secret token or
password. `.gitignore` blocks the obvious filenames; check `git diff` before
committing regardless.

## Known gaps

- **`flip_rebalance.sh` is not in this repo.** It lives outside the subrepo
  (historically `~/bin/flip_rebalance.sh`), so the rebalancer is not version
  controlled and `lnd-flip-rebalance.service` cannot start from a fresh
  checkout. Moving it into `bin/` would close the last home-directory
  dependency.
- ~~`config/lnd-ops.env.example` carries the remote host and its lncli path as
  defaults.~~ Closed: the example ships them empty and `lib/common.sh` has no
  address as a default. To enable the remote comparison, set
  `LND_REMOTE_HOST` in the untracked `config/lnd-ops.env` **on the local
  node** -- `bin/lnd-fee-alert.sh` runs there and compares against the remote,
  and `scripts/install.sh` skips it for `--role remote`. Unset, it reports
  local figures and skips the remote side.
