# Qualify a serving performance profile

> Last updated: 2026-09-28 · commit `602bfe613`

This procedure prepares an exact model/runtime/hardware profile for code review.
It never installs a profile or changes a running provider. The initial reviewed
catalogs are empty: M5 Max B8 and M5 Ultra B16 remain qualification targets.

## Prerequisites

- A dedicated test Mac, verified model artifact, source-matched provider build
  and Metal libraries; follow [build](build.md) and [test](test.md).
- Record the provider version, `cbv2-first-content-v1` runtime revision, resolved
  KV backend, chip name, GPU cores, RAM and the engine's entire configured context
  limit. The initial runtime identity covers plain target execution; assistant
  and unrelated runtime overrides do not qualify. A mixed-prefill candidate may
  use only its exact global cap override described below.
- Automatic power mode and nominal thermal posture. High-power-only results do
  not certify ordinary service. Keep production traffic off the test machine.

## Steps

1. Measure supported actual prompts 1,024/4,096/16,384/32,768 and outputs
   128/1,024/4,096 at widths 1/2/4/6/8 for Max and 1/2/4/8/12/16 for Ultra.
   Include fixed/staggered arrivals, cold/reused prefixes and isolated/competing
   serving sets. Also measure the configured boundary for each supported output
   length (`context_tokens_max - output_tokens` prompt tokens). Shapes that exceed the
   configured total context are excluded; the resolver never silently reduces
   a model's advertised context to match a profile.
2. Use production-engine benchmark modes for numeric measurements. For example:

   ```bash
   darkbloom benchmark --model MODEL --arrival-invariance --arrival-width 8 \
     --arrival-prompt-tokens 4096 --arrival-decode-tokens 1024 \
     --arrival-iterations 20 --kv-backend contiguous
   ```

   Arrival invariance measures host delivery and greedy output agreement. It has
   no prefix cache and does not alone certify reused-prefix, isolation,
   cancellation, accounting or competing-model cases. Collect those receipts
   with the real cache/HTTP/lifecycle suites described in [test](test.md).
   Benchmark factories explicitly preserve candidate widths before a profile
   exists, while retaining native architecture and memory gates. Arrival/sweep
   reports record `effectiveMaxConcurrentRequests` and refuse a requested width
   that the architecture cannot construct. Ordinary serving still uses reviewed
   profile limits. Engine timing records actual batch rows; a constructed
   scheduler cap alone is insufficient evidence of an actual forward width.
3. Assemble the raw JSON receipt below from preserved artifacts. Every cell needs
   at least 20 independent repetitions. Record numeric measurements and hashes
   of the raw artifacts; do not turn missing checks into passing booleans.
4. Evaluate without changing runtime defaults:

   ```bash
   python3 scripts/qualify-serving-performance.py receipt.json --output review.json
   make benchmark-wrapper-test
   ```

   A failed width remains in the review report with its reasons. The derived
   curve ends before the first missing or failed required width: a larger
   scheduler can still execute that smaller batch shape, so passing B4 cannot
   bypass a failed B2. Every required width through the proposed cap must pass.
5. Review the raw receipts and derived report, then add the same reviewed record
   to Swift `ServingPerformanceProfiles.reviewed` and Go
   `reviewedServingPerformanceProfiles` in one signed change. Preserve the raw
   receipt whose exact bytes hash to `qualification_report_sha256`. The hash
   excludes the derived profile, avoiding a self-referential digest.

## Receipt contract

The executable contract is `scripts/serving_performance/matrix.py` and
`scripts/serving_performance/evaluate.py`; synthetic unit fixtures in
`scripts/serving_performance/test_qualification.py` illustrate the schema and
are **not hardware evidence**.

| Object | Required fields |
|---|---|
| Root | `schema_version: 1`, `identity`, `serving_sets` (includes `[]` and explicit competing model IDs distinct from `identity.model_id`), `qualification_cells`; optional `mixed_prefill_token_cap` |
| Identity | `id`, `model_id`, `artifact_sha256`, `provider_version`, `runtime_revision`, `kv_backend`, `chip_name`, `gpu_cores`, `memory_gb`, `context_tokens_max` |
| Cell | `width`, `prompt_tokens`, `output_tokens`, `arrival_pattern` (`fixed`/`staggered`), `cache_state` (`cold`/`reused`), `competing_models`, `failures`, `raw_measurements_sha256`, `absolute_first_content_budget_ms`, `resolved_activation_floor_bytes`, `checks`, `samples` |
| Checks | Each of `correctness`, `constraints`, `isolation`, `cancellation`, `accounting`, `retirement` has `passed: true` and `receipt_sha256` |
| Sample | Unique `run_id`, `decode_p10_tps`, `aggregate_decode_tps`, `prefill_tps`, `first_content_p95_ms`, `token_gap_p95_ms`, actual `forward_widths`, `competing_model_active_requests` (positive measured count for every competing model), `power_mode: "automatic"`, `thermal_state: "nominal"`, `mtp_active: false`, `effective_mixed_prefill_token_cap` (explicit integer engine cap; `null` selects the existing runtime/model default), `runtime_policy_overrides` (empty, or only the exact candidate global override), `activation_peak_bytes`, `kv_peak_bytes`, `resident_bytes`, `activation_reserve_bytes`, `memory_budget_bytes` |
| Chunk comparison | Each mixed staggered cell also carries `mixed_prefill_work_p95_ms` and `mixed_prefill_baseline` (the five rate/latency metrics, `receipt_sha256`, and explicit `effective_mixed_prefill_token_cap`: `null` for the runtime/model default or a nonnegative integer different from the candidate) |

The identity object accepts only the fields listed above; extra fields reject
the receipt. Put a candidate `mixed_prefill_token_cap` at the root. The evaluator
derives concurrency limits, `batch_curve`, and `qualification_report_sha256`
from the evidence and copies only the allowed identity fields into the profile.
An identity field cannot attach a runtime policy or qualification result.

## Verify

The evaluator uses the lowest rate and highest latency across independent
repetitions, checks each shape against its own B1 and previous required width,
requires decode p10 ≥30 tokens/s and ≥10% aggregate gain, and enforces both the
absolute first-content budget and `max(3000 ms, 1.5 × B1)`.

Every sample must record the engine's explicit mixed-prefill cap configuration.
An explicit `null` selects the existing runtime/model default; it does not mean
that mixed prefill is unlimited. For a candidate such as `128`, the field must
be the integer `128` in every sample. An empty override map is valid when the
benchmark sets the cap directly; otherwise the only permitted map is
`{"DARKBLOOM_CBV2_MIXED_PREFILL_CAP": "128"}`. A changed root candidate cannot
reuse measurements of a different applied cap. Other overrides remain rejected,
and a runtime-default profile requires an empty map. The baseline comparison must
identify a different explicit cap (or `null` for the runtime/model default); a missing policy or the
same candidate policy is not a qualifying baseline.

Mixed-prefill promotion requires ≤100 ms incremental work, ≥25% lower mixed
token-gap p95, ≤5% first-content regression, ≤5% aggregate throughput loss and
no failures. A B1-only result cannot certify or attach a mixed-prefill cap.
The 5% first-content bound is the evaluator's explicit definition
of the design's “no material regression.” Existing activation floors, hard
memory cap and serving-set KV fit remain mandatory; these measurements do not
lower the Swift/Go floor tables.

The evaluator validates receipts' shape and claims, not their authenticity.
Reviewers must inspect the referenced source artifacts and rerun measurements
before adding release data. A passing report is a review candidate, never an
automatic runtime promotion.

## Related

- [Provider inference](../architecture/inference.md)
- [Scheduling and warm pools](../architecture/scheduling.md)
- [First-content design](../design/first-content-performance.md)
