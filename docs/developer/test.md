# Test Provider And Native Contracts

> Last updated: 2026-10-23

Run isolated Swift, native-resource, public-fixture, retained-console and landing tests here.
Backend integration and cross-implementation qualification are platform-owned.
Never point tests at production or overwrite a running provider's state.

## Prerequisites

Use the [source-matched build](build.md), Apple Silicon and the documented Xcode
toolchain for MLX execution. GPU/native tests need exclusive device access and
their real resource bundles; ordinary Python checks do not prove GPU correctness.
Build the relevant test products and stage matching metallibs before any
`--skip-build` command below. Run provider commands from `provider-swift/` and
SDK commands from `libs/mlx-swift-lm/` unless a command specifies otherwise.

## Provider Terminal And Stop Signals

After rebuilding the provider test products, run the focused
`ModelPickerInputEndTests|ProviderSignalTests|ProviderStopSignalsTests` selector
through the isolated provider test runner. The suites cover closed input,
invalid descriptors, interrupted and temporarily unavailable reads, terminal
hangup, and real-process SIGTERM/SIGHUP. They preserve launchd and inherited
ignored-hangup behavior and exercise signal handling across process replacement.
No model weights or live provider state are needed.

## Provider And SDK

From the repository root, use the [MiMo regression fixture recipe](#mimo-regression-fixtures)
to prepare the inputs and run `make provider-test`.

The Make target builds test products, stages source-matched metallibs and uses
`scripts/run-provider-tests.sh`. The runner isolates daemon-state and loaded-model
snapshots. Preserve its watchdog, cleanup and state isolation when using a focused
selector. Use `scripts/run-nested-suite.sh` for documented nested Swift Testing
cases and `scripts/run-exclusive-native-gpu-test.sh` for exclusive native work.

The SDK has independent test products under `libs/mlx-swift-lm`. CI validates
native memory ownership, cancellation, media decoding, paged KV and resource
packaging there as well as provider behavior. Preserve all retained lane gates;
do not treat the repository split as permission to skip native regressions.

### Local Responses and reasoning regressions

After building the exact provider/SDK test products, run these focused suites
from `provider-swift/`. Keep the test state isolated as in
`scripts/run-provider-tests.sh`; the helper/router fixtures use synthetic
credentials and no live provider endpoint.

```bash
../scripts/run-nested-suite.sh 'LocalResponseConversationTests|ReasoningPromptProbeTests|LocalOpenAIObjectCompatibilityTests' --no-parallel
```

`LocalResponseConversationTests` executes the real helper and authenticated
Hummingbird `.router` responder. Its acquisition counter must remain zero for
non-null invalid ID types and unknown/empty strings, on both URL aliases and
both response modes. Null and omitted IDs must reach acquisition. Retain the
known-ID, tool-history, storage opt-out and bounded-LRU controls.
`ReasoningPromptProbeTests` composes the actual prompt probe, service and
continued history for a prompt-open length stop; it must retain reasoning and
leave answer text empty. These sources are in
`provider-swift/Tests/ProviderCoreTests/Server/LocalResponseConversationTests.swift`
and `provider-swift/Tests/ProviderCoreTests/Inference/Prompting/ReasoningPromptProbeTests.swift`.

Use an SDK revision whose `ReasoningParser.parseThinkTags` handles unclosed
blocks. Run `CollectedReasoningTests` through the same suite runner from
`libs/mlx-swift-lm/` after rebuilding its test product. Provider-only prompt
seeding cannot close this regression against the older parser.
`LocalOpenAIObjectCompatibilityTests` additionally requires stable fallback
model creation values in `MLXOpenAIService` and flat tool configuration in
`OpenAIResponsesProtocol` and `ResponsesStreamWriter`. A provider test host
does not provide those SDK changes; select the corresponding immutable SDK
revision before treating these assertions as a gate.

Record actual discovered/executed counts and failures separately. Syntax
parsing and extracted CPU probes do not execute the package router or scheduler.
Keep full HTTP create/retrieve/continue, disconnect, cross-request/model
isolation and retrieval-after-history-eviction checks in product qualification;
the history LRU and object store have
[different lifetimes](../provider/direct-mode.md#responses-continuation-and-retention).

### SSD test working volume

Fixtures that call `SSDTestDirectory.parent()` use Foundation's resolved temporary
directory unless `DARKBLOOM_SSD_TEST_TMPDIR` selects another test working volume.
The shared SSD-prefix fixtures and bridge fixtures that require successful
cache donations honor this selector. It does not configure the provider cache
or change the process-wide `TMPDIR`.

When the default volume lacks the free space required for real cache writes,
create a task-owned directory on a suitable volume and pass its canonical,
absolute path to the test runner. The parent directory must already exist and
be writable. Empty, relative, missing, file and symlink paths are rejected;
selection or directory-creation errors fail fixture setup instead of falling
back silently.

```bash
mkdir -p "/Volumes/Test Scratch/darkbloom-tests"
DARKBLOOM_SSD_TEST_TMPDIR="/Volumes/Test Scratch/darkbloom-tests" make provider-test
```

Leave the variable unset for the normal temporary directory. The production
free-space checks, write limits, assertions and cleanup still apply. Raw-codec
fixtures that do not call the selector keep their existing temporary paths.
Rebuild changed test products before using `--skip-build`; see the
[build guide](build.md#build).

### GLM5Next prerequisite tests

Provider ownership regressions are in `GLM5NextManagedKernelTests`. In a fresh,
isolated test process, set `DARKBLOOM_TEST_GLM5_MANAGED_SYNTHETIC=1` and select
that suite to exercise actual bridge MTP submission, checked partial-load
cleanup, expert-source retirement, and the resolved-tokenizer preallocation
probe. These use tiny local fixtures, not the full downloaded model. With the
same flag, `GLM5NextStandaloneLoadPolicyTests` checks that the standalone local
opt-in refuses target-only GLM before any load state exists, and
`GLM5NextLogprobsTests` submits logprobs to the protected native bridge built
from the same fixture: the relay channel must receive one entry per generated
token with the requested alternatives, the row must not draft, and a later
plain request must still speculate. In the SDK,
`GLM5NextMTPTests/protectedPagedEngineCapturesLogprobRowsOffSpeculation` and
`protectedPagedEngineServesALogprobRowBesideAPlainRow` compare the captured
values with the target's own log-softmax for serial and rectangular
verification. `NativeOutputControlRefusalTests` keeps the typed 400 for
native engines that do not capture logprobs (MiMo). The pure
`GLM5NextLocalQualificationTests` cover selection, retained-byte charges and
the KV rate derived from the pinned architecture evidence.

The retained-fault tests deliberately poison their process and must run **one
selector per fresh process**, never as flags on the full suite:

| Selector | Required flag | Evidence |
|---|---|---|
| `failedCleanupFenceRetainsPartialNativeRootsAndPermit` | `DARKBLOOM_TEST_GLM5_RETAINED_FAULT=1` | Partial tensor roots and the real pending permit survive failed cleanup |
| `glmNativeFenceFailureKeepsNewcomerAndShrunkSurvivor` | `DARKBLOOM_TEST_GLM5_RETAINED_RESLICE=1` | Inner load failure keeps the newcomer and charges it, so survivors cannot regrow into it |
| `unprovenPostBuildUnwindKeepsLeaseOwnershipAndCharge` | `DARKBLOOM_TEST_GLM5_RETAINED_FAULT=1` | A refused post-build unwind keeps the pending lease, loading marker, ownership and activity; fleet budgets exclude the charge; other families still build |
| `ordinaryFactoryRunsTextHTTPImageAndProtectedEmbeddedMTP` | `DARKBLOOM_TEST_GLM5_MANAGED_SYNTHETIC=1`, `DARKBLOOM_TEST_GLM5_RETAINED_SHUTDOWN=1` | A refused bridge retirement retains its actual native owner |

The last flag is omitted for the ordinary successful bridge/retirement test.
No test manufactures a positive native completion receipt. See
`provider-swift/Tests/ProviderCoreTests/Inference/Models/GLM5Next/GLM5NextManagedLoadTests.swift`,
`provider-swift/Tests/ProviderCoreTests/Inference/Models/GLM5Next/GLM5NextLocalLoadPolicyTests.swift`
and `provider-swift/Tests/ProviderCoreTests/Inference/Engine/EngineV2ProductionWiringTests.swift`.

`GLM5NextResidencyIntegrationTests` exercises the actual factory, bridge and
native owner with tiny model fixtures. Reserve the exclusive GPU lane, set
`DARKBLOOM_EXCLUSIVE_NATIVE_GPU_TEST=1`, and run its selector in a fresh process
for each `DARKBLOOM_TEST_GLM_RESIDENCY_INTEGRATION` value: `start-fault`,
`complete-success` and `end-fault`. The fault cases intentionally retain native
roots until exit. They verify that pending or failed residency settlement keeps
the bridge's KV claim and activity guards; successful concurrent completion
releases ownership once. Do not enable these flags on the full test suite.

After building the SDK test product and staging its source-matched Metal
library, run the initial configuration and mathematical-reference suites from
`libs/mlx-swift-lm/` under the exclusive native test lease:

```bash
MLX_ENABLE_TF32=0 ../../scripts/run-nested-suite.sh 'GLM5NextConfigurationTests|GLM5NextHyperConnectionTests|GLM5NextLinearAttentionTests|GLM5NextSparseAttentionTests|GLM5NextMoETests|GLM5NextGPUParityTests|GLM5ToolCallParserTests|GLM5ToolStreamingTests|GLM5ServerToolParserTests' --no-parallel
```

These suites exercise fixed synthetic tensors, configuration validation,
state continuation, tiny CPU/Metal comparisons and low-level tool parsing. They
do not load the real checkpoint or qualify a provider, MTP, sparse paging, prefix persistence,
multimodal behavior or throughput. Keep the
[GLM integration gates](../design/glm53-flash-native.md) incomplete until their
actual execution evidence exists.

The continuation suites (`GLM5NextTextModelTests`, `GLM5NextMTPTests`,
`GLM5NextArtifactLoaderTests`, `GLM5NextVisionTests`,
`GLM5NextMultimodalTests`, `GLM5NextSparseStateTests` and
`GLM5NextPagedSparseStateTests`) cover tiny assembled components and ownership.
They are not full-checkpoint or provider acceptance tests. Keep their receipts
separate from the earlier prerequisite suites; a previous passing binary does
not validate newly added source. The provider's `GLM5NextPromptPolicyTests`
renders the shipped `EigenLabs/GLM-5.3-Flash-MLX-NVFP4-mtp` template with the
unpatched pinned Swift-Jinja. It must match every official-template golden byte
for byte, including list-shaped tool results that reach each rewritten `[0]`
access. `onlyTheShippedArtifactTemplateIsRecognizedAndRenders` confirms that
only the shipped template is recognized and passes the load-time render check.
`returnedAssistantReasoningRendersLikeReasoningContent` and
`openRouterReasoningContentReturnRequestIsServed` push OpenRouter's
returned-reasoning tool turn through the coordinator and local HTTP paths to the
rendered prompt, with each of its reasoning spellings and controls.
`capturedOpenRouterToolRequestIsServed` and
`capturedOpenRouterToolServesAFiveStepConversation` replay OpenRouter's captured
`strict` weather-tool requests, held byte for byte and hash-checked, with tool
choice omitted, `auto` and `none`, and a five-step tool conversation built from
them.

`GLM5NextOpenRouterCapabilityTests` serves OpenRouter's capability request
shapes through `MultiModelBatchSchedulerEngine` and `MLXOpenAIService`, with
the shipped template rendered by Swift-Jinja, the serving
`GLM5NextThinkingTokenizer` and a scripted CBv2 engine standing in for the
model. JSON `response_format` requests must render the service instruction,
stream reasoning, expose one validated answer, and fail with a content-free 422
for prose, schema violations or truncation. OpenRouter's captured `strict`
weather tool with `tool_choice` `required` or named must render the forcing
instruction, expose exactly one validated call, and fail with a 422 and nothing
exposed for prose, a wrong function, a schema violation or a truncated frame;
the models update must list the GLM serving identity under tool-constraint
protocol v1. Each served JSON or forced submission must carry no token
constraint and no logprobs, so `EngineV2Bridge.nativeOutputControlRefusal`
evaluated as GLM's native-tracked engine admits it. In the control, GLM admits
a logprobs row that the same check refuses for a native engine without logprobs
capture. The scripted completions prove the
provider's withholding and validation, not the model's compliance; that needs
the real-model run in `GLM5NextRealArtifactQualificationTests`.

`GLM5NextRealLogprobsQualificationTests` qualifies logprobs on the real GLM
checkpoint through the production bundle and the `EngineV2Bridge` relay channel
(the standalone `--local` HTTP server never emits logprobs). It needs the
`GLM5NextRealModelHarness` variables (`DARKBLOOM_TEST_GLM5_REAL_MODEL_DIR`,
`DARKBLOOM_TEST_GLM5_REAL_RESULTS_DIR`, `DARKBLOOM_TEST_GLM5_REAL_SOURCE_REPO`,
`DARKBLOOM_TEST_GLM5_REAL_SOURCE_REVISION`,
`DARKBLOOM_TEST_GLM5_REAL_AGGREGATE_SHA256`, `DARKBLOOM_EXPERIMENTAL_GLM5_NEXT`,
`DARKBLOOM_CBV2_MTP=1`) plus `DARKBLOOM_TEST_GLM5_REAL_LOGPROBS=1`. A greedy
32-token `top_logprobs: 5` request must return one entry per token, never
draft, match the MTP greedy tokens of the same prompt without logprobs, and
match a teacher-forced dense-cache log-softmax within
`DARKBLOOM_TEST_GLM5_REAL_LOGPROBS_TOLERANCE` nats (default `5e-2`, above the
bf16 rounding floor of the different kernels). Batched with a plain row, both
rows keep their solo greedy output and the plain row drafts again after the
logprobs row finishes. The engine must end without a native fault or retained
load. Results go to `logprobs-qualification.json` in the results directory.

`fixtures/prompt-contract/glm53-flash/additional-goldens.json` adds the
`minimal`, `medium` and `xhigh` effort aliases and an image-marker render.
`GLM5NextPromptPolicyTests` checks those fixed bytes through the shipped
renderer. No image is fetched or processed, so these vectors do not qualify
native vision. The fixture metadata's `media: false` is an evidence limit, not
a runtime prohibition. `GLM5ToolFailureTests` separately exercises streaming
suffix rejection, including a valid call followed by malformed output, before
fallback text or partial calls can escape.

The provider test host also carries the SDK's `GLM5NextAlignedPayloadReaderTests`
(eight filesystem/resource tests), `GLM5NextArtifactCachePolicyTests` (three
filesystem policy/cleanup tests), their inventory fixture and suite namespaces,
and `GLM5NextArtifactLoaderTests` (eight native tiny-artifact tests). The first
two suites exercise real files without creating MLX arrays. The loader suite
creates arrays and belongs in an authorized native test window. Sources live in
`provider-swift/Tests/ProviderCoreTests/Inference/Models/GLM5Next/`.
Use an immutable SDK revision containing `GLM5NextAlignedPayloadReader`,
`verificationHostBytes`, `payloadReadScratchAllowanceBytes` and the internal
descriptor-policy test initializer. An older SDK pin cannot compile this host;
resolve the dependency in the SDK rather than weakening the tests or importing
cluster-stage APIs. These tests retain full-artifact verification, aligned
windows, mutation/truncation refusal, cancellation and resource charges.

The metadata-only `GLM5NextDiscoveryLoadFootprintTests`,
`GLM5NextDiscoveryTests` and `rawDiscoveryQuotationMatchesManagedTinyFixture`
compare the raw same-directory LOAD formula and wire values without evaluating
native arrays. Run them from `provider-swift/` only in an authorized build/test
window:

```bash
GLM53_RAW_HEADER_FIXTURE_DIR=/path/to/retained-raw-header-bundle \
  xcrun swift test --jobs 2 --force-resolved-versions --no-parallel \
  --filter 'GLM5NextDiscoveryLoadFootprintTests|GLM5NextDiscoveryTests|rawDiscoveryQuotationMatchesManagedTinyFixture'
```

The optional bundle contains `config.json`, `model.safetensors.index.json`,
`metadata.json`, `header-audit.json` and `headers/*.safetensors.json` at the
recorded raw revision. Header hashes are checked; no tensor payload is read.
Without the variable, that full-header test is explicitly disabled; the compact
projection and tiny-fixture tests remain enabled. Neither proves managed
serving integration or a hardware tier. See the [raw quotation contract](../reference/model-registry-format.md#raw-glm-discovery-quotation).

`scripts/prepare-glm53-fixtures.py` prepares synthetic numerical oracles using
the pinned official Transformers CPU implementation, never real BF16 weights.
Its environment and generated manifest record source hashes, fixture transforms
and precision. `scripts/test-prepare-glm53-fixtures.py` checks fixture tooling;
passing it alone is not a native numerical comparison. MTP requires a separate
oracle because that Transformers revision has no trained NextN implementation.

For the official synthetic-oracle comparisons, supply the complete prepared
canonical bundle, including its original and mapped weights, expected tensors,
configuration and provenance receipts. After rebuilding the SDK test product:

```bash
GLM53_REFERENCE_FIXTURE_DIR=/path/to/canonical-oracle MLX_ENABLE_TF32=0 \
  ../../scripts/run-nested-suite.sh 'GLM5NextOfficial(Reference|VisionReference)Tests' --no-parallel
```

An absent bundle skips this optional lane; an explicitly supplied invalid bundle
fails. Keep image/video preprocessing, fixed-patch tower checks and root-model
outputs separate when diagnosing differences. The programmatic
`GLM5NextProcessorConfiguration.videoSamplingPolicy` defaults to `.official`;
use `.disabled` only when the reference supplies already-selected frames.
Both modes retain frame, token and byte limits. This is not a provider request
option or a serving-capability declaration
(`libs/mlx-swift-lm/Libraries/MLXVLM/Models/GLM5NextProcessor.swift`).

Real-checkpoint image correctness is a separate, explicit lane
(`libs/mlx-swift-lm/Tests/MLXLMTests/Kernel/LLM/GLM5NextRealVisionTests.swift`).
It generates shapes, counting, rendered-text, bar-chart, two-image and
8000-token images in process and checks the greedy answers through the direct
multimodal forward and the paged CBv2 engine with the `.serving` policy, next to
a concurrent text request:

```bash
GLM53_REAL_VISION=1 GLM53_REAL_MODEL_DIR=/path/to/artifact \
GLM53_REAL_PROFILE_DIR=/path/with/identity.json \
  ../../scripts/run-nested-suite.sh 'GLM5NextRealVisionTests' --no-parallel
```

`GLM53_VISION_REFERENCE_DIR` adds the official Transformers processor/tower
comparison for the same artifact's vision weights; `GLM53_REAL_STORAGE=q4`
selects the affine layout, `GLM53_REAL_VISION_TOKENS` the answer budget and
`GLM53_REAL_VISION_LARGE=0` skips the 8000-token image.

The SDK's reference-math policy disables TF32 on M5 for float32 comparisons
(`libs/mlx-swift-lm/CONTRIBUTING.md`). This test precision setting is not proof
of an ordinary serving default or of full-model performance.

### MiMo regression fixtures

Before the full provider test gate, provision its ordinary MiMo regression
inputs from the repository root in fresh directories:

- `scripts/prepare-mimo-provider-fixtures.py` creates bounded synthetic weights
  offline.
- `scripts/prepare-mimo-prompt-fixtures.py` downloads four hash-pinned public
  metadata files, not trained model weights or the genuine audio codec. These
  inputs require no private model or credentials.

```bash
FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/darkbloom-test-fixtures.XXXXXX")"
python3 -B scripts/prepare-mimo-provider-fixtures.py --output "$FIXTURE_ROOT/provider"
python3 -B scripts/prepare-mimo-prompt-fixtures.py --output "$FIXTURE_ROOT/prompt"
export MIMO_V26_SERIAL_LOAD_FIXTURES="$FIXTURE_ROOT/provider"
export MIMO_V26_WIRED_METADATA_FIXTURE="$FIXTURE_ROOT/provider/tiny-bf16"
export MIMO_PROMPT_ARTIFACT_DIRECTORY="$FIXTURE_ROOT/prompt"
export MIMO_PROMPT_REFERENCE_VECTORS="$PWD/fixtures/prompt-contract/mimo-v26-additional20.json"
HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 DARKBLOOM_NO_UPDATE_CHECK=1 MLX_ENABLE_TF32=0 make provider-test
```

These inputs do not enable the separately opted-in native/audio qualification
suites and do not establish full-model quality. An unset fixture path can fail
ordinary regression tests before model construction; do not turn those failures
into skips or substitute a live provider's cache.

The MiMo FP32 preflight-refusal fixtures convert both ordinary and router
weights, so they update `dtype` and `moe_router_dtype` together. This keeps the
inventory valid until the strict BF16-only load-profile gate rejects it;
an earlier inventory error does not exercise that gate. The four `testFP32`
cases in `MiMoV26ManagedSlotTests` and `MiMoV26ServingLoadTests` use
`MIMO_V26_SERIAL_LOAD_FIXTURES` pointing to the symmetric synthetic fixture
directory and require `MIMO_V26_SERIAL_NATIVE_TESTS=1` through their fixture
rewrite helper. The fixture-path check occurs before that opt-in check, so an
unprovisioned general run can fail rather than skip. Run these separately in the
native lane; they verify refusal before native ownership, not successful FP32
serving.

#### MiMo tool-schema parity

After building the current provider test product, use the
[tool-schema ingress regression recipe](mimo-prompt-fixtures.md#tool-schema-ingress-regressions)
for the five schema regressions, adjacent prompt/decode suites and nine current
consumer cases. Required focused selections reject zero tests and any skip.
The optional historical two-case corpus runs separately and cannot supply a
passing result when absent. These metadata-only, scripted-generation checks
exercise real provider preparation but do not load a model or prove live
platform parity.

#### Separate native and audio qualification

Ordinary fixtures use symmetric 128-context geometry; the separate complete-prefix
process uses `--asymmetric` for K64/V128 and 1,024-context geometry.
`scripts/prepare-mimo-audio-fixtures.py` prepares hash-pinned public inputs
including the genuine audio codec. Keep these output directories isolated from
the ordinary regression inputs. Audio gates exercise PCM8 and AAC-video with a
small target, not full-model quality or peak memory. Release-only builds do not
provision test fixtures or opt into native qualification.

## Prompt Preparation And Admission

```bash
swift test --skip-build --filter 'PromptTokenCacheTests|ChatTemplateLoopRewritesTests|InboundChatRequestDecodeTests|ServeLoopColdLoadTests'
```

`PromptTokenCacheTests` loads synthetic tokenizers through the production
`LocalTokenizerLoader` for the Qwen split, GPT-2 byte-level and Gemma metaspace
pre-tokenizer families, with no download, and requires piecewise, cached and
cross-turn token IDs to equal the unchanged path. A marker template that only
the served loop renders, or raises for, checks that a background comparison
disables reuse. `ChatTemplateLoopRewritesTests`
renders random agent histories through skeleton templates built from each loop
rewrite's matched blocks and requires the rewritten render to equal the
original. Set `PROMPT_TOKEN_CACHE_MODEL_DIRS` to colon-separated local model
directories to repeat both comparisons on real chat templates. `InboundChatRequestDecodeTests`
checks the merged admission body decode against the separate decoders, and
`ServeLoopColdLoadTests` drives the serve loop with a request parked on a model
load, including a request for a second cold model that fits only without the
first, and a request for the loading model when a second copy would not fit.
`darkbloom benchmark --prompt-prep --model <id>` times prompt preparation
and the body decode on the CPU with only the tokenizer loaded and the background
comparisons off; it exits 2 if any token ID or decoded field differs.

## Startup Performance Recovery

`StartupPerformanceEvidenceTests` drives the actual OpenAI serving adapter and
bridge with deterministic engine receipts: a one-token startup warmup must not
seed a slow deadline/heartbeat rate, and overlapping customer work must remain
measurable. `ModelCalibrationTests` exercises bounded native bootstrap, customer
preemption and actual retirement without customer traffic or model weights.
Its partial-bootstrap regression holds the second measured request in engine
work, interrupts it with a real foreground request, and checks rejection just
before the retry deadline plus acceptance at the deadline despite fresh rates.
`ProviderLoopCalibrationTests` runs registration against loopback and exercises
normal and timed-out startup preloads. It checks eager scheduling after the
self-test, before the first capacity tick, while retaining a blocked-posture
case. `firstBootstrapRunsWithFreshServingRates` verifies that an early request
cannot suppress the unfinished bootstrap.
The loop suite also checks serial calibration across three resident engines
without another capacity tick, stops that chain for foreground work or draining
(`IdleCalibrationCoordinatorTests` checks that a preempting request waits only
for the session's retirement, never for cross-actor successor scheduling),
and runs the production load-completion epilogue
with a real activity receipt and parked inference waiter to verify scheduling
prioritizes the newly loaded slot before waiter resumption even when another
resident engine is eligible. A blocked handoff checks that both load-transition
state and parked waiters remain held across the bridge actor hop. These epilogue
checks also cancel the load owner during that hop and require committed slot
publication to complete successfully, releasing both classes of waiters.
These epilogue tests do not load model weights. The native MiMo lifetime suite separately loads
its real tiny transaction-backed model and verifies publication releases the
construction activity before calibration can acquire ownership, then retires
the real owner. This is ownership coverage, not full-model calibration quality.
`finalCellPostureChangeDiscardsOnlyCalibration` holds the final measured cell,
changes its injected posture, and checks that only that cell's staged evidence
is discarded, independently published serving observations survive, and the
bootstrap succeeds on a later retry.
`lateCancelledPrefillRetainsProvenance` captures the production receipt of a
blocked warmup or measured probe, cancels and joins the real engine request,
then delivers an unconsumed prefill sample after cell cleanup. Neither serving
counters nor rate evidence may change.
`ProductionModelCalibrationTests` builds tiny real dense and MoE Qwen models
through `EngineV2SlotFactory.makeProductionBundle`, using the three affected
catalog IDs with both automatic paged selection and explicit contiguous KV.
It verifies fresh prefill/decode heartbeat evidence and zero customer-work
counters across repeated engine construction, without a customer request.
The dependency's `OrdinaryRequestRetirementTests` covers ordinary completion,
early watchdog terminal, waiter cancellation, zero work and closed admission.
`ModelCalibrationPolicyTests` keeps the native MiMo sweep and smaller ordinary
startup bounds explicit. Run these together with `EngineV2PrefillSamplingTests`
and `PrefillEvidenceRecoveryTests` using the provider test runner. Synthetic
timings prove state transitions, not real GPU throughput or fleet recovery.

## Deadline Admission Estimators

`EngineMeasurementOrderingTests` drives the measurement owner with synthetic
timestamps across the 120-second expiry boundary, and the real `EngineV2Bridge`
event pump with two scripted requests whose terminals arrive in reverse
observation order. `AdmissionRateEstimatorTests` covers the kill switch, the
anchored isolated-prefill policy (floor, idle expiry, posture, stale-evidence
expiry with or without an anchor), poisoned-sample and slow-calibration
lockouts through the bridge and the real submission path, another model's
lease or device activity on a shared whole-Mac service budget, a fresh
long-prompt bucket below the floor, decode step-shape measurement and plumbing
(including the first-token step's rows), rate and shape kept coupled across
batch widths, the per-row charge kept for reviewed calibrations, and a late
older cold sample. In the SDK, the unit suite
`CBv2PerBatchDecodeChargeTests` pins per-step decode accounting, MTP-measured
shape conversion, the mirrored MTP depth gates (batch gate and automatic
envelope, with a driver check that the ceiling bounds every live plan depth)
and the full-slot stretch; the integration suite
`CBv2PerBatchDecodeConversionTests` pins the engine conversion.

```bash
swift test --skip-build --no-parallel --filter 'EngineMeasurementOrderingTests|AdmissionRateEstimatorTests'
```

Run both SDK suites from `libs/mlx-swift-lm/` with `--filter CBv2PerBatchDecode`;
they need no Metal library. These use scripted engines and synthetic numeric
usage: no model or GPU runs, and they do not qualify live refusal rates,
hardware performance or routing.

## Native Inference Checkpoint Storage Qualification

Live attention and durable checkpoint precision are independent. Build the
provider and nested test products and stage both Metal libraries first. The
[precision architecture](../architecture/kv-cache-quantization.md) and
[SSD format reference](../reference/ssd-kv-cache.md#complete-checkpoint-payload)
define the contracts under test.

Provider policy/configuration/diagnostic checks require no model download:

```bash
swift test --skip-build --filter 'KVQuantizationConfigTests|EngineV2KVQuantizationPolicyTests|NativeCheckpointQuantizationTests|BenchmarkKVQuantizationOptionsTests|KVCheckpointPostureTests|ModelCheckpointStorageSpecificationTests'
```

From `libs/mlx-swift-lm/`, exercise native restoration, unsupported/profile
refusal, fragmentation and actual ownership:

```bash
../../scripts/run-nested-suite.sh \
  'NativeCheckpointRowCodecTests|NativeQuantizedPagedCheckpointTests|NativeQuantizedContiguousCheckpointTests|Qwen35NativeQuantizedCheckpointTests|HistoricalWindowCheckpointEngineTests.testContiguous' \
  --no-parallel
DARKBLOOM_TEST_NATIVE_COMPLETE_PREFIX=1 ../../scripts/run-nested-suite.sh \
  CBv2NativeCompleteCheckpointTransferTests.testLossyNativePartialImportKeepsChargeUntilRealCompletion \
  --no-parallel
```

These are CPU/GPU regressions, not whole-model quality or performance evidence.
Keep existing live-packed suites and exact-native assertions; do not loosen
tolerances or equality requirements for lossy checkpoint tests.

`ModelCheckpointStorageLiveTests` uses the production factory, isolated encrypted
stores and public fixed-date prompts. Inspect the
[runner and input schema](../../reports/kv-checkpoint-storage-2026-10-09/README.md)
before a real-model comparison. From the repository root:

```bash
python3 -B reports/kv-checkpoint-storage-2026-10-09/checkpoint_storage.py \
  --spec /absolute/model-spec.json --output-dir /absolute/existing-parent/new-run \
  --dry-run
```

Remove `--dry-run` only after building and reserving the GPU. The runner never
builds or downloads. It selects native-live/native-checkpoint and
native-live/balanced-checkpoint arms, with optional `--include-balanced-live`
for the existing live-packed path. Use distinct supported `kvBackend`
specifications for paged and contiguous; `auto` proves only the actual backend
reported. A requested profile resolving to another profile is not a passing
treatment.

- Retain requested/effective precision, layout and binary/metallib/model identity.
  Same-profile original-donor restores and restart continuations keep equality
  checks. Native-cold versus lossy-restored output equality is an observation,
  not a quality guarantee. Re-encoding restored rows need not be byte-exact.
- `cold_fork` is cache-disabled full prefill, not cold model loading;
  `warm_full_prefill` is hot-model full prefill, not a RAM prefix hit. Donor writes,
  SSD reads, tenant refusal, cancellation after output and recovery remain
  separate roles with real read/write and restored-token checks.
- Ephemeral-key runs do not prove cross-process persistence. Persistent phases
  require an isolated key namespace, a signed runner with the matching access
  group and a completed donor report from another process. `--exercise-read-refusal`
  checks refusal and subsequent recovery. Never use production cache roots/keys.
- `memoryAtFirstOutput` reports queue-owned `backendBytesInUse` and
  `backendBytesReserved`, separately from lagging capacity gauges. It is not
  peak process RAM or a disk compression ratio. TTFT precedes the sample;
  generation TPS includes sampling cost and is not saturated throughput.
  `supportsOrdinaryDecodeChaining` is a capability; `decodeSteps` and
  `chainedDecodeSteps` record actual use.

Retain raw reports, refusals, skips and incomplete cells. A tiny suite, compression
ratio or runner exit code alone does not qualify encrypted restart, quality,
TTFT, TPS or memory. The existing `ModelPrefixBenchmarkLiveTests` exact replay
suite requires native live and native checkpoint precision and rejects nonnative
specifications before loading; keep those output-hash assertions unchanged.

`ModelCheckpointRestoreContentionLiveTests`
(`provider-swift/Tests/ProviderCoreTests/Inference/Live/PrefixQualification/ModelCheckpointRestoreContentionLiveTests.swift`)
is the opt-in real-model regression for complete-checkpoint SSD restore TTFT on
a shared engine. It reads the first case of the same standalone
`ModelPrefixBenchmarkSpecification` and an isolated ephemeral cache, and
requires native live and checkpoint precision: a lossy checkpoint can restore
slower than recompute, which belongs in `ModelCheckpointStorageLiveTests`. For each
pair it serves the fork prompt restored and cold under three conditions: idle,
while another tenant's long prefill is running, and right after another
tenant's donor completes. Each condition gets its own donor and cache scope,
so a deeper checkpoint donated by one measured fork never serves another. It
fails when a restore does not reach `demandedTokens`, restores a different
depth than the idle restore of its pair, produces its first token later than
the cold run under the same condition, or stages more than 1 s slower than the
idle restore, the signature of waiting on another prefill's `evalLock`. A
contended run also fails if the foreign prefill finished before its stage did.
Other timings are observations. The timing gates need exclusive GPU use. Run
it from `provider-swift/` after building tests and staging the metallib, with
only the listed variables:

```bash
env -i HOME="$HOME" PATH="$PATH" TMPDIR="$TMPDIR" \
  DARKBLOOM_PREFIX_EXCLUSIVE_GPU=1 \
  DARKBLOOM_RESTORE_CONTENTION_BENCHMARK=1 \
  DARKBLOOM_PREFIX_MODEL_SPEC=/absolute/model-spec.json \
  DARKBLOOM_RESTORE_CONTENTION_OUTPUT=/absolute/new-report.json \
  swift test --skip-build --disable-automatic-resolution \
  --filter ModelCheckpointRestoreContentionLiveTests
```

Pick `demandedTokens` at or below the deepest checkpoint that fits
`DARKBLOOM_PREFIX_CACHE_SSD_MAX_STAGE_MB`; a deeper demand fails the boundary
check rather than measuring restore latency. The contended fork is submitted
two seconds after the foreign prefill starts, so pick a `donorTokens` long
enough to still be prefilling then. The report records the session's runtime
identity (`runtime`, from `makeReport`) and keeps every sample, including the
foreign requests that create each condition. It is rewritten atomically after
each measured run, so an interrupted run keeps every completed run's samples,
and its `failure` records contract violations, thrown errors and teardown
errors alike. The test qualifies provider-staged imports only, so it refuses
MiMo specifications, which load through the native engine.

## Runtime Generation Comparisons

Run focused policy and CLI checks from `provider-swift/`:

```bash
swift test --skip-build --filter 'EngineV2KVQuantizationPolicy|EngineV2DiffusionPrefixPrecision|BenchmarkRuntimeGeneration|RuntimeGenerationBenchmark|RuntimeConcurrencyBenchmark'
```

With an owned GPU and verified model, compare production-session live precision:

```bash
darkbloom benchmark --model "$MODEL_ID" --runtime-generation --kv-backend paged \
  --kv-quantization native --runtime-prompt-file "$PUBLIC_PROMPT_FILE" \
  --runtime-prompt-date 2026-10-09 --max-tokens 4096 > "$NATIVE_REPORT"
darkbloom benchmark --model "$MODEL_ID" --runtime-generation --kv-backend paged \
  --kv-quantization balanced --runtime-prompt-file "$PUBLIC_PROMPT_FILE" \
  --runtime-prompt-date 2026-10-09 --max-tokens 4096 > "$PACKED_REPORT"
```

Keep artifact, prompt and date fixed. Runtime generation keeps prefix caches off,
so this is not a checkpoint-storage comparison. Reports include resolved
precision/backend, generated IDs/text, finish reason, runtime identity, timing
and memory. Target-only is a diagnostic control; repeat with `--runtime-mtp`
for the configured assistant. Fluent text or a `length` finish is not a
correctness result. Ordinary scalar `MLX.generate` does not exercise the
production compressed cache. MiMo retains its separate native benchmark.

## Provider Endpoint Resumption And Logout

These synthetic tests require neither Apple calls nor credentials:

| Coverage | Suites / sources |
|---|---|
| Shared fixed vector, authenticated bytes, reflection, malformed fields, time bounds and protocol negotiation | `provider-swift/Tests/ProviderCoreTests/Crypto/AppAttestResumeTests.swift`; `provider-swift/Tests/ProviderCoreTests/Fixtures/app-attest-resumption-v1.json` |
| Real loopback reconnect, fresh socket nonce, stale callback rejection, one response per socket and unchanged model state | `provider-swift/Tests/ProviderCoreTests/Coordinator/AppAttestResumeTransportTests.swift` |
| Stop before revoke/delete, missing token, stop/deletion failures, exact HTTP 204 and redirect/offline refusal | `provider-swift/Tests/ProviderCoreTests/Auth/ProviderLogoutTests.swift` |
| Logout flags, current-process identity refusal and accurate completion messages | `provider-swift/Tests/DarkbloomCLITests/LogoutCommandTests.swift` |

```bash
swift test --skip-build --no-parallel --filter 'AppAttestResume|ProviderLogout|LogoutCommand'
```

Keep state paths isolated as in `scripts/run-provider-tests.sh`; these tests
must never stop an operator process. They do not establish physical Apple
qualification or end-to-end platform authorization.

## Watchdog Launch Acknowledgement

`WatchdogLaunchAdapterTests` (in `LaunchAgentLifecycleTests.swift`) drives the
actual `LaunchAgent.kickstartIfLoaded` adapter, `WatchdogRecoveryService` and
the disk-backed crash-loop guard with a temporary install and scripted
`LaunchctlControl`.

```bash
swift test --skip-build --no-parallel \
  --filter 'WatchdogLaunchAdapterTests|LaunchAgentLifecycleTests|refusedKickstartRollsBackTrip|rollbackRestoresPreexistingGuard'
```

A missing-service response after a successful loaded check (exit 3 text or
launchctl's exit-113 `Could not find service`) must return
`noLongerLoaded`, restore the exact prior guard bytes and invoke no trip
callback. Controls cover an already absent job, a successful kickstart,
permission errors and manual restart reload. No real launchctl, model or GPU is
used; the scripted interleaving does not measure native race frequency.

## App Attest Provider Dispatch

`ServeLoopAppAttestTests` runs the actual provider loop, WebSocket client and
App Attest client against loopback. Held model-load waits and Apple callbacks
check responsive challenge/status handling, reconnect invalidation, no overlapping
proof operations and key reuse. Model work and Apple callbacks are local fixtures.

```bash
swift test --skip-build --no-parallel --filter 'ServeLoopAppAttestTests|WorkerProcessTests|WorkerTransportTests|WorkerRuntimeDiagnosticsTests|QualificationAssertionCallbacksTests|NativeWorkerServeQualificationTests'
```

The worker suites cover supervised process/transport behavior without replacing
the physical Apple gates. `ServeLoopAppAttestInteropTests` is an opt-in Swift peer
for the platform's `TestSwiftProviderAppAttestInterop`; its owner supplies
`DARKBLOOM_SWIFT_INTEROP_PACKAGE` pointing at this built package. Both processes
use loopback with seeded enrollment/receipt/runtime facts and software proofs
for the real verifier. That private test checks loss, reconnect and revocation,
not initial Apple enrollment or a signed release. No backend checkout or test
command is part of the public provider gate.

## Native Serving Qualification

`NativeServeQualificationTests` checks literal-loopback refusal, owner-only
descriptor inputs (including callback-arm value, permissions and symlink refusal),
failed-observer lifetime ownership and bounded in-memory key-ID/budget storage,
without Apple calls or model allocation. `NativeServeRunLifetimeTests` covers
completion and teardown ownership.

```bash
swift test --skip-build --no-parallel --filter 'NativeServeQualificationTests|NativeServeRunLifetimeTests'
```

The physical harness is platform-owned. It requires a separately built, final-signed
SDK 27 app, explicit Apple/GPU execution approval and exclusive GPU access. Follow
the [local signed-app procedure](../../scripts/nativequalification/README.md), not
the installed provider. Scoped LaunchServices registration must be restored after
the captured child is reaped.

Inputs are an existing canonical `0700` directory containing a `0600` `auth-token`
(64 lowercase hex characters), a `0600` `model-id`, and a private `models`
HuggingFace cache. Snapshot bytes may be read-only links. The diagnostic creates
fresh `state`, uses an ephemeral Secure Enclave signer and Apple's real service,
and retains key IDs/budgets only in memory. It does not read installed auth/config,
use persistent signing keys, register APNs, install profiles, start launch agents
or run updates. Normal provider hardening, signed registration, encrypted inference,
engine construction, memory admission and disconnect cleanup remain enabled.

The platform seeds only its isolated account/token, exact runtime approval and
actual model catalog. Initial enrollment/assertion must pass its real router and
verifier. Stage C checks encrypted inference before/after a 125-second transport
break following an encrypted chunk and fresh live-request observation, unchanged
process/endpoint/model identities and load/Apple counters, old-request terminal
cleanup, reservation release and fresh capacity. A `0600` one-byte `done` file
requests graceful shutdown; the diagnostic also has a 900-second limit.
`observation.json` contains identity hashes, counts and sequence/time stamps,
never content, keys or proofs. Stale observations, failed drain, or serving-loop
completion before the observed completion marker fail rather than claiming
success (`NativeServeRunLifetime.run`).

The [October 11 result](../reports/2026-10-11-native-serving-resumption-qualification.md)
records an exact-artifact target-only pass, not MTP, SSD persistence, APNs, daemon
installation or fleet rollout. The separate
[loaded-engine callback result](https://github.com/Layr-Labs/darkbloom-platform/blob/7e69b67aa4173e7af021de4f846e4c4667a25aed/docs/reports/2026-10-12-native-loaded-worker-callback-qualification.md)
uses `DARKBLOOM_NATIVE_WORKER_SERVE_QUALIFICATION=1` and
`DARKBLOOM_APP_ATTEST_WORKER_QUALIFICATION=1`, normal renewal/retry clocks and
encrypted paid probes strictly inside callback-withheld and reap-to-retry
windows. Neither result qualifies a later rebuilt artifact, physical OS/security
transition, reboot, self-update or fleet rollout. Compilation and opt-in skips
are not successful physical runs.

## SDK 27 Release Qualification

The release `qualify-sdk` job uses SDK 27 / Swift 6.4 and runs independently of
optimized compilation. Signing requires both successes. GPU suites retain serial
execution and exclusive-process isolation. A cache hit never skips a test.

`Qwen4StandaloneAdmissionTests` uses scripted memory through the real standalone
server to cover low-headroom refusal before loading, pending-load cleanup and
same-server retry. Physical allocator tests still require actual measurements.
`BoundedSingleConsumerPipelineTests` covers reusable drains, bounded retention,
overflow, cancellation and shutdown. Its `pipelineShutdownDrainReleasesLastPayload`
test repeats the final-payload handoff 10,000 times: drain must wait for consumer
completion, not just a zero pending count. Run from `provider-swift/`:

```bash
swift test --skip-build --filter Qwen4StandaloneAdmissionTests --no-parallel
swift test --skip-build --filter pipeline --no-parallel
```

The final packaged binary must pass [runtime smoke](build.md#app-attest-release-qualification),
including the compiled environment line and four resource/callback markers.
This is not real Apple service validation. Physical smoke is optional for normal
publication; official-build registration and runtime Apple authorization remain
distinct. See [release](../operations/provider-release.md).

## Watchdog Launch Evidence

`WatchdogRecoveryIntegrationTests` exercises
`WatchdogRecoveryService.observeHealthyProvider`, the real updater and the
disk-backed recovery store with synthetic bundles, temporary install roots and
loopback release HTTP. Launch snapshots, process liveness and restart callbacks
are injected; no model or MLX kernel runs.

```bash
swift test --skip-build --no-parallel \
  --filter 'unprovenLaunchEvidencePreservesIntent|prelaunchHealthObservationRetainsIntent|partialLaunchEvidenceRequiresComparison|interruptedLaunchReceiptTimesOut|unprovenLaunchIntentDoesNotTimeOut|interruptedLaunchReceiptPromotes'
```

It covers missing and partial baseline evidence, intent retention before
restart, later positive run-count or process-identity evidence, the startup
timeout, one-time failure accounting and heartbeat promotion. It does not run
native launchd, the controller cancellation interleaving or a signed release
installation.

## Public Fixtures And Private Qualification

Public protocol JSON and prompt golden vectors contain fixed inputs and expected
outputs. Provider tests load them from provider-owned resources or `fixtures/`,
not from a removed backend tree. Preserve exact bytes, attribution, artifact
hashes, enum casing and optional-field omission.

`scripts/verify-prompt-parity.sh` uses `scripts/prepare-prompt-fixtures.py` to
download only the committed manifests' hash-pinned public prompt assets, never
weights. The downloader identifies itself as `darkbloom-prompt-fixtures/1` to
the CDN and retains same-origin HTTPS, byte-budget and integrity checks.
Provisioning failures fail qualification; they must not silently skip vectors.

Public validation means **this implementation matches those fixed expectations**.
It does not run private Go/Rust implementations, establish current cross-implementation
parity, prove live routing or certify all models. Platform qualification independently
runs its implementation at explicit revisions and records native/full-model evidence.
Public CI must not clone a moving private branch or replace failed qualification
with a hash check. Refresh expected outputs only after review.

The retained console tests still read
`coordinator/tests/protocol/testdata/paged_footprint_wire.json` and
`coordinator/tests/protocol/testdata/process_memory_wire.json`. These are fixtures,
not a retained coordinator implementation/test suite. Preserve agreement with the
provider resource copies and run each implementation's checks in its owner repo.
The [immutable platform test guide](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/developer/test.md)
is historical context, not the current backend source authority.

## Focused Tooling Checks

For the PR reviewer, run the seven offline suites listed in
[threat-review verification](threat-model-review.md#verify). They cover bounded
change context, final-review integration, fail-closed merge decisions, failure
classification and exclusion of private response text from diagnostics. Loopback
HTTP tests need permission to bind a local port; none of these suites call paid
models. Bedrock-shaped lifecycle fixtures exercise transport, scanner, saved
reports and merge decisions together, including truncation, call limits,
interruption and failed report/diagnostic writes. Selective integration tests
enforce each model's source citation scope across fresh and cached results,
bounded exact-source replay, explicit omissions and unchanged acknowledgments.
State tests reproduce shared-branch conflicts between different report files,
including twelve simultaneous writers and a burst exceeding the former retry
window, cache immutability, bounded recovery and refusal to retry ambiguous writes.
Request tests verify native schema projection preserves local bounds; workflow
tests keep current trusted scanner code separate from pinned threat-model data.
Bedrock usage tests preserve Sol cache-write input and reject malformed cache
counts; finding-text and both scan paths' analysis tests enforce raw character
limits including padding.
Lifecycle tests ensure failed backup accounting also stops a recovered primary,
and missing native usage or failed response-usage writes preserve validated
findings while stopping further spending and denying clearance.
Response-repair tests inject empty analysis in Sonnet, Opus and Sol source and
integration passes and incorrect primary acknowledgments during integration.
Both faults share one repair allowance, preserve original findings and uncertainty,
and stop at a second invalid response, exhausted call budget or failed checkpoint.
Replay IDs cannot be confused with primary IDs; the integration schema and cache
identity bind the expected acknowledgments. CLI tests retain original diagnostics
and findings after final-result write failure. Merge-gate tests reject artifacts
from another run/attempt even for the same revisions. PR closure has a distinct
lifecycle stop code and cannot grant merge clearance.
Live smoke tests establish model compatibility separately.
Workload tests segment large fixtures into 31 and 62 source batches, then complete
Sonnet and selected Sol review, hierarchical integrations and one repair. Removing
duplicate Opus passes reduces those critical-code fixtures from 100 to 69 and
197 to 135 requests without losing source coverage. Routing regressions retain
full Sonnet review of clean support files, escalate their findings and uncertainty,
preserve workflow and renamed-path risk, and target exact integration citations.
Production `AppAttest.swift`, `Attest.swift`, `AuthLatest.swift` and critical
test-named files retain independent depth outside explicit support trees.
Global uncertainty still denies clearance without triggering a blanket rescan;
cached results preserve the same selected scope. Adapter tests stop after
exactly 500 requests, apply the larger native output default and preserve fixed
probe limits. Client configuration tests preserve single-attempt transport and
allow more response time for workload mode. Lifecycle tests verify stage admission
failure identifies the
unadmitted integration rather than the previous source call, manual GitHub job
reruns perform no paid work, runtime configuration stays bounded and every final
incomplete outcome requires human review. Workflow checks restrict manual dispatch
to unpaid preflight and keep the scanner deadline below the job timeout.

From the repository root:

```bash
make benchmark-wrapper-test
python3 scripts/test-docs-impact-check.py
python3 scripts/test-docs-check-historical-links.py
python3 scripts/test-docs-stamp.py
python3 provider-swift/Tests/test_protocol_fixture_resources.py
python3 scripts/test-changelog.py
make changelog-check
python3 scripts/test-provider-release-resolution.py
python3 scripts/test-provider-release-resume.py
python3 scripts/test-provider-release-publication.py
python3 scripts/test-release-dev-branch.py
python3 scripts/test-provider-release-pipeline.py
python3 scripts/test-provider-release-artifact.py
python3 scripts/test-provider-release-cache.py
python3 scripts/test-provider-signing-validation.py
python3 scripts/test-prepare-metal-toolchain.py
python3 scripts/test-stage-swiftpm-resource-bundles.py
python3 scripts/nativequalification/test_staging_guards.py
python3 -m unittest discover -s scripts/benchmarks -p test_radix_forward_shapes.py
make docs-impact-check BASE=origin/master
make docs-check
```

Release tests cover provider-only version/tag/binary parity even when backend
source is absent, signed tags and trusted `master` before secrets, exact artifact
registration, immutable producing attempts and retry-safe publication. Archive
checks reject unsafe members, changed inventories, wrong source and entitlements.
`scripts/test-release-dev-branch.py` pins the experimental dev-branch lane
(`.github/workflows/release-dev-branch.yml`) to dev scope: dispatch-only with a
`ref` input, no tag path, no production environment, signing identity or secret,
and publication only with `DEV_RELEASE_KEY`. These CPU-only checks do not prove
Apple runtime behavior.

Docs-impact tests retain provider, protocol, privacy, native capacity, cache,
release/model publication, console packaging and fixture mappings. Historical
links need exact provenance. Final full-tree lint needs intended additions/removals
staged because it enumerates tracked files; explicit paths can be checked earlier
without the orphan pass. Neither replaces final staged full-tree validation.

For SSD write endurance, `bash scripts/test-ssd-write-budget.sh` compiles production
accounting sources and Swift Testing suites without MLX or GPU work. Keep restart,
damaged-ledger, clock rollback and multiprocess cases. Native cache gates also
retain missing/replaced-volume, encryption, epoch, owner-only and no-fallback
checks. `SSDCheckpointMaintenanceEpochTests`, `SSDTrackedNativeRetryTests` and
`SSDCacheEpochStoreRecoveryTests` cover encrypted accounting/reconciliation,
real-completion fences and refusal/recovery. Permission cases require a non-root
test user and only change temporary fixture directories.

## Retained Console

```bash
make ui-install ui-lint ui-test ui-build
```

Vitest covers route handlers, validation, state and protocol fixtures. ESLint
checks `src/`; the console lane and console-only pre-commit hook remain.
The retained `next build` ignores TypeScript errors, so it does not replace
lint, Vitest or the separate `npm run typecheck` diagnostic in `console-ui/`.
Use isolated fixtures/services, never real accounts or billing credentials.
See [console architecture](../architecture/components/console-ui.md);
new console development remains platform-owned.

## Landing

```bash
make landing
```

The aggregate installs locked dependencies, lints, builds and exercises local
HTTP routes. `landing/tests/helpers/site-server.mjs` starts isolated production
servers for HTML/Markdown negotiation, real 404s, discovery, canonical/structured
metadata, sitemaps and OpenAPI validation. Pricing uses a local HTTP upstream,
including unavailable/malformed responses. Preserve framework `Vary` tokens and
`Accept` across alternating representations when upgrading Next.js.

`landing/tests/story-gestures.test.mjs` covers pointer, wheel and keyboard input,
vertical-scroll passthrough, controls, cancellation and listener cleanup through
the homepage binding. Run `node --test tests/story-gestures.test.mjs` in `landing/`
without a server. DOM tests do not replace browser checks for pointer capture,
touch scrolling or responsive carousel layout. Search/discovery after an
authorized deployment needs separate read-only inspection; local success is
not live verification.

## Model publication workflow checks

Run `python3 scripts/test_model_registry_workflow.py` to exercise the actual
workflow shell steps against a loopback HTTP server with fixture credentials.
It checks that an uploaded revision sends only revision identity, needs no R2
credentials, preserves normal registration payloads, and propagates failures.
It also rejects unconfirmed revision promotion while retaining staged-only
normal registration.
CI runs this suite without contacting production. The test host needs Bash,
Python, jq and curl, matching the workflow runner.

`python3 scripts/test_publish_model_revision.py` covers the immutable upload
reservation. `actionlint .github/workflows/register-model.yml` checks workflow
syntax. These checks do not establish native model quality or serving capacity;
use the [publication runbook](../operations/model-revisions.md) for those checks.

## Reporting Results

Report exact selector, revision, native resources and model identity. Distinguish
compile-only, fixed vectors, tiny native fixtures, full-model execution,
signed-artifact tests and private platform integration. Document skips and
unavailable hardware honestly. Local validation does not authorize deployment.

## Flint native validation

Run `make provider-test` for repository checks. Focused provider suites are
`FlintPolicyTests`, `FlintDiscoveryTests`, `FlintTemplateReplayTests`,
`FlintToolChoicePromptPolicyTests`, `FlintContextAdmissionTests`,
`FlintPagedOnlyBackendTests`, `ModelBenchmarkDispatchTests`,
`FlintNativeProtocolTests` and `FlintNativeProtocolFactoryTests`; SDK suites
are `FlintTests`, `FlintToolTests`, `FlintPrefixTests` and
`ToolCallParserIntegrationTests`. `FlintToolChoicePromptPolicyTests`
(`provider-swift/Tests/ProviderCoreTests/Inference/Prompting/FlintToolChoicePromptPolicyTests.swift`)
pins exact-type native framing, original messages, named filtering and invalid
tool requests against the pinned template. The SDK fixture is generated independently by
`libs/mlx-swift-lm/scripts/generate-flint-oracle.py` with NumPy and credits the pinned mlx-vlm
oracle. Numeric assertions retain their declared tolerances and run with
`MLX_ENABLE_TF32=0`.

`FlintPagedOnlyBackendTests.defaultSettingsBuildRealPagedSlot` assembles a tiny
Flint through the production slot factory with default `BackendSettings` and no
engine override. It checks paged attention, native KV and checkpoint precision,
the artifact's context limit despite a conflicting sizing hint, and the default
2,048-token solo-prefill stripe. Persistent caching is disabled only for fixture
isolation; backend, precision and prefill environment overrides are absent.

Verify the prefill output seam against full-logit forward, including identical
KV and continuation results, sliding-window wrap and both contiguous/paged
prefix restore. Tool coverage must include schema-aware values, null-preserving
history, Unicode/chunk boundaries and rejection of unsupported controls and raw
`</arg_value>` history. These checks do not establish full-model quality or
throughput. Sources: `libs/mlx-swift-lm/Tests/MLXLMTests/Integration/Flint/`,
`provider-swift/Tests/ProviderCoreTests/Inference/FlintPolicyTests.swift`,
`provider-swift/Tests/ProviderCoreTests/Inference/Prompting/FlintTemplateReplayTests.swift`.

Run the CPU-only native protocol suites to check dedicated and split markers,
all prepared tool choices, parallel-call cardinality, quoted tool examples in
reasoning, raw strings beginning with braces/brackets, JSON delimiter protection,
custom-stop rejection and bounded state exhaustion. Check mask/transition
agreement and retain independent complete-frame/schema rejection tests: a
protocol-valid frame can still contain invalid JSON or arguments. Factory
fixtures must supply the verified native tokenizer and rendered assistant
boundary; a generic fake tokenizer cannot establish that contract. Source:
`provider-swift/Tests/ProviderCoreTests/Inference/Tools/FlintNativeProtocolTests.swift`
(`FlintNativeProtocolTests`, `FlintNativeProtocolFactoryTests`). These suites
do not load model weights or establish full-model answer quality.

Set `DARKBLOOM_FLINT_BACKEND=paged` for the paged HTTP qualification pass and
select `--kv-backend paged` in the matching performance runs. Retain the resolved
backend; contiguous reference results do not qualify paged serving.

`FlintHTTPBenchmarkTests` is the opt-in authenticated HTTP baseline. It lives in
`ServingQualificationTests`, which builds in release; `ProviderCoreTests` uses
debug-only test hooks. Build that target in release with `-Xswiftc
-enable-testing`, stage the source-matched metallib, then run only that suite with
`DARKBLOOM_FLINT_HTTP_BENCHMARK=1`, `MLX_ENABLE_TF32=0`,
`DARKBLOOM_CBV2_SOLO_PREFILL_STRIPE=2048`, `DARKBLOOM_FLINT_BACKEND=paged` and
task-owned `_ROOT`, `_CONFIG`, `_RECEIPT`, cache, port and a fresh, nonexistent
`DARKBLOOM_PREFIX_CACHE_TEST_ROOT` with `DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL=1`.
`DARKBLOOM_PREFIX_CACHE_TEST_PERSISTENT_KEY` must not be `1`, both prefix-cache
policies must be off, and the owned config must select paged/native/native
without an external MTP drafter.
It verifies 401 before any load, binds the staged metallib, and after every
request requires the production slot to resolve paged/native/native with the
2048-token stripe and zero cached prompt tokens. `decode_short` and
`prefill_4k` (about 4.1K tokens) each run one warmup and
`DARKBLOOM_FLINT_HTTP_BENCHMARK_MEASURED` requests (default 3). The receipt
holds counts, timings and hashes only. Its prefill rate is prompt tokens per
TTFT second, a lower bound on engine prefill; its decode figure is an estimate
that includes reasoning tokens. Both are single-stream results from a release
test build, not server capacity or a signed release. Source:
`provider-swift/Tests/ServingQualificationTests/FlintHTTPBenchmarkTests.swift`.

`FlintR2InstallTests` checks delivery of a published model: with
`DARKBLOOM_FLINT_R2_INSTALL=1`, a fresh nonexistent absolute
`DARKBLOOM_FLINT_R2_INSTALL_CACHE`, and the published `_R2_PREFIX`,
`_R2_AGGREGATE` and `_R2_VERSION`, the production `ModelDownloader` installs
the manifest into that cache and the test checks the installed aggregate and
template. Optional `DARKBLOOM_FLINT_HF_REPO` and `_HF_REVISION` pin a public
Hugging Face source that the downloader tries first, falling back to R2. Then
run `FlintLiveTests` with `DARKBLOOM_FLINT_CACHE` set to the same root to load
and serve that copy. It downloads the full model and needs no coordinator.
Source: `provider-swift/Tests/ProviderCoreTests/Server/FlintR2InstallTests.swift`.

`FlintLiveTests` is opt-in physical-machine qualification, not an ordinary CI
weight download. In an exclusive GPU process, set `DARKBLOOM_FLINT_LIVE=1` and
`DARKBLOOM_FLINT_CACHE` to an owned HF-layout cache containing the verified
`RecursiveSI/flint-int4` snapshot. It starts an authenticated loopback service,
uses a task-local encrypted-cache directory, executes real production slots,
and stops/drains them. `DARKBLOOM_FLINT_PORT` selects an unused port;
Flint is paged-only, so `DARKBLOOM_FLINT_BACKEND` may only be unset or `paged`.
`DARKBLOOM_FLINT_RECEIPTS` optionally writes synthetic response evidence to an
owned file. Keep these model-dependent checks separate from tiny-fixture,
public-CI and signed-release evidence.

`FlintOpenRouterLiveTests` uses the same environment plus
`DARKBLOOM_FLINT_OPENROUTER_LIVE=1` and always serves paged attention. It sends
the parameters OpenRouter lists for Flint over loopback HTTP: reasoning effort,
enabled and exclude controls (chat, streaming and Responses), `stop`,
`json_object` and strict `json_schema` (alone and with tools), named tools,
`logprobs`/`top_logprobs` and `seed`. Only the coordinator relay emits
logprobs, so `FlintRelayLogprobsLiveTests` (same gate; optional
`DARKBLOOM_FLINT_RELAY_RECEIPTS`) sends sealed requests to the production
handler on a paged slot and checks the entries, with and without withheld
reasoning. Sources:
`provider-swift/Tests/ProviderCoreTests/Server/FlintOpenRouterLiveTests.swift`,
`provider-swift/Tests/ProviderCoreTests/Server/FlintRelayLogprobsLiveTests.swift`.

Keep adversarial history assertions on visible answer content and unintended
calls. Do not replace a failed answer with a reasoning-only assertion. An
unconstrained raw-token diagnostic can help identify which terminal was sampled,
but it bypasses the [production protocol constraint](../architecture/inference.md#native-flint)
and cannot qualify production reasoning, tool safety or throughput. The engine
suppresses EOS token text, so decoded content plus `finish_reason: stop` alone
does not identify the sampled EOS. Keep synthetic token-level diagnostics in
explicitly owned local evidence; never send tokens, prompts or completions to
telemetry or heartbeats. Source:
`libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/EngineLoopV2.swift`.

For performance claims, rebuild the exact SDK/provider pins and source-matched
metallib, record hashes and precision settings, and use an exclusive inference
process. Separate scalar SDK prefill, production CBv2 decode and HTTP timings.
Record whether the native constraint is active and whether its vocabulary cache
is cold or warm. Include tool-less requests, which still pay constraint costs,
and measure complete request time as well as decode throughput. Compare matched
constraint policies: masking and decode-chaining eligibility differ from an
unconstrained diagnostic. See [constraint overhead](../architecture/hardware-support.md#flint-memory-admission).
A captured dense/expert NAX dispatch establishes execution only; a speedup needs
a matched portable-path comparison. Track the full provider suite independently
from successful test compilation and focused SDK tests. See
[hardware evidence limits](../provider/hardware-requirements.md#flint-validation-scope).

## Nemotron Super component qualification

The [portable fixture harnesses](../../scripts/nemotron-qualification/README.md)
reproduce isolated native SDK/provider checks from the pinned gitlinks on a new
Apple Silicon machine. They include the original 88-shard checksum verifier and
require separate full-checkpoint admission/reservation calibration. Tiny fixture
passes do not qualify the shipping provider, MTP speed or full image support.
Prompt parity uses a committed golden corpus from
`scripts/nemotron-qualification/prompt_golden.py`; token-ID checks run only when
`NEMOTRON_SUPER_REFERENCE_DIR` names the pinned tokenizer and template, and
otherwise skip with that instruction.

Nemotron Super image fixtures and their goldens are generated by
`scripts/nemotron-qualification/image-goldens` (see its
[README](../../scripts/nemotron-qualification/README.md)). PNG must match Pillow
byte for byte and the final tensors bitwise; JPEG uses the bounds in the
[image format reference](../reference/nemotron-super-image-formats.md).
Regenerated fixtures must be byte-identical unless a pinned reference changes.

The three Nemotron Super reference clips in
`provider-swift/Tests/ProviderCoreTests/Fixtures/NemotronSuperVideos` and their
`nemotron-super-video-golden.json` come from NVIDIA's serving path (vLLM's
OpenCV loader at 2 fps and 256 frames, the HF processor and the pinned
tokenizer). `NemotronSuperVideoGoldenTests` checks the frame plan, labels,
grid, decoded frame layout, the red first frame of the colors clip, EVS
retained counts, the `<video>` replacement ids
and the template text without the tokenizer; with
`NEMOTRON_SUPER_REFERENCE_DIR` it also checks the label and full prompt token
ids. `NemotronSuperVideoBindingTests` covers video admission, the tubelet
layout, the media charge and its quote, and serves a synthesized MP4 end to
end on the tiny installed fixture, checking its prompt length and one span per
tubelet that kept rows; it also checks that batched EVS keeps the rows EVS
selects over the whole video, that cancelling or draining a decoding video
returns its charge and that a malformed pruning rate fails the load
before installing. `NemotronSuperVideoDecodeTests` covers the decoder's
refusals on synthesized clips (decoded-pixel budget, codec, second track,
zero-duration frame), per-frame validation, the decode allowance, reader
cancellation and the container type hint.

The managed slot is covered by `NemotronSuperServingPolicyTests` and
`NemotronSuperMediaChargeTests` (identity, discovery, image advertisement, load
plan, footprint, media charge and capacity quotes; CPU only) and
`NemotronSuperManagedSlotTests` (fixture load through `ProviderLoop`, encrypted
coordinator and local-endpoint text and image requests on the speculating
owner, an image beside speculating text, media refusal before allocation,
cancellation, admission refusal and retirement). Three gated cases need the
pinned checkpoint: `NEMOTRON_SUPER_CHECKPOINT_DIR` alone checks its discovery
and that the recorded LOAD constants equal the SDK quotes over every verified
shard (hashes about 75 GB, loads no weights); adding
`DARKBLOOM_SUPER_MANAGED_LIVE=1` loads the full checkpoint (about 80 GB) through
the production loader, once to serve an encrypted text request and once for PNG
and JPEG questions and an image beside a text request. Run them only with
exclusive GPU access.

## Related

- [Build](build.md)
- [Serving-performance qualification](serving-performance-qualification.md)
- [Historical references](historical-references.md)
- [Provider release](../operations/provider-release.md)
