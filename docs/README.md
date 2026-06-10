# Darkbloom Documentation

Technical documentation for the Darkbloom decentralized private inference network.

## Core Documentation

| Document | Description |
|----------|-------------|
| [ARCHITECTURE.md](ARCHITECTURE.md) | System architecture: coordinator, provider, routing, attestation, encryption, billing |
| [api.md](api.md) | Full HTTP API reference for `api.darkbloom.dev` (OpenAI-compatible + platform endpoints) |
| [threat-model.yaml](threat-model.yaml) | Machine-readable threat model (consumed by the `threat-model-review` CI workflow) |

## Design & Spec Documents (`design/`)

Design rationale, specs, and findings — see the [design index](design/README.md) for per-doc status and reading order.

| Document | Description |
|----------|-------------|
| [design/apns-code-attestation-design.md](design/apns-code-attestation-design.md) | APNs-triggered code attestation design |
| [design/acme-mda-apple-root-signed.md](design/acme-mda-apple-root-signed.md) | Apple-root-signed ACME device-attest-01 with MicroMDM |
| [design/ssd-kv-cache-design.md](design/ssd-kv-cache-design.md) | Encrypted SSD prefix (KV) cache design |
| [design/ssd-kv-cache.md](design/ssd-kv-cache.md) | SSD KV-cache implementation notes |
| [design/ssd-kv-cache-hybrid-models.md](design/ssd-kv-cache-hybrid-models.md) | SSD KV-cache behavior on hybrid sliding-window models |
| [design/kv-cache-lookup-shadowing-finding.md](design/kv-cache-lookup-shadowing-finding.md) | Finding: short in-window checkpoints shadow the SSD tier |
| [design/self-route.md](design/self-route.md) | Self-route: free relayed inference on your own Mac |
| [design/direct-mode.md](design/direct-mode.md) | Direct/local mode: coordinator-free LAN/localhost inference |

## Runbooks (`runbooks/`)

Operational runbooks. Several are human-only for prod actions — read the warnings at the top of each.

| Document | Description |
|----------|-------------|
| [runbooks/dev-environment.md](runbooks/dev-environment.md) | Dev environment on Google Cloud (`api.dev.darkbloom.xyz`) |
| [runbooks/model-migration-runbook.md](runbooks/model-migration-runbook.md) | Zero-downtime model migration via alias desired-build pointers |
| [runbooks/eigencloud-to-gcp-migration-runbook.md](runbooks/eigencloud-to-gcp-migration-runbook.md) | EigenCloud → GCP coordinator migration plan |
| [runbooks/dar70-state-export-runbook.md](runbooks/dar70-state-export-runbook.md) | Admin-gated `/data` state export (TEE state extraction) |
| [runbooks/m5-stress-runbook.md](runbooks/m5-stress-runbook.md) | M5 SSD KV-cache 4-hour stress soak |

> The production coordinator deploy runbook (`coordinator-deploy-runbook.md`) contains infra details and is intentionally not committed to this public repo.

## Other

- `legal/` — privacy policy and terms of service
- `assets/` — benchmark data and charts (KV-cache prefill/TTFT sweeps)
