# Moving the local node to a permanent cloud host

The concrete, operator-facing procedure is
[`CUTOVER-CHECKLIST.md`](CUTOVER-CHECKLIST.md). This page records why the
architecture is staged this way.

## Chosen architecture

| Role | Host | Lifetime | Wallet material |
|---|---|---|---|
| Current authority | local workstation | until cutover | existing LND wallet and two channels |
| Sync accelerator | rebuilt Azure `Standard_D2s_v4` on Ubuntu | temporary | **none** |
| Permanent node | 2 vCPU / 4 GiB / 80 GiB Ubuntu VPS, about USD 24/month | ongoing | LND, then a separate CLN wallet later |

Azure is used only to synchronize a pruned Bitcoin Core data directory more
quickly. Bitcoin Core is stopped cleanly before that chain data is checksummed
and copied to the permanent VPS. The LND wallet, seed, password, macaroons,
`channel.db`, channel backup and Tor key never go to Azure.

The LND archive moves exactly once: directly from the stopped workstation to
the permanent VPS.

## What “move to Core Lightning” means

The two open channels belong to the current LND node. LND's wallet and channel
databases cannot be imported into Core Lightning.

The safe sequence is:

1. Preserve both channels by moving LND intact to the permanent VPS.
2. Run and observe that LND node on its original backend.
3. Install CLN later with a separate wallet, node identity, data directory,
   ports and Tor service.
4. Cooperatively close the LND channels one at a time.
5. Wait for confirmed, spendable on-chain funds and all sweeps/timelocks.
6. Transfer funds to CLN and open new CLN channels.
7. Retire LND only when it has no channels, pending closes or unswept funds.

CLN normally uses Bitcoin Core through its Bitcoin backend plugin. Neutrino is
an LND backend choice; it is not part of this CLN cutover plan.

## The one wallet rule

**Two copies of the LND wallet must never run at once.**

The freeze script disables every `lnd-*` timer before stopping LND so the
watchdog cannot restart it underneath the archive. The destination must match
the source LND version and use the already-proven Bitcoin backend.

The rollback boundary is deliberately conservative: rollback to the
workstation is allowed only before destination LND has been started. Once LND
is started on the permanent VPS, never start the old copy again. Diagnose and
recover forward on the permanent host.

## Why the backend is not changed during cutover

Changing host, operating environment, Bitcoin backend and Lightning
implementation in one operation makes a failure ambiguous and turns rollback
into guesswork.

The real-wallet move therefore retains LND v0.20.1-beta and the existing
bitcoind backend. Neutrino may be rehearsed with a disposable LND wallet, but
an established production wallet is not switched during its host migration.

## Cost boundary

The existing Azure D2s v4 is not the permanent host. It is billed only while
used for synchronization and transfer, then the VM, detached disks, public IP,
NIC and unwanted snapshots are removed after the permanent backend is proven.

The steady-state target is the approximately USD 24/month VPS. Configure a
provider budget alert and encrypted backups. Cloud snapshots contain sensitive
wallet material once LND is installed, so access to the provider account and
backup retention are part of node security.

## Safety gates

Cutover cannot begin until all of the following are true:

- The local node reports the expected pubkey and exactly the two expected
  channel points.
- There are no unexplained pending/force-closing channels and no indication
  that the missing phunkii/Umbrel host holds newer channel state.
- Seed, wallet password and a fresh static channel backup are recoverable
  outside the workstation.
- Source OS/CPU architecture, LND version, Bitcoin Core version and backend
  settings are recorded.
- Permanent Bitcoin Core is synchronized, pruned, fits its disk, and its RPC
  and ZMQ endpoints work from a disposable LND rehearsal.
- Tor, service stop/start behavior, checksums, ownership and file permissions
  have all been rehearsed without the real wallet.
- GitHub Actions success is not treated as evidence until the organization's
  runner `startup_failure` problem is resolved; run the fixture suite in a
  working environment and retain its output.

See the checklist for the exact stop/go sequence, validation snapshots, source
freeze, direct transfer, first start, 24-hour observation period, Azure
cleanup and later CLN transition.

## Sensitive data

Move wallet material only over an authenticated, encrypted SSH/SCP channel.
Never place it in Azure staging storage, cloud drives, chat, email or git.
Verify archive and file manifests before first start and keep destination data
owner-only.
