# Copilot repository guidance

## Goals
- Prefer small, targeted changes.
- Keep scripts POSIX/Bash-safe where the repo already uses Bash.
- Preserve the project’s operational focus and existing test style.

## Safety and secrets
- Never commit real SSH targets, private keys, passwords, tokens, or home-directory paths.
- Treat `config/lnd-ops.env` as untracked local configuration.
- If a default or example value must exist, make it a placeholder that cannot be mistaken for a real host.

## Licensing and publication
- Prefer business-friendly, widely recognized licenses.
- Keep documentation aligned with the repo’s public-facing posture.

## Validation
- Update or add shell tests when behavior changes.
- Prefer deterministic, offline checks over network-dependent verification.
- Ensure new changes do not reintroduce hardcoded hostnames or user-specific paths.
