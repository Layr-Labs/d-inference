# Paged KV quantization

> Last updated: 2026-09-07 · commit `47da6bf26`

Reference for the optional packed full-attention KV formats in the Swift provider.
Native storage remains the default for every model; model weight precision does
not select a KV format. The [design record](../design/paged-kv-quantization-strategy.md)
contains the research rationale.
The [implementation report](../reports/2026-09-07-paged-kv-quantization-implementation.md)
records measured results and the remaining qualification work.

## Provider selection

| Setting | Default | Contract and source |
|---|---|---|
| `[backend] engine_v2_kv_quantization` | `"native"` | `native`, `int4`, `k8v4`, or `int8`; decoded in `provider-swift/Sources/ProviderCore/Config/ProviderConfig.swift`, `BackendSettings` |
| `[backend] engine_v2_kv_quantization_by_model` | Empty table | Exact model ID overrides the global choice; parsing uses `EngineV2KVQuantizationPolicy.parseSelection` in `provider-swift/Sources/ProviderCore/Inference/EngineV2KVQuantizationPolicy.swift` |
| Paged requirement | Required for every packed format | Refuses construction if the resolved backend is not paged, or no supported owning full-attention layer exists; `EngineV2KVQuantizationPolicy.requireResolvedBackend`, `EngineV2Factory+SegmentedBackend.swift` |
| Model geometry | Checked at construction | Supported head dimensions are 64, 128, 256 and 512; group and rotation divisibility are checked by `PagedKVQuantizationConfig.validate` in `libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/Paged/PagedKVQuantization.swift` |
| Retired `[backend] kv_quant` | No effect | Still emits the existing retired-setting warning; it does not enable the new storage format (`ProviderConfig.swift`, `RetiredCodingKeys`) |

## Physical format

The public choices use group size 64 and FP32 affine scale and offset metadata
for every token-local K or V group. The ratios below compare only full-attention
K/V payload with BF16 payload; page tails, temporary workspaces, native windows,
recurrent state, weights and allocator overhead are additional costs.

| Choice | K/V code bits | Effective bits per value including metadata | BF16 payload reduction | Source |
|---|---|---|---|---|
| `native` | Native dtype | Native dtype | 1× for BF16; dtype-dependent otherwise | `PagedKVGroupKey.bytesPerToken` |
| `int4` | 4 / 4 | 5 | 3.2× | `EngineV2KVQuantizationSelection.configuration`, `PagedKVQuantizedRowLayout` |
| `k8v4` | 8 / 4 | 7 averaged across K/V | 16/7× | Same |
| `int8` | 8 / 8 | 9 | 16/9× | Same |

| Component | Representation and contract | Source |
|---|---|---|
| Packed row | Codes, FP32 scales, then FP32 offsets; byte offsets and byte strides | `PagedKVQuantizedRowLayout` |
| Segment | All K rows followed by all V rows; each region orders `[page, KV head, token]` | `PagedKVSegments.swift`, `PagedKVStorageLayout.swift` |
| K/Q transform | Fixed signed normalized Walsh-Hadamard after model RoPE; block size is `min(128, headDim)` for public choices | `PagedKVQuantizationConfig.resolvedRotationBlockSize`, `PagedQuantizedMetal.swift` |
| V transform | No rotation | `PagedQuantizedTransfers.swift` |
| Direct attention compute | Packed values unpack inside attention; native input/output dtype with FP32 accumulation | `PagedQuantizedMetal.swift`, `PagedQuantizedPrefill.swift` |
| Sliding windows and recurrent state | Existing native storage | `PagedKVGroupKey` in `PagedKVStorageLayout.swift`, `KVAdmissionStorageLayout.swift` |
| Versioned identity | Example `affine-v1-k4v4-g64-f32-h128-s1` binds bit widths, grouping, metadata and transform | `PagedKVQuantizationConfig.identity` |

## Prefill execution

The production default is direct packed attention. The alternative is selected
only through the benchmark option below; it does not change the stored format.

| Route | Contract | Source |
|---|---|---|
| `direct` | Default `PagedKVPoolConfig.quantizedPrefillMode`; packed pages feed attention directly, with one shared FP32 partial/meta arena per compatible step geometry | `libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/Paged/PagedKVPool.swift` (`PagedKVPoolConfig`), `PagedQuantizedStepScratch.swift` |
| `opportunisticSDPA` | Native API name for CLI `opportunistic`; full attention with head dimension 64 or 256, at least nine queries, no attention softcap, no bidirectional/span mask, and an active admitted step scope | `libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/Paged/PagedQuantizedFusedPrefill.swift` (`opportunisticQuantizedPrefill`) |
| Fast working buffers | Direct dequantization into fixed FP32 K/V arenas; K stays in the stored rotated basis, Q is rotated into FP32, and V stays in its native basis. A shared BOOL mask and balanced 9–128-query blocks feed explicitly forced fused SDPA | `PagedQuantizedFusedPrefillPlan.swift`, `PagedQuantizedFusedPrefillKernels.swift`, `PagedQuantizedFusedPrefill.swift` |
| Extra reservation | One additive permit covers new arenas, all FP32 block outputs, final native output, metadata and fences before array construction or any KV write. Allocations must also fit the configured single-buffer limit | `PagedQuantizedFusedPrefillPlan`, `AdmissionV2.reserveOpportunisticWorkspace` in `libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/AdmissionOpportunisticWorkspace.swift` |
| Refusal | Ineligible shape or unavailable extra budget selects the whole call's direct path; accepted optional memory does not consume prepaid direct-attention credit | `opportunisticQuantizedPrefill`, `AdmissionV2.reserveOpportunisticWorkspace` |
| Retirement | A real attention-output dependency protects arena reuse. The extra permit remains owned until its submitted step completes and retires; request cancellation alone does not refund it | `PagedQuantizedFusedPrefillArena.recordCompletion`, `PagedQuantizedScratchLease.finishAfterSynchronization` |
| Wide FP32 tile | D256 uses `bq=16`, `bk=8`, `wm=2`; D192 uses `bq=16`, `bk=16`, `wm=2`. The existing default SDPA routing remains unchanged | `libs/mlx-swift/Source/Cmlx/mlx/mlx/backend/metal/scaled_dot_product_attention.cpp` (`sdpa_full_self_attention_metal`) |

This fast route uses additional live memory and is not a promise that every
eligible call will use SDPA. Its measured route and cleanup are reported separately.

## Capacity and concurrency

| Quantity | Contract | Source |
|---|---|---|
| `kv_bytes_per_token` | Literal physical growing KV rate, including packed metadata; native compute dtype is separate | `EngineV2KVSizing.swift`, `KVAdmissionStorageLayout.swift` |
| Request charge | Growing storage plus page/window/fixed overhead and a checked temporary-workspace bound | `AdmissionV2.swift`, `QuantizedWorkspaceProjection.swift` |
| Workspace retirement | Request credit cannot be reused while submitted GPU work still owns its workspace; retirement follows real stream completion | `AdmissionWorkspaceFloor.swift`, `EngineLoopV2+QuantizedScratch.swift`, `EngineLoopV2.finalize` |
| Deadline arrivals during optional prefill | Retires the actual in-flight optional step before the new forecast; drain time consumes the incoming request's original absolute deadline. Direct mode does not force this extra boundary | `libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/EngineLoopV2.swift` (`retireOptionalPrefillBeforeDeadlineAdmission`, `enqueueForFirstTokenDeadline`) |
| Overlap bound | Engine prefill may overlap a pure decode successor; MTP verification calls are priced together and do not chain another step | `WorkspaceOverlapPolicy.swift`, `EngineLoopV2.swift` |
| Wire token budgets | Remain raw prompt-plus-generation tokens; physical overhead reduces the maximum rather than inflating used tokens into byte-equivalent units | `EngineV2Bridge+Capacity.swift`, `EngineV2RoutingCapacity.swift`, `coordinator/protocol/messages.go` |
| In-flight coordinator requests | Reservations not yet present in a heartbeat debit both routing admission and public slot capacity | `coordinator/registry/slot_token_budget.go`, `freeMemoryAdmits`, `ModelCapacitySnapshot` |
| Concurrent request limit | Configured compute limit remains a ceiling; physical admission may advertise fewer serviceable requests | `EngineV2RoutingCapacity.project`, `EngineV2Bridge+Capacity.swift` |
| Cold model admission | Existing padded weight estimates and activation floors remain authoritative; packed warm-cache gains are not guessed for unloaded models | `EngineV2Factory+Production.swift`, `coordinator/registry/servability.go` |

## Prefix and checkpoint compatibility

| Surface | Contract | Source |
|---|---|---|
| Resident paged prefix | Reuses the exact packed pages under the original storage charge | `Paged/PrefixBlocks/EngineLoopV2+PagedPrefix.swift` |
| Complete checkpoint K/V | UInt8 tensors retain packed codes and FP32 metadata exactly, without dequantization or requantization | `Prefix/CheckpointStorageTensorLayout.swift`, `PagedCheckpointTensorSource.swift`, `PagedCheckpointStorage.swift` |
| Manifest | Quantized layouts and `kvQuantization` must match before allocation; native manifests omit the optional field and retain their existing layout | `CompleteCheckpointContract.swift`, `CompleteCheckpointManifestCoding.swift`, `CompleteCheckpointCodec.swift` |
| Persistent identity | Storage format is included in the provider checkpoint identity; incompatible native/packed checkpoints cannot alias | `provider-swift/Sources/ProviderCore/Inference/CompleteCheckpointStorageIdentity.swift` |
| Legacy native snapshot | Disabled for packed storage; complete packed checkpoints and resident page reuse retain their own paths | `EngineV2.swift`, `PagedKVBackend.makeSequenceState` |

## Execution identity and performance history

The optional wire identity separates performance observations for different KV
formats and prefill policies; it is independent of the weight-format label and
the checkpoint-storage identity.

| Contract | Behavior | Source |
|---|---|---|
| Wire fields | `models[].execution_identity` declares future-load policy; `backend_capacity.slots[].execution_identity` reports actual loaded execution. Native execution omits the field; absent/empty values retain legacy history keys | `coordinator/protocol/messages.go` (`ModelInfo`, `BackendSlotCapacity`), `provider-swift/Sources/ProviderCore/Protocol/Types.swift`; [wire reference](protocol-messages.md#models) |
| Precedence | A `running` or `idle` slot is authoritative, including its native omission. A missing or nonresident slot uses the model declaration | `provider-swift/Sources/ProviderCore/Inference/KVPerformanceIdentity.swift` (`resolved`), `coordinator/registry/performance_execution.go` (`providerExecutionIdentityLocked`) |
| Packed spelling | Example `kvq-v1:affine-v1-k4v4-g64-f32-h128-s1:prefill=direct`; a different KV format or prefill mode has a different history key | `KVPerformanceIdentity.actual`, `normalizeExecutionIdentity` |
| Finite grammar | At most 160 bytes; version/seed 1, K/V bits 4 or 8, group 32/64/128, FP32 metadata, rotation 0/32/64/128/256/512, and prefill `direct` or `opportunisticSDPA` | `KVPerformanceIdentity.normalized`, `coordinator/registry/performance_execution.go` (`executionIdentityPattern`) |
| Invalid nonempty value | Normalizes to `kvq-v1:invalid`; it is quarantined and contributes no observed rates, rather than becoming native or an unbounded new history key | `normalizeExecutionIdentity`, `executionSlotRatesCompatible`, `coordinator/registry/heartbeat.go` (`Heartbeat`) |
| Histories | Provider TTFT buckets and their fallbacks, fleet TPS/solo observations and TTFT calibration use the exact execution identity. Prediction/request-start capture prevents a later policy transition from relabeling an observation | `provider-swift/Sources/ProviderCore/Inference/TTFTQuantileTracker.swift` (`TTFTQuantileTracker`), `coordinator/registry/tps_registry.go`, `solo_tps.go`, `ttft_calibration.go` |
| Uncalibrated execution | Native static, environment, model and registration-rate seeds do not bootstrap packed execution. Compute capacity starts at one until the same-model, same-chip-class, same-identity solo threshold is met: `EIGENINFERENCE_QUALITY_CAP_SOLO_MIN_SAMPLES`, default `5` heartbeat observations. The configured ceiling remains unchanged | `coordinator/registry/concurrency_cap.go` (`resolvedSoloModelTPSLocked`, `qualityCapSoloMinSamples`), `performance_execution.go` (`modelBootstrapTPSLocked`) |
| Unknown TTFT | Missing packed-prefill measurements remain unknown, not known-zero latency. First measurement still passes actual memory/deadline gates and any known cold-load lower bound; the zero uncalibrated raw forecast does not train calibration. Actual slot prefill observations restore normal forecasting | `coordinator/registry/scheduler.go` (`ttftMsFromSnapshot`, `buildCandidateWithReason`), `ttft_calibration.go`, `provider-swift/Sources/ProviderCore/Coordinator/CapacityQuoteEngine.swift` |
| Native bandwidth anomaly detector | Excludes resolved nonnative execution, including declared-quantized nonresident placeholders, until an execution-specific expectation exists. Actual loaded native execution retains its existing detector | `coordinator/api/throughput_anomaly.go`, `coordinator/registry/performance_execution.go` (`Provider.ExecutionIdentityForModelLocked`) |

Deploy the coordinator support before enabling quantized providers: older
coordinators ignore this field and can mix performance histories. This change
adds no version-floor or capability negotiation. Scalar heartbeat EWMAs retain
their existing shape dependence; repeated heartbeat samples are not independent
request experiments. Historical offline fleet exports without an execution
column are not used as live bootstrap evidence.

## Benchmark surfaces

| Surface | Contract | Source |
|---|---|---|
| `--kv-quantization` | `native`, `int4`, `k8v4`, or `int8`; reports the actual resolved identity | `BenchmarkCommand+KVQuantization.swift`, `BenchmarkKVBackend.swift` |
| `--quantized-prefill` | `direct` or `opportunistic`; unset resolves to `direct`. Requires explicit paged execution and a packed format, and is accepted only with sweep, scheduler-prefill or KV-quality mode | `provider-swift/Sources/darkbloom/BenchmarkCommand+QuantizedPrefill.swift` (`quantizedPrefillOptionError`, `resolvedQuantizedPrefillMode`) |
| `--model-directory` | Exact local artifact override for teacher-forced, quality, sweep, scheduler-prefill and arrival-invariance modes; model hashes bracket measurement | `BenchmarkCommand+ModelDirectory.swift`, `BenchmarkArtifactIdentity.swift` |
| `--teacher-forced-input` | Fixed token context/continuation, repeated ordinary-forward controls, MTP and prefix cache off | `TeacherForcedBenchmark.swift`; [input reference](../provider/cli-reference.md#teacher-forced-scores) |
| `--kv-quality-input` | Bounded natural greedy generation, explicit token prompts, actual EOS IDs, raw tokens/text and supplemental production-parser serving content; absent expected text remains ungraded | `KVQualityInput.swift`, `KVQualityBenchmark.swift`, `KVQualityCollection.swift`, `BenchmarkServingContent.swift` |
| `--scheduler-prefill` | Actual production scheduler/backend prefill measurement | `SchedulerPrefillBenchmark.swift` |
| `--sweep` | Decode uses the selected production format; native-model prefill microbenchmarks are explicitly omitted for packed selections | `ThroughputSweep+PrefillExecution.swift` |

## Prefill receipts

Packed scheduler-prefill samples, sweep decode trials and KV-quality reports
capture the measured engine's statistics after shutdown.

| Receipt field | Meaning | Source |
|---|---|---|
| `counterScope` | `"graph_built_layer_rows"`; route decisions are not finalized GPU kernel counts | `provider-swift/Sources/ProviderBenchmark/BenchmarkQuantizedPrefillReceipt.swift` (`BenchmarkQuantizedPrefillReceipt.make`) |
| `observationScope` | `"measured_engine_after_shutdown"` | `BenchmarkQuantizedPrefillReceipt.make` |
| `successfulTerminalControls` | Separate terminal/control outcome; success also requires zero current additional workspace bytes and the expected mode | `BenchmarkQuantizedPrefillReceipt.make` |
| `statistics.mode` | Actual native policy: `direct` or `opportunisticSDPA` | `libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/Paged/PagedQuantizedPrefillStatistics.swift` (`PagedQuantizedPrefillStatistics`) |
| `directCallCount`, `fusedCallCount` | Cumulative per-layer, per-row prefill graph decisions | `PagedQuantizedPrefillCounters` |
| `directQueryTokenCount`, `fusedQueryTokenCount` | Query tokens summed across those layer/row decisions; not request-level token usage | `PagedQuantizedPrefillCounters` |
| `budgetFallbackCount`, `ineligibleFallbackCount` | Optional-path preflight refusals, separated by budget and eligibility | `opportunisticQuantizedPrefill`, `PagedQuantizedPrefillCounters` |
| `currentAdditionalWorkspaceBytes`, `peakAdditionalWorkspaceBytes` | Accepted additive reservation bytes still owned, and their lifetime maximum; not measured allocator heap usage | `PagedQuantizedPrefillCounters.reserved`, `PagedQuantizedPrefillCounters.retired` |

No benchmark status alone establishes broad model quality or a release decision.
Memory reduction, request capacity, prefill latency and decode throughput are
separate measurements.
