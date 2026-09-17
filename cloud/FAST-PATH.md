# Fast path: local LND to one cloud host

The shortest route from the workstation node to a running cloud node, with
both channels preserved. Core Lightning and Azure recovery are out of scope.

`CUTOVER-CHECKLIST.md` remains the thorough version. This page is that plan
with the staging tier removed.

## What this cuts, and why

The staged plan syncs Bitcoin Core on Azure first, then copies the chain data
to the permanent VPS. That exists to make the initial sync faster.

It does not, on these machines. An Azure `D2s_v4` and a 2 vCPU VPS are close
enough in CPU and disk that the staged route adds work without buying time:

| | Staged | Direct |
|---|---|---|
| Hosts to build | 2 | 1 |
| Initial block downloads | 1 | 1 |
| Chain-data transfers between hosts | 1 (20-30 GB) | 0 |
| Azure account involved | yes | no |
| Steps that can fail | more | fewer |

Both wait roughly the same time for the same sync. The direct route just
waits on the machine that will keep the node, and removes the Azure account
from the critical path, which is what you asked to defer.

Skip sections 2, 3, 9 and 10 of the checklist entirely. Section 4 loses its
"transfer chain data from Azure" step.

## Shape of it

Three sittings. Roughly two and a half hours of your attention, spread across
about two days. The gap is the initial block download, which needs no
babysitting.

---

## Sitting 1 — build the host and start the sync (~45 min)

Nothing here touches the workstation. It keeps running normally.

1. Create the VPS: 2 vCPU, 4 GiB, 80 GiB, Ubuntu LTS, SSH key only, password
   and root login disabled. On DigitalOcean that is the Basic (shared CPU)
   droplet `s-2vcpu-4gb` at USD 24/month — see **Sizing the host** below
   before picking anything smaller.
2. Firewall: SSH from your IP only. Nothing else. Inbound Lightning arrives
   over Tor, so `9735` stays shut.
3. Set a provider budget alert before anything else runs.
4. Create unprivileged `bitcoin` and `lnd` service users with separate data
   directories.
5. Install `tor`, Bitcoin Core, and **LND v0.20.1-beta exactly**. A newer LND
   migrates the channel database on first start and that is not reversible.
6. Install `cloud/bitcoin.conf.example` as the bitcoind config.
7. **Raise `dbcache` for the sync only.** LND is not running yet, so bitcoind
   can use the memory: set `dbcache=1500` on this 4 GiB host, and put it back
   to `450` before LND starts in sitting 3. This is the single largest lever
   on how long the download takes.
8. Start bitcoind.

Then leave it. Expect somewhere between half a day and a day and a half.

---

## Sizing the host

The permanent host is specified as 2 vCPU, 4 GiB RAM, 80 GiB disk. On
DigitalOcean that is exactly one Basic droplet, `s-2vcpu-4gb`, USD 24/month.
Its 4,000 GiB transfer allowance is far more than an initial block download
needs.

Both the disk and the memory figure are floors, not preferences. A smaller
droplet fails, and fails in a way that is expensive to discover late: after
the sync has run.

**Disk.** With `prune=20000` the block store is capped near 20 GB, but that is
not the whole footprint. The 2026 chainstate is roughly 11 GB and is *not*
pruned, and LND, Tor, the OS and the freeze archive all want room beside it.
The total lands near 45 GB. 80 GiB is the smallest Basic droplet that clears
it with headroom for chainstate growth; a 30 GiB disk does not fit the
chainstate and the prune target together, let alone the OS.

**Memory.** LND alone wants roughly 400-800 MB resident. bitcoind wants its
`dbcache` on top, and this runbook deliberately raises `dbcache` to 1500
during the sync because it is the largest lever on download time. On a 1 GiB
droplet there is no configuration of those two that fits, and the failure mode
is the OOM killer taking bitcoind or lnd mid-operation.

So a 1 vCPU / 1 GiB droplet is not a cheaper version of this plan. It fails on
disk and on memory independently, and neither is recoverable by tuning.

**If a bigger droplet is affordable**, the money buys sync time rather than
safety: more vCPU and more RAM for `dbcache` shorten sitting 1. Nothing in
this plan requires it, and the steady-state node runs comfortably on
`s-2vcpu-4gb` once `dbcache` goes back to 450.

**Resizing later.** DigitalOcean can raise CPU and RAM on a Basic droplet
without touching the disk, and that is reversible. Growing the disk is not
reversible on a droplet. Start at 80 GiB rather than planning to expand.

## Sitting 2 — prove the backend, rehearse (~30 min)

Begin once `bitcoin-cli getblockchaininfo` reports `initialblockdownload:
false`, header count equal to block count, and pruning active.

9. Clone this repo on the VPS. Run `scripts/test.sh`, then
   `scripts/preflight.sh`.
10. Create a **disposable** LND wallet against the local bitcoind. Throw the
    seed away; it will never hold funds.
11. Confirm it reaches `synced_to_chain: true`. This is the check that
    matters: it proves block refetching works against a pruned backend before
    real funds depend on it.
12. Confirm Tor produced an onion address.
13. Delete the disposable wallet completely:
    `sudo systemctl stop lnd && rm -rf ~/.lnd/data ~/.lnd/tls.* ~/.lnd/v3_onion_private_key`
14. Verify the production LND directory is still absent.

**STOP:** if the disposable node cannot sync against this backend, do not
continue. The production wallet will not fare better.

## Sitting 3 — cutover (~1 hour, at a terminal you are sitting at)

Do this one in person. A dropped connection between freezing the node and
verifying the archive is the worst place to lose your session.

**On the workstation:**

15. Snapshot while it is still healthy, saving output outside git:

```bash
lncli getinfo > pre-getinfo.json
lncli listchannels > pre-listchannels.json
lncli walletbalance > pre-walletbalance.json
lncli channelbalance > pre-channelbalance.json
lncli exportchanbackup --all > channel.backup
```

16. `bin/lnd-migrate-freeze.sh` and read the dry run.
17. `bin/lnd-migrate-freeze.sh --confirm`.
18. Confirm no `lnd` process remains and RPC does not answer. The script
    refuses to continue otherwise, but check anyway.

**Transfer:**

19. `scp` the archive, its checksum and the manifest straight to the VPS.
    Not cloud storage, not chat, not git.

**On the VPS:**

20. Verify the archive checksum, then extract as the `lnd` user.
21. Set `dbcache=450` in bitcoin.conf and restart bitcoind, so LND has memory.
22. Point `lnd.conf` at the local bitcoind using
    `cloud/lnd.conf.bitcoind.example`. Change **only** the backend connection
    details. Not the LND version, not the database backend, not the
    implementation.
23. Confirm `v3_onion_private_key` is in place, or the node's address changes
    and peers cannot find it.
24. `bin/lnd-migrate-verify.sh --manifest ~/lnd-manifest.sha256`. Resolve
    every failure and every Tor or auto-unlock warning.

**ROLLBACK BOUNDARY.** Everything above is reversible: nothing has changed,
so you can restart the workstation node and regroup. Once you run the next
step, that stops being true.

25. Start LND. Once.
26. Confirm: same identity pubkey, the same two channel points, balances
    matching the snapshots, `synced_to_chain`, peers reconnecting, and the
    preserved onion address advertised.
27. Export a fresh channel backup to encrypted storage off the VPS.
28. Mark the workstation LND directory retired. Never start it again.

## After it is up

29. `scripts/install.sh --role local --dry-run`, read it, then without
    `--dry-run`.
30. Leave the fee autotuner off for 24 hours. Watch `bin/lnd-fee-autotune.sh
    --dry-run` output first and confirm the ppm values match what the node
    charges today.

## If the platform is the actual blocker

If the reason you want Lightning in the cloud is to build the
`witching-hour-platform` integration, that does not need this migration at
all, and does not need your channels.

The platform emitter reads `getinfo`, `listchannels` and `fwdinghistory`.
Every one is read-only, and none cares whether the node holds funds.

So: put a fresh LND node with a **neutrino** backend on any host, with no
funds and a throwaway wallet. It syncs in minutes rather than a day, carries
no risk, and is enough to develop and test
`com.witchinghour.lightning.*` events against. Migrate the production node on
its own schedule afterwards.

That path is about an hour, and nothing it touches can cost you a channel.
