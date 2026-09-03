# Concrete cutover checklist

Target architecture:

- **Temporary staging:** the existing Azure `Standard_D2s_v4`, rebuilt as
  Ubuntu, used only to accelerate a pruned Bitcoin Core initial sync.
- **Permanent host:** a 2 vCPU / 4 GiB / 80 GiB Linux VPS in the roughly
  USD 24/month class.
- **Channel-preserving move:** the current LND v0.20.1-beta data directory
  moves once, directly from the workstation to the permanent VPS.
- **Later implementation change:** Core Lightning is introduced as a new node.
  Open LND channels cannot be imported into CLN.

Mark every box. A failed **STOP** gate ends the attempt; do not improvise around
it while channel funds are at risk.

## 0. Record the decisions

- [ ] Permanent VPS provider, region, plan and operator are recorded.
- [ ] Both staging and permanent hosts are Ubuntu LTS on x86_64.
- [ ] The real cutover keeps LND v0.20.1-beta and its existing Bitcoin backend.
- [ ] Neutrino testing and the later CLN transition are separate changes.
- [ ] A maintenance window of at least one uninterrupted hour is reserved.
- [ ] Azure is temporary; its deletion is part of this plan, not a later idea.

## 1. Prove the workstation is the authoritative node

Run these while the local LND node is healthy and save the output outside git:

```bash
lnd --version
lncli getinfo > pre-getinfo.json
lncli walletbalance > pre-walletbalance.json
lncli channelbalance > pre-channelbalance.json
lncli listchannels > pre-listchannels.json
lncli pendingchannels > pre-pendingchannels.json
lncli listpeers > pre-listpeers.json
lncli exportchanbackup --all > channel.backup
```

- [ ] `getinfo` reports the expected identity pubkey and mainnet.
- [ ] Exactly the two expected channel points appear in `listchannels`.
- [ ] `pendingchannels` has no unexpected force-closing, waiting-close or
      pending-open channel.
- [ ] The wallet seed, wallet password and fresh static channel backup are
      recoverable without using the workstation.
- [ ] The current `lnd.conf`, Bitcoin backend, Bitcoin Core version, ZMQ
      endpoints, Tor settings, service user, OS and CPU architecture are
      recorded.
- [ ] There is no evidence that the missing phunkii/Umbrel machine has newer
      channel state.

**STOP:** If the local node cannot show both channels, has a fatal database
error, or may not hold the newest channel state, treat this as recovery. Do not
run the migration scripts.

## 2. Rebuild Azure as a temporary Bitcoin Core staging host

Erasing the EOS FAM VM is destructive and was approved for this plan.

- [ ] Anything worth retaining from the Windows disk has been exported.
- [ ] Rebuild the VM with Ubuntu LTS, SSH key authentication and no password
      login.
- [ ] Remove the unrelated EOS/Zoho workload identity and extensions.
- [ ] Allow SSH only from the operator's current IP.
- [ ] Do not expose Bitcoin RPC, ZMQ, LND REST/RPC or port 9735 publicly.
- [ ] Create an unprivileged Bitcoin service user.
- [ ] Install the exact Bitcoin Core version intended for the permanent VPS.
- [ ] Configure pruning small enough to fit the permanent 80 GiB disk, with
      room for chainstate, logs, LND/CLN data and upgrades. See
      `cloud/bitcoin.conf.example`: `prune=20000` lands near 45 GB total once
      the ~11 GB 2026 chainstate and LND are counted. Do not use the
      `prune=550` minimum, because LND refetches discarded blocks from P2P
      peers and that is slower again over Tor.
- [ ] Keep `txindex=0`; configure the ZMQ endpoints required by LND. Both
      `zmqpubrawblock` and `zmqpubrawtx` must match `lnd.conf` exactly, or LND
      never sees new blocks.
- [ ] Start Bitcoin Core and complete initial block download.

Azure never receives `~/.lnd`, the LND seed, wallet password, macaroons,
channel database, or Tor identity.

## 3. Prove the staged Bitcoin backend

- [ ] `bitcoin-cli getblockchaininfo` reports mainnet.
- [ ] `initialblockdownload` is false.
- [ ] Header count equals block count and verification progress is current.
- [ ] Pruning is active and disk usage fits the permanent VPS with safe margin.
- [ ] RPC is bound to localhost or a private interface, never the public IP.
- [ ] Bitcoin Core is stopped cleanly before any chain-data copy.
- [ ] A manifest/checksum is generated for the stopped Bitcoin data.

## 4. Build the permanent VPS

- [ ] Create the 2 vCPU / 4 GiB / 80 GiB Ubuntu VPS.
- [ ] Enable SSH key authentication; disable password and root SSH login.
- [ ] Enable automatic security updates without uncontrolled automatic reboot.
- [ ] Configure a firewall: SSH from the operator IP; no public RPC/REST/ZMQ.
- [ ] Create separate unprivileged service accounts/data directories.
- [ ] Configure encrypted provider backups or snapshots and a monthly budget
      alert.
- [ ] Install the exact staged Bitcoin Core version.
- [ ] Transfer only the stopped Bitcoin chain data from Azure over SSH.
- [ ] Verify the transfer against the staging manifest and correct ownership.
- [ ] Start Bitcoin Core and repeat every gate in section 3.

**STOP:** Do not freeze local LND until the permanent Bitcoin backend passes
every check.

## 5. Rehearse without the real wallet

Use a separate disposable LND directory. Never point the rehearsal process at
the restored production directory.

- [ ] Install exactly LND v0.20.1-beta.
- [ ] Confirm it can use the permanent Bitcoin Core RPC and ZMQ endpoints.
- [ ] Confirm the disposable node reaches `synced_to_chain` against the pruned
      backend, which proves block refetching works before real funds depend
      on it.
- [ ] Confirm Tor starts and produces an onion service.
- [ ] Confirm systemd starts, stops and leaves the disposable node stopped.
- [ ] Delete the disposable wallet/data and verify the production LND
      directory is still absent.
- [ ] Run this repository's test suite and preflight locally on the VPS.

## 6. Freeze the source

- [ ] Stop new operational changes: no channel opens/closes, payments,
      rebalances, fee automation or upgrades.
- [ ] Run `bin/lnd-migrate-freeze.sh` without flags and read the dry run.
- [ ] Confirm it lists the watchdog and all other `lnd-*` timers before LND.
- [ ] Run `bin/lnd-migrate-freeze.sh --confirm`.
- [ ] Confirm no `lnd` process remains and RPC does not answer.
- [ ] Confirm the archive, archive checksum, manifest and pre-stop snapshots
      exist.
- [ ] Keep the workstation powered off or network-isolated after the archive
      is produced.

## 7. Transfer directly to the permanent VPS

- [ ] Copy the LND archive and manifests directly from the workstation to the
      permanent VPS using SSH/SCP.
- [ ] Do not route Lightning wallet material through Azure, cloud drives,
      email, chat or git.
- [ ] Verify the archive checksum before extraction.
- [ ] Extract as the dedicated LND user.
- [ ] Set directories to owner-only and verify all ownership.
- [ ] Restore the original Tor onion private key.
- [ ] Configure LND for the already-proven local Bitcoin Core RPC/ZMQ backend,
      using `cloud/lnd.conf.bitcoind.example` as the reference. Set
      `bitcoind.pruned-node-max-peers` since the backend is pruned.
- [ ] Do not change LND version, database backend, chain backend or Lightning
      implementation during this move.
- [ ] Run `bin/lnd-migrate-verify.sh --manifest ...` and resolve every
      failure and warning relevant to Tor or auto-unlock.

**ROLLBACK BOUNDARY:** Rollback to the workstation is allowed only before LND
has been started on the permanent VPS. Once destination LND is started, do not
restart the old copy. Investigate and recover forward on the permanent host.

## 8. Start once and validate

- [ ] A second operator/read-through confirms the source is stopped and
      destination paths, version and backend are correct.
- [ ] Start LND once.
- [ ] Confirm the expected identity pubkey.
- [ ] Confirm the same two channel points.
- [ ] Confirm wallet and channel balances match the saved snapshots.
- [ ] Confirm no unexpected pending or force-closing channels.
- [ ] Confirm chain and graph synchronization.
- [ ] Confirm peers reconnect and the preserved onion address is advertised.
- [ ] Export a fresh static channel backup to encrypted storage outside the
      VPS.
- [ ] Monitor logs, disk, memory, Bitcoin/LND block height and channel status
      continuously for the first hour.
- [ ] Leave fee automation and unattended restarts disabled for 24 hours.
- [ ] Mark the old LND data directory retired and never boot its service again.

## 9. Remove temporary Azure cost

Only after the permanent Bitcoin Core and LND services are stable and the
staging manifest is no longer needed:

- [ ] Confirm no wallet or Lightning material ever reached Azure.
- [ ] Delete the staging VM.
- [ ] Delete or deliberately retain and budget its detached OS/data disks.
- [ ] Delete unused NIC, public IP and snapshots.
- [ ] Confirm Cost Management shows no unexpected remaining resources.

## 10. Later: transition from LND to Core Lightning

This is not part of the channel-preserving host cutover.

- [ ] Install CLN with a separate data directory, seed, node identity, Tor
      service and ports.
- [ ] Point CLN at the same fully synchronized Bitcoin Core backend.
- [ ] Test CLN with no meaningful funds first.
- [ ] Keep LND running until all existing LND channels and pending sweeps are
      resolved.
- [ ] Cooperatively close one LND channel at a time when economical.
- [ ] Wait for each close to confirm and for any timelock/sweep to finish.
- [ ] Move confirmed on-chain funds to the CLN wallet.
- [ ] Open new CLN channels deliberately; do not copy `channel.db`,
      `wallet.db` or the LND seed into CLN.
- [ ] Retire LND only after it reports no open/pending channels and no
      unswept funds.

## Explicit non-goals

- No live-channel database conversion from LND to CLN.
- No simultaneous copies of the LND wallet.
- No real-wallet rehearsal.
- No Neutrino switch during the host migration.
- No permanent USD 70/month Azure VM.
