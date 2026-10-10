# Copilot guidance for `lnd-ops-subrepo`

## Repository purpose
This repository is a public-facing operational tooling repo for Lightning node operations. It is intended to be grant-friendly, business-friendly, and safe to share with outside contributors and reviewers.

The default posture is: treat the project as if it will be read by strangers, funders, and operators who do not know your personal infrastructure.

## Public repo and grant-readiness policy
- Keep the repository publishable without exposing private infrastructure.
- Never commit real SSH targets, usernames, hostnames, IPs, or private keys.
- Do not commit any `user@host` defaults or real remote-node values into tracked files.
- Treat `config/lnd-ops.env` as untracked local configuration, not committed repository state.
- Prefer placeholder values like `user@remote-node.example` only in examples when necessary, and keep them clearly marked as examples.
- Prefer explicit empty values over fake defaults when the project is public.
- Prefer widely accepted, business-friendly OSS licenses. Apache-2.0 is acceptable and grant-friendly when patent protection is a factor.
- Keep docs aligned with the project’s public posture: explain local-only configuration, remote comparison behavior, and safe setup steps.
- Do not reintroduce home-directory paths or machine-specific paths into the repository. The repo must be portable and reproducible.
- If a previously deployed host was private or decommissioned, do not leave new defaults or examples that suggest it is still active.

## Security-sensitive shell conventions
These scripts are operational and may run against real node infrastructure. Safety matters more than cleverness.

- Prefer `set -eu` or `set -euo pipefail` in scripts when appropriate.
- Quote variables consistently: `"$VAR"`, `"${VAR:-default}"`, and avoid unquoted expansions.
- Guard remote execution paths so they cannot run with empty values.
- Never call `ssh` with an empty host or empty command. If remote mode is disabled, skip the remote branch entirely.
- Avoid `eval`, indirect expansion, or shell tricks that can hide argument injection.
- Use environment overrides in a safe, explicit pattern, such as `${LND_REMOTE_HOST:-}` and `${LND_REMOTE_LNCLI:-lncli}`.
- Do not hardcode personal usernames or home directories in tracked code.
- Avoid using absolute paths to machine-specific locations unless the path is intentionally required and clearly documented.
- Avoid silent failures that hide misconfiguration. If a block is intentionally skipped when config is absent, make that behavior explicit in comments and docs.
- When a value is only for local use, store it in untracked config and keep examples empty.

## Bash tooling and repository conventions
This repo is Bash-centric. Follow the project’s established patterns and stay minimal.

- Prefer small, surgical changes over large refactors.
- Keep shell behavior predictable and easy to test.
- Do not add network calls or host-dependent logic to the default code path.
- Favor deterministic checks that work offline.
- Keep examples and defaults obviously non-production unless the user is intentionally configuring a real deployment.
- Prefer README / CLAUDE / config comments to document operational assumptions, not hidden behavior.
- If a variable is optional, make the optional behavior obvious in code comments and docs.
- If settings exist for both local and remote roles, make the role split explicit and avoid conflating them.

## Testing expectations
- Update tests when changing defaults or remote behavior.
- Prefer repo-local checks over environment-dependent verification.
- Add or update assertions for things like:
  - no hardcoded personal home directories
  - no committed `user@host` values
  - no empty/placeholder remote config being treated as a live target
- Verify Bash syntax and shell behavior for any edited script.

## Copilot behavior requirements
When generating or editing code in this repository, Copilot should:
- Keep patches narrow and targeted.
- Preserve the safety model: no secrets, no personal infrastructure, no live SSH targets in repo files.
- Maintain the public-facing default: safe placeholders, explicit unset behavior, and local config in untracked files.
- Avoid introducing machine-specific filesystem assumptions.
- Prefer existing patterns in the repo over inventing new conventions.
- Keep operational comments honest: explain why a config is unset or intentionally empty.
- If a variable is optional, make the disable path explicit instead of silent/implicit.
- If a new config value is required, explain where it belongs (typically `config/lnd-ops.env`) and why it should not be committed.
- Do not add comments or docs that imply the repo is safe to publish while still containing real hostnames or private data.

## Approval checklist for changes
Before accepting a patch, check:
- No real hostnames, usernames, or IPs in tracked files
- No private keys or secrets
- No hardcoded home directories or machine-specific paths
- Remote config is either unset or clearly local-only
- Docs explain required untracked config
- Shell changes are minimal, safe, and testable
- Public-facing policy remains intact for grants and outside contributors

This repo should remain safe for a public release, grant review, and contributor onboarding.
