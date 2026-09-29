# First-content release comparison

These read-only aggregate queries compare two received-at cohorts for one
resolved model. They keep logical failures, successful first-content latency,
additional attempts and provider decode gaps separate. They produce no request,
provider, account or customer identifiers and no prompt or completion content.

## Run a comparison

1. Record the exact coordinator revisions, provider release/adoption state,
   model/runtime identity, UTC windows and **historical**
   `EIGENINFERENCE_PROFILE_SAMPLE_RATE` for both windows. Choose nonoverlapping
   windows of at most 24 hours each, away from rollout transitions; split a
   window if its sampling configuration changed. The profiler must have been
   enabled throughout both windows. A coordinator-only release cannot change
   the provider's admission gate.
2. Verify both tables still retain the complete windows. Wait for handlers,
   attempt finalization and replica replay to settle. Inspect outcome sink
   dropped/write-failed metrics and profile sink dropped/write-failed metrics
   for both windows. Unsampled is not a guarantee of lossless storage. Record
   retention, lag and sink-health evidence alongside the aggregate result.
3. With an authorized read-only replica connection, run the query below using
   the real historical parameters. These values illustrate the invocation;
   they are not production measurements or an assertion about deployed rates.

   ```bash
   PGOPTIONS='-c default_transaction_read_only=on -c statement_timeout=120000' \
   psql "$READONLY_REPLICA_DSN" -XqAt -v ON_ERROR_STOP=1 \
     -v model='EigenLabs/Qwen3.8-27B-4bit-mtp' \
     -v before_start='2026-09-28T20:44:00Z' \
     -v before_end='2026-09-28T20:59:00Z' \
     -v after_start='2026-09-29T20:44:00Z' \
     -v after_end='2026-09-29T20:59:00Z' \
     -v before_sample_rate='0.1' -v after_sample_rate='0.1' \
     -c 'BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY' \
     -f scripts/serving_performance/monitoring/release_comparison.sql \
     -c COMMIT > release-comparison.json
   ```

   No helper function, temporary table or persistent object is created. IDs
   are used only inside the query for sampling and joining. The final JSON is
   an allowlisted aggregate projection; do not replace it with raw table or
   provider-profile exports. It includes extraction/replay timestamps and
   parameters, so the result can be reproduced. Later evidence revisions can
   change a repeated query; retain the original aggregate with its extraction
   timestamp. Invalid windows/rates produce `parameters_valid: false` and
   empty metric arrays.
4. Require `parameters_valid: true`; report all coverage and completeness
   counters before interpreting differences. Zero rows are not evidence of
   zero traffic if retention, capture or replay is incomplete. Publish the
   aggregate JSON with the release evidence; these scripts do not query
   production automatically.

## Metric definitions

| Output | Definition and source |
|---|---|
| `logical_requests`, `http_429_requests`, `status_zero_requests` | Count the latest unsampled `request_outcomes` row once, using indexed `received_at` in `[start,end)` and the resolved `record.model`. Group by endpoint and stream mode. Do not count retained failure attempts as separate HTTP requests. Status zero stays visible rather than disappearing from a success/429 denominator. [`RequestOutcomeRecord`](../../../coordinator/store/request_outcomes.go). |
| `final_actual_first_content_timeouts` | Conflict-free logical outcomes with `normalized_code=ext_first_content_timeout`: the final coordinator first-content timeout rejection. Provider `deadline_unreachable`, queue deadline and provider safety/backpressure timeouts are different outcomes. This does not count every provider-side elapsed expiry. [`normalizedRequestOutcome`](../../../coordinator/api/request_outcome.go), [`classifyExhaustedStatus`](../../../coordinator/api/dispatch.go). |
| `requests_with_recorded_timeout_attempt`, `recorded_timeout_attempts` | Requests/attempts with compact attempt `raw_reason=first_chunk_timeout` and `final_status=timeout`, including a timeout followed by recovery. Incomplete/truncated evidence can undercount these; the corresponding completeness counter remains visible. These are separate from the final logical timeout count. |
| `deadline_unreachable_rejections` | Conflict-free rejected logical outcomes whose final raw reason is `deadline_unreachable`. Includes predictive refusal **and provider-side elapsed expiry**, which share this code. The raw reason alone cannot distinguish them; this query does not infer a predictive count from it. [`FirstContentDeadline.check/race`](../../../provider-swift/Sources/ProviderCore/Coordinator/CoordinatorClientTypes.swift), [`EngineV2Bridge.submitTokenized`](../../../provider-swift/Sources/ProviderCore/Inference/Engine/Bridge/EngineV2Bridge+Submission.swift). |
| `additional_attempts_per_request` | Sum `max(attempts_total-1,0)` divided by `retry_denominator_requests`, including zero-attempt/one-attempt requests. Restrict to complete, untruncated, conflict-free outcomes. Includes speculative hedges; `hedge_attempts` counts nonempty `backup_of`, and `additional_non_hedge_attempts_per_request` subtracts those. Attempt slots are not proof of provider receipt or GPU admission. [`refreshLocked`](../../../coordinator/api/request_outcome.go). |
| `successful_first_content` | One successful winning attempt per completed, conflict-free logical request that passes the reconstructed deterministic sample. `first_content_us/1000` measures coordinator request ingress to content commit, including earlier retries. It is not engine TTFT, first transport byte, client flush or confirmed upstream receipt. [`stampFirstContent`](../../../coordinator/api/profiler_dispatch.go), [`RequestProfileRecord`](../../../coordinator/store/profile_records.go). |
| `actual_prompt_band` | Positive provider-tokenized `provider_profile.prompt_tokens`, only from valid, consistent profiles. Never replace a missing actual count with the coordinator estimate. Bounds are `[1,4096)`, `[4096,16384)`, `[16384,32768)`, `[32768,infinity)`. |
| `matched_in_both_periods` | Exact common strata across actual prompt band, endpoint, stream, tools, vision, chip family, KV backend, reported MTP state, original first-content budget and requested output band. Compare only rows marked true. Missing MTP metadata remains null, separate from false. `provider_release_mix` reports versions among this latency sample, not whole-fleet adoption. |
| `coordinator_on_time_completed_requests` | Sampled completed requests with one unambiguous, non-anomalous first-content stamp within the original positive request-absolute `first_content_budget_ms`. Divide by **all** `sampled_logical_requests` to monitor on-time completed responses per incoming request, and report missing timing/budget coverage alongside it. Missing timing makes this a lower bound, not a zero-latency success. Completion is coordinator-observed; upstream receipt is unobserved. |
| `provider_decode_token_gaps` | Unavailable in current production profiles. `max_chunk_gap_us` measures coordinator response flush/event spacing, while `engine.step_latency_ns_max` mixes engine phases and is only a maximum. Neither is a token-gap distribution. Use separately qualified hardware confirmed-token timing receipts; identify batched/MTP token timing semantics. Do not label content-frame gaps as token gaps. [`relayStamps.flushedFrames`](../../../coordinator/api/profiler_dispatch.go), [`StoredEngineProfile`](../../../coordinator/api/profiler_provider.go). |

Logical 429 rate is `http_429_requests / logical_requests`; final actual timeout
rate uses the same logical denominator. Report raw counts and status-zero,
conflict and unfinished-handler counts beside rates. Do not derive prompt-band
failure rates: outcome rows do not contain actual prompt counts for every
request, especially refusals before tokenization.

## Sampling and interpretation

[`profiler.sampled`](../../../coordinator/api/profiler.go) uses 32-bit FNV-1a
over the UTF-8 **logical coordinator request ID**, then compares
`float64(hash)/2^32 < sampleRate`. The query mirrors its strict inequality and
uses the smaller of the two historical rates for a common sample. It includes
all successes selected by that hash, including slow/retried successes, and
excludes successes retained **only** by the
[`alwaysRecord`](../../../coordinator/api/profiler_record.go) exception. Hashing
an attempt ID, dropping all slow/retried successes, or using all retained rows
would each produce a different, biased latency sample.

Percentiles use PostgreSQL `percentile_cont` with linear interpolation and
include sample counts. Do not average percentiles across strata. Small samples,
missing profiles and lack of overlap must remain visible; this query does not
claim confidence intervals or repair nonrandom telemetry loss. Success-only
latency is conditional on acceptance: a gate that rejects long requests can
appear faster. Lower 429 rates require corroborating on-time completed-response
counts/rates, stable timeout/retry behavior and dedicated decode-gap evidence.

Even matched strata can differ in cache reuse, contention and prompt composition.
Provider rollout, coordinator changes and workload mix can move together.
This descriptive comparison does not identify a causal release effect and does
not turn retained refusal projections into observed successful timings.

## Verify locally

```bash
cd scripts
python3 -m unittest serving_performance.monitoring.test_release_comparison -v
```

Tests launch an isolated local PostgreSQL cluster on a temporary Unix socket,
run the actual query in a read-only transaction, and remove the cluster. They
cover sampling enrichment, logical/attempt denominators, coordinator timeout
versus the shared provider deadline-refusal code (including elapsed expiry),
prompt-band matching, percentile arithmetic, missing/ambiguous
evidence, conflict precedence, half-open windows and aggregate-only output.
They skip explicitly when PostgreSQL binaries are unavailable or run as root;
a skipped run is not SQL validation. No production connection is used.
