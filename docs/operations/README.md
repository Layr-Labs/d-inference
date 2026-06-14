# Operations Runbooks

This directory contains procedural runbooks for deploying, migrating, and operating Darkbloom infrastructure. Every runbook uses the same section structure:

- **Prerequisites** — what must be true before starting
- **Steps** — ordered operator actions
- **Verification** — how to prove the outcome is correct
- **Rollback** — how to undo or fail back safely

Runbooks are written for operators. For architecture and security context, see the [`architecture/README.md`](../architecture/README.md) docs; for API and protocol details, see [`reference/README.md`](../reference/README.md).

## Runbook index

| Runbook | Scope | Audience |
|---|---|---|
| [`coordinator-deploy.md`](coordinator-deploy.md) | Build and deploy the coordinator (Go) and provider CLI (Swift) | Infra / release engineer |
| [`dev-environment.md`](dev-environment.md) | Stand up and operate the GCP dev environment | Infra engineer |
| [`model-migration.md`](model-migration.md) | Zero-downtime model alias / build cutover | Model ops / on-call |
| [`state-export.md`](state-export.md) | Extract and rehydrate sealed coordinator state (`DAR-70`) | Infra engineer (human-only) |
| [`eigencloud-to-gcp-migration.md`](eigencloud-to-gcp-migration.md) | Move prod from EigenCloud to a GCP Confidential VM | Infra engineer (human-only) |
| [`m5-stress-runbook.md`](m5-stress-runbook.md) | 4-hour SSD KV-cache stress soak on the M5 bench box | Performance engineer |

## Safety rules that apply to every runbook

1. **Prod EigenCloud, GCP prod deploys, KMS, DNS, and release registration are human-only.** AI agents may prepare commands; a human executes anything that mutates prod.
2. **The code is the source of truth.** Claims cite canonical file paths and line ranges where possible.
3. **Privacy model** (from [`docs/AGENTS.md`](../AGENTS.md)):
   - Consumer → coordinator: TLS by default; optional NaCl Box.
   - Coordinator → provider: mandatory per-request NaCl Box to the provider's attested X25519 public key.
   - Provider → coordinator: response SSE chunks encrypted back to the coordinator's ephemeral X25519 key.
   - The coordinator decrypts consumer bodies in Confidential VM memory for routing and billing, but does not log or retain prompt content.
   - The provider is the decryption endpoint for prompts; it is bound to Apple Secure Enclave identity and code-identity attestation.
4. **Validate on dev first.** Any command that publishes a model, flips an alias, or extracts state should be run against `api.dev.darkbloom.xyz` before prod.
