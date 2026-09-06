# Reports — dated records

> Last updated: 2026-09-06 · commit `35fea6d0e`

Frozen records: incident analyses, measurements, experiment results, and
migration records. Each file describes the code **as it was on its date**; none
is edited after it lands, and none describes the current system. For how things
work today read [`../architecture/README.md`](../architecture/README.md); for
what was decided and whether it shipped read [`../design/README.md`](../design/README.md).

File names start with the date of the work (`YYYY-MM-DD-slug.md`). Each file's
freshness stamp carries its own date, not the current one.

- [Qwen3.8 B2 coordinated reads](2026-09-06-qwen38-b2-coordinated-reads.md) — both strict comparisons pass on the fresh coordinated-read runtime; both warm requests restore 5,120 tokens with unchanged outputs.
- [SSD read coordination runtime](2026-09-06-ssd-read-coordination-runtime.md) — same-file coordination and final alias repair; 324 fresh provider/CLI cases, original CPU regressions and exact artifact audit pass; real-model retest pending.
- [Qwen3.8 B2 staging policy](2026-09-06-qwen38-b2-staging-policy.md) — exact backend outputs and actual B2 pass, but one warm request skips authenticated SSD restore; failed gate and full raw evidence preserved.
- [Isolated signing validation](2026-09-06-isolated-signing-validation.md) — old `f91fe843`/`0.8.16` app passes Developer ID/notarization and cleanup; preserve signature metadata, exclude flat-export equivalence and Qwen56fa/production acceptance.
- [Qwen-first candidate runtime](2026-09-06-qwen-first-candidate-runtime.md) — both release builds and 266 fresh provider/CLI cases pass; exact-source audit and preserved rollback/capacity, with real-model release gates still open.
- [GPT-OSS B2 cache divergence](2026-09-06-gptoss-b2-cache-divergence.md) — retained three-arm pilot passes strict cache-off backend comparison but fails strict cache parity; cross-row equality does not prove restoration correctness.
- [Fixed-context Qwen and Gemma scores](2026-09-06-teacher-context-scores.md) — all four real-model scoring controls run successfully; Qwen differs at two of 83 positions and Gemma at zero of 61, with numerical acceptance still open.
- [Corrected Gemma QAT backend controls](2026-09-06-gemma-qmv-controls.md) — all three B1 mode pairs match across backends; automatic-versus-ordinary output equality still fails on both.
- [Recurrent teacher scoring](2026-09-06-recurrent-teacher-scoring.md) — request-owned recurrent state, normal peak admission and failure retirement; 45 functions/59 cases pass, with exact-model reruns pending.
- [Qwen3.6 dispatch cache comparison](2026-09-06-qwen36-dispatch-cache-comparison.md) — twelve matched cells preserve exact outputs; small MTP-off delivery gains and mixed normal-MTP timing remain fully reported.
- [Same-binary segmented metadata profiler](2026-09-06-segment-metadata-profiler.md) — actual segmented attention, exact output/history checks, and separated synthetic host/fence timings.
- [Two-host connected cache fixture](2026-09-06-two-host-connected-fixture.md) — explicit owned hosts and five routing cases; race/CPU validation passes, real two-host execution remains pending.
- [Segmented dispatch metadata reuse](2026-09-06-segmented-dispatch-metadata-cache.md) — one per-layer immutable plan; 69 native functions/108 cases pass, with repeated model speed measurements pending.
- [Gemma QAT MTP-off controls](2026-09-06-gemma-qat-mtp-off-controls.md) — both backend controls and all seven exact trajectories pass; the normal-MTP mismatch remains open.
- [Gemma QAT actual MTP logits](2026-09-06-gemma-qat-actual-logits.md) — four integrity cells and both same-backend trace comparisons pass; confirmed logits preserve the backend token divergence.
- [Optimized Gemma QAT diagnostic probe](2026-09-06-generic-qat-release-probe.md) — exact committed source and 25 parser checks pass; four-cell retry handoff preserves the existing inputs and assertions.
- [Qwen3.6 native attention packets](2026-09-06-qwen36-owner0-packets.md) — four integrity cells pass; identical captured Q/K/V produce different attention outputs, while strict backend tokens still differ.
- [Qwen3.6 same-input operator replay](2026-09-06-qwen36-owner0-operator-replay.md) — native SDPA reproduces the contiguous capture; both paged layouts reproduce the paged capture with exact complete KV readback, isolating this operator's numerical difference.
- [Standalone attention operator replay](2026-09-06-attention-operator-replay.md) — genuine SDPA and fixed/segmented decode pass 29 synthetic cases with exact readback; source and synthetic validation provenance.
- [Connected SSD cancellation and recovery](2026-09-06-connected-http6-canceled-prefix.md) — all ten cache-off/SSD cases and strict pair pass; cancellation preserves actual 4,096-token reuse before one terminal.
- [Isolated persistent SSD test namespace](2026-09-06-persistent-ssd-test-namespace.md) — separate key selectors, protected-root checks and 47 distinct Swift functions; actual signed restart remains open.
- [Model-independent logit diagnostics](2026-09-06-generic-logit-diagnostic-reducer.md) — shared top-two reduction and actual Gemma adapter tests pass with unchanged MTP policy.
- [Packet and cancellation optimized binaries](2026-09-06-packet-cancellation-release-build.md) — both committed-union builds and 21 parse checks pass; real HTTP and model packet results remain separate.
- [Gemma QAT diagnostic capability refusal](2026-09-06-gemma-qat-logit-capability.md) — normal MTP control passes; Qwen-specific diagnostic gate refuses Gemma before main inference, leaving backend diagnosis open.
- [Qwen3.6 complete attention-owner metadata](2026-09-06-qwen36-attention-owner-results.md) — corrected contiguous trace captures all ten BF16 owners and preserves all completed trajectories; numerical parity remains unresolved.
- [Qwen 3.8 and Gemma QAT backend/cache pilots](2026-09-06-q38-qat-backend-pilots.md) — Q38 passes all four comparisons and QAT passes paged SSD reuse; QAT backend parity fails and repeated performance validation remains open.
- [Native attention packet capture](2026-09-06-attention-packet-capture.md) — bounded native bytes and explicit owner identity; native and export tests pass; bounded real-model packet evidence is recorded separately.
- [Native prefix lookup settlement after cancellation](2026-09-06-canceled-prefix-settlement.md) — actual SSD-hit/cold negative controls reproduce the terminal race; 73 distinct provider tests pass the native usage handoff.
- [Production attention diagnostic owners](2026-09-06-attention-owner-identity.md) — explicit cache identity fixes contiguous metadata capture; native and actual-family regressions pass, corrected real-model rerun pending.
- [Independent attention packet reference](2026-09-06-attention-packet-analyzer.md) — bounded native-byte analysis and 22 synthetic CPU tests; real-model fidelity remains open.
- [Actual attention metadata diagnostic](2026-09-06-attention-metadata-diagnostic.md) — bounded original query/cache dtype observations, confirmed sample identity and passing native/benchmark tests; real-model numerical diagnosis remains open.
- [Connected SSD routing and canceled settlement](2026-09-06-connected-http5-cache-and-cancel.md) — real Qwen3.8 donation, hits and seven SSD cases pass; cancellation loses native usage/lookup evidence and the strict pair remains failed.
- [Qwen3.6 actual logits at the first backend difference](2026-09-05-qwen36-actual-logits.md) — tracing preserves full trajectories; measured logits differ at the shared decision context, while strict backend parity remains failed.
- [Qwen3.6 attention geometry coverage](2026-09-05-qwen36-attention-geometry.md) — thirteen new synthetic cases pass unchanged numerical limits; long-context storage, segment placement and fault calibration are covered, while model backend mismatches remain unresolved.
- [Initial supported backend comparison groups](2026-09-05-supported-backend-groups.md) — GPT and Gemma8 pass cold backend and paged SSD comparisons; Qwen3.5 backend parity fails while its cache pairs pass; unsupported cells remain unrun.
- [Prefix receipt pump ownership](2026-09-05-prefix-receipt-pump-ownership.md) — reproduced premature receipt deletion, explicit pump handoff and 88 passing provider functions; real HTTP rerun pending.
- [Bounded actual-logit diagnostic](2026-09-05-bounded-logit-diagnostic.md) — observe actual ordinary and MTP target decisions with bounded, optional capture; native, benchmark and wrapper validation passes, real-model diagnosis pending.
- [Gemma QAT4bit native KV and initial SSD pairs](2026-09-05-gemma-qat4-initial-pairs.md) — exact production artifact, measured BF16 writes and normal-MTP B1 passes at output caps 32 and 128; broader release gates remain separate.
- [Connected Qwen3.8 HTTP coverage and missing SSD publication](2026-09-05-connected-http3-donation.md) — ten cache-off cases pass on the rebuilt CLI; the SSD donor stores a checkpoint but publishes no ready event, so the paired gate fails.
- [Qwen3.6 backend parity regression](2026-09-05-qwen36-backend-parity-regression.md) — both within-backend SSD pairs pass, but contiguous/paged outputs differ with normal MTP and with MTP off; default promotion held.
- [Qwen3.5 normal MTP SSD pairs](2026-09-05-qwen35-useful-tail-pairs.md) — strict same-budget B1 passes at output caps32 and128; actual outputs32 and74, with cross-budget difference retained.
- [Connected cache inputs, revision 2](2026-09-05-connected-cache-inputs-revision2.md) — corrected Gemma assistant, SSE reader build provenance and reviewed five-model inputs; prepared package, without the new MTP tail runtime.
- [Qwen3.6 coherent paged SSD pair](2026-09-05-qwen36-coherent-paged-pair.md) — initial strict B1 pair passes; 4,096-token restore and all 20 idle observations ready; original native source, single-pair limits.
- [Useful MTP output budget](2026-09-05-mtp-output-budget.md) — eliminate speculative tail work that cannot produce extra output; 126 native cases pass, with subsequent normal-Qwen3.5 pairs recorded separately.
- [Connected reasoning aliases](2026-09-05-connected-reasoning-aliases.md) — correct duplicate SSE reconstruction using captured HTTP streams and retain the original failed run.
- [Coherent benchmark idle observations](2026-09-05-coherent-idle-harness.md) — bounded retirement sampling, preserved failure tuples and eight Swift tests; Qwen3.6 paired observations recorded separately.
- [Initial paged SSD pairs](2026-09-05-initial-paged-ssd-pairs.md) — strict Qwen3.8, GPT-OSS and Gemma B1 passes, observed latency, and preserved setup failures; broader release gates pending.
- [Exact connected cache inputs](2026-09-05-connected-cache-inputs.md) — five-model CPU plans, normal tool/MTP capabilities and isolated executable preparation; real HTTP pending.
- [Strict cache evidence and first Qwen3.6 pair](2026-09-05-final-cache-evidence.md) — real SSD restoration, stronger acceptance checks and the unresolved post-terminal observation gap.
- [Isolated cache key mode](2026-09-05-isolated-cache-key-mode.md) — correct benchmark root/key handoff, retain construction diagnostics and preserve the initial SSD failure.
- [Connected HTTP cache validation](2026-09-05-connected-cache-http.md) — exact-artifact coordinator/provider harness, routing and native-reuse assertions, and helper evidence; model runs pending.
- [Production-grant benchmark and restored cancellation](2026-09-05-production-grant-harness.md) — derive real slot grants, require same-scope SSD restore before cancellation, and retain final release build proof.
- [Measured SSD restore costs](2026-09-05-cache-stage-measurement.md) — preserve observations across Ready refreshes and bind their use to the current capability.
- [Segmented production KV grants](2026-09-05-segmented-production-grant.md) — delete fixed-pool limits, preserve live owners across resize, and verify synthetic capacity boundaries.
- [Complete paged SSD provider integration](2026-09-05-paged-complete-provider.md) — shared host/native ownership, loaded factory gates and benchmark inputs; exact fleet validation pending.
- [Cache plan and dispatch generation ownership](2026-09-05-cache-prepare-generation.md) — stale-plan/dequeue regression fixes, lifecycle audit and combined race evidence.
- [Complete native paged checkpoints](2026-09-05-paged-complete-native.md) — bounded recurrent and historical-window restore, ownership and retirement; 630 native cases, with provider/model gates pending.
- [Coordinator cache restore cost](2026-09-05-cache-stage-cost.md) — signed restore overhead, cross-machine selection, unchanged admission and diagnostic microbenchmarks.
- [Provider allocator accounting and SSD lookup](2026-09-05-provider-footprint.md) — real backing lifetime, coherent capacity boundaries, optional footprint telemetry and candidate-only metadata probes.
- [Detached allocator sizing policy](2026-09-05-allocator-policy.md) — pure per-buffer projection, CPU/Metal allocator checks and six Swift cases.
- [Allocator footprint and native ownership](2026-09-05-allocator-footprint.md) — per-buffer bounds, actual backing settlement and 404 native cases; provider and model gates remain separate.
- [Process-memory telemetry](2026-09-05-process-memory-telemetry.md) — coherent optional observations, replay aging and bounded metrics; Swift, Go and TypeScript validation with explicit limits.
- [Paged runtime dtype protection](2026-09-05-paged-runtime-dtype.md) — 353 native cases, deterministic fault retirement and preserved fixture correction evidence.
- [Process admission and native ownership](2026-09-05-process-memory-admission.md) — atomic load claims, 169 native and 196 provider cases; real allocator evidence identifies the remaining footprint gate.
- [Native checkpoint page adoption](2026-09-05-paged-checkpoint-adoption.md) — typed ownership transfer, 162 distinct native cases and 118 combined provider cases; codec/process binding pending.
- [Coherent allocator snapshots](2026-09-05-coherent-memory-snapshot.md) — locked CPU/Metal accounting, a failing old-getter control, and the Swift C bridge.
- [Memory reservation retirement](2026-09-05-kv-owner-retirement.md) — live decode and load owners survive sustained rejection audits; 100 lifecycle cases pass.
- [Paged-storage producer and private transfers](2026-09-05-paged-storage-producer.md) — immutable native captures reach provider heartbeats; bounded raw page transfers pass mechanical checks.
- [Paged-storage heartbeat ingestion](2026-09-05-paged-storage-ingestion.md) — bounded coordinator observations, capture freshness and counter baselines; provider emission pending.
- [Paged model validation tools](2026-09-05-paged-model-validation-tools.md) — bounded concurrent measurements, explicit slot grants and failure-aware comparison.
- [Paged physical ownership and admission](2026-09-05-paged-physical-admission.md) — dynamic grants, exact buffer charges and release-before-refund checks across 224 cases.
- [Native KV types and explicit Qwen paging](2026-09-05-paged-native-types.md) — measured native storage types, tiny Qwen MTP parity and remaining shared-capacity gates.
- [Five-model native KV observations](2026-09-05-five-model-native-kv-probes.md) — exact fleet artifacts, measured per-layer types and target-only validation limits.
- [Request-owned date and GPT-OSS parity](2026-09-05-request-date-prompt-parity.md) — shared UTC context, actual GPT/Gemma token comparisons and preprocessing cost.
- [Qwen rendering and shared token parity](2026-09-05-qwen-renderer-parity.md) — exact 98-case fleet corpus, original 56-case replay, tool grouping and JSON bridge fixes.
- [Shared tokenizer ownership](2026-09-05-tokenizer-sharing.md) — verified tokenizer reuse, lower measured sidecar memory and unchanged exact plans in a local comparison.
- [Prompt sidecar under Linux limits](2026-09-05-prompt-sidecar-linux-arm64.md) — local native ARM/musl proof with both child address-space limits observed; native amd64 CI remains pending.
- [Exact-prefix holder index](2026-09-05-cache-holder-index.md) — bounded holder lookup across machine epochs, isolation regressions and local scaling measurements.
- [Provider cache tier advertisement](2026-09-05-provider-cache-tier.md) — suppress resident evidence when the accepted complete SSD store takes precedence.
- [Provider-aligned cache service cost](2026-09-05-cache-service-cost.md) — price verified executable prefixes by saved prefill after staging, with isolated coordinator and race checks.
- [Checkpoint routing across machines and turns](2026-09-05-checkpoint-turn-routing.md) — exact earlier-state eligibility, staging/queue crossovers and cold fallback through real receipts and reservation.
- [Segmented paged KV foundation](2026-09-05-paged-segment-foundation.md) — transactional native storage, bounded attention bindings and GPU dependency regression tests.
- [SSD cache heartbeat telemetry validation](2026-09-05-ssd-cache-telemetry.md) — typed observations, counter freshness, donation outcomes and nonblocking maintenance snapshots.
- [Qwen 3.5 contiguous SSD reference](2026-09-05-qwen35-contiguous-ssd-reference.md) — exact fleet artifact, normal-MTP SSD comparison and lifecycle checks before paging.
- [Qwen 3.6 contiguous SSD reference](2026-09-05-qwen36-contiguous-ssd-reference.md) — exact fleet artifact, first cache comparison and lifecycle checks before paging.

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
| 2026-09-05 | [qwen-moe-checkpoint-prerequisite](2026-09-05-qwen-moe-checkpoint-prerequisite.md) | Native and provider MoE checkpoint tests; full-size models and paging remain separate gates |
| 2026-09-05 | [gptoss20b-improvement-estimate](2026-09-05-gptoss20b-improvement-estimate.md) | Estimated optimization upside and corrected compiled-operation attribution |
| 2026-09-05 | [gptoss20b-quick-profile](2026-09-05-gptoss20b-quick-profile.md) | Approximate M4 Max prefill/decode measurements and targeted GPU dispatch findings |
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
| 2026-09-05 | [paged-prefix-cache-milestone](2026-09-05-paged-prefix-cache-milestone.md) | Tested resident page sharing, SSD tier selection and deadline preservation |
| 2026-09-05 | [paged-prefix-cache-model-check](2026-09-05-paged-prefix-cache-model-check.md) | GPT-OSS real-model parity, useful resident-page reuse, and first-token latency samples |
| 2026-09-05 | [radix-prefix-cache-baseline](2026-09-05-radix-prefix-cache-baseline.md) | Clean M5 Qwen3.8 HTTP baseline with MTP disabled; repeated prompts still pay full prefill |
| 2026-09-05 | [radix-prefix-cache-serial](2026-09-05-radix-prefix-cache-serial.md) | MTP-disabled prototype: exact replay evidence and repeated-prefix latency measurements |
| 2026-09-05 | [qwen-checkpoint-cache-model-check](2026-09-05-qwen-checkpoint-cache-model-check.md) | Normal-MTP exact outputs, compact long-prefix reuse, and native validation for resident prototypes |
| 2026-09-05 | [ssd-prefix-cache-model-check](2026-09-05-ssd-prefix-cache-model-check.md) | Normal-MTP Qwen SSD reuse, exact outputs, measured latency, bounded staging, and validation limits |

Plans and decision memos live in [`../design/`](../design/README.md).

## Trust, fleet, and infrastructure records

| Date | Report | One line |
|---|---|---|
| 2026-07-04 | [provider-trust-reliability](2026-07-04-provider-trust-reliability.md) | Why ~11% of the fleet stalled at `self_signed`, and the per-connection MDM fix |
| 2026-07-17 | [eigencloud-to-gcp-migration](2026-07-17-eigencloud-to-gcp-migration.md) | Record of the prod move from EigenCloud to a GCP Confidential VM (complete) |

## Coordinator performance program (2026-09)

| Date | Report | One line |
|---|---|---|
| 2026-09-04 | [coordinator-provider-modularization](2026-09-04-coordinator-provider-modularization.md) | Responsibility modules, removed wrappers, source-size accounting, and full Go/Swift validation |
| 2026-09-04 | [coordinator-provider-hotpaths](2026-09-04-coordinator-provider-hotpaths.md) | Routing, tool-call assembly, provider parsing and startup cleanup with local CPU measurements |
| 2026-09-02 | [coordinator-performance-program](2026-09-02-coordinator-performance-program.md) | First-principles pass over every coordinator operation with a measurable cost: fleet-scale benchmarks, store cache, route batching, relay coalescing, parse-once bodies |
| 2026-09-02 | [coordinator-performance-pr-body](2026-09-02-coordinator-performance-pr-body.md) | Original PR body of the 75-commit program branch, kept as the record |
| 2026-09-03 | [perf-pr-a-body](2026-09-03-perf-pr-a-body.md) | Landing the store/api half of the program on master (read-through cache, batched route sink, parse-once bodies, relay coalescing) |
| 2026-09-03 | [perf-pr-b-body](2026-09-03-perf-pr-b-body.md) | PR description for the routing-scan landing (PR B): per-model provider index, in-place snapshots, TPS median caches, version memos, heartbeat swap-plan coalescing; before/after benchmarks and the `scanned` semantics change |
| 2026-09-03 | [perf-pr-c-tier3-body](2026-09-03-perf-pr-c-tier3-body.md) | PR description for the Tier 3 lock restructure (PR C, stacked on PR B): per-identity `gateState` fault trackers off the global write lock, the reservation commit under `r.mu.RLock` + `p.mu`, the `EIGENINFERENCE_RESERVE_COMMIT_MODE` kill switch; invariants, benchmarks and the review follow-ups |
| 2026-09-03 | [perf-pr-cd-body](2026-09-03-perf-pr-cd-body.md) | Wave fixes following the A+B base: WebSocket fragmentation, bounded queue drains, restart/drain/cancel lifecycle and telemetry |

## Raw benchmark outputs

Machine-generated; kept as evidence for the reports above.

| Files | What |
|---|---|
| [`raw/…L500…`](raw/gptoss-20b-actfloor-shipped-pins-L500-2026-09-02.md), [`raw/…L4000…`](raw/gptoss-20b-actfloor-shipped-pins-L4000-2026-09-02.md), [`raw/…L4000-solostripe2048…`](raw/gptoss-20b-actfloor-shipped-pins-L4000-solostripe2048-2026-09-02.md) | `BenchCBv2RealModel` runs measuring gpt-oss-20b activation floors on the shipped pins at prompt lengths 500 and 4000, and with the solo-prefill stripe at 2048 (2026-09-02) |
| `clean-*.json`, `m22-*.json`, `mr-*.json` (in this directory, not `raw/`) | `BenchCBv2` JSON outputs from the Gemma 4 prefill experiments (`MLX_GATHER_QMM_EXPERT_SLICES` control vs `trust`; stripe 2048 vs base) behind the August measurement reports |

## Not here

- Release notes: [`../releases/v0.8.0-notes.md`](../releases/v0.8.0-notes.md) (superseded by v0.8.1; kept as the record). Current release history is `CHANGELOG.md` at the repository root.
- Plans and decisions, each with a status: [`../design/README.md`](../design/README.md).

- [GPT-OSS 20B optimization results](2026-09-05-gptoss20b-optimization-results.md) — local prefill/decode changes, paired comparisons, correctness evidence and rejected experiments.
- [2026-09-06-gemma-contiguous-logit30-traces.md](2026-09-06-gemma-contiguous-logit30-traces.md) — Corrected-control Gemma index-30 logit evidence, preserved correctness failure and M5 retirement.
- [Gemma position-30 raw evidence capsule](2026-09-06-gemma-contiguous-logit30-traces/README.md) — All 137 manifested payloads and CPU reproduction of the original analysis.

- [Actual forward-width runtime build and native validation](2026-09-06-forward-width-runtime.md) — source-bound M5 build, engine/compiler tests and retained setup failures; real-model batching remains separate.

- [Representative quality cohort preparation](2026-09-06-representative-quality-cohort.md) — six-artifact prose/code/reasoning inputs with CPU checks; model execution and quality conclusions remain pending.
