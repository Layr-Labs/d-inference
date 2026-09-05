# Design records — what was decided, and whether it shipped

> Last updated: 2026-09-05 · commit `4d9811f7c`

Plans, proposals, and architecture decision records. Each file is frozen at the
moment it was written except for its **Status** line, which says whether the
design was built, superseded, or abandoned and points at the page that
describes the system as it is today. Read these for the *why*; read
[`../architecture/README.md`](../architecture/README.md) for the *how*.

Status vocabulary (closed, [`../AGENTS.md`](../AGENTS.md) §3):
`Status: Proposed | In progress | Implemented (vX.Y.Z) | Superseded by <link> | Abandoned`,
followed by the record's date and one clause of evidence. The Status column
below repeats the vocabulary word only; the file's line 5 carries the evidence.

## Routing and scheduling

| Record | Status | Date | One line |
|---|---|---|---|
| [provider-service-quality.md](provider-service-quality.md) | In progress | 2026-09-05 | Recent reliability, authoritative provider status, bounded recovery and routing feedback |
| [routing-v2.md](routing-v2.md) | Implemented | 2026-06-16 | Admit by measurement, serve all compute, never ship bad streams — the plan behind today's [`../architecture/routing.md`](../architecture/routing.md) |
| [routing-v2-attestation-churn.md](routing-v2-attestation-churn.md) | Implemented | 2026-06-16 | W5 root cause of code-attestation churn and its fix |
| [routing-telemetry-and-calibration.md](routing-telemetry-and-calibration.md) | Implemented | 2026-06-16 | Per-route telemetry and calibration of the cost model |
| [consumer-latest-routing-plan.md](consumer-latest-routing-plan.md) | Superseded by [routing-v2.md](routing-v2.md) | 2026-06-14 | Earlier routing plan; tracks C/D/F landed as W4/W3/W7 |
| [prefix-cache-and-cached-routing.md](prefix-cache-and-cached-routing.md) | Proposed | 2026-08-31 | Why cached routing is dark end to end, and the phased plan to turn it on model by model |

## Security

| Record | Status | Date | One line |
|---|---|---|---|
| [apns-code-attestation.md](apns-code-attestation.md) | Implemented | 2026-06-14 | Why code identity is proven through an APNs-delivered challenge; as built in [`../architecture/security/attestation.md`](../architecture/security/attestation.md) |

## Inference engine and memory

| Record | Status | Date | One line |
|---|---|---|---|
| [gemma4-cbv2-mtp.md](gemma4-cbv2-mtp.md) | Implemented | 2026-07-14 | Gemma 4 frozen-KV multi-token prediction on continuous batching v2 |
| [gemma4-26b-inference-optimization.md](gemma4-26b-inference-optimization.md) | Proposed | 2026-08-03 | Op-level profile of Gemma 4 26B-A4B decode and prefill with a tiered list of kernel and scheduling wins |
| [paged-attention-for-prefill.md](paged-attention-for-prefill.md) | Superseded by [paged-kv-migration.md](paged-kv-migration.md) | 2026-07-25 | Decision memo: paged attention does not solve the prefill problem; optimise AttentionV1 instead |
| [paged-kv-migration.md](paged-kv-migration.md) | Implemented | 2026-07-25 | Contiguous → paged KV and B=4 → B=8 migration plan (Rev 2) |
| [activation-reserve-overhaul-plan.md](activation-reserve-overhaul-plan.md) | In progress | 2026-08-30 | Replacing the fixed activation reserve with measured per-model floors |
| [provider-memory-limit.md](provider-memory-limit.md) | Proposed | 2026-08-10 | Operator-settable `memory_limit_gb` cap for the provider, and what it reports to the coordinator |
| [ssd-kv-cache.md](ssd-kv-cache.md) | Superseded by [../reference/ssd-kv-cache.md](../reference/ssd-kv-cache.md) | 2026-06-13 | Encrypted SSD prefix KV cache (ADR) |
| [ssd-kv-cache-v1-design.md](ssd-kv-cache-v1-design.md) | Superseded by [../reference/ssd-kv-cache.md](../reference/ssd-kv-cache.md) | 2026-05-28 | Original SSD KV cache design |
| [kv-cache-lookup-shadowing.md](kv-cache-lookup-shadowing.md) | Superseded by [../architecture/prefix-cache.md](../architecture/prefix-cache.md) | 2026-06-13 | Lookup shadowing on small-window hybrid models |

## Billing

| Record | Status | Date | One line |
|---|---|---|---|
| [base-rewards.md](base-rewards.md) | Implemented | 2026-06-06 | Additive base income for providers; as built in [`../architecture/billing.md`](../architecture/billing.md) |
| [provider-referral-growth-program.md](provider-referral-growth-program.md) | Proposed | 2026-08-21 | Provider-acquisition referral rewards plus an interim payout share, on top of the existing referral fee split |

## Adding a record

Write the record and make line 5 — directly under the freshness stamp — read
`Status: **<status>** — <YYYY-MM-DD> — <one clause of evidence>.` Add a row
here and stop editing the body once it lands. When the design ships, fold the
as-built facts into `architecture/` and change only the status line. See
[`../AGENTS.md`](../AGENTS.md) §8.
