# Test Provider And Native Contracts

> Last updated: 2026-10-23

Run isolated Swift, native-resource, public-fixture, retained-console and landing tests here.
Backend integration and cross-implementation qualification are platform-owned.
Never point tests at production or overwrite a running provider's state.

`ClusterAPIParityTests` runs real loopback standalone and distributed HTTP
handlers over fabricated engines for seven model-family fixtures. It compares
all stable JSON/SSE fields and translated engine requests, including scalar
stops, `min_p`, captured logprobs and reasoning usage. Only generated IDs and
timestamps are normalized; no capability fields are removed. The capture-capable
fixture supplies fixed logprob events explicitly. Strict streaming comparison
covers multiple content tokens and every frame field. SDK `EventBoundLogprobsTests`
queues the producer's entire output before consumption, checks event-to-frame
association, empty-text holdback, parser flushes, terminal failures, cancellation,
collected completeness and the 4096-entry pending bound. Reasoning/tool source
spans remain unclassified; those entries retain the existing next-content policy.
A separate unsupported-profile case requires HTTP 400 before reservation and
successful text afterward. Run
`swift test --package-path provider-swift --filter ClusterAPIParityTests` with
the [provider build prerequisites](build.md). These CPU checks prove API wiring,
not native model capabilities, numerical parity or hardware qualification.

The placement checks also cover exact family request scopes, completion-heavy
and long-prompt helper plans, overflow refusal, conservative memory refusal and
unchanged GLM adapter bounds. Run `libs/darkbloom-cluster/Tests/PlacementChecks/run.sh`
and `provider-swift/Tests/ClusterPlacementChecks/run.sh`; then run
`provider-swift/Tests/ClusterPlacementChecks/run-flow.sh` for the real child-process
provider path with a fake installed helper. These checks use recorded metadata
and CPU arithmetic; they do not load models or run the real device index.


`MeasuredShardRateChecks.swift` in the same placement suite covers exact measured
half/quarter points, severe served slowdowns through calibration and replanning,
unchanged ordinary/unmeasured predictions, and invalid speed-record refusal.
Its rates are constructed CPU test inputs; they make no hardware speed claim.

The Bonsai 9B qualification CLI accepts the exact base-r2 manifest and uses its
artifact's Qwen chat template with thinking disabled. Run
`python3 libs/darkbloom-cluster-worker/Tests/PromptChecks/check_bonsai9.py /ABS/darkbloom-cluster-pair-check /ABS/MODEL_METADATA`
with the built pair tool and verified tokenizer metadata. It generates real
requests, checks literal wrapper and artifact-template token parity, preserves
the wrapper at exact lengths through 32,768 tokens, and refuses crossed model
IDs or changed manifest/tokenizer files. It reads no model weights and runs no
GPU work. `QualificationChecks/run.sh` also covers Bonsai 9B's own profile,
structural cuts, arithmetic environment, context limits and lane cancellation.
Its timeout row uses conservative estimates until hardware rates are measured.

Automatic local batching's CPU checks run with
`provider-swift/Tests/ClusterInstalledSessionChecks/run.sh` and
`provider-swift/Tests/ClusterConfigurationChecks/run.sh`. They cover persisted
lane widths through real sanitized child launches, exact setup hashes,
supervisor PID/start/expiry fencing, stale follower refusal, actual canonical
store adoption and byte-exact partial-write compensation. The placement suite
also checks whole-model state multiplication, overflow and unchanged singleton
plans. These checks do not establish reload latency or hardware batch speed.

## Prerequisites

For the Bonsai 9B cluster adapter, select `ResidentAdmissionBonsai9Tests` and
`Bonsai9StagePreparationTests` together with the existing
`ResidentAdmissionBonsaiTests`. They bind the public configuration, manifest,
header and transform metadata, cover every cut and crossed-identity refusal,
and prepare both SDK stage models as CPU lazy shells. They never read model
weight payloads or prove hardware arithmetic; file-backed numerical comparison
and paired-worker runs remain separate qualification gates.

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
opt-in refuses target-only GLM before any load state exists. The pure
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
- `scripts/prepare-mimo-image-http-fixtures.py` downloads hash-pinned metadata
  and creates deterministic PNGs for actual HTTP image ingress. Both ordinary
  provider CI and SDK release qualification prepare these before the full suite;
  GitHub applies the emitted environment variables to the following test step.

```bash
FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/darkbloom-test-fixtures.XXXXXX")"
python3 -B scripts/prepare-mimo-provider-fixtures.py --output "$FIXTURE_ROOT/provider"
python3 -B scripts/prepare-mimo-prompt-fixtures.py --output "$FIXTURE_ROOT/prompt"
python3 -B scripts/prepare-mimo-image-http-fixtures.py --output "$FIXTURE_ROOT/image-http" --github-env "$FIXTURE_ROOT/image-http.env"
export MIMO_CLUSTER_IMAGE_METADATA_DIR="$FIXTURE_ROOT/image-http"
export MIMO_CLUSTER_IMAGE_ASSET_DIR="$FIXTURE_ROOT/image-http"
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
swift test --skip-build --filter 'EngineV2KVQuantizationPolicy|EngineV2DiffusionPrefixPrecision|BenchmarkRuntimeGeneration|RuntimeGenerationBenchmark'
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

### Two-Mac Cluster Checks

The coordinator-wire vectors
`provider-swift/Tests/ProviderCoreTests/Fixtures/coordinator-wire/cluster_registration_vector.json`
and `native_pair_lease_vector.json` pin a cluster member's registration
(signed roster with Secure Enclave pins, device profile with numerics class,
measured edges, inventory and plan digests) and the coordinator's pair lease
frame (member nonce, epoch, generation, renewal payloads and a refused payload).
`CoordinatorWireVectorTests` and `provider-swift/Tests/ClusterPairingChecks/run.sh`
check the provider against them; the platform's own tests must agree. Refresh them only together with the
coordinator change, after review.

The `cluster-member-fixture-child` executable target (`provider-swift/Tests/ClusterMemberFixtureChild/`)
is a CPU-only stand-in for an installed owner and its native child, run by the
native-pair member control tests over the real owner pipe and key prelude. It is
not a product and no release ships it.

Cluster logic that needs no model or GPU is covered by check runners compiled
with isolated fixture runners: each `provider-swift/Tests/Cluster*Checks/run.sh`,
`libs/darkbloom-cluster/Tests/*Checks/run.sh` and
`libs/darkbloom-cluster-worker/Tests/*Checks/run.sh` prints its pass count and
exits non-zero on a failure. The library's XCTest targets
(`swift test --package-path libs/darkbloom-cluster`) and the worker package's
tests (built for macOS 26.2) need the GPU and exclusive device access. A
loopback or fixture pass never counts as a two-Mac hardware pass.

Most runners compile a model-free source closure with `swiftc`. Worker
`CapabilityChecks` and the worker argument portion of `PrefillScheduleChecks`
link the actual runtime catalog, including MLXLLM metadata dependencies. These
entrypoints describe pinned metadata and parse arguments only; MLX being linked
does not mean a model or GPU was executed. The [build guide](build.md#cluster-metadata-check-builds)
describes their isolated scratch directory and optional reuse.

`ClusterConsoleChecks`, `ClusterDiagnosticsChecks` and
`ClusterInstalledSessionChecks` resolve `TMPDIR` to its physical path and keep
fixtures there. A checkout in a synced Desktop folder can have file metadata
changed after verification. Keep fixture scratch outside synced folders;
never relax the installed input identity check to accommodate those changes.

`ClusterInstalledSessionChecks` also covers keyed selection and credential
refusal across the registered profiles, then exercises installed startup with
real CPU owners and synthetic worker readiness. Plaintext, unverified and
mismatched reports must remain unroutable and release both owners; matching
verified reports may become ready. These reports do not prove native encryption
or a model load. Run the real two-Mac qualification separately.

The optional pair batch diagnostics use `--batch-trace yes` and
`--batch-logit-directory /private/tmp/<private-run-directory>` with the plain
Qwen pipeline lane path and `--evidence none`. Native rows are captured only on
rank 1 at output ordinals 0, 1, 30, 37, 78 and 88 after normal selection. The
metadata binds each file to the timing report's actual request UUID, output
ordinal, native dtype/shape, batch step, slot, row width and preceding-token
hash. Compare rows only when prompt and preceding-history hashes match; a row
after divergent history cannot classify the original difference. Apply the
existing near-tie predicate unchanged. Missing capture at a first divergence
is unclassified evidence, and diagnostic timings are not performance results.

`QwenBatchDiagnosticsTests` exercises native-byte preservation, history binding,
private paths, collisions, writer locking, capture limits and disabled defaults
with CPU data only. `PairBatchDiagnosticsTests` checks exact worker launch
routing in both rank orders and mode/lane/recording refusals. These checks do
not load a model or qualify its output. Sources:
`libs/darkbloom-cluster/Tests/DarkbloomClusterRuntimeTests/QwenBatchDiagnosticsTests.swift`,
`libs/darkbloom-cluster-worker/Tests/DarkbloomClusterQualificationTests/PairBatchDiagnosticsTests.swift`.

## Focused Qwen3.5 MoE tensor-parallel checks

1. Run the isolated CPU metadata checks from the repository root:

   ```bash
   bash libs/darkbloom-cluster/Tests/TensorParallelPlanChecks/run.sh
   bash libs/darkbloom-cluster-worker/Tests/CapabilityChecks/run.sh
   ```

   The plan check reads the pinned Qwen3.5 and Qwen3.6 configurations, covers
   stored and canonical fused expert banks on both ranks, verifies divided
   tensor coverage and Qwen3.6's replicated affine8 routing gates, and refuses
   unequal candidates and malformed overrides. The capability check verifies
   the registered modes for both routed rows.

2. With the native runtime package built, run the CPU tensor and admission tests:

   ```bash
   swift test --package-path libs/darkbloom-cluster --filter QwenMoETensorParallelTests
   swift test --package-path libs/darkbloom-cluster --filter ResidentAdmissionA3BTests
   swift test --package-path libs/darkbloom-cluster --filter QwenMixedRouterTensorParallelTests
   swift test --package-path libs/darkbloom-cluster --filter ResidentAdmissionQwen36A3BTests
   ```

   `QwenMoETensorParallelTests` compares canonical cuts against separate halves
   for weights, scales and biases, rejects malformed ranges, and checks the
   exact product-row/share gate. `QwenMixedRouterTensorParallelTests` constructs
   tiny CPU models with independently quantized affine4 experts and affine8
   routing gates, loads both stored and canonical banks, and compares native
   BF16 full-model outputs exactly. Both rank loaders must construct without
   executing collectives, and malformed divided overrides must fail before
   reading tensors. These fixtures do not establish cross-rank numerics or
   execute the registered weight payload.

3. Qualify the installed pair using numerical `ReferenceReport` output from
   `darkbloom-cluster-reference` and product pair-check runs with
   `--mode tensor-parallel --tensor-shares 1:1 --evidence none`. Use pair-check
   `record` for the existing acceptance rules. Pair-check `solo` emits timing
   data and cannot replace a numerical reference. Preserve both rank orders,
   long-context, cancellation and memory-release checks. CPU metadata success
   does not establish this hardware gate or a speed improvement.

The [routed-expert TP architecture](../architecture/inference.md#qwen35-routed-expert-tensor-parallel)
states the arithmetic descriptor and supported scope.

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
`FlintNativeProtocolTests` and `FlintNativeProtocolFactoryTests`; SDK suites
are `FlintTests`, `FlintToolTests`, `FlintPrefixTests` and
`ToolCallParserIntegrationTests`. `FlintToolChoicePromptPolicyTests`
(`provider-swift/Tests/ProviderCoreTests/Inference/Prompting/FlintToolChoicePromptPolicyTests.swift`)
pins exact-type native framing, original messages, named filtering and invalid
tool requests against the pinned template. The SDK fixture is generated independently by
`libs/mlx-swift-lm/scripts/generate-flint-oracle.py` with NumPy and credits the pinned mlx-vlm
oracle. Numeric assertions retain their declared tolerances and run with
`MLX_ENABLE_TF32=0`.

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
`DARKBLOOM_FLINT_BACKEND` selects `contiguous` or `paged`.
`DARKBLOOM_FLINT_RECEIPTS` optionally writes synthetic response evidence to an
owned file. Keep these model-dependent checks separate from tiny-fixture,
public-CI and signed-release evidence.

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

## Cluster onboarding UI checks

Run `bash provider-swift/Tests/ClusterOnboardingChecks/run.sh` from the repository
root for model-free pseudo-terminal checks of setup stages, menu selection,
failed test responses, terminal restoration and plain output. Set
`ONBOARDING_TRANSCRIPTS` to a private output directory to retain screen text.
The harness compiles only the onboarding flow, terminal and scripted operations;
it does not configure a network port, start a service or load a model.

`ClusterOnboardingPeerLabelTests` checks the live adapter with injected pairing
facts: fresh authenticated peer labels replace saved display names, changed
peer identity refuses reuse, and saved serving intent remains unchanged. Run
that filter with the provider test setup described above. These checks do not
prove macOS authorization, Recovery changes, TCC approval or installed-service
behavior.

## Finite GLM terminal-status schedule

Select `GLM5NextCalibrationTerminalStatusRaceTests` in an isolated CPU test
process with `DARKBLOOM_GLM_METADATA_BINDING_REQUIRED=1` and the existing required
metadata fixture inputs. Supply the source-matched CPU helper through
`DARKBLOOM_GLM_DISPATCH_CPU_CHILD` and
`DARKBLOOM_GLM_DISPATCH_CPU_CHILD_SHA256`; the fixture verifies its bytes before use.
See `provider-swift/Tests/ProviderCoreTests/Inference/Distributed/GLM5NextCalibrationDispatchRunFixture.swift`
(`init`) and `provider-swift/Tests/CalibrationDispatchCPUChild/main.swift`.

The test pauses a real driver after its terminal status sample, allows the other
driver to finish its actual archive sync and close, observes the actual transport
close, then releases the first driver. Both encrypted drivers, actual CPU child
exits, acknowledgment consumption and durable fences must complete. The observer
changes scheduling only; it supplies no status or completion. For a RED/GREEN
comparison, retain identical test/fixture bytes and change only the control
decision under review. Count an actual `terminal transport lost` failure
separately from compilation, fixture setup, watchdog failures and skips.
See the [retirement semantics](../architecture/inference.md#finite-glm-paired-control-retirement).

## GLM cluster prefill gates

Check the [GLM cluster prefill bounds](../architecture/inference.md#glm-cluster-prefill-bounds)
against the frozen composed source before running an isolated test process.
Keep passing, failing and skipped tests separate; missing fixture coverage is
not a pass.

- Geometry/default checks: `ResidualStreamTransportTests` covers authenticated
  logical-array geometry, chunk rejection, bounded record ranges and unchanged
  raw/default limits; `LongContextLimitsTests` checks the explicit GLM chunk
  choice without raising other models' default. Their sources are
  `libs/darkbloom-cluster/Tests/DarkbloomClusterRuntimeTests/ResidualStreamTransportTests.swift`
  and `libs/darkbloom-cluster/Tests/DarkbloomClusterRuntimeTests/LongContextLimitsTests.swift`.
  A range-partition assertion does not execute encryption or a large transfer.
- Metadata/budget checks: supply a verified immutable metadata fixture through
  `DARKBLOOM_GLM_METADATA_DIRECTORY` for
  `libs/darkbloom-cluster/Tests/DarkbloomClusterRuntimeTests/GLM5NextServingMetadataTests.swift`
  (`largerChunksChargeWholeResidualsAndRejectStaleWorkspaceScope`). It checks
  registered text/image layout agreement, whole-boundary charges and refusal of
  stale workspace scope. Synthetic allowance equality does not measure peaks;
  the envelope test also queries actual device allocation bounds.
- Composed-source gates: run calibration authorization/binding and
  provider-to-worker quote tests for the finite scope, plus
  `provider-swift/Tests/ClusterPlacementChecks/PlacementSetupCheck.swift` for
  short-prompt preference rejection, artifact matching, both chunk caps and
  explicit-limit preservation. Old quote/binary identity and overbound controls
  must still refuse.

Native qualification additionally requires a real full-size encrypted residual
round trip with byte/shape equality and bounded sealed frames, active/missing/
invalidated data-plane controls, then paired serving and cancellation/fault
retirement. Test availability alone does not establish execution. Measure
per-rank native high-water and host wire/assembly peaks through normal peer
acknowledgement and retirement, including cold dense DSA, later sparse DSA and
cache-growth boundaries under the actual serving policy. Retain the conservative
workspace until evidence matches its complete scope. Private image and MTP
execution need separate coverage; CPU geometry/metadata checks do not qualify
them or establish production readiness or throughput.

## GLM cluster still-image checks

Run `bash libs/darkbloom-cluster/Tests/StillImageChecks/run.sh` for isolated
Foundation/CryptoKit protocol checks. The script compiles in a unique temporary
directory and never links MLX or touches a model or provider state. It checks
malformed/overflow bounds, source/pixel/span commitments, marker ownership,
video refusal, codec round trips, nil omission, profile and route refusal.

Metadata-only GLM image tests in
`libs/darkbloom-cluster/Tests/DarkbloomClusterRuntimeTests/GLM5NextClusterImageMetadataTests.swift`
cover PNG geometry, animation and rank-specific LOAD/workspace accounting.
CPU checks do not establish native output parity, memory peaks, cleanup or
paired cancellation. The parent qualification owner must build the frozen
composition, select the candidate through
`darkbloom cluster local glm-5.3-flash --private-glm-image-qualification` and test
still-image HTTP serving, changed-pixel controls, chunk-boundary spans, repeated
text/media isolation, paired retirement and cancel/fault cleanup on both ranks.

## Restricted-umask update and encrypted GLM fixture checks

Run `SelfUpdaterTests` with an isolated installation root and inherited
`umask 077`. Keep the exact `0755` fan-helper assertion and existing bundle,
hash, symlink and rollback checks; the extraction child must not change the
parent's mask or weaken archive-path checks.

`GLM5NextEncryptedCheckpointTests` funds the MTP-enabled fixture from its actual
bounded assistant allocation quote at 1536 inputs, in addition to the existing
64MiB target allowance and unchanged admission watermark. Both parameter arms
and protected-import cancellation must execute. Preserve 1024-token restore/logit
parity, positive MTP metrics and confirmed retirement with zero outstanding
budget. A quote equality assertion is not execution evidence; use the rebuilt
provider tests and normal isolated native-test lane.

`ClusterServiceAgentTests` covers Local Network app attribution, replacement
of older unassociated jobs, symlinked CLI entry points and unbundled tools.
`ClusterConsoleChecks` preserves the socket failure in setup/lease diagnostics.
Live qualification must close both setup terminals and check lease stability
and follower connections in both role orientations; a foreground SSH success
alone does not qualify detached background serving.


## GPT-OSS cluster paged KV checks

Run the metadata budget check and the CPU cache parity tests from the repository
root. The latter use real SDK cache objects and CPU MLX arrays; no model weights,
GPU inference or pair are required:

```sh
bash libs/darkbloom-cluster/Tests/GPTOSSStageChecks/run.sh
swift test --package-path libs/darkbloom-cluster -c release \
  --filter GPTOSSPagedKVTests
```

`GPTOSSPagedKVTests` compares exact rows, masks, offsets and learned-sink SDPA
results with `StandardKVCache` and `RotatingKVCache`. It also checks demand
allocation, bounded sliding retention, copy/trim isolation and owner release.
`GPTOSSStageChecks` checks each page's allocator overhead and sliding repack
charge. These are CPU correctness checks, not native transport, MXFP4 model
parity or performance evidence. Retain the existing two-Mac reference comparator
and retirement checks for hardware qualification; see
[the cache mechanism](../architecture/inference.md#gpt-oss-cluster-paged-kv).

## GPT-OSS native dtype checks

Run `swift test --package-path libs/darkbloom-cluster -c release --filter GPTOSSNativeDTypeTests`
and `bash libs/darkbloom-cluster/Tests/GPTOSSStageChecks/run.sh` from the repository root.
The CPU tests construct small deterministic models with MXFP4 experts, affine
8-bit projections and learned sinks, compare split forwards with the whole
model in BF16 and float32, and check prefill/decode cache types across a sliding
window. They also bind the registered BF16 profile and actual wire bytes while
preserving conservative memory charges. These tests do not load the registered
weight payload or establish hardware numerical qualification. See the
[native dtype contract](../architecture/inference.md#gpt-oss-native-residual-dtype).

## Qwen batch projection arithmetic

`libs/mlx-swift-lm/Tests/MLXLMTests/Integration/Qwen/Qwen35BatchDecodeProjectionTests.swift`
checks the actual Qwen-owned helper on the CPU: logical native bytes against
individual forwards, linear biases, tied heads, Hadamard transforms/layout,
custom overrides, supported packing, and explicit decode scope restoration.
`libs/darkbloom-cluster/Tests/DarkbloomClusterRuntimeTests/QwenBatchArithmeticAgreementTests.swift`
checks the unchanged singleton/default agreement and the multi-lane arithmetic
marker. These checks establish no model, GPU, transport or throughput result.

Numerical qualification must separately compare native bytes across one and
multiple rows on each target GPU, then compare model logits/recurrent state
and paired tokens with distinct histories and row permutations. Keep private
row capture disabled in speed runs. A projection-only sweep cannot replace
full-model artifact qualification or justify changing the installed lane
default.

## Installed batch-lane propagation checks

Run `bash provider-swift/Tests/ClusterInstalledSessionChecks/run.sh`. The CPU
runner compiles the actual local-owner launcher, installed plan/session and
member-installation code. `InstalledBatchLanesCheck.swift` launches a real child
with the fixed owner arguments and checks its exact environment, supported
lane widths, out-of-range rejection, malformed-override parity even with an
eight-lane family default, admission/owner/native parity, unsupported
mode and image gates, and both member ranks. No model, GPU or real service is
started. The checks preserve the singleton and GLM tensor-parallel defaults;
actual multi-lane output, encrypted transport and retirement still require
qualification on both Macs.

### Gemma per-request decode equality

With the pinned native dependencies built as in [build](build.md), run the
`Gemma4BatchDecodeTests` and `Gemma4BatchArithmeticAgreementTests` filters in
`libs/darkbloom-cluster`, and `Gemma4BatchDecodeProjectionTests` in
`libs/mlx-swift-lm`. The model fixture explicitly runs on CPU and compares
logical native bytes, without tolerance, for every logit and live KV value.
It uses widths 2/4/8, both registered quantization patterns, distinct histories,
ring wrap, reordered rows, leaving/rejoining requests, and token/embedding
entry points. It also rejects nonfinite output or state. Projection tests
cover bias, tied heads, custom-module dispatch, unsupported packing fallback,
and disabled/prefill/singleton scopes. Agreement tests preserve other-family
and singleton bytes.

`Gemma4StagePagedSyntheticTests` additionally requires batched stage logits
to equal each request's solo logits. That larger native fixture and actual
artifact GPU/pair throughput validation are separate from the tiny CPU suite.

### Qualification bundle alias checks

Run `python3 -I scripts/tests/test_cluster_bundle_pair_qualifications.py`.
The temporary-directory checks use explicitly synthetic input records and
verify that the exact registered Gemma plain/8-bit alias pair retains both
original identities and lines, regardless of ordering or duplicate input.
Wrong aggregates, unrelated or additional IDs remain refused without changing
the previous output. These tests grant nothing and do not replace real
cross-cable records for each runtime identity.


## GPT-OSS native batch prerequisite checks

Use the SDK revision containing `GPTOSSPerRowAttentionCache`, then run from the
repository root with a source-matched metallib available to the test bundle:

```bash
swift test --package-path libs/darkbloom-cluster -c release \
  --filter 'GPTOSS(BatchForward|NativeDType|PagedKV)Tests'
```

The batch CPU fixture uses the registered native BF16 contract, MXFP4 experts
and affine8 projections; non-BF16 batches refuse before advancing any cache.
The ordinary scalar dtype suite retains both BF16 and F32 coverage. The batch
fixture compares different prompt chunk grids, unequal absolute
positions, wrapped sliding windows and changing decode membership against
independent ordinary SDK executions, including exact cache bytes and inactive
request state. Refusal cases must leave caches unallocated and unadvanced.
These checks cover the SDK hook and the native batch primitive, not live worker
lanes, GPU batch arithmetic, aggregate memory admission, cancellation or useful
throughput. Follow [the architecture boundary](../architecture/inference.md#gpt-oss-independent-history-batch-forward)
before enabling concurrency.

## GPT-OSS batch owner checks

Run the actual two-rank scheduling driver and native primitive on CPU, then the
worker policy and fixed installed-child environment checks:

```bash
swift test --package-path libs/darkbloom-cluster -c release \
  --filter 'GPTOSSBatch(Driver|Settings|Forward)Tests|QwenBatchSelectionTests'
swift test --package-path libs/darkbloom-cluster-worker -c release \
  --filter 'GPTOSSWorkerBatchSettingsTests|WorkerLaneTests|WorkerLaneJoinReproductionTests|WorkerQwenCancellationTests|PairBatchCancellationTests|PairBatchDiagnosticsTests'
bash provider-swift/Tests/ClusterInstalledSessionChecks/run.sh
```

`GPTOSSBatchDriverTests` uses the production driver, request frames, lane book
and serialized headers/replies on both ranks. Deterministic native/data-link
substitutes cover mixed histories, delayed joins with pending token credit,
accepted-start cancellation, follower cancellation, deadlines, clean stops and
cleanup-failure charge retention. `GPTOSSBatchSettingsTests` checks LOAD binding,
mode bounds and whole per-lane accounting including retained lookahead terms.
The installed check launches a real fixed-environment child for the GPT-OSS
plan and compares provider/child/native widths, paging policy and cancellation.
These checks do not replace native GPU or full-artifact owner/throughput proof.
Use the source-matched GPU fixture and installed candidate on both target Macs
before treating an explicitly selected multi-lane configuration as qualified.

### Tensor-parallel failed-shape checks

Run `bash provider-swift/Tests/ClusterInstalledSessionChecks/run.sh`.
`InstalledTensorQualificationCheck.swift` decodes immutable metadata from the
2026-10-23 Qwen3.6 16K cross-cable failure and its passing reverse orientation.
It checks TP-only decision construction, planner/start refusal, both local rank
guards using actual installed Plan objects, and preservation of pipeline/hybrid
cuts. Existing installed checks retain GLM default behavior. These CPU checks
exercise refusal logic and do not rerun or replace the model qualification.


### Pending HTTP requests across native mode replacement

`DistributedAutomaticBatchPlannerTests` exercises the replacement planner's
actual decision with owner-only recorded link and served-speed files. It checks
that a measured keyed reduction reaches TP selection, foreign/stale/non-private
measurements retain fallback, served costs reach calibration, and the real
helper child receives `device --json --index`. These are CPU metadata checks;
they do not execute models or claim measured batch throughput.

The current-fit case prices descending widths 8, 4 and 2 with constructed
bilateral pressure and checks that a hardware-possible width cannot pass the
current admission predicate. `libs/darkbloom-cluster/Tests/PlacementChecks/run.sh`
also checks complete simultaneous LOAD/request coexistence and a smaller
allocator ceiling independently of OS memory. These checks preserve the native
thresholds; an installed automatic two-Mac run must separately prove successful
replacement, actual batch widths and recovery.

```bash
cd provider-swift
swift test --filter DistributedAutomaticBatchPlannerTests
```

`DistributedLocalServerBatchReplacementTests` exercises the real host, bridge and loopback listener with fabricated model-free sessions. It covers widths two/four/eight, owner ACK before preparation, preserved pending response and listener, disconnect during loading, original queue expiry, failed-start release before fresh rollback, changed request-contract refusal, unresolved cleanup, stop during deferred factory preparation, and rejection of an unexpected actual lane count. A blocked read-only planner
also reproduces a short burst draining before its proposal returns: the next
real burst consumes the retained intent without a second planning call. Tests
cover expiry and fresh planning, no reload with an empty queue, disconnected
pending work, stop during planning, teardown of a ready intent, generation
binding and unchanged cleanup-before-load. Run it with `DistributedLocalServerTests` and `DistributedRequestQueueTests`; none loads model payloads. Native two-Mac mode switching and throughput require separate hardware evidence.

### GPT-OSS registered projection arithmetic

Run the SDK integration suite on CPU and the native batch suite against the
same SDK revision:

```bash
swift test --package-path libs/mlx-swift-lm -c release \
  --filter GPTOSSBatchDecodeProjectionTests
swift test --package-path libs/darkbloom-cluster -c release \
  --filter 'GPTOSSBatch(Forward|Settings)Tests'
```

The projection fixture constructs deterministic packed affine8/group64 BF16
arrays with the registered Q, KV, output, router and full vocabulary-head
shapes. Widths 1, 2, 4 and 8 compare candidate bytes to original singleton
forwards and also count ordinary wide-forward differences. Custom modules,
unsupported packing, singleton calls and prefill retain their original entry
points. The agreement test rejects the former wide-projection arithmetic
binding while preserving single-lane binding. CPU equality does not prove GPU
kernel equality: execute the same frozen fixture on each target GPU, then
repeat full-artifact paired output, cancellation and throughput qualification.

### Native stage observation policy

`StageBatchObservationTests` covers both ranks' shared scope, bounded increasing
width evidence, pre-work and out-of-capacity rejection, suppressed counter reads,
reservation versus materialized backing, unavailable contiguous allocation, and
truthful failed or non-drained retirement. These CPU tests verify the reporting
policy; two-Mac full-model qualification must still show actual completed native
width and paged growth followed by retirement counters for each worker generation.

## MiMo independent-history batch checks

Build with the SDK's explicit `MiMoV26IndependentHistoryCache` and
`decodeIndependentHistories` seam, then run:

```bash
swift test --package-path libs/mlx-swift-lm -c release \
  --filter MiMoV26IndependentHistoryTests
swift test --package-path libs/darkbloom-cluster -c release \
  --filter 'MiMoBatch(Driver|Settings)Tests|GPTOSSBatchDriverTests'
swift test --package-path libs/darkbloom-cluster-worker -c release \
  --filter PairBatchCancellationTests
bash provider-swift/Tests/ClusterInstalledSessionChecks/run.sh
```

The SDK CPU suite compares page/ring order, chunk masks, wrapped-copy isolation,
actual BF16 affine8/MXFP4 logits, residual boundaries and every live KV byte
against ordinary singleton forwards. It covers widths 1, 2, 4 and 8, distinct
histories, membership reorder/removal, tied and untied heads, split stages and
refusal before mutation. Ordinary SDK cache validation remains unchanged.

The shared model-free owner fixture retains all seven GPT-OSS scheduling cases
and adds actual MiMo reservation specializations for mixed histories,
cancellation, deadlines and failed-cleanup charge retention. Accounting checks
include unequal K/V widths, per-page allocator rounding, every lane's complete
state plus host history, and bounded shared workspace. The installed check
launches a real child and compares effective provider/lease/native width across
plain and unsupported modes. These are separate from model execution.

Synthetic GPU parity on each host does not establish full-artifact paired
output equality or performance. Validate encrypted widths, survivor equality
after cancellation, live page growth, synchronized retirement and useful
throughput with the exact candidate and catalog artifact before qualification.
The new page path applies to every normal plain-pipeline owner, including a
single lane. MTP, phase handoff and media paging remain separate qualification
work; automatic normal serving must use the proven paged plain-pipeline mode
until their rollback/handoff paging has its own proof. Ordinary SDK reference
execution remains available for diagnostic contiguous-versus-paged comparisons.

### Native family batch quote checks

Run `bash libs/darkbloom-cluster/Tests/PlacementChecks/run.sh` and
`bash provider-swift/Tests/ClusterConfigurationChecks/run.sh`.
`NativeBatchQuoteChecks.swift` uses authentic GPT-OSS/MiMo configurations and
the real metadata budgets to compare every admitted stage against the quote,
including paged supplements and shared workspace. It tests typed width/chunk
binding, full-envelope growth, hostile bounds before allocator work, underbound
refusal and actual planner charges on both ranks. Existing singleton golden
plans and unpriced/GLM refusal checks remain. Configuration fixtures exercise
persisted widths 2/4/8 for both ranks of these families. These are CPU metadata
checks, not native arithmetic, paged ownership or throughput passes.

### Gemma paged prefix and prompt checks

Run the `CBv2PagedPrefixRestoreTests` native test filter with a matching
metallib on each Mac. It restores sliding tails at frontiers 511, 575, 1100
and 4095 with a 512-token write bound, compares exact KV bytes before and
after continuation, and checks release and invalid-input refusal. The
installed-session fixture in `provider-swift/Tests/ClusterInstalledSessionChecks/run.sh`
checks actual sanitized child settings for Gemma widths 1/2/4/8 and the
explicit contiguous diagnostic. These do not replace full-model pair tests.

Run `python3 libs/darkbloom-cluster-worker/Tests/PromptChecks/check_gemma4.py
/ABS/darkbloom-cluster-pair-check /ABS/TOKENIZER_FIXTURES` as one command
against exact catalog tokenizer metadata. It checks all three Gemma aliases,
actual artifact chat-template parity and fixed 1K/4K/16K/32K request boundaries.
The qualification wrapper includes the artifact's newline after `<bos>`;
existing request files must be regenerated into a fresh evidence directory.

## Bonsai packed FP32 row checks

`HadamardLayerTests.testBonsaiFloat32RowsMatchSingletonPackedArithmetic` in
`libs/mlx-swift/Tests/MLXTests/HadamardLayerTests.swift` compares multi-row
FP32 calls with independently evaluated singleton calls, including grouped
gated-delta layouts, optional bias, and prefill widths 511 and 512.
`Float16ConstantCastTests` covers repeated calls, parameter and descriptor
replacement, compiled state replacement and ineligible policies.
`BonsaiRowArithmeticTests` in
`libs/darkbloom-cluster/Tests/DarkbloomClusterRuntimeTests/BonsaiRowArithmeticTests.swift`
binds the registered 27B receipt change while retaining the 9B receipt exactly.

Run the MLX suites with CPU as the explicit default device for a bounded
arithmetic check, and with GPU only in an exclusive hardware window. Run
registered-artifact projection diagnostics on both architectures under the
unchanged product environment, retaining output bytes, source/binary hashes
and warmed cost measurements. The candidate must match independent singleton
outputs; full-model solo/pair qualification still uses the original numeric
comparator, original schedules and retained pre-change reports. Projection
checks alone establish neither full-model equivalence nor performance.

## Nemotron prefix chunk checks

`NemotronPrefixChunkTests` in
`libs/darkbloom-cluster/Tests/DarkbloomClusterRuntimeTests/NemotronPrefixChunkTests.swift`
checks cold prefix-on frame equality with the original request across chunk
and prompt boundaries, exact restored suffix shapes, off-grid refusal,
existing-grid capture, other-family framing, and the changed numerical receipt.
`PrefixCacheContractTests` adds actual bilateral choice/confirmation coverage
for resident and SSD grid hits, empty caches and restore failure. These CPU
checks execute no weights or transport. Hardware qualification must retain
old failures and rerun the affected pair and solo reports with the original
comparator; frame equality alone is not numeric full-model proof.

## Gemma prefix chunk checks

`GemmaPrefixChunkTests` in
`libs/darkbloom-cluster/Tests/DarkbloomClusterRuntimeTests/GemmaPrefixChunkTests.swift`
executes the shared production request policy for all three registered Gemma
profiles, including final-layer tail thresholds and chunk boundaries through
32K prompts. It checks original cold frames, restored suffixes, grid captures,
off-grid refusal, the changed Gemma receipt and unchanged Qwen/Bonsai/GLM
framing. CPU checks do not establish model-level agreement: rerun prefix-on
full-artifact qualification and keep the separate cross-chip negative evidence.

## MiMo paged speculative and phase checks

Run `MiMoV26MTPPagedHistoryTests` and `MiMoV26IndependentHistoryTests` in the
SDK integration suites, then `MiMoPagedPhaseStateTests`,
`MiMoPagedModelHandoffTests`, `MiMoPagedAdmissionTests` and
`MiMoBatchSettingsTests` in the cluster runtime. The runtime tests live in
`libs/darkbloom-cluster/Tests/DarkbloomClusterRuntimeTests/`; the SDK tests live
in `libs/mlx-swift-lm/Tests/MLXLMTests/Integration/MiMo/`.

Use an explicit CPU device for the bounded fixtures. Actual packed BF16
model forwards cover a producer with both full and sliding attention, byte
transfer into fresh pages, original/kept/adopted continuation rows and every
cache byte. Cache tests cover wrapped rings, rollback 0...3, malformed late
layers and refusal before recipient mutation. The trained-head tests compare
accepted draft counts 0...3 and subsequent drafts against contiguous replay,
including compaction, measured page ownership and release. Admission tests
retain the prior envelopes, every page bound, phase handoff, and the target's
verification width on both ranks even with a one-token prompt chunk.

The unchanged unquantized BF16 routed-target legacy cases require GPU GatherMM;
CPU-only runs must identify those excluded cases explicitly. Packed BF16
fixtures execute on CPU. Source-matched both-host GPU and full-artifact MTP,
compact and phase runs remain separate gates, with existing references and
numeric tolerances unchanged. The CPU checks do not prove transport, installed
worker loading or artifact throughput.

The SDK integration suite `Gemma4PrefillProjectionTests` compares BF16 affine4/8
prompt projections with actual singleton calls at chunk boundaries, checks
explicit scope restoration and unsupported/custom fallbacks, and verifies the
unchanged tied head. `Gemma4PrefillExpertTests` executes the actual Gemma decoder, router,
shared MLP and sparse expert block with the attention output isolated to zero;
it assembles an independent projection/expert oracle while preserving the
original rectangular normalization and elementwise operations, and compares
selected routes across prompt boundaries. A separate expert-only composition
check compares complete singleton calls with the shared branch isolated to
zero. Ordinary and verification paths remain covered. These checks do not
claim whole-layer singleton equivalence: existing normalization can depend on
rectangle shape on CPU.
`GemmaPrefillArithmeticTests` in the runtime target verifies that both exact
policies change the receipt while the family environment and chunk policy
remain bound. These CPU checks do not establish full-model cross-chip qualification
or throughput.

The placement suite retains the exact Qwen3.8 27B visual header fixture in
`libs/darkbloom-cluster/Tests/PlacementChecks/Inputs/qwen27-vision-budget.json`.
`QwenVisionResidencyChecks` verifies all 333 independently bounded allocations,
inventory and configuration corruption, decoded invalid charges, strictly
additive TP rank memory, working-set refusal, and unchanged pipeline/legacy
behavior. It uses metadata only and is not a model or media execution test.

### Qwen media carrier checks

Run `bash libs/darkbloom-cluster/Tests/QwenMediaChecks/run.sh` for the actual
Foundation-only protocol/codec checks, then
`bash libs/darkbloom-cluster/Tests/ProtocolChecks/run.sh` for existing text and
worker-message regressions. The media suite verifies round trips, metadata-only
peer identity, nil omission, prompt/span and geometry identity, byte/raster
bounds, malformed/duplicate fields, and checked memory arithmetic. These checks
do not decode media, load a model, run MLX or establish visual capability.

Qwen native media coverage includes `QwenNativeMediaSeamTests` and
`QwenNativeMediaForwardTests` in SDK Integration/Qwen, plus native
`QwenMediaStateTests`, `QwenMediaPreparationTests` and
`WorkerQwenMediaAdmissionTests`. They check processor precedence and preallocation
grids, request-local axes/deltas, vision-only tiny wrapper parity, serial loading,
malformed-cache refusal, live producer custody, memory overflow and fail-closed
worker dispatch. CPU tensor execution does not prove CoreImage/AVFoundation
rasterization, the full registered tower, cross-Mac feature transfer, or endpoint
media concurrency. Those require separate paired hardware evidence.

Qwen media forwarding is covered by `ClusterQwenMediaForwardingTests`, which
round-trips both encoded and metadata-only envelopes through owner and peer-link
clock translation. `bash libs/darkbloom-cluster/Tests/ProcessChecks/run.sh
--owner-only` runs the actual child/owner checks, including rank-specific media
bytes, cancellation before start, early-release refusal and idempotent release
after retirement. It runs no model or MLX code; it does not replace the full
provider contract or hardware suites.

### Qwen27 tensor-parallel native batch checks

Run `QwenTensorParallelBatchDriverTests`, `QwenTensorParallelBatchBudgetTests`
and `QwenTensorParallelBatchSettingsTests` in the Runtime test target for
bilateral scheduling/retirement, canonical inventory pricing and exact keyed
model admission. Run `QwenTensorParallelBatchSessionTests` with the matching SDK
for physically sliced native attention, greedy ties, seeded mixed sampling,
raw logprobs, reordered histories, nonfinite refusal and resource-release retry.
The default execution is CPU; the production hybrid recurrence requires Metal.

For its tiny attention/hybrid fixture, set `QWEN_TP_BATCH_GPU=1` and run separately
with `QWEN_TP_BATCH_KV=contiguous` and `QWEN_TP_BATCH_KV=paged` on both chips.
Keep source, binary and Metal resources identical and retain negative logs.
These tests use local ordered reductions, synthetic tensors and synthetic
media positions/features. They do not exercise RDMA, the registered tower or
actual artifact, installed owner capacity, warm prefixes or TP speculation.
Full model/reference, media, concurrency, throughput and logical-retirement
checks remain required.

### Qwen cluster media provider ingress checks

`DistributedQwenMediaIngressTests` runs the actual ImageIO/AVFoundation and Qwen
processor path on deterministic red/blue PNG and short MP4 fixtures. It checks
single/multiple images, video, repeat isolation, expanded prompt bounds, metadata
identity and refusal before native reservation. It also drives the real scheduler,
bridge and distributed engine with explicitly fabricated native leases, proving
routing, usage and independent completion/cancellation cleanup without claiming
physical peers or model answers. The JSON/schema regression traverses the actual
scheduler, media preprocessing and bridge into `MLXOpenAIService`; fabricated
native tokens prove positive JSON responses, schema rejection and unchanged
retirement. It observes the shared format instruction reaching the tokenizer.
These results establish response plumbing, not model-generated schema accuracy.

`DistributedQwenMediaLifetimeTests` and `DistributedQwenMediaHostMemoryTests`
cover the two ownership fences, stale generation/request identity, cancellation,
failed cleanup retention, bounded arithmetic and process-ledger reservations.
The SDK's `CBv2QwenClusterCarrierTests` proves an opaque cluster envelope cannot
fall through to a local model or allocate KV state. Run the focused provider
classes with the repository provider test runner, and the SDK integration class
with `xcodebuild test -scheme mlx-swift-lm-Package -destination 'platform=macOS'`.
Stage the matching Metal library even for MLX CPU-device execution. These checks
load no language-model weights; full-artifact TP image/video and concurrent
capability acceptance remain separate.

### Automatic Qwen27 TP width checks

Run `libs/darkbloom-cluster/Tests/PlacementChecks/run.sh` for exact-width ledger
validation, unchanged measured mode ranking, keyed-link and failed-shape gates,
and per-rank memory refusal. Run
`provider-swift/Tests/ClusterInstalledSessionChecks/run.sh` for saved widths,
actual sanitized child propagation, cancellation policy, raw-logprob support,
other-model refusal and unchanged GLM defaults.
`libs/darkbloom-cluster/Tests/DarkbloomClusterRuntimeTests/QwenTensorParallelBatchQuoteTests.swift`
uses actual registered headers with a sparse zero payload to compare the public
metadata helper against native owner budgets at every admitted share and width.
It proves metadata accounting without reading or qualifying weight payloads.
Full-artifact TP batching, RDMA, media, warm-prefix and throughput checks remain
separate hardware gates.

### Qwen27 TP warm-prefix checks

`QwenTensorParallelBatchPrefixTests` checks original-grid boundaries, bilateral
misses, media/key isolation, allocator rounding and bounded LRU eviction. The
real-shard `QwenTensorParallelBatchSessionTests` compares cold and restored
outputs plus attention/conv/SSM state at widths 2, 4 and 8, mixed positions,
reordered decode and one-sided cache loss. Run it with both contiguous and
paged backends; production recurrent kernels require the Metal invocation
listed above. `QwenTensorParallelBatchDriverTests` checks that donation follows
both ranks' cleanup while the lane charge is still held, and that cancelled or
failed lanes cannot donate. The registered-header quote test must continue
matching the exact native LOAD budget. Full-artifact warm reuse and speed are
separate paired-hardware gates.

### Qwen27 feature-preserving placement

Run `cd provider-swift && swift test --filter DistributedAutomaticBatchPlannerTests` for the actual provider mode-policy boundary. Constructed CPU profiles compare a cheaper pipeline against identical TP cost inputs, require explicit refusal on absent/unkeyed/stale/foreign link records, missing shard geometry or memory, and retain the other dense-model and GLM behavior. A real temporary configuration store loads an old pipeline record, refuses its startup/resave, then replans and saves TP without rewriting the old record. Actual bridge-factory tests reject missing/mismatched READY and absent logprob support before model-metadata reads. These tests run no models and establish no hardware speed or native TP concurrency result.

### Metal cross-stream fence chains

The pinned core's `metal_fence_chain` CTest target checks exact GPU-to-CPU-to-GPU
chains and released request arrays at command-buffer limits 8, 50 and 1024.
Each process has a 60-second timeout. Run the core's configured Metal tests
with `ctest --test-dir build -R '^metal_fence_chain_' --output-on-failure --no-tests=error`.
This component check does not reproduce or qualify an installed RDMA model;
repeat the installed provider's automatic cluster flow and concurrent API
requests on both Macs after a native pin change.
