# FOSS cloud Lightning plan

## Constraint

DigitalOcean is the only paid infrastructure in this phase. Everything else
must be free/open-source, self-hosted where a server component is required,
and replaceable without exporting the Lightning wallet.

This plan does not authorize moving funds, changing channel policy, closing a
channel, restarting LND, or exposing RPC outside the private administration
network.

## Current production boundary

- One DigitalOcean Ubuntu host runs LND and a pruned Bitcoin Core backend.
- The migrated wallet must never run on the retired workstation.
- Bitcoin RPC and ZMQ remain loopback-only.
- LND peer traffic may use TCP 9735/Tor. Administrative RPC must use a private
  network; it is never opened to the public Internet.
- Wallet material, seed, macaroon, TLS private key and backup encryption keys
  never enter Git, logs, metrics or Phigit events.

## Eight workstreams

### 1. Read-only production audit

Run `scripts/cloud-audit.sh` on the host. It checks host resources, services,
sync state, peers, channels, listening sockets and backup freshness. It never
calls a state-changing RPC. Store the output outside the repository because
it contains operational metadata.

### 2. Retire the workstation copy

Confirm LND and every `lnd-*` watchdog/timer are disabled on the source. Keep
the encrypted archive offline only for recovery. Never use it to start a
second node. Record the retirement date and destination node pubkey without
committing wallet data.

### 3. Encrypted off-host backups

Use LND's static channel backup as the primary recoverable artifact. Encrypt
before transfer with `age`; send it over SSH/rsync to storage controlled by
Witching Hour. Do not copy a live `channel.db`. Keep at least three encrypted
generations and test decryption plus `lncli verifychanbackup` without
restoring the wallet. A second free destination may be an offline workstation
or attached drive; Git, public object storage and email are prohibited.

### 4. FOSS monitoring and alerts

Start with the scripts and systemd timers already in this repository. Add
Prometheus, node_exporter and Grafana OSS only after measuring steady-state
RAM; the monitoring stack must not cause LND or bitcoind to be OOM-killed.
Use self-hosted ntfy for notifications if push alerts are needed. Bind every
dashboard and metrics endpoint to loopback or the private admin network.

### 5. Host hardening

- SSH keys only; disable password and root SSH login.
- nftables/ufw default deny. Publicly expose only SSH from an allowlist and
  Lightning peer traffic when required.
- Use WireGuard for administration. Tor remains available for Lightning peer
  reachability. Do not make Cloudflare, Tailscale coordination, or another
  proprietary control plane a required trust dependency.
- Install unattended security updates, but stage LND/Bitcoin upgrades and
  never auto-upgrade either daemon.
- Run LND and Bitcoin Core as unprivileged users with restrictive umasks.

### 6. Recovery proof

Quarterly, create a new empty test wallet on an isolated host, validate the
documented Bitcoin/LND versions and verify that encrypted backup artifacts can
be decrypted and inspected. Never bring the production seed or channel state
online in the rehearsal. Record recovery time and every missing step.

### 7. Phigit OS and hOUR Chain integration

Publish only allowlisted, read-only fields: node alias/pubkey, sync booleans,
peer counts, active/inactive channel counts, aggregate local/remote liquidity,
forward counts and aggregate fees. Never export invoices, payment hashes,
preimages, channel points, macaroon data or peer addresses by default. The
emitter receives a read-only macaroon and communicates over the private
network.

### 8. LND to Core Lightning

Treat CLN as a separate future project. Existing LND channels cannot be
imported. Migrate one channel at a time: select a channel, agree the exact
close type and fee, close it in LND, wait for confirmation, then open a new
CLN channel with separately approved peer and amount. Keep one implementation
authoritative for each channel and preserve enough LND liquidity to recover
until the final channel is moved.

## Free/FOSS component policy

| Need | Default | Cost beyond Droplet | Rule |
|---|---|---:|---|
| OS | Ubuntu LTS or Debian | $0 | Distribution packages and signed upstream releases |
| Bitcoin | Bitcoin Core | $0 | Pruned, RPC/ZMQ loopback-only |
| Lightning now | LND | $0 | Keep while four live channels remain |
| Lightning later | Core Lightning | $0 | Separate channel-by-channel transition |
| Private admin | WireGuard | $0 | No required hosted coordination plane |
| Metrics | existing scripts first | $0 | Prometheus/Grafana OSS only if resources allow |
| Alerts | systemd logs; optional self-hosted ntfy | $0 | No paid alerting dependency |
| Backup crypto | age | $0 | Encrypt before leaving the host |
| Backup transport | OpenSSH/rsync | $0 | Destination must be independently controlled |
| Provisioning | Ansible/OpenTofu | $0 | No secret values in state or Git |

## Gates

1. Audit passes and the node reports chain/graph sync.
2. Source copy is demonstrably unable to restart.
3. A fresh encrypted static channel backup exists off-host.
4. Restore verification is documented and rehearsed without production keys.
5. Monitoring fits the current Droplet with safe memory/disk headroom.
6. Phigit receives only the approved read-only schema.
7. CLN work begins only after an explicit per-channel migration approval.
