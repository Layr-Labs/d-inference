# Darkbloom Documentation

This directory contains the public technical documentation for Darkbloom, a
decentralized private-inference network for Apple Silicon Macs.

The code is the source of truth. If a doc contradicts the code, the code wins.
See [`AGENTS.md`](./AGENTS.md) for authoring rules and the canonical privacy
model.

![Darkbloom system architecture](./assets/diagrams/system-architecture.svg)

## Navigation matrix

### Getting started

| Audience | Start here |
|---|---|
| I want to call the API | [`consumer/quickstart.md`](./consumer/quickstart.md) |
| I want to run a provider node | [`provider/installation.md`](./provider/installation.md) → [`provider/quickstart.md`](./provider/quickstart.md) |
| I want to build or contribute | [`developer/build.md`](./developer/build.md) → [`developer/test.md`](./developer/test.md) |

### Architecture

| Concern | Doc |
|---|---|
| System overview | [`architecture/overview.md`](./architecture/overview.md) |
| Data flow | [`architecture/data-flow.md`](./architecture/data-flow.md) |
| Coordinator | [`architecture/components/coordinator.md`](./architecture/components/coordinator.md) |
| Provider CLI | [`architecture/components/provider.md`](./architecture/components/provider.md) |
| Console UI | [`architecture/components/console-ui.md`](./architecture/components/console-ui.md) |
| MLX-Swift integration | [`architecture/components/mlx-swift.md`](./architecture/components/mlx-swift.md) |
| Consumer HTTP surface | [`architecture/components/consumer.md`](./architecture/components/consumer.md) |
| Routing | [`architecture/operations/routing.md`](./architecture/operations/routing.md) |
| Scheduling | [`architecture/operations/scheduling.md`](./architecture/operations/scheduling.md) |
| Billing & pricing | [`architecture/operations/billing.md`](./architecture/operations/billing.md) |
| Model registry | [`architecture/operations/model-registry.md`](./architecture/operations/model-registry.md) |
| Telemetry | [`architecture/operations/telemetry.md`](./architecture/operations/telemetry.md) |
| Inference & prefix cache | [`architecture/inference.md`](./architecture/inference.md) |
| Storage backends | [`architecture/storage.md`](./architecture/storage.md) |
| Hardware support | [`architecture/hardware-support.md`](./architecture/hardware-support.md) |

### Security & privacy

| Concern | Doc |
|---|---|
| Encryption hop-by-hop | [`architecture/security/encryption.md`](./architecture/security/encryption.md) |
| Provider attestation | [`architecture/security/attestation.md`](./architecture/security/attestation.md) |
| MDM enrollment & MDA | [`architecture/security/enrollment.md`](./architecture/security/enrollment.md) |
| Identity binding | [`architecture/security/identity-binding.md`](./architecture/security/identity-binding.md) |
| APNs code-identity attestation | [`architecture/decisions/apns-code-attestation.md`](./architecture/decisions/apns-code-attestation.md) |
| Privacy expectations (consumer) | [`consumer/privacy-expectations.md`](./consumer/privacy-expectations.md) |

### Consumer docs

| Concern | Doc |
|---|---|
| Quickstart | [`consumer/quickstart.md`](./consumer/quickstart.md) |
| Authentication | [`consumer/authentication.md`](./consumer/authentication.md) |
| API contracts & endpoints | [`reference/api-contracts.md`](./reference/api-contracts.md) |
| Model catalog | [`consumer/models.md`](./consumer/models.md) |
| Billing & balance | [`consumer/billing.md`](./consumer/billing.md) |
| Self-route (use your own Mac) | [`provider/self-route.md`](./provider/self-route.md) |
| Verifying provider attestation | [`consumer/verification.md`](./consumer/verification.md) |
| Privacy expectations | [`consumer/privacy-expectations.md`](./consumer/privacy-expectations.md) |

### Provider docs

| Concern | Doc |
|---|---|
| Installation | [`provider/installation.md`](./provider/installation.md) |
| Quickstart | [`provider/quickstart.md`](./provider/quickstart.md) |
| CLI reference | [`provider/cli-reference.md`](./provider/cli-reference.md) |
| Hardware requirements | [`provider/hardware-requirements.md`](./provider/hardware-requirements.md) |
| Attestation & security model | [`provider/attestation.md`](./provider/attestation.md) |
| Direct / local mode | [`provider/direct-mode.md`](./provider/direct-mode.md) |
| Self-route | [`provider/self-route.md`](./provider/self-route.md) |
| Troubleshooting | [`provider/troubleshooting.md`](./provider/troubleshooting.md) |

### Developer docs

| Concern | Doc |
|---|---|
| Build all components | [`developer/build.md`](./developer/build.md) |
| Test | [`developer/test.md`](./developer/test.md) |
| Release | [`developer/release.md`](./developer/release.md) |

### Operations runbooks

| Concern | Doc |
|---|---|
| Runbook index | [`operations/README.md`](./operations/README.md) |
| Coordinator deploy | [`operations/coordinator-deploy.md`](./operations/coordinator-deploy.md) |
| Dev environment | [`operations/dev-environment.md`](./operations/dev-environment.md) |
| Model migration | [`operations/model-migration.md`](./operations/model-migration.md) |
| State export (`DAR-70`) | [`operations/state-export.md`](./operations/state-export.md) |
| EigenCloud → GCP migration | [`operations/eigencloud-to-gcp-migration.md`](./operations/eigencloud-to-gcp-migration.md) |
| SSD KV-cache stress soak | [`operations/m5-stress-runbook.md`](./operations/m5-stress-runbook.md) |

### Reference

| Concern | Doc |
|---|---|
| API contracts | [`reference/api-contracts.md`](./reference/api-contracts.md) |
| Protocol messages | [`reference/protocol-messages.md`](./reference/protocol-messages.md) |
| Telemetry schema | [`reference/telemetry-schema.md`](./reference/telemetry-schema.md) |
| Pricing model | [`reference/pricing-model.md`](./reference/pricing-model.md) |
| Model registry format | [`reference/model-registry-format.md`](./reference/model-registry-format.md) |
| SSD KV cache (as-built) | [`reference/ssd-kv-cache.md`](./reference/ssd-kv-cache.md) |
| SSD KV cache design | [`reference/ssd-kv-cache-design.md`](./reference/ssd-kv-cache-design.md) |
| SSD KV cache hybrid models | [`reference/ssd-kv-cache-hybrid-models.md`](./reference/ssd-kv-cache-hybrid-models.md) |
| KV-cache lookup shadowing finding | [`architecture/decisions/kv-cache-lookup-shadowing.md`](./architecture/decisions/kv-cache-lookup-shadowing.md) |

### Legal

| Doc |
|---|
| [`legal/privacy-policy.md`](./legal/privacy-policy.md) |
| [`legal/terms-of-service.md`](./legal/terms-of-service.md) |

## Directory roles

| Directory | Purpose | Audience |
|---|---|---|
| `consumer/` | How to use the OpenAI-compatible API | API consumers |
| `provider/` | How to run a provider node | Node operators |
| `developer/` | How to build, test, and release | Contributors |
| `architecture/` | System architecture — source of truth for how it works | Anyone |
| `operations/` | Deployment, migration, and incident runbooks | Operators |
| `reference/` | Contracts, schemas, and specs | All audiences |
| `legal/` | Privacy policy and terms of service | Legal / users |
| `assets/` | Shared images, CSVs, diagrams | All docs |
| `.private/` | Internal/marketing drafts | Not public docs |

## Canonical privacy model

- Consumer → coordinator: TLS by default; optional NaCl Box
  (X25519 + XSalsa20-Poly1305).
- Coordinator → provider: mandatory per-request NaCl Box to the provider's
  attested X25519 public key.
- Provider → coordinator: response SSE chunks encrypted back to the
  coordinator's ephemeral X25519 key.
- The coordinator decrypts consumer bodies in its Confidential VM memory for
  routing and billing, but does not log or retain prompt content.
- The provider is the decryption endpoint for prompts; it is bound to Apple
  Secure Enclave identity and code-identity attestation.
