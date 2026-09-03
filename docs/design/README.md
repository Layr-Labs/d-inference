# Design records — what was decided, and whether it shipped

> Last updated: 2026-09-03 · commit `5d400cf75`

Plans, proposals, and architecture decision records. Each file is frozen at the
moment it was written except for its **Status** line, which says whether the
design was built, superseded, or abandoned and points at the page that
describes the system as it is today. Read these for the *why*; read
[`../architecture/README.md`](../architecture/README.md) for the *how*.

Status vocabulary (closed): `Proposed` · `In progress` · `Implemented (version / PR)` ·
`Superseded by <link>` · `Abandoned`.

## Routing and scheduling

| Record | Status | One line |
|---|---|---|
| [routing-v2.md](routing-v2.md) | Implemented (W0–W5, W7, W8 default-on; W6 investigated only) | Admit by measurement, serve all compute, never ship bad streams — the plan behind today's [`../architecture/routing.md`](../architecture/routing.md) |
| [routing-v2-attestation-churn.md](routing-v2-attestation-churn.md) | Implemented (16 m challenge freshness, 300 s code-attest timeout) | W5 root cause of code-attestation churn and its fix |
| [routing-telemetry-and-calibration.md](routing-telemetry-and-calibration.md) | Implemented (later phases landed as the system profiler) | Per-route telemetry and calibration of the cost model |
| [consumer-latest-routing-plan.md](consumer-latest-routing-plan.md) | Superseded by [routing-v2.md](routing-v2.md) | Earlier routing plan; tracks C/D/F landed as W4/W3/W7 |

## Security

| Record | Status | One line |
|---|---|---|
| [apns-code-attestation.md](apns-code-attestation.md) | Implemented (v0.6.0) | Why code identity is proven through an APNs-delivered challenge; as built in [`../architecture/security/attestation.md`](../architecture/security/attestation.md) |

## Inference engine and memory

| Record | Status | One line |
|---|---|---|
| [gemma4-cbv2-mtp.md](gemma4-cbv2-mtp.md) | See status line in file | Gemma 4 frozen-KV multi-token prediction on continuous batching v2 |
| [activation-reserve-overhaul-plan.md](activation-reserve-overhaul-plan.md) | See status line in file | Replacing the fixed activation reserve with measured per-model floors |
| [ssd-kv-cache.md](ssd-kv-cache.md) | Superseded in v0.7.5 by the EngineV2 `KVCacheSSD` path | Encrypted SSD prefix KV cache (ADR) |
| [ssd-kv-cache-v1-design.md](ssd-kv-cache-v1-design.md) | Superseded (pre-v0.7.5 design) | Original SSD KV cache design; current format in [`../reference/ssd-kv-cache.md`](../reference/ssd-kv-cache.md) |
| [kv-cache-lookup-shadowing.md](kv-cache-lookup-shadowing.md) | Superseded in v0.7.5 | Lookup shadowing on small-window hybrid models |

## Billing

| Record | Status | One line |
|---|---|---|
| [base-rewards.md](base-rewards.md) | Implemented (v0.6.21, PR #282); gated off by default; UI surfacing not built | Additive base income for providers; as built in [`../architecture/billing.md`](../architecture/billing.md) |

## Adding a record

Write the record, add a `**Status:**` line directly under the freshness stamp,
add a row here, and stop editing the body once it lands. When the design ships,
fold the as-built facts into `architecture/` and change only the status line.
See [`../AGENTS.md`](../AGENTS.md) §8.
