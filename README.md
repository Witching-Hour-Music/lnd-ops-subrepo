# LND Ops Subrepo

Operational scripts and systemd units for local and remote LND nodes.

## Included
- Local user-level systemd units and helper scripts for:
  - watchdog
  - health reporting
  - fee autotuning
  - hourly summary
  - fee alerting
- Remote (phunkii) equivalents and node-specific service units.

## Excluded (safety)
- Wallet passphrases/files
- Macaroons
- TLS private keys
- Any secret tokens/passwords

## Layout
- `local/` local node artifacts
- `remote-phunkii/` remote node artifacts
- `docs/` notes
