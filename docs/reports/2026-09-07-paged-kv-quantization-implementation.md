# Paged KV quantization implementation and validation

> Last updated: 2026-09-07 · commit `47da6bf26`

Packed KV storage and an optional fused-prefill experiment are implemented in
the isolated `d-inference-kv-quant` worktree. The observed GPT-OSS INT4 failures
and remaining prefill cost do not support changing the native storage default.
**Status: Implementation complete for opt-in review** — targeted code and
ownership gates pass; broader quality, strict mixed-arrival qualification and
new-head CI remain open. Native defaults are retained. This implementation
record does not authorize rollout.

## Scope and provenance

The work starts from parent `0b46b1618` and the native-library baseline recorded
in the [catalog provenance](../../reports/kv-quantization-2026-09-07/provenance.json).
The [strategy body](../design/paged-kv-quantization-strategy.md) remains frozen.
All measurements below are local Apple M4 Max observations with 128 GiB of RAM.
Names such as `release9`, `release10` and `release11` identify optimized local build attempts,
not deployed provider release versions.

| Tested artifact | Aggregate SHA-256 | Source |
|---|---|---|
| `qwen3.6-35b-a3b-vl-mtp-mxfp8` | `d932e96b00404b0575fff47e2dac8ed113056b3f22d0040c3c8d3f9ef25b09ed` | [Qwen native receipt](../../reports/kv-quantization-2026-09-07/model-runs/qwen36-quality-c1-native-release9-attempt1.json) |
| `gpt-oss-20b` | `61bfc04e4016a7fa487eb10e29f79360047e302487229f298da3681984aec512` | [GPT native receipt](../../reports/kv-quantization-2026-09-07/model-runs/gptoss-quality-512-c1-native-release9-attempt1.json) |
| `gemma-4-26b-qat-4bit` | `2468a0cb3049a871f42052f4d9f9380bf12a0792f64c7a29f768559fc7d28785` | [Gemma native receipt](../../reports/kv-quantization-2026-09-07/model-runs/gemma4-quality-c1-native-release9-attempt1.json) |

The release9 quality receipts record executable SHA-256
`2d6dea4e5c93e6d39f9690deb50b8f7029d6e53de0a883db52e7674a937af6d7`
and metallib SHA-256
`20972c37e53fe6db3b3191a0434f6604c4ffc4f5ac62b370574f9922585b0fdb`.
The matched release10 prefill batch uses executable
`7529f66e0ed940a0009c2eda33fcb807d96fb5b52bd85dffaf5f03c3eaceddd6`
and the same metallib. Model hashes match before and after each completed run;
the [release10 runtime postcheck](../../reports/kv-quantization-2026-09-07/validation/release10-prefill-runtime-postcheck.json)
retains the runtime-file check. Source inventories before and after each build
remain under [validation](../../reports/kv-quantization-2026-09-07/validation/).
The release11 quiet repeat uses executable
`8e18d7c8ffcba82d2f4ae67c92ad6abd254164efe18c6046b70eb77bcbc65935`;
its [window receipt](../../reports/kv-quantization-2026-09-07/model-runs/release11-quiet-window.json)
and per-run runtime brackets retain the execution controls.

## Implemented behavior

The [format and accounting reference](../reference/paged-kv-quantization.md)
is the canonical description of the current APIs and defaults.

| Area | Implemented result |
|---|---|
| Storage | Optional K4/V4, K8/V4 and K8/V8 byte-packed full-attention pages; token-local group64 affine codes with FP32 scale/offset metadata. K4/V4 occupies five effective bits per value, including metadata. |
| Quantization basis | Fixed signed normalized Hadamard on post-RoPE Q/K; public choices use `min(128, headDim)`. V remains unrotated. Native query/output types and FP32 accumulators are retained. |
| Direct attention | Decode reads packed pages inside the attention tile. Prefill shares one physical-row topology across query blocks and uses fixed step-owned partial/meta arenas, without a native full-history duplicate. |
| Optional prefill | Benchmark-only `--quantized-prefill opportunistic` uses fixed FP32 KV/Q and BOOL-mask arenas with forced fused SDPA for eligible D64/D256 text prefill. Balanced blocks contain 9–128 queries. Every FP32 SDPA output and the final native output are priced. |
| Memory ownership | Guaranteed direct workspace is prepaid separately from growing storage. Optional prefill obtains an additive permit before any allocation or KV write; refusal preserves the funded direct path. Real completion fences order arena reuse and stream retirement precedes refund. |
| Persistence | Resident reuse and complete checkpoints retain original packed bytes and format identity. Generic native-snapshot adoption is disabled for packed storage, avoiding dequantization/requantization on restore. |
| Serving surfaces | Exact-model storage selection, literal physical KV rates, raw-token capacity accounting and graph-built prefill receipts are wired through the provider. Sliding windows, recurrence, model weights and compute-concurrency limits retain their own accounting. |

The native storage choice remains the default for all models. Direct packed
prefill remains the production prefill policy even when an operator explicitly
selects packed storage; the optional selector is exposed only by supported
benchmark commands.

## Native and provider validation

These runs overlap. Their counts must not be summed as a new unique-test total.

| Gate | Completed evidence | Boundary |
|---|---|---|
| Scoped native baseline | 126 unique native tests across the scoped, broader and isolated physical-admission runs in the [admission validation record](../../reports/kv-quantization-2026-09-07/admission-validation/README.md) | Baseline before subsequent optional-prefill and late admission work |
| Tensor-stride correction | [23 tests in seven suites](../../reports/kv-quantization-2026-09-07/admission-validation/kv-query-stride-tests-attempt1.log) pass | Actual feature stride two, zero strides and negative strides across FP16/BF16/FP32; native segmented and window controls included |
| Optional fused integration | [40 tests in nine suites](../../reports/kv-quantization-2026-09-07/admission-validation/kv-fused-prefill-integrated-attempt1.log) pass | Exact Qwen/GPT GQA8 attention shapes, 9/129/273-query calls, strided inputs, sinks, cross-group reuse, no duplicate arena charge, refusal, cancellation/reused-ID ownership and single-buffer limits |
| Explicit fused API and Metal tile | [Five Swift/C API tests](../../reports/kv-quantization-2026-09-07/validation/kv-force-fused-swift-attempt4.log) pass | D64/D192/D256 pitched-mask/sink controls, GQA8, default-routing compatibility, D512 refusal and an allocation control that excludes a composed score tensor |
| Provider option and receipts | [43 tests in 11 suites](../../reports/kv-quantization-2026-09-07/validation/quantized-prefill-provider-attempt1-pass.log) pass | CLI validation, typed mode propagation, graph-built statistics and post-shutdown cleanup receipts |
| Optional-memory deadline arrival | [28 XCTest and 11 Swift Testing tests](../../reports/kv-quantization-2026-09-07/admission-validation/kv-optional-deadline-retirement-attempt1.log) pass, including six new expanded cases | Actual fast-step retirement, full/partial prefill, original deadline expiry, cancellation/generation fencing and the unchanged direct-mode path |
| Coordinator capacity | Registry/protocol tests and the focused race run pass in the [admission record](../../reports/kv-quantization-2026-09-07/admission-validation/README.md) | Baseline physical/raw-token capacity work; execution partition has separate checks below |
| Execution-history partition | Full Go run passes 26 tested packages; 11 focused identity race tests pass. Provider runs pass 17 tests in two suites and an overlapping expanded 95 tests in 25 suites; focused API/registry checks and TS mirror lint pass after the final additions | [Validation receipt and log inventory](../../reports/kv-quantization-2026-09-07/validation/execution-identity-validation-log-receipt.json). The full Go run precedes the final API detector exclusion; focused tests cover that addition. |

The tested optional reservation is additive to direct credits, rather than
borrowing credit needed by later layers. A later audit also identified that a
deadline arrival can observe an earlier step's optional reservation before
retirement. The implemented helper now finalizes the actual owning step before
forecasting that arrival, using real GPU/CPU stream completion and the original
absolute deadline. Its targeted runtime tests above pass; an independent
read-only review also finds no remaining issue in the changed path. Strict
mixed real-model arrival qualification remains inconclusive, as recorded below.

## Authored generation observations

Each input contains nine authored cases: eight have expected text and one code
generation case is ungraded. Prompts are pinned token arrays, MTP and prefix
cache are off, generation is greedy with natural EOS, and generated code is
recorded without execution. Qwen/Gemma ceilings are 96 or 160 output tokens;
the matched GPT controls below use a 512-token ceiling.

Grades below use the supplemental production-parser serving-content comparison,
trimming only outer whitespace. Raw streamed text, token IDs and raw grades
remain unchanged. This distinction matters for GPT's Harmony reasoning frames:
raw-stream exact equality is not a final-answer grade.

| Local runtime | Artifact / case concurrency | Candidate | Native serving matches | Candidate serving matches | Paired record |
|---|---|---|---|---|---|
| release9 | Qwen3.6 / 1 | INT4, direct | 6/8 | 6/8 | [C1 comparison](../../reports/kv-quantization-2026-09-07/model-runs/qwen36-quality-c1-int4-comparison-release9-attempt1.json) |
| release9 | Qwen3.6 / 4 | INT4, direct | 6/8 | 6/8 | [C4 comparison](../../reports/kv-quantization-2026-09-07/model-runs/qwen36-quality-c4-int4-comparison-release9-attempt1.json) |
| release9 | Gemma QAT / 1 | INT4, direct | 6/8 | 6/8 | [Gemma comparison](../../reports/kv-quantization-2026-09-07/model-runs/gemma4-quality-c1-int4-comparison-release9-attempt1.json) |
| release9 | GPT-OSS / 1 | INT4, direct | 8/8 | 6/8 | [INT4 comparison](../../reports/kv-quantization-2026-09-07/model-runs/gptoss-quality-512-c1-int4-comparison-release9-attempt1.json) |
| release9 | GPT-OSS / 1 | K8/V4, direct | 8/8 | 8/8 | [K8/V4 comparison](../../reports/kv-quantization-2026-09-07/model-runs/gptoss-quality-512-c1-k8v4-comparison-release9-attempt1.json) |
| release9 | GPT-OSS / 1 | INT8, direct | 8/8 | 8/8 | [INT8 comparison](../../reports/kv-quantization-2026-09-07/model-runs/gptoss-quality-512-c1-int8-comparison-release9-attempt1.json) |
| release10 | Qwen3.6 / 4 | INT4, opportunistic | 6/8 | 6/8 | [Optional Qwen comparison](../../reports/kv-quantization-2026-09-07/model-runs/qwen36-quality-c4-int4-opportunistic-comparison-release10-attempt1.json) |
| release10 | GPT-OSS / 1 | K8/V4, opportunistic | 8/8 | 8/8 | [Optional GPT comparison](../../reports/kv-quantization-2026-09-07/model-runs/gptoss-quality-512-c1-k8v4-opportunistic-comparison-release10-attempt1.json) |

Qwen and Gemma miss the inventory-arithmetic and set-state expectations in both
native and INT4 runs. GPT INT4 introduces misses on inventory arithmetic and
code tracing relative to its matched native run. K8/V4 and INT8 avoid those two
misses in this sample; that makes K8/V4 a candidate for further GPT qualification,
not an accepted default. Optional release10 pairs retain all runtime/terminal
controls; raw text matches in 8/9 Qwen cases and 2/9 GPT cases, with reasoning
differences retained rather than normalized away.

**Eight authored graded cases cannot establish a one-percentage-point
non-inferiority margin.** Equal scores do not establish broad quality, and
6/8 is not a correctness pass for the underlying tasks. These runs do not
qualify other artifacts, a held-out corpus, long reasoning, vision, tools or MTP.

Earlier teacher-forced copy diagnostics score 124 continuation tokens after
actual prompt lengths of 545 and 4,206 tokens. Top-1 agreement is 100%; mean
INT4-minus-native forced-token NLL is approximately `-3.32e-6` and `+2.15e-7`,
respectively. The file labels 512 and 4096 describe nominal input targets.
Their near-one continuation perplexities describe those easy copy tasks only:
[545-token prompt diagnostic](../../reports/kv-quantization-2026-09-07/model-runs/qwen36-copy512-int4-comparison-attempt1.json),
[4,206-token prompt diagnostic](../../reports/kv-quantization-2026-09-07/model-runs/qwen36-copy4096-int4-comparison-attempt1.json).
They are not a general language-model PPL benchmark.

## Matched Qwen scheduler-prefill observations

The release10 batch uses the same executable, metallib and model aggregate for
native, direct INT4 and opportunistic INT4. Each prompt length has two sequential
measured iterations, ordinary scheduler execution and a 2,048-token solo stripe.
The table shows arithmetic mean TTFT and the observed minimum–maximum in seconds;
with two samples the median equals the mean. No significance claim follows.

| Prompt tokens | Native | INT4 direct | INT4 opportunistic |
|---|---|---|---|
| 512 | 0.313 (0.313–0.314) | 0.390 (0.388–0.392) | 0.340 (0.337–0.343) |
| 4,096 | 2.293 (2.264–2.322) | 4.415 (4.408–4.423) | 2.954 (2.950–2.959) |
| 16,384 | 11.952 (11.515–12.389) | 36.505 (36.476–36.535) | 18.727 (18.605–18.849) |

Sources: [native](../../reports/kv-quantization-2026-09-07/model-runs/qwen36-prefill-native-release10-attempt1.json),
[direct INT4](../../reports/kv-quantization-2026-09-07/model-runs/qwen36-prefill-int4-release10-attempt1.json),
[opportunistic INT4](../../reports/kv-quantization-2026-09-07/model-runs/qwen36-prefill-int4-opportunistic-release10-attempt1.json).
At 16K, optional prefill reduces the observed direct-INT4 mean by about 49%,
but remains about 57% slower than native. It does not establish a native-speed
prefill path. The earlier matched release9 means were 10.296 seconds native
and 36.520 seconds direct INT4; they remain separate artifacts, not pooled samples.

At 16K, both optional samples record 80 fused layer/row graph decisions, zero
budget or eligibility fallbacks, successful terminal controls and zero additional
workspace bytes after shutdown. Peak accepted extra reservation is 588,980,701
bytes. This is reservation telemetry, not a measured heap delta. Maximum recorded
process peak bytes are 24,583,693,997 native, 24,191,405,959 direct INT4 and
24,556,085,123 optional INT4; weights and activations dominate these observations.

Strict real-model arrival qualification is inconclusive. The scheduler prefill
timings above do not substitute for that gate or for deadline-serving validation.

## Exploratory Qwen 4K decode sweep

The release10 native/direct-INT4 sweep measures B1/B2/B4/B8 with 4,096 prompt
tokens per row and 128 output tokens per row, two measured repeats per cell,
and separate full-shape warmups. All requested cells and common-overlap support
checks complete, and the runtime-file brackets remain unchanged. **This sweep
is exploratory:** a concurrent Go build/test invocation overlapped part of the
window and may have introduced host CPU contention. The completed quiet B1/B4
repeat is reported separately below; the raw exploratory results are retained.

| Batch | Native common-overlap aggregate tok/s | INT4 common-overlap aggregate tok/s | Native end-to-end aggregate tok/s | INT4 end-to-end aggregate tok/s |
|---|---|---|---|---|
| 1 | 94.57 | 74.73 | 33.23 | 20.35 |
| 2 | 147.24 | 118.77 | 35.54 | 22.04 |
| 4 | 207.56 | 169.73 | 35.74 | 22.98 |
| 8 | 235.09 | 212.65 | 34.49 | 23.82 |

Values are means of the two samples. `decodeTiming.overlapAggregateTokensPerSecond`
uses the common interval in which every row is decoding; it is distinct from
`decodeTiming.endToEndTokensPerSecond`, which includes prompt processing and
completion. The legacy `aggregateTokensPerSecond` can include other rows'
prefill and batch drain and is not used as the steady-decode headline here.
Sources: [native sweep](../../reports/kv-quantization-2026-09-07/model-runs/qwen36-sweep-4k-native-release10-attempt1.json),
[direct INT4 sweep](../../reports/kv-quantization-2026-09-07/model-runs/qwen36-sweep-4k-int4-release10-attempt1.json),
`provider-swift/Sources/ProviderBenchmark/ThroughputSweepDecodeTiming.swift`
(`DecodeTiming`) and `ThroughputSweepReport.swift` (`DecodeSample`).

Cell peak memory is about 22.368 GiB native and 22.451–22.452 GiB INT4. Peak
accounting resets per cell; fixed segment backing and workspace dominate this
short-context comparison. These observations show neither a 4K speed win nor
a process peak-memory saving. They do not justify increasing compute
concurrency or claim larger-context capacity saturation.

## Quiet Qwen 4K repeat

The release11 repeat measures B1 and B4 with the same 4,096-token prompt and
128-token output lengths, separate full-shape warmups and two samples per cell.
INT4 runs before native, reversing the earlier order. No agent builds or tests
overlap this window. All common-overlap support checks pass, and executable,
metallib, runtime-resource and configuration hashes remain unchanged across
their recorded brackets.

| Batch | Native common-overlap aggregate tok/s | INT4 common-overlap aggregate tok/s | Native end-to-end aggregate tok/s | INT4 end-to-end aggregate tok/s |
|---|---|---|---|---|
| 1 | 95.67 (95.38–95.96) | 76.04 (75.85–76.23) | 37.00 (36.91–37.09) | 20.68 (20.56–20.81) |
| 4 | 224.14 (223.78–224.49) | 168.01 (167.73–168.29) | 43.59 (43.35–43.83) | 24.19 (23.86–24.53) |

Values are arithmetic means with observed minimum–maximum ranges. The
[paired comparison](../../reports/kv-quantization-2026-09-07/model-runs/qwen36-sweep-4k-quiet-comparison-release11-attempt1.json)
is generated by `scripts/kv_quantization/compare_sweeps.py` from the
[native](../../reports/kv-quantization-2026-09-07/model-runs/qwen36-sweep-4k-native-quiet-release11-attempt1.json)
and [INT4](../../reports/kv-quantization-2026-09-07/model-runs/qwen36-sweep-4k-int4-quiet-release11-attempt1.json)
receipts. Mean peak MLX bytes are approximately 24.018 billion native and
24.107 billion INT4 at both batch sizes.

The unfavorable speed and peak-memory result persists in this quiet repeat.
It supports keeping the compute-concurrency ceiling unchanged. Two local
samples per cell do not establish statistical significance, a deadline-serving
SLA, a larger-context capacity limit or general model quality.

## Strict mixed-arrival qualification

The release11 follow-ups request prompt lengths `[4096, 128, 512, 128]` with
64 output tokens across burst, stagger-25ms, stagger-100ms and rolling-250ms
arrivals, at an unchanged 5ms delivery tolerance. Each invocation warms all
four patterns and completes one measured burst. It then refuses to qualify
stagger-25ms iteration one after three out-of-tolerance attempts.

| Invocation | Arrival errors across the three stagger attempts | Outcome |
|---|---|---|
| [Native attempt 1](../../reports/kv-quantization-2026-09-07/model-runs/qwen36-arrival-mixed-native-quiet-release11-attempt1.stderr) | 9.87 / 8.54 / 8.93ms | Strict host-delivery control fails |
| [Native attempt 2](../../reports/kv-quantization-2026-09-07/model-runs/qwen36-arrival-mixed-native-quiet-release11-attempt2.stderr) | 9.47 / 8.80 / 9.34ms | Strict host-delivery control fails |
| [INT4 attempt 1](../../reports/kv-quantization-2026-09-07/model-runs/qwen36-arrival-mixed-int4-quiet-release11-attempt1.stderr) | 8.68 / 7.44 / 8.56ms | Strict host-delivery control fails |

The command and runtime receipts are retained beside these logs, with the
[follow-up exit outcomes](../../reports/kv-quantization-2026-09-07/model-runs/release11-arrival-followup-outcomes.json).
None supplies a complete invariance JSON report. The tolerance was not relaxed,
and there was no overlapping agent build or test work. The strict topology
qualification is inconclusive for both native and INT4; these refusals are
neither a quantized-kernel parity result nor a quantized-kernel failure. The
completed C4 generation, controlled decode and targeted deadline-ownership
tests remain separate evidence.

## Capacity arithmetic is a separate result

The [scoped workspace decomposition](../../reports/kv-quantization-2026-09-07/admission-validation/workspace-step-arena-components.json)
and its native diagnostic log retain allocator-aware upper bounds. For a
four-request engine cap, the following are one request's packed full-KV payload
plus guaranteed direct workspace, in GiB. Optional SDPA memory is additional
and must obtain its own permit.

| Artifact geometry | INT4 payload + direct workspace, 32K / 128K | Native full-KV payload, 32K / 128K |
|---|---|---|
| Qwen3.6 | 0.569 / 1.305 | 0.625 / 2.5 |
| GPT-OSS | 0.678 / 1.544 | 1.5 / 6 |
| Gemma4 | 0.586 / 1.388 | 0.625 / 2.5 |

This is admission arithmetic, not measured concurrency or throughput. It excludes
weights, native windows, recurrent state, page tails, detached owners and other
model slots, which remain separately charged. A smaller full-KV payload alone
does not establish an end-to-end memory or latency improvement.

## Preserved failures and corrections

| Retained evidence | Interpretation and disposition |
|---|---|
| [Original physical-admission combined invocation](../../reports/kv-quantization-2026-09-07/admission-validation/kv-quant-admission-integrated-attempt1.log) | A process-global memory expectation failed while other suites allocated concurrently; the unchanged physical suite passes in its required isolated process. |
| [First quality-harness crash stack](../../reports/kv-quantization-2026-09-07/validation/kv-quality-native-attempt1-crash-stack.json) | Optimized `Task.sleep(for:)` failed before usable model-quality evidence. The bounded nanoseconds-based deadline replacement and its controls are retained under validation. |
| [GPT runtime-resource refusal](../../reports/kv-quantization-2026-09-07/model-runs/gptoss-quality-c1-int4-attempt1.stderr) | Different development SwiftPM resource copies were found. This is an artifact-consistency refusal, not a quantized-kernel result; later fixed-runtime runs supply the paired evidence. |
| [Initial forced D256 failure](../../reports/kv-quantization-2026-09-07/validation/kv-force-fused-swift-attempt2.log) | The original FP32 tile requests 53,760 bytes of threadgroup memory on a 32,768-byte device limit. The smaller D256 tile uses 28,928 bytes and passes the subsequent forced-attention controls. No silent BF16 narrowing is used. |
| [Release11 mixed-arrival follow-ups](../../reports/kv-quantization-2026-09-07/model-runs/release11-arrival-followup-outcomes.json) | Both native invocations and the INT4 invocation fail the unchanged 5ms delivery control. Their logs and incomplete outputs remain retained; strict topology qualification is inconclusive for both formats. |
| Earlier build/probe logs and short-budget GPT observations | Retained under [validation](../../reports/kv-quantization-2026-09-07/validation/) and [model runs](../../reports/kv-quantization-2026-09-07/model-runs/). Failed or incomplete files are not counted as successful measurements; the GPT summary uses the matched 512-token controls. |

## Remaining gates and draft dependencies

The optional-memory deadline-arrival helper is implemented and passes its
targeted tests; strict real-model mixed arrivals remain inconclusive. Execution-identity
partition is also implemented and validated: declaration and actual-slot wire
fields, provider TTFT/fallback history, fleet TPS/solo/calibration history, and
prediction/request-start identity capture use the same finite format scope.
Loaded native omission overrides a declared quantized policy; malformed
nonempty identities are quarantined rather than becoming native.

Uncalibrated quantized execution begins at concurrency one until the existing
same-model, same-execution, same-chip-class threshold is met, defaulting to five
heartbeat observations. Its missing TTFT is unknown rather than zero latency;
independent cold-load lower bounds and actual memory/deadline gates still apply.
No native static or registration-rate seed fills that gap. The native bandwidth
anomaly detector excludes quantized execution pending a suitable expectation;
format-unlabeled historical exports are not live bootstrap sources. Scalar
heartbeat shape dependence and sample correlation remain limitations.

Coordinator-first rollout is required: older coordinators ignore the optional
identity and can mix histories; this patch adds no compatibility negotiation.
The quiet matching-runtime B1/B4 decode repeat is complete, with no observed
speed or peak-memory win. Remaining qualification is concrete:

- A held-out, cache-consuming quality corpus with a defined non-inferiority
  margin and adequate sample size; the authored GPT INT4 misses remain unresolved.
- A strict mixed-arrival run that satisfies its delivery controls, followed by
  actual deadline-serving validation across the intended workload.
- Measured larger-context memory saturation and full-service latency before
  claiming a capacity benefit or changing any compute-concurrency ceiling.
- Hardware qualification beyond this M4 Max, including M5; model/artifact,
  vision, tool and MTP coverage are not established by these text-only runs.
- Review and CI for the final dependency and parent heads, followed by a separate
  coordinator-first rollout decision if an operator wants to enable the feature.

Native storage and direct prefill remain defaults. No production configuration
or traffic change is made by these observations.

CI at the interim published parent head `cbd206b24` is separate from the
published feature branch:

| Check at the recorded head | Observed state |
|---|---|
| [Parent provider/coordinator and related CI](https://github.com/Layr-Labs/d-inference/actions/runs/34126435626), [E2E integration](https://github.com/Layr-Labs/d-inference/actions/runs/34126435937) | Passed at the interim parent head; this does not cover the later execution-identity changes. |
| [E2E Benchmarks](https://github.com/Layr-Labs/d-inference/actions/runs/34126435612) | Waiting for the existing manual cost approval. `.github/workflows/benchmarks.yml` documents the separate 45-minute macOS benchmark gate; no approval or settings bypass was performed. |
| [Threat Model Review](https://github.com/Layr-Labs/d-inference/actions/runs/34126435949) | Failed before analysis because its configured review credential was rejected. This is not a completed threat-model review; no secret change was performed. |
| [LM CodeQL at `da524e5`](https://github.com/Layr-Labs/mlx-swift-lm/actions/runs/34137582458) | All CodeQL checks passed. Model acceptance remains separate. |
| [Published feature branch checks](https://github.com/Layr-Labs/d-inference/pull/860/checks) | Code and evidence are pushed. Local pre-push Go formatting/tests, console lint and Next.js build passed; new-head CI was still running at finalization. |

| Draft PR | Scope |
|---|---|
| [d-inference #860](https://github.com/Layr-Labs/d-inference/pull/860) | Provider selection, capacity, benchmark integration and evidence |
| [mlx-swift-lm #142](https://github.com/Layr-Labs/mlx-swift-lm/pull/142) | Packed storage, attention, ownership, admission and persistence |
| [mlx #17](https://github.com/Layr-Labs/mlx/pull/17) | FP32 wide-head Metal tile sizing |
| [mlx-c #9](https://github.com/Layr-Labs/mlx-c/pull/9) | Explicit forced-fused C API |
| [mlx-swift #22](https://github.com/Layr-Labs/mlx-swift/pull/22) | Swift forced-fused binding and dependency pins |

The final runtime/control-plane code is `47da6bf264c22f594e753263fc58bffcc46b1b98`.
The [committed-source check](../../reports/kv-quantization-2026-09-07/validation/release11-final-code-source-check.json)
verifies that its 52 modified build-source files retain the hashes recorded
around the release11 build, with matching dependency heads. The
[pre-push log](../../reports/kv-quantization-2026-09-07/validation/final-code-pre-push.log)
retains the final local Go and console checks. Later documentation/evidence
commits do not change the measured runtime.

All five are draft review surfaces at this snapshot. An updated PR head does
not retroactively change which source or runtime produced an earlier result.
