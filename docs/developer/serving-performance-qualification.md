# Qualify a serving performance profile

> Last updated: 2026-09-28 · commit `d89ef42be`

This procedure prepares an exact model/runtime/hardware profile for code review.
It never installs a profile or changes a running provider. The initial reviewed
hardware catalogs are empty: M5 Max B8 and M5 Ultra B16 remain qualification
targets. Six separately qualified prompt-count fallback records cover bounded
Qwen3.8 text/tool shapes; they grant no hardware scheduling authority.

## Prerequisites

- A dedicated test Mac, verified model artifact, source-matched provider build
  and Metal libraries; follow [build](build.md) and [test](test.md).
- Record the provider version, `cbv2-first-content-v2` runtime revision, resolved
  KV backend, chip name, GPU cores, RAM and the engine's entire configured context
  limit. An MTP profile also binds the verified assistant and every effective
  draft/verification setting. Plain-target evidence never certifies MTP. A
  mixed-prefill candidate may use only its exact global cap override described
  below; unrelated runtime overrides do not qualify.
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

   For an inline Qwen target with active production MTP, commit the candidate,
   acquire an exclusive test-machine lease, create a clean release build record,
   then run the supervised collector:

   ```bash
   python3 scripts/build-serving-qualification.py --output /tmp/qualification-build
   python3 scripts/run-serving-qualification.py \
     --build-receipt /tmp/qualification-build/build-receipt.json \
     --model-path /path/to/verified/snapshot --model-id EXACT_CATALOG_ID \
     --artifact-sha256 VERIFIED_WEIGHT_HASH --exclusive-gpu-lease LEASE_REFERENCE \
     --prompt-lengths 4096,16384,32768 --width 1 --iterations 20 \
     --output-tokens 128 --partition baseline
   ```

   The builder first runs `swift package clean`, then builds the isolated release
   tests, stages the matching metallib and runs the executable-identity test.
   Its record binds the unchanged committed source, SDK, toolchain, command log
   and resulting binary/metallib hashes. Reuse that record across cohorts only
   while those exact bytes and identities remain unchanged. A stale test bundle
   cannot acquire the identity of a newer checkout through the runner.

   The collector uses those verified prebuilt tests, never downloads weights, and writes a
   private temporary run directory containing receipts, logs, hashes and a
   summary. Its hard timeout terminates only its own process group. Add
   `--tool-history`, `--reused`, `--stagger-ms`, and each
   `--mixed-prefill-token-cap 128|256|512` in separate recorded cells. Requested
   lengths are measured after the actual template; a shorter resulting length
   cannot certify an unmeasured context boundary. Actual MTP rounds and prefix
   savings must be positive in cells claiming those paths.

   The supervisor checks actual `pmset` policy before and after the run;
   low-power-disabled alone cannot exclude High Power. It also checks process
   inventories before launch and once per second for unrelated CI workers,
   compilers and known inference/test runners. Detection terminates only its
   own workload and preserves an ineligible receipt. Idle CI listeners are
   allowed; unrelated work is never stopped.
   Each trial also samples thermal and Low Power state before, during and after
   execution. The nominal-only cohort declares a minimum 20-second cooldown,
   five seconds of stable nominal state, and a bounded 180-second recovery wait.
   A posture failure invalidates the cohort; samples are never dropped to repair
   its coverage. Cooldown policy and actual observations remain in the receipt.

   The explicit qualification build selects only `ServingQualificationTests`;
   production targets and release optimization remain unchanged. The
   `-enable-testing` flag exposes internal production APIs to this isolated
   harness. Do not add `-DDEBUG`: unrelated correctness tests intentionally use
   debug-only seams and are excluded from the qualification build graph.
   The executing test image reports its compile-time `DEBUG` condition, debug
   assertion mode and own binary SHA-256. The supervisor checks that hash against
   the staged binary; qualification rejects missing identity or debug behavior,
   even if the command-line build label says `release`.

   The collector records actual OpenAI content-frame arrivals and opt-in
   engine forward shapes. Its summaries label delivered throughput and frame
   gaps explicitly; a frame can contain several MTP tokens, so these are not
   individual token-gap measurements. The engine observer separately records
   committed-token counts at each existing readback, including accepted MTP
   bursts. Observation-local numeric row ordinals and relative timestamps
   produce engine decode rates and individual confirmed-token gaps (zero
   between tokens confirmed in the same burst). No request IDs, token IDs,
   draft proposals or text enter these receipts. Storage is bounded to 65,536
   receipts and 256 rows; any dropped receipt disqualifies the observation.
   It also records
   completed step launch-to-readback wall durations, classified as prefill,
   decode or mixed. It stores at most 8,192 timings per observation scope;
   dropped or unobserved timings disqualify a full-run percentile. No extra GPU
   evaluation or timing clock is introduced. Collector output is always
   `qualified: false` until the complete release evaluation below passes.
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
| Root | `schema_version: 2`, `identity`, `serving_sets` (includes `[]` and explicit competing model IDs distinct from `identity.model_id`), `qualification_cells`, `deadline_calibration`, candidate `build` identity; optional `mixed_prefill_token_cap` |
| Identity | `id`, `model_id`, `artifact_sha256`, `provider_version`, `runtime_revision`, `kv_backend`, `chip_name`, `gpu_cores`, `memory_gb`, `context_tokens_max`; optional exact `mtp` configuration |
| MTP identity | `enabled: true`, verified `artifact_sha256`, `max_draft_tokens`, optional `fixed_draft_tokens`, `max_speculative_batch`, `verification_mode`, `max_automatic_rectangular_tokens`; omitted for plain-target execution |
| Cell | `width`, `prompt_tokens`, `output_tokens`, `arrival_pattern` (`fixed`/`staggered`), `cache_state` (`cold`/`reused`), `competing_models`, `failures`, `raw_measurements_sha256`, `absolute_first_content_budget_ms`, `resolved_activation_floor_bytes`, `checks`, `samples` |
| Checks | Each of `correctness`, `constraints`, `isolation`, `cancellation`, `accounting`, `retirement` references actual `receipt_path` and `receipt_sha256`; live checks also require `provenance_path` and `provenance_sha256` |
| Sample | Unique `run_id`, `decode_p10_tps`, `aggregate_decode_tps`, `prefill_tps`, `first_content_p95_ms`, `token_gap_p95_ms`, actual `forward_widths`, `competing_model_active_requests` (positive measured count for every competing model), `power_mode: "automatic"`, `thermal_state: "nominal"`, `mtp_active` matching the identity, matching `mtp` and positive `mtp_rounds`/`mtp_proposed_tokens` when active, `effective_mixed_prefill_token_cap` (explicit integer engine cap; `null` selects the existing runtime/model default), `runtime_policy_overrides` (empty, or only the exact candidate global override), `activation_peak_bytes`, `kv_peak_bytes`, `resident_bytes`, `activation_reserve_bytes`, `memory_budget_bytes` |
| Chunk comparison | Each mixed staggered cell also carries `mixed_prefill_work_p95_ms` and `mixed_prefill_baseline` (the five rate/latency metrics, `receipt_sha256`, and explicit `effective_mixed_prefill_token_cap`: `null` for the runtime/model default or a nonnegative integer different from the candidate) |

The identity object accepts only the fields listed above; extra fields reject
the receipt. Put a candidate `mixed_prefill_token_cap` at the root. The evaluator
derives concurrency limits, `batch_curve`, and `qualification_report_sha256`
from the evidence and copies only the allowed identity fields into the profile.
An identity field cannot attach a runtime policy or qualification result.

`deadline_calibration` uses `version: 1`, the verified `prompt_contract_id`,
and bounded cells from `scripts/serving_performance/calibration.py`. Each cell
declares prompt/context intervals, cold/reused cache state, isolated/same-model/
other-model contention, exact competing profile IDs, measured phase rates and
maximum scheduler work/request/service-fraction bounds. Its numeric samples
include actual first-content duration, the same workload fields, receipt and
workload hashes, `tool_history`, unique request/run IDs and a partition fixed
before collection (`calibration` or `validation`). Measure each declared
interval endpoint and maximum work bound; the evaluator refuses extrapolation.

Training fits the smallest mean upper envelope `base_ms * error_ratio +
error_additive_ms` that covers every calibration observation, with ratio at
least one and nonnegative additive error. Validation never changes those fitted
terms. Both partitions need at least 20 observations, distinct prompts/runs,
and tool/history cases. A run or identical prompt in both partitions rejects
the receipt. Censored or refused observations remain failures, preventing a
successful-request-only sample from certifying the tail.

The default tail target is 95% coverage, with its exact one-sided 95%
Clopper-Pearson lower confidence bound also at least 95%. With no misses, this
requires at least 59 independent validation trials; 20/20 supplies only an
86.1% lower bound. The report includes empirical coverage, confidence bound
and signed validation error p50/p95/max. These bounds assume independent,
representative trials; changing only an ID does not make a repeated prompt an
independent workload. Explicit relaxed-confidence receipts remain evidence
only and cannot produce a profile. Schema 1 concurrency-only receipts remain
readable for existing tooling; use schema 2 for new calibrated profiles.

### Verify prerequisite files

Preserve the actual prerequisite JSON files beside the assembled receipt, or
supply `--evidence-root /path/to/reviewed/evidence` to either qualification
command. Relative references resolve under that root; references outside it,
missing files, changed bytes, and files over 8 MiB fail closed. A caller-supplied
`passed` flag and a digest-shaped string cannot replace execution evidence.

Use these two receipt kinds:

- `deterministic_regression` may cover only explicit `scopes` of `constraints`
  and/or `isolation`. It must record the candidate's exact `sdk_commit`, a zero
  test exit status, positive passed-test counts and its test-log digest. These
  SDK unit fixtures do not claim a hardware/model match or certify live
  cancellation/accounting. Rerun them when the SDK commit changes.
- `serving_lifecycle` covers `correctness`, `cancellation`, `accounting` and
  `retirement`. Retain both the supervised raw receipt and provenance. The
  verifier binds model, artifact, provider version, runtime revision, KV backend,
  actual scheduler configuration, MTP identity, source commit/tree, SDK, binary
  and metallib to the candidate. Both real cancellation phases must be present,
  with actual work accounting, native retirement and post-cancellation greedy
  parity. Live checks cannot transfer from another artifact or build.

The `build` object supplies `source_commit`, `sdk_commit`,
`source_tree_sha256`, `test_binary_sha256` and `metallib_sha256`; deadline-only
receipts additionally require their existing clean optimized build fields.
The live prerequisite's embedded clean-build record is verified by the same
build-identity validator as performance observations. One raw receipt may cover
several applicable checks; each reference retains its exact file hash. See
[`check_receipts.py`](../../scripts/serving_performance/check_receipts.py) for
the closed scope and identity rules. Review the referenced test receipts as
well as the numeric performance report before promoting any record.

### Narrow deadline-only qualification

Use `--serving-policy --scheduler-max-concurrency 4 --width 1` when the verified
ordinary configuration is four running slots but the observed cell is isolated.
The receipt records the factory's actual effective width, prefill chunk,
partial-prefill cap, solo stripe, mixed cap and full configured context; a
requested value alone is insufficient. `--prompt-band 4096:12288 --iterations
40 --partition calibration --tool-history` declares varied bodies across that
band, including its endpoints. Collect a separate `validation` job with new
bodies and enough independent samples for the confidence gate.

Add a supervised `--lifecycle-checks` job for real prefill/post-MTP-content
cancellation, native retirement, partial-work accounting and subsequent greedy
output parity. This enables only
`ServingQualificationLifecycleTests.cancellationRetiresActualWorkAndPreservesGreedyOutput`
through its explicit `DARKBLOOM_SERVING_QUALIFICATION_LIFECYCLE=supervised-v1`
gate. Correctness/lifecycle receipts and performance receipts remain distinct.

```bash
python3 scripts/assemble-deadline-receipts.py /tmp/training-run /tmp/heldout-run \
  --profile-id deadline-EXACT_ID --prompt-min 4096 --prompt-max 12288 \
  --checks /tmp/reviewed-lifecycle-checks.json --output /tmp/deadline-receipt.json
python3 scripts/qualify-deadline-performance.py /tmp/deadline-receipt.json \
  --output /tmp/deadline-review.json
```

The initial assembler supports isolated cold work and refuses to infer a
contended scheduler's work. Training alone selects measured phase rates;
held-out data never refit them. First-content context is the incoming prompt
plus `min(requested_output_tokens, 33)` for an isolated request; its full requested output remains an independent
memory/context check and does not inflate the first-content work vector.
The bounded incoming decode allowance remains in that vector.

A deadline-only candidate binds the clean release build, exact factory
configuration and measured cell domain. It has no batch curve or service limit
and cannot change concurrency, mixed-prefill policy, activation reserve or
configured context. Out-of-cell work retains the existing conservative path.
Universal serving-profile gates above remain mandatory for actual policy
promotion. Review and add passing deadline-only entries to the corresponding
Swift/Go deadline catalogs together.

### Prompt-count fallback evidence

Generate independent synthetic text/tool/history bodies with
`scripts/generate-prompt-count-corpus.py`. The JSON input carries temporary
base64 bodies; do not commit those inputs. Project the exact original JSON
bytes through the coordinator's real estimator and shape extractor:

```bash
cd coordinator
DARKBLOOM_PROMPT_COUNT_CORPUS=/tmp/corpus-bodies.jsonl \
  DARKBLOOM_PROMPT_COUNT_OUTPUT=/tmp/corpus-shapes.jsonl \
  go test ./api -run '^TestPromptWorkQualificationCorpus$' -count=1
```

Run `ServingPromptCountQualificationTests.collectTemplateCounts` with
`DARKBLOOM_PROMPT_COUNT_QUALIFICATION=1` and the explicit
`DARKBLOOM_PROMPT_COUNT_MODEL_PATH`, `DARKBLOOM_PROMPT_COUNT_MODEL_ID`,
`DARKBLOOM_PROMPT_COUNT_ARTIFACT_SHA256`, `DARKBLOOM_PROMPT_COUNT_INPUT`, and
`DARKBLOOM_PROMPT_COUNT_OUTPUT` environment variables. This path loads only the
actual tokenizer and template. It does not construct a model or invoke Metal.
Then join the numeric receipts:

```bash
python3 scripts/qualify-prompt-counts.py /tmp/provider-counts.json \
  /tmp/corpus-shapes.jsonl --output /tmp/prompt-count-review.json
```

The evaluator freezes grouping before collection, fits the median and upper
count bound using training observations, and measures held-out coverage with
the same confidence requirement. Serialized body/messages/tools/tool-call/
tool-result sizes and role/count domains are mandatory, including zero bounds
for absent features. Held-out observations outside the training domain count
as uncovered; they never expand the domain or disappear from the denominator.
Only passing exact-artifact/template cells are candidates for reviewed fallback
defaults. The exact runtime tokenizer planner remains the primary path.

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
