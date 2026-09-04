# Reports — dated records

> Last updated: 2026-09-03 · commit `5d400cf75`

Frozen records: incident analyses, measurements, experiment results, and
migration records. Each file describes the code **as it was on its date**; none
is edited after it lands, and none describes the current system. For how things
work today read [`../architecture/README.md`](../architecture/README.md); for
what was decided and whether it shipped read [`../design/README.md`](../design/README.md).

File names start with the date of the work (`YYYY-MM-DD-slug.md`). Each file's
freshness stamp carries its own date, not the current one.

## Incidents and root causes

| Date | Report | One line |
|---|---|---|
| 2026-07-03 | [reconnect-churn-root-cause](2026-07-03-reconnect-churn-root-cause.md) | Why providers reconnected in a loop, and the heartbeat/ack timing fix |
| 2026-07-20 | [generation-deadline-incident-and-redesign](2026-07-20-generation-deadline-incident-and-redesign.md) | Generation-deadline cancellations: incident, root cause, and the redesigned deadline model |
| 2026-07-30 | [auto-tool-schema-rejection-root-cause](2026-07-30-auto-tool-schema-rejection-root-cause.md) | `tool_choice:"auto"` rejected standard JSON-Schema tools for every model; fix as shipped |
| 2026-08-24 | [qwen-openrouter-504-provider-analysis](2026-08-24-qwen-openrouter-504-provider-analysis.md) | Provider-side analysis of the OpenRouter 504s on Qwen |
| 2026-08-24 | [qwen-openrouter-timeout-fix-and-release](2026-08-24-qwen-openrouter-timeout-fix-and-release.md) | The timeout fix and the release that carried it |
| 2026-08-31 | [openrouter-504-cascade-root-cause](2026-08-31-openrouter-504-cascade-root-cause.md) | How one slow provider cascaded into fleet-wide 504s |
| 2026-08-31 | [coordinator-agent-deployment-failure-postmortem](2026-08-31-coordinator-agent-deployment-failure-postmortem.md) | Postmortem of an agent-driven coordinator deploy that failed; the production-mutation rules that followed |

## Engine and model measurements

| Date | Report | One line |
|---|---|---|
| 2026-06-15 | [metal-resource-count-fix-handoff](2026-06-15-metal-resource-count-fix-handoff.md) | How the Metal resource-count crash fix was landed through the `Layr-Labs/mlx*` forks |
| 2026-07-02 | [engine-v2-contract-issues-provider-bridge](2026-07-02-engine-v2-contract-issues-provider-bridge.md) | Where the frozen `CBv2Contracts.swift` was insufficient for the provider bridge, and what was chosen |
| 2026-07-19 | [frozen-full-prefix-cache-proof](2026-07-19-frozen-full-prefix-cache-proof.md) | Proof that frozen full-prefix reuse is exact on hybrid sliding-window models |
| 2026-07-25 | [paged-gate-results](2026-07-25-paged-gate-results.md) | Live gate results for v0.8.0 PagedAttention |
| 2026-07-25 | [prefill-and-fleet-performance-findings](2026-07-25-prefill-and-fleet-performance-findings.md) | Prefill and fleet performance findings that drove v0.8.0 |
| 2026-07-25 | [v0.8.0-action-list](2026-07-25-v0.8.0-action-list.md) | Ranked list of what was left before v0.8.0 |
| 2026-07-26 | [gemma-26b-adoption-exactness](2026-07-26-gemma-26b-adoption-exactness.md) | Cold-vs-adopted output exactness on `gemma-4-26B-A4B-it-qat-4bit` |
| 2026-07-27 | [v080-post-release-engine-bench](2026-07-27-v080-post-release-engine-bench.md) | Post-release engine benchmark sweep for v0.8.0 |
| 2026-08-18 | [qwen36-prefill-metal-trace](2026-08-18-qwen36-prefill-metal-trace.md) | Metal trace of Qwen3.6 prefill on M4 Max |
| 2026-08-19 | [solo-prefill-stripe-experiment](2026-08-19-solo-prefill-stripe-experiment.md) | A/B of the opt-in solo-prefill stripe scheduler feature (Qwen3.6 35B-A3B) |
| 2026-08-20 | [gemma4-26b-prefill-decode-profile](2026-08-20-gemma4-26b-prefill-decode-profile.md) | Prefill/decode profile of Gemma 4 26B |
| 2026-08-21 | [qwen-prefill-retained-optimizations](2026-08-21-qwen-prefill-retained-optimizations.md) | Which Qwen prefill optimisations were retained on master, with numbers |
| 2026-08-21 | [qwen-prefill-retained-pr-body](2026-08-21-qwen-prefill-retained-pr-body.md) | PR description for the retained-optimisations rebase |
| 2026-08-25 | [v0.8.12-prefill-deadline-admission](2026-08-25-v0.8.12-prefill-deadline-admission.md) | Default-on prefill-deadline admission shipped in v0.8.12 |
| 2026-08-28 | [qwen35-9b-validation-and-mtp](2026-08-28-qwen35-9b-validation-and-mtp.md) | Qwen3.5-9B validation and its native inline-MTP head |
| 2026-08-30 | [activation-floor-measurements](2026-08-30-activation-floor-measurements.md) | Full-catalog activation-floor sweep behind the per-model activation floors |
| 2026-08-30 | [mlx-upstream-comparison](2026-08-30-mlx-upstream-comparison.md) | Fork vs upstream MLX comparison |
| 2026-08-31 | [pr686-resident-prefix-cache-review](2026-08-31-pr686-resident-prefix-cache-review.md) | Review of PR #686 (resident prefix cache) |

Plans and decision memos live in [`../design/`](../design/README.md).

## Trust, fleet, and infrastructure records

| Date | Report | One line |
|---|---|---|
| 2026-07-04 | [provider-trust-reliability](2026-07-04-provider-trust-reliability.md) | Why ~11% of the fleet stalled at `self_signed`, and the per-connection MDM fix |
| 2026-07-17 | [eigencloud-to-gcp-migration](2026-07-17-eigencloud-to-gcp-migration.md) | Record of the prod move from EigenCloud to a GCP Confidential VM (complete) |

## Raw benchmark outputs

Machine-generated; kept as evidence for the reports above.

| Files | What |
|---|---|
| [`raw/…L500…`](raw/gptoss-20b-actfloor-shipped-pins-L500-2026-09-02.md), [`raw/…L4000…`](raw/gptoss-20b-actfloor-shipped-pins-L4000-2026-09-02.md), [`raw/…L4000-solostripe2048…`](raw/gptoss-20b-actfloor-shipped-pins-L4000-solostripe2048-2026-09-02.md) | `BenchCBv2RealModel` runs measuring gpt-oss-20b activation floors on the shipped pins at prompt lengths 500 and 4000, and with the solo-prefill stripe at 2048 (2026-09-02) |
| `clean-*.json`, `m22-*.json`, `mr-*.json` (in this directory, not `raw/`) | `BenchCBv2` JSON outputs from the Gemma 4 prefill experiments (`MLX_GATHER_QMM_EXPERT_SLICES` control vs `trust`; stripe 2048 vs base) behind the August measurement reports |

## Not here

- Release notes: [`../releases/v0.8.0-notes.md`](../releases/v0.8.0-notes.md) (superseded by v0.8.1; kept as the record). Current release history is `CHANGELOG.md` at the repository root.
- Plans and decisions, each with a status: [`../design/README.md`](../design/README.md).
