# Moving the local node to Azure

Target: the workstation node, currently two channels, running on an Azure VM
instead, with a neutrino backend for now and bitcoind later.

## The one rule

**Two copies of one wallet must never run at once, and you never go back.**

Everything below exists to serve that. The moment the Azure node finishes
starting and connects to peers, the workstation node is retired permanently.
Starting it again after that point publishes stale channel state, and your
peers are entitled to take the channel balance as a penalty.

Before that moment, rollback is free: if the Azure node fails to start,
nothing has changed anywhere, and you just start the workstation again.

## Cost

Sizing for neutrino, which needs no chain storage.

| Item | Spec | Rough monthly |
|---|---|---|
| VM | Standard_B2s, 2 vCPU, 4 GB | about 30 USD |
| Disk | 32 GB premium SSD | about 5 USD |
| Egress | a routing node with two channels | negligible |

Call it 35 USD a month. Moving to pruned bitcoind later adds a larger disk,
roughly 64 GB, and a bigger VM if you want it responsive, so budget more like
70 to 90 USD then.

**Set an Azure budget alert before you create anything.** Given how the GCP
bill went, put a hard budget with an email alert at 50 USD and another at 100.
Azure budgets are under Cost Management, and they take about a minute.

The GCP overspend was two full archival nodes on ETH and BTC. Neither is
needed here. Neutrino stores no chain at all, and a pruned bitcoind later
stores tens of gigabytes rather than terabytes.

## Do not put anything else on this VM

The phunkii node was shut down for a terms of service violation. The
workstation home directory contains xmrig, ccminer and a pile of mining pool
launch scripts. Cloud providers routinely suspend accounts for cryptomining,
and almost never for running a Lightning node.

Keep this VM to lnd, tor, and nothing else. If mining had anything to do with
the previous suspension, repeating it costs you this node too.

## Phase 0 — build the VM, risking nothing

The workstation node keeps running normally throughout this phase.

1. Create the VM. Ubuntu LTS, Standard_B2s, 32 GB disk, SSH key auth only,
   password auth disabled.
2. Network security group: allow inbound `22` from your IP only. Nothing
   else. Inbound Lightning traffic arrives over Tor, so `9735` stays closed.
3. Create an unprivileged `lnd` user. Do not run the node as root.
4. Install `tor` and `lnd`, matching the workstation's version. The
   workstation runs **v0.20.1-beta**. Use the same version. A newer lnd may
   migrate the channel database on first start, and that migration is not
   reversible.
5. Enable and start tor.

## Phase 1 — rehearse with a throwaway wallet

This is the step that de-risks the backend change, and it costs nothing.

Do **not** copy the real `~/.lnd` yet. Instead:

1. Put `cloud/lnd.conf.neutrino.example` in place as `~/.lnd/lnd.conf`.
2. `lnd` will start with no wallet. Create a brand new one with
   `lncli create`. Throw the seed away; this wallet is disposable and will
   never hold funds.
3. Watch it sync: `lncli getinfo` until `synced_to_chain` is true. Neutrino
   should take minutes, not hours.
4. Confirm the node got an onion address, which proves tor is wired up.

If that works, neutrino, tor, the VM and the lnd build are all proven on this
host. If it does not work, you have learned that while your real node is
still happily running at home.

Then delete the throwaway wallet completely:

```bash
sudo systemctl stop lnd
rm -rf ~/.lnd/data ~/.lnd/tls.* ~/.lnd/v3_onion_private_key
```

## Phase 2 — cutover

Only start this once Phase 1 succeeded and you have an hour free.

### On the workstation

```bash
cd ~/lnd-ops
bin/lnd-migrate-freeze.sh              # dry run first, read it
bin/lnd-migrate-freeze.sh --confirm
```

This stops and disables every `lnd-*` timer **before** stopping lnd, which
matters: the watchdog restarts lnd within a minute otherwise. It then proves
the process is gone and the RPC is closed, refuses to continue if either is
still alive, checksums every file under `~/.lnd`, and writes a tarball.

From here the workstation node is down. That is expected and intended.

### Transfer

```bash
scp ~/lnd-migration/lnd-*.tar.gz*        lnd@<azure-host>:~/
scp ~/lnd-migration/lnd-manifest.sha256  lnd@<azure-host>:~/
```

Use scp. The archive holds the wallet, the macaroons, the TLS key and the
onion key. It does not go in cloud storage, chat, email, or a git repo.

### On Azure

```bash
sha256sum -c lnd-*.tar.gz.sha256      # archive arrived intact
tar -xzf lnd-*.tar.gz -C ~            # restores ~/.lnd
```

Apply the neutrino backend **before the first start**:

```bash
# edit ~/.lnd/lnd.conf: set bitcoin.node=neutrino, remove the bitcoind
# section, add the [neutrino] block from cloud/lnd.conf.neutrino.example
```

Then verify, and only then start:

```bash
cd ~/lnd-ops
bin/lnd-migrate-verify.sh --manifest ~/lnd-manifest.sha256
```

That checks nothing is already running, every file matches the source
checksums, and the identity-critical files are present: `wallet.db`,
`channel.db`, `channel.backup`, `tls.key`, and `v3_onion_private_key`. The
onion key is the one people forget, and losing it changes the node's address
so peers can no longer reach it.

If verify passes:

```bash
sudo systemctl start lnd
lncli getinfo
lncli listchannels
```

Compare against `~/lnd-migration/pre-getinfo.json` and
`pre-listchannels.json` from the freeze step. Same pubkey, same two channels,
same channel points. `synced_to_chain` true.

**When this succeeds, the workstation node is retired. Do not start it again.**

### Install the ops scripts

```bash
cd ~/lnd-ops
cp config/lnd-ops.env.example config/lnd-ops.env   # LND_ROLE=local
scripts/preflight.sh
scripts/install.sh --role local --dry-run
scripts/install.sh --role local --enable
```

Leave the fee autotuner off until you have watched the node for a day:

```bash
bin/lnd-fee-autotune.sh --dry-run
```

Read what it intends before letting the timer apply it.

## If the Azure node will not start

Read the error first. The likely causes, in order:

1. **Backend mismatch.** `lnd.conf` still points at a bitcoind that does not
   exist on this host.
2. **Version skew.** A newer lnd wanting to migrate the channel database.
   Install the matching version instead of letting it migrate.
3. **Neutrino refusing the existing wallet.** This is the one I cannot
   promise works. Switching an established bitcoind wallet to neutrino is not
   a well-trodden path.

In all three cases, **nothing has been lost**, because the node never
connected. Restart the workstation node and regroup:

```bash
systemctl --user enable --now lnd.service
systemctl --user enable --now lnd-watchdog-local.timer lnd-health-report.timer
```

The freeze script disabled those units; this re-enables them.

If neutrino turns out to be the blocker, the fallback is pruned bitcoind:
stand it up on the Azure VM, let it sync for a day or two with the
workstation node still running, and cut over afterwards. Slower, but it
changes only the host and not the backend.

## Later: back to bitcoind

When the budget allows, this is a much smaller operation than the migration:
run pruned bitcoind alongside on the same VM, let it sync, then stop lnd,
switch `bitcoin.node` back to `bitcoind`, and start it. Same host, same
wallet, brief downtime.
