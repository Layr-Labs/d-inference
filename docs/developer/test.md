# Test Provider And Native Contracts

> Last updated: 2026-10-29

Run isolated Swift, native-resource, public-fixture and landing tests here.
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

### Download completion ownership

After rebuilding the provider test products, select
`StreamingFileDownloadDelegateTests` through the isolated provider test runner.
The suite cancels a real suspended `URLSession` task before attaching its waiter,
checks both completion orders and duplicate terminal callbacks, races attachment
against completion, and verifies that cancellation preserves the exact received
`.part` bytes. Fixtures use unique temporary directories and never resume a
network task or load model weights. These component tests do not qualify live
HTTP downloads or model serving.

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
from the same fixture: the bridge's logprob events must carry one entry per
generated token with the requested alternatives, the row must not draft, and a later
plain request must still speculate. Beside a concurrent plain row, a ten-step
logprob row must carry the entries it carries alone and leave the plain row's
text unchanged. Without a flag, `GLM5NextRelayLogprobsTests` replays scripted
GLM tokens through the production coordinator handler and frames loop
(`ScriptedCoordinatorRelay`): a mixed reply and a reply that ends while
reasoning, requested streamed and not, must carry one entry per generated token
in generation order (none for the mixed reply's stop token), reasoning tokens on
the reasoning chunks and the marker and answer tokens on the content chunks; a
request without logprobs carries none, and another model type keeps
content-chunk attachment. In the SDK,
`GLM5NextMTPTests/protectedPagedEngineCapturesLogprobRowsOffSpeculation` and
`protectedPagedEngineServesALogprobRowBesideAPlainRow` compare the captured
values with the target's own log-softmax for serial and rectangular
verification. `NativeOutputControlRefusalTests` keeps the typed 400 for
native engines that do not capture logprobs (MiMo). The pure
`GLM5NextLocalQualificationTests` cover selection, retained-byte charges and
the KV rate derived from the pinned architecture evidence.

The same flag runs `verifiedDigestExistsOnlyAfterEveryManifestFileVerified`:
the load reports the manifest aggregate only after every file verified, equal to
a `WeightHasher` pass, and a same-size corrupted shard leaves it unset. With
`DARKBLOOM_TEST_GLM5_PROTECTED_FACTORY=1`, `GLM5NextProviderLoopTests` loads
through `ProviderLoop.ensureModelLoaded` and checks that no load-time
`WeightHasher` pass runs, the live hash is the aggregate, and the
`VerifiedWeightHashStore` record matches the files. `VerifiedWeightHashStoreTests`
and `RegistrationWeightHashTests` need no flag. `scripts/run-provider-tests.sh`
points `DARKBLOOM_VERIFIED_WEIGHTS_FILE` at its isolated state directory.

`scripts/benchmarks/glm_load_timeline.py` turns a provider log into a phase
timeline (weight-hash passes, the GLM load's verification and tensor phases,
shape warmup, listener); `python3 -m unittest discover -s scripts/benchmarks -p
test_glm_load_timeline.py` checks it against a recorded M5 Ultra start.

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
`reasoningContextRendersEveryGoldenLikeItsClearThinkingSpelling` replaces each
golden's `clear_thinking` with OpenRouter's equivalent `reasoning.context` and
must still match it byte for byte; `currentTurnReasoningContextRendersLikeClearThinking`
and `reasoningContextContradictingClearThinkingIsRefused` cover the current
turn and the refused contradictions.
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
capture. `openRouterSecretWordReasoningReturnIsServed` serves OpenRouter's
secret-word `reasoning-content-return` turn (a `get_time` call whose returned
reasoning holds the word) with each reasoning carrier, the strict declaration,
empty-string arguments and `reasoning.context`/`reasoning.mode`; the reasoning
must render in the call's thinking block. The scripted completions prove the
provider's withholding and validation, not the model's compliance; that needs
the real-model run in `GLM5NextRealArtifactQualificationTests`.

`GLM5NextRealLogprobsQualificationTests` qualifies logprobs on the real GLM
checkpoint through the production bundle and the `EngineV2Bridge` logprob events
the coordinator relay consumes. It needs the
`GLM5NextRealModelHarness` variables (`DARKBLOOM_TEST_GLM5_REAL_MODEL_DIR`,
`DARKBLOOM_TEST_GLM5_REAL_RESULTS_DIR`, `DARKBLOOM_TEST_GLM5_REAL_SOURCE_REPO`,
`DARKBLOOM_TEST_GLM5_REAL_SOURCE_REVISION`,
`DARKBLOOM_TEST_GLM5_REAL_AGGREGATE_SHA256`, `DARKBLOOM_EXPERIMENTAL_GLM5_NEXT`,
`DARKBLOOM_CBV2_MTP=1`) plus `DARKBLOOM_TEST_GLM5_REAL_LOGPROBS=1`. A greedy
32-token `top_logprobs: 5` request at the template-default effort, which opens
with reasoning tokens (`reasoningPositions`; at low effort GLM closes the thought
at once), must return one entry per token, never draft, equal the same row submitted to the raw engine, and match a
teacher-forced dense-cache log-softmax along its own tokens within the larger
of `DARKBLOOM_TEST_GLM5_REAL_LOGPROBS_TOLERANCE` nats (default `5e-2`) and two
bf16 spacings of the step's largest logit. A logprob row decodes one-token
target steps, so the MTP greedy stream may leave it only at a reference
near-tie. Batched with a plain row on another prompt, the logprob row keeps
its chosen values within the same bound and its alternatives within
`DARKBLOOM_TEST_GLM5_REAL_LOGPROBS_BATCHED_TOLERANCE` nats (default `1.0`),
every alternative is a reference top-8 token, and every plain token is the
reference argmax up to a near-tie; the plain row drafts again after the
logprobs row finishes. Batch width alone moves GLM's non-top logits: the run
also scores the reference as two identical rows and records its drift from
the one-row reference (`pairedReferenceMaxDrift`, 0.56 nats on an M3 Ultra).
The engine must end without a native fault or retained load. Results go to
`logprobs-qualification.json` in the results directory. The model directory
must hold regular files; a Hugging Face snapshot of symlinks fails with
`regular file required`.

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

## Prompt Preparation And Admission

```bash
swift test --skip-build --filter 'PromptTokenCacheTests|ChatTemplateLoopRewritesTests|InboundChatRequestDecodeTests|ServeLoopColdLoadTests'
```

`PromptTokenCacheTests` loads synthetic tokenizers through the production
`LocalTokenizerLoader` for the Qwen split, GPT-2 byte-level and Gemma metaspace
pre-tokenizer families, with no download, and requires piecewise, cached and
cross-turn token IDs to equal the unchanged path. Cache-generation regressions
require hits present at batch-lookup entry to be returned in request order,
including duplicate keys and genuine misses across multiple rotations. They
check exact byte accounting and subsequent eviction, and ensure batches without
old-generation hits preserve cached entries. A marker template that only the
served loop renders, or raises for, checks that a background comparison
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

## Desktop Control And Frontend

`make desktop-test` exercises the frontend journeys and bridge validation.
Run `npm test -- --maxWorkers=4` in `desktop-app/` to bound UI-test concurrency
while compiling Swift. `desktop-app/tests/previewRuntime.test.ts` exercises
local-preview process startup, duplicate-start suppression, shutdown, persistent
state, startup failure, and signature rejection using isolated executable
fixtures; `desktop-app/tests/previewSigning.test.ts` covers propagation of the
exact certificate fingerprint when electron-builder supplies its display name.
Check the signed packaged app separately using the
[desktop preview procedure](desktop-app.md#signed-local-preview).

`make desktop-api-test` runs the compiled Swift CLI API with a temporary config,
model cache, credentials, daemon state, discovery directory, and local catalog
(`scripts/test-desktop-api.py`). It checks that release reads share the existing
latest-release API, earnings use the existing ledger window parameter, a
credential change rejects an in-flight private response, authenticated insights
are relayed, decimal strings are preserved, and account-session revisions change.
The fixture never starts a serving provider or changes its credentials.
`DesktopControlTests` and the `DeviceCodeLogin` suite cover native authentication
and account separation. Activity and earnings checks are described in the
[desktop verification guide](desktop-app.md#verify).

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

`ModelCheckpointConversationLiveTests`
(`provider-swift/Tests/ProviderCoreTests/Inference/Live/PrefixQualification/ModelCheckpointConversationLiveTests.swift`)
is the opt-in real-model observation of one growing conversation. It reads the
same standalone specification (only its model, precision and `outputTokens`)
and an isolated ephemeral cache, requires native live and checkpoint precision,
and refuses MiMo. Six turns grow from 30,000 tokens by 5,000 tokens each. Each
turn is served with the prompt it shares with the previous turn as the
repeated-prefix hint, as an agent loop's next turn would be. Per turn the
report records TTFT, restored tokens, the gap from the last token to the
terminal (which waits for checkpoint publication) and the files and bytes the
complete-checkpoint store wrote, the delta files and the greedy output tokens;
`DARKBLOOM_PREFIX_CACHE_SSD_INCREMENTAL_CHECKPOINTS=0` gives the complete-file
baseline to compare against. It fails only when a turn after the first
restores nothing. `DARKBLOOM_CHECKPOINT_CONVERSATION_STAGE_MB` sets
`DARKBLOOM_PREFIX_CACHE_SSD_MAX_STAGE_MB` for the run, for example `1024` to
compare against the large-memory complete-checkpoint default. The timings need
exclusive GPU use:

```bash
env -i HOME="$HOME" PATH="$PATH" TMPDIR="$TMPDIR" \
  DARKBLOOM_PREFIX_EXCLUSIVE_GPU=1 \
  DARKBLOOM_CHECKPOINT_CONVERSATION_BENCHMARK=1 \
  DARKBLOOM_PREFIX_MODEL_SPEC=/absolute/model-spec.json \
  DARKBLOOM_CHECKPOINT_CONVERSATION_OUTPUT=/absolute/new-report.json \
  swift test --skip-build --disable-automatic-resolution \
  --filter ModelCheckpointConversationLiveTests
```

GLM-5.3-Flash and Nemotron 3.5 Super always serve with MTP and load through
their own managed paths, so `ModelCheckpointStorageLiveTests` cannot select
them. Their checkpoint profiles have dedicated opt-in qualifications:
`GLM5NextRealCheckpointProfileTests`
(`provider-swift/Tests/ProviderCoreTests/Inference/Models/GLM5Next/GLM5NextRealCheckpointProfileTests.swift`)
and `NemotronSuperManagedSlotTests/pinnedCheckpointCheckpointProfileQualification`
(`provider-swift/Tests/ProviderCoreTests/ProviderLoop/NemotronSuperManagedSlotLiveTests+CheckpointProfile.swift`).
Each process runs one storage arm. Run `native`, then `balanced`, from the same
optimized test build (`swift build -c release --build-tests -Xswiftc
-enable-testing -Xswiftc -DDEBUG`, then the staged metallib) with exclusive GPU
use and a fresh isolated store per arm:

| Model | Selection | Prompt lengths | Report |
|---|---|---|---|
| GLM | the `GLM5NextRealModelHarness` variables plus `DARKBLOOM_TEST_GLM5_REAL_CHECKPOINT_PROFILE=native` or `balanced` | `DARKBLOOM_TEST_GLM5_REAL_CHECKPOINT_LENGTHS`, default `2048,8192,32768`; the dense reference runs up to `DARKBLOOM_TEST_GLM5_REAL_CHECKPOINT_REFERENCE_MAX` tokens (default 40,000) | `checkpoint-profile-<arm>.json` in the harness results directory |
| Super | `DARKBLOOM_SUPER_MANAGED_LIVE=1`, `DARKBLOOM_SUPER_CHECKPOINT_PROFILE_LIVE=1`, `NEMOTRON_SUPER_CHECKPOINT_DIR`, `DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL=1`, a fresh `DARKBLOOM_PREFIX_CACHE_TEST_ROOT` and `DARKBLOOM_CBV2_CHECKPOINT_QUANTIZATION=native` or `balanced` | `DARKBLOOM_SUPER_CHECKPOINT_LENGTHS`, default `2400,8400,32000` (checkpoints sit at whole 2,048-token chunks) | `DARKBLOOM_SUPER_CHECKPOINT_PROFILE_OUT` |

Each prompt asks for a fact placed a fifth of the way into a generated fact
document, inside the profile's coded rows. Per length the report records cold,
donor, restored, repeated, another tenant's, cancelled-after-first-output and
after-cancel runs (answer, finish, TTFT, restored tokens, stage), the donor's
bytes and file sizes, the restore's stage time, and restored and cold logprob
rows against teacher forcing along their own tokens: GLM against the dense
reference under `GLM5NextRealLogprobsQualificationTests`'s bounds, Super against
`EngineV2.teacherForcedScores` under its 0.35-nat bound. GLM also records the
profile's reconstruction error on the reference prefill's latent rows. A run
fails when a restore reads nothing, a repeat or after-cancel restore covers a
different depth, another tenant hits, or a cold, donor, restored, repeated or
after-cancel answer is wrong or truncated. Super's speculation is deterministic,
so it also fails when the donating export changes the donor's output or a restore
of the same file differs. Compare the two arms' reports for equal restored
coverage, bytes, TTFT and logprob deltas; one process cannot.

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

## Add-On Hold

These suites need no downloaded model weights, credentials or live provider
state. The socket and loop tests bind a real `AF_UNIX` socket and take a real
`flock` in a private temporary runtime directory. The load-fence and managed
Super cases load synthetic tiny weights through MLX, so they need the staged
test metallib.

```bash
swift test --skip-build --no-parallel \
  --filter 'AddonIPCTests|AddonHoldDrainOwnershipTests|AddonHoldStoreTests|AddonPeerPolicyTests|AddonIPCServerTests|AddonHoldLoopTests|AddonHoldServeLoopTests|AddonHoldLoadFence|anAddonHoldRetiresTheSuperSlotButKeepsItsPreloadPlan|aFIFOInPlaceOfARequestIsIgnoredWithoutBlocking|ProviderBusyWireTests|AddonCommandTests|AutopilotBusyReasonTests'
```

| Coverage | Suites |
|---|---|
| `hold.v1` parsing, limits, exact response keys; drain-owner precedence | `AddonIPCTests`, `AddonHoldDrainOwnershipTests` |
| Owner-only record, a FIFO record refused without blocking, lock probe, runtime paths; the real peer policy refuses the test process | `AddonHoldStoreTests`, `AddonPeerPolicyTests` |
| Socket permissions, several requests per connection, oversized and unfinished lines, peers refused when accepted so silent ones cannot fill the slots, stale and live sockets | `AddonIPCServerTests` |
| Unload of every model, kept preload set, idempotency, bounded drain that cancels only its own stragglers, update and reconnect cannot reopen, stop takeover, lease expiry with and without the lock, restart restore, operator mailbox | `AddonHoldLoopTests` |
| A real tiny-model load running when the hold begins never installs, the hold waits for it, and loads resume after release | `TinyModelLoadTests/AddonHoldLoadFence` |
| The managed Super slot's own retirement keeps the preload plan; a FIFO mailbox file is refused without blocking | `NemotronSuperManagedSlotTests`, `LifecycleMailboxTests` (filtered cases above) |
| Loopback coordinator: draining heartbeat with busy fields, no `provider_drain`, 503 draining rejection, planned reconnect keeps the hold in `register`, release heartbeat | `AddonHoldServeLoopTests` |
| Heartbeat and both register encodings | `ProviderBusyWireTests` |

The peer check is exercised only negatively: no signed add-on is available to
the test runner, and a test authenticator stands in for it in the socket and
serve-loop flows. Physical add-on interoperation remains a separate check.

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

`fixtures/prompt-contract/v1/production_vectors.json` is regenerated only in
darkbloom-platform, by its prompt sidecar at an explicit revision. This
repository copies the file byte-for-byte and records the source revision and
SHA-256 in the commit. A provider change to the rendered prompt, such as the
Qwen JSON `response_format` thinking default, lands with the regenerated
vectors and must pass `scripts/verify-prompt-parity.sh` before review.

darkbloom-platform keeps byte-identical copies of the provider's
`paged_footprint_wire.json` and `process_memory_wire.json` for its own
coordinator and console tests. Coordinate fixture changes with the platform and
run each implementation's checks in its owner repo.
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
exits non-zero on a failure. The CI job `test-cluster-checks` (Cluster Metadata
Checks, `.github/workflows/ci.yml`) runs five of them on every pull request that
changes provider code: `libs/darkbloom-cluster-worker/Tests/CapabilityChecks/run.sh`,
`libs/darkbloom-cluster/Tests/StageMetadataChecks/run.py`,
`libs/darkbloom-cluster/Tests/GPTOSSStageChecks/run.sh`,
`libs/darkbloom-cluster/Tests/NemotronStageChecks/run.sh` and
`provider-swift/Tests/ClusterModelProvisioningChecks/run.sh provisioning`. The
last one runs the provisioning checks only. Its download cache-policy check
reads how many written pages stay in the file cache, which the host's kernel
and disk decide: on the hosted CI VM 0.75 of the pages written with
`F_NOCACHE` stayed resident. Run `run.sh` with no argument on a Mac for that
check. The library's XCTest targets
(`swift test --package-path libs/darkbloom-cluster`) and the worker package's
tests (built for macOS 26.2) need the GPU and exclusive device access. A
loopback or fixture pass never counts as a two-Mac hardware pass.

Build the runtime tests once (`swift build --package-path libs/darkbloom-cluster
-c release --build-tests --triple arm64-apple-macosx26.2 -Xcc -target -Xcc
arm64-apple-macosx26.2 -Xswiftc -enable-testing`), stage the source-matched
`mlx.metallib` in the test bundle's `Contents/MacOS/`, and run `swift test`
with the same flags plus `--skip-build --no-parallel`. Without environment
switches the run evaluates synthetic models on the GPU by default; the GPU-only
cases (`QWEN_TP_BATCH_GPU=1`, `QWEN_TP_MTP_GPU=1`, `QWEN_TP_MOE_GPU=1`,
`QWEN_TP_AQV_GPU=1`) run each in a process of their own with their filter. On
an M5 GPU MLX computes float32 matrix products in TF32 unless the process
starts with `MLX_ENABLE_TF32=0` (`libs/mlx-swift-lm/CONTRIBUTING.md`): the
forward comparison in `GLM5NextStageSessionTests` asserts a float32 tolerance
and is skipped without it. `StageLoadRealSamplerTests` reads this Mac's own
counters; its kernel file-cache minimum check is cancelled, with the figure it
read, when the pageout scan does not run during its four-second window.

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
   swift test --package-path libs/darkbloom-cluster --filter QwenMoETensorParallelPackingTests
   swift test --package-path libs/darkbloom-cluster --filter ResidentAdmissionA3BTests
   swift test --package-path libs/darkbloom-cluster --filter QwenMixedRouterTensorParallelTests
   swift test --package-path libs/darkbloom-cluster --filter ResidentAdmissionQwen36A3BTests
   ```

   `QwenMoETensorParallelTests` compares canonical cuts against separate halves
   for weights, scales and biases, rejects malformed ranges, and checks the
   exact product-row/share gate. `QwenMoETensorParallelPackingTests` runs two
   real ranks (two threads summing each other's float32 elements in rank
   order, each submitting to its own MLX stream because the default stream is
   process-wide and thread-unsafe) of a tiny routed model through a sorted
   40-token prefill and greedy steps, with the shared expert packed into the
   expert collective and with its earlier separate collective: every logit
   must be bit-identical on both ranks, with two collectives a layer against
   three. `QWEN_TP_MOE_GPU=1` adds the GPU variant (the test bundle needs
   `mlx.metallib` beside it); `QWEN_TP_MOE_MODEL=<registered A3B directory>`,
   with an optional `QWEN_TP_MOE_REQUEST=<qualification request JSON>`, runs
   the same comparison on the artifact's real shards on the GPU, both ranks in
   one process. `QwenMixedRouterTensorParallelTests` constructs
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
python3 scripts/test-darkbloom-route.py
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
`scripts/test-release-dev-branch.py` pins the dev-branch lane
(`.github/workflows/release-dev-branch.yml`). The only trigger is a push to
`dev`, with the `paths:` list of the `release-swift.yml` master push. The lane
has no dispatch, no input and no `ref:`. Its one job checks `refs/heads/dev` and
only calls `release-provider.yml` with `environment: dev` and `secrets: inherit`.
The caller names no secret and has no step, so it has no build or signing path
of its own. In `release-provider.yml`, every secret read without a prod or
staging guard is a `DEV_*` secret or one of the five Apple signing secrets, and
those are read only in the signing job. The signing job signs with the
Developer ID, notarizes, staples and verifies the fan helper against the
Apple-team requirement; nothing signs ad-hoc. These CPU-only checks do not
prove Apple runtime behavior.

`scripts/test-provider-release-publication.py` creates isolated local Git tags
with verbatim annotations, including multiline opening paragraphs, extra blank
lines, CRLFs and synthetic SSH/PGP signature armor. It checks exact retained note
text and payload/provenance digest guards without invoking signing or live
publication.

`scripts/test-provider-release-pipeline.py` and
`scripts/test-provider-release-resolution.py` pin the routing of
`.github/workflows/release-swift.yml`. A master push publishes staging only, and
only when `STAGING_ENABLED` is `true`. A tag publishes prod. No master path
publishes dev: the dispatch has no `dev` choice, the `dev` lane runs only as an
unpublished signed validation build, and the resolver refuses a dev publication
from master and a master push routed to dev. A push to `dev` resolves to
`X.Y.Z-dev.branch.N` for `dev` only; `staging`, `prod` and other branches are
refused. `scripts/test-provider-release-resume.py` pins the source gate: a dev
push needs environment `dev` and a verified commit on `dev` ancestry, and the
tag, master push and dispatch rows keep the master checks. The pipeline test
pins the final-app check against the self-updater's designated requirement.

`scripts/test-darkbloom-route.py` runs the actual
[CI runner routing](build.md#ci-runner-routing) shell step against a loopback
HTTPS plane with a throwaway certificate; the host needs Bash, Python, jq, curl
and openssl. It covers the default-off switch, fork pull requests, exact label
grants, HTTP errors, the single retry, timeouts, untrusted or plain-HTTP planes
and hostile reply text. It also pins each routed job's fallback, timeout and
read-only permissions, and keeps release workflows on literal Blacksmith
runners. No check contacts the real plane.

Docs-impact tests retain provider, protocol, privacy, native capacity, cache,
release/model publication and fixture mappings. Historical links need exact
provenance. Final full-tree lint needs intended additions/removals
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
Developer and contact coverage checks browser/RSC 404s, explicit and negotiated
Markdown, agent discovery links, and their absence from human navigation and
the XML sitemap.

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

## Constrained JSON answers

After rebuilding the provider test product and staging its metallib, run the
CPU-only JSON-answer suites from `provider-swift/` together with the Flint suites
whose automaton they share:

```bash
../scripts/run-nested-suite.sh 'QwenJSONAnswer(Constraint|Policy|Output|Serving)Tests|FlintResponseFormat|FlintNativeProtocol|FlintAnswerStop' --no-parallel
```

`QwenJSONAnswerConstraintTests` drives the production constraint over a
synthetic Qwen-shaped vocabulary: single bytes, the pinned terminators and think
markers at 248044, 248046, 248068 and 248069, and no piece for any other id up to
248,320. It covers both prompt phases, masked EOS, schema violations, forbidden
spellings, mask/transition agreement, token splits, bounded states and the
pinned tokenizer checks. `QwenJSONAnswerPolicyTests` checks eligibility and
every prompt-only fallback through `ToolConstraintFactory.make`, and
`QwenJSONAnswerOutputTests` the completed-output validation.
`QwenJSONAnswerServingTests` samples a scripted engine through the real bridge
and scheduler: streamed content, a typed 422 on truncation, requested reasoning
split before validation, and unchanged tool and other-family paths.

`QwenJSONAnswerRealTokenizerTests` is opt-in. Set
`DARKBLOOM_TEST_QWEN_TOKENIZER_DIR` to a local Qwen 3.5, 3.6 or 3.8 snapshot
directory and select that suite alone; it reads only tokenizer and template
files, checks the pinned contract and both rendered JSON prompt tails, and walks
a real tokenization of an answer. Without the variable the suite is skipped,
which the nested runner reports as an error. None of these suites loads weights
or establishes answer quality or throughput. Sources:
`provider-swift/Tests/ProviderCoreTests/Inference/Tools/QwenJSONAnswerConstraintTests.swift`,
`provider-swift/Tests/ProviderCoreTests/Inference/Tools/QwenJSONAnswerServingTests.swift`,
`provider-swift/Tests/ProviderCoreTests/Inference/Tools/QwenJSONAnswerRealTokenizerTests.swift`.

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
`logprobs`/`top_logprobs` and `seed`. `FlintRelayLogprobsLiveTests` (same gate; optional
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
before installing. `NemotronSuperOpenRouterVideoTests` runs OpenRouter's two
readiness clips (the SDK's `MiMoOpenRouter` resources, read through the source
tree) through the body bound, request parsing, inspection, the pinned
template's prompt, the media plan and every sampled frame's decode, then
serves both on the tiny installed fixture. `NemotronSuperVideoDecodeTests` covers the decoder's
refusals on synthesized clips (decoded-pixel budget, codec, second track,
zero-duration frame), per-frame validation, the decode allowance, reader
cancellation and the container type hint.

The managed slot is covered by `NemotronSuperServingPolicyTests` and
`NemotronSuperMediaChargeTests` (identity, discovery, image advertisement, load
plan, footprint, media charge and capacity quotes; CPU only) and
`NemotronSuperManagedSlotTests` (fixture load through `ProviderLoop`, encrypted
coordinator and local-endpoint text and image requests on the speculating
owner, logprobs on both paths without a draft, and relayed thinking-on replies,
mixed and ending while reasoning, with one entry per generated token on
reasoning or content chunks; an image beside speculating text, media refusal
before allocation, cancellation, admission refusal and retirement).
`toolCallReplyCarriesTheSameLogprobsOnEveryPath` checks that the relay, the
local stream and the local complete response carry identical entries for
thinking-on replies that call a tool: only the reasoning and answer tokens'
when the call ends the reply, and every entry before a newline that follows
the call. `NemotronSuperLocalOutputTests` checks the same selection for a
complete response without a model (`NemotronSuperCompleteLogprobs`). The local
hook's `liveHTTPTextReasoningToolsAndStructuredOutput` checks streamed and
complete logprobs on the tiny installed fixture for a mixed reply and one that
ends while reasoning, with entries on the stream's reasoning chunks, and none
without `logprobs`, and the
SDK's `NemotronSuperMTPMediaFallbackTests` checks a logprob row's tokens and
logprobs against the plain owner's while a text row beside it speculates
([logprob rows](../architecture/inference.md#nemotron-super-logprobs)). Three gated cases need the
pinned checkpoint: `NEMOTRON_SUPER_CHECKPOINT_DIR` alone checks its discovery
and that the recorded LOAD constants equal the SDK quotes over every verified
shard (hashes about 75 GB, loads no weights); adding
`DARKBLOOM_SUPER_MANAGED_LIVE=1` loads the full checkpoint (about 80 GB) through
the production loader, once to serve an encrypted text request and once for PNG
and JPEG questions and an image beside a text request.
`pinnedCheckpointLogprobsMatchTeacherForcing` (same gate) checks relay logprobs
against the engine's and, at every step the relay served, against a cold
prefill of the prompt and the tokens before it, twice: with thinking off up to
the end of turn, and with thinking on for a 48-token reply that ends inside
reasoning, whose 48 entries must all ride reasoning chunks. Each served value
must be within 0.35 nats of the reference, and the served token the reference
argmax unless the reference prefers another token by at most 0.7 nats, a swap
two values within the bound allow.
`DARKBLOOM_SUPER_LIVE_MTP=off` runs it on a plain owner and
`DARKBLOOM_NEMOTRON_SUPER_PREFILL_CHUNK=1` prefills one token per step, which
makes the reference bitwise equal to the served values. Run them only with exclusive GPU access.

`NemotronSuperOpenRouterCapabilityTests` replays OpenRouter's capability-test
shapes, built from the captured tool request the platform's conformance fixture
pins, with reasoning enabled and disabled: tool-call steps 1 and 5, every
`tool_choice`, `json_object`, strict `json_schema` and JSON formats with tools.
Each passes the relay's inbound decode, the request plan, the pinned template
and the output parser, and a compliant response validates streamed and
complete. CPU only; it does not load a model or measure answer quality.

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
it does not configure a network port, start a service or load a model. CI runs
it in the `Cluster Metadata Checks` job (step `Run cluster onboarding checks`).
Its rows include the end of the setup after the cluster registers with the
coordinator: the screen waits for both parts to serve again before it says
Done (`leaderWaitsForThePartsAfterTheRegistration`).

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
qualification on both Macs. The same real-child checks pass canonical local
`MLX_METAL_FAST_SYNCH=0|1` choices through the owner and final native launch,
reject free-text spellings from forwarding, preserve unrelated native guards,
and keep absent/default and non-TP behavior unchanged. They do not establish
Metal progress; require fresh bilateral native startup markers and completed
batch retirement in the installed synchronization comparison.

The actual-child and final-native tests also exercise canonical local
`MLX_EAGER_FENCE_COMMIT=0|1`, malformed values, combined fast/eager choices,
unchanged GLM defaults and exclusion from pipeline launches.
`WorkerEagerFenceCommitTests` checks that the startup reporter describes only
explicit canonical TP choices and does not mutate the environment. The real
worker StartupChecks cover the marker against a missing model directory. These
checks prove propagation only; they do not establish a faster or stall-free
collective path.

Run `swift test --package-path libs/darkbloom-cluster-worker --filter WorkerCollectiveSynchronizationTests`
for the startup policy checks. `WorkerCollectiveSynchronizationTests` exercises the actual startup policy and
runtime lane parser without loading a model or opening a Metal device. It checks
Qwen27 capacities 2...8, omitted/single capacity, malformed lanes, launcher
precedence and every other catalog entry and generation mode. The actual worker
checks in `libs/darkbloom-cluster-worker/Tests/StartupChecks/run.sh` verify startup
markers and malformed-lane refusal against a missing model directory. These
checks do not prove native progress or output equality: the installed product
must still complete concurrent two-row TP decoding and clean retirement on both
Macs, followed by the unchanged full capability and output checks.

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
measurements retain fallback, served costs of the pair's own worker build reach
calibration while another build's (or a record without a build) do not, and the
real helper child receives `device --json --index`. These are CPU metadata checks;
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
truthful failed or non-drained retirement. Per-width step tests cover repeated and
decreasing widths, zero-work and failed scopes, exclusion outside a live valid scope,
and exactly one final summary with unchanged bounded logs and memory reads. These CPU tests verify the reporting
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

## Cluster prefix tenant partition checks

The request's prompt-prefix partition (`ClusterWorkerPrefixCache`) is covered
at every layer it crosses:

| Layer | Check |
|---|---|
| Codec, bounds, default absent | `bash libs/darkbloom-cluster/Tests/ProtocolChecks/run.sh` (`prefixCache` group) |
| Owner and peer-link hops | `ClusterPrefixCacheForwardingTests` through `bash libs/darkbloom-cluster/Tests/RemoteChecks/run.sh` |
| Fingerprint, scope helper, resident keys | `PrefixTenantScopeTests` (CPU) |
| Stage SSD records | `PrefixDiskTierTests.aTenantsRecordsAreFoundOnlyUnderThatTenant` |
| Qwen TP batch owner, both tiers | `QwenTensorParallelBatchSessionTests.partitionedPrefixesNeverCrossTenantsAndADisabledRequestKeepsNothing` (CPU; with `QWEN_TP_BATCH_GPU=1` on Metal) |
| GLM pipeline and GLM TP caches | `GLM5NextPipelineGenerationTests.promptPrefixesArePartitionedByTenantAndKeptNoneWhenOff`, `GLM5NextTensorParallelPrefixCacheTests.entriesAreHeldOnlyForTheirTenant` (synthetic artifact, Metal) |
| GLM TP SSD record scopes | `GLM5NextTensorParallelPrefixDiskTests.aRequestsRecordsAreItsOwnPartitions` (CPU) |
| Qualification request files | `QualificationRequestPrefixCacheTests` in the worker package |
| Provider owner and bridge | `DistributedPrefixPartitionTests`, `GLMPairForcedOutputTests.thePrefixCacheFieldsReachThePairReservation`, `DistributedHTTPCompletionTests.localRequestsReachThePairWithTheCacheOnAndNoSalt` |

On the pair, `darkbloom-cluster-pair-check request --request-prefix-cache
off|tenant:SALT` writes a request with that partition (the file holds only the
salt's digest); a repeat under another tenant must report no reused tokens.
These are synthetic checks: tenant isolation on a real model and pair, and GLM
bit-identity with no partition, are hardware gates.

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
clock translation. `ClusterReservationRelayTests` (run by
`bash libs/darkbloom-cluster/Tests/RemoteChecks/run.sh`) sends one reservation
per media carrier (still images, MiMo images, GLM media, Qwen media), each with
sampling and a prefix partition, and a routed text reservation through both
hops and requires each to arrive unchanged but for its deadline.
`PairWorkerEndpointReservationTests` (run
by `bash libs/darkbloom-cluster-worker/Tests/QualificationChecks/run.sh`) sends
the same set through the pair-check driver's `PairWorkerEndpoint` into a
`/bin/sh` stand-in that records its input, and the protocol checks' `retiming`
group compares `ClusterWorkerReservation.withDeadline` with a field-by-field
construction. `bash libs/darkbloom-cluster/Tests/ProcessChecks/run.sh
--owner-only` runs the actual child/owner checks, including rank-specific media
bytes, cancellation before start, early-release refusal and idempotent release
after retirement. It runs no model or MLX code; it does not replace the full
provider contract or hardware suites.

### Qwen27 tensor-parallel native batch checks

Run `QwenTensorParallelBatchDriverTests`, `QwenTensorParallelBatchBudgetTests`
and `QwenTensorParallelBatchSettingsTests` in the Runtime test target for
bilateral scheduling/retirement, canonical inventory pricing and exact keyed
model admission. The real paired-driver fixtures stagger owner token credits to
require a two-row decode rectangle, bound a silent owner's delay, and interrupt
credit coalescing for cancellation or deadline retirement. Existing fixtures
keep later joins and prefills moving while an older token credit is withheld.
These CPU scheduling checks do not establish installed native batch width. Run `QwenTensorParallelBatchSessionTests` with the matching SDK
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

### Cluster SSD prefix record encoding checks

`PrefixDiskEncodingTests` (Runtime test target, CPU, synthetic rows) covers
family eligibility, the rank's precision parsing, peers told different
encodings refusing the load's first exchange (local sockets), a round trip
whose older rows equal the SDK reference's and lie within the 4-bit affine
bound while the newest 128 rows stay exact, shallower frontiers, GLM's DSA and
KDA layer caches through a balanced record (only the older latents
approximate), a unit read row by row from a history encoding as the whole
array does, a layer kept native (a speculative head's history) beside encoded
ones, encodings never restored under one another, a root holding both
encodings, refused corrupt, truncated and undecodable records, and the bytes at
the beta models' shapes. Three of its tests cover restored rows written again:
three generations of records, each from the previous one's restore, keep every
restored row bit for bit at every precision and dtype (and a tier without the
earlier record moves them); rows computed rather than restored are encoded as
usual; an earlier record that cannot be read drops the new one. Like every MLX
test in the target it needs the source-matched `mlx.metallib` beside the test
executable. `PREFIX_RECORD_ENCODE_BENCH=1` adds a timing of one 27B rank layer
at 32,768 tokens and of the next record of a longer prompt from its restore.
`QwenTensorParallelBatchSessionTests.ssdBalancedRecordsAdoptOnBothRanksWithAnExactBand`
writes a balanced record through the batch owner and adopts it on both ranks.
`GLM5NextTensorParallelPrefixRecordEncodingTests` writes a GLM tensor-parallel
rank's record through its row readers at the artifact's widths (only the DSA
latents encoded; the NextN history native), adopts it, and keeps the restored
latents' bytes in a deeper record. The SDK's
`NativeCheckpointRowCodecTests.testReencodingDecodedRowsIsIdempotentOnlyForHalfPrecisionValues`
encodes decoded rows again: key rows (every dtype) and FP32 value rows move,
FP16 and BF16 value rows do not on the rows it covers. `GLM53_PREFIX_SSD=1`
adds
`GLM5NextTensorParallelPrefixRestoreTests.aServingStageRestoresFromABalancedRecord`
(GPU, about 1 GB of synthetic weights: real paged histories through a balanced
record, then the restored request prefills on).

On real weights, compare a plain run with a run through a record:

```bash
darkbloom-cluster-tp-check run --mode full --model-dir "$MODEL" --request request.json \
  --record-top 8 --report cold.json
darkbloom-cluster-tp-check run --mode full --model-dir "$MODEL" --request request.json \
  --record-top 8 --prefix-records balanced --report balanced.json
darkbloom-cluster-tp-check compare --reference cold.json --candidate balanced.json
```

The second report's `prefixRecord` holds each layer's errors and bytes and the
prompt tail scored from both states; `--prefix-records native` must reproduce
the first run's tokens. `--mode tp` measures each rank's own shard (no tail
scoring). These synthetic and tool checks do not establish answer quality on
the pair; needle and perplexity comparisons after a restored disk prefix remain
model qualification work.

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
Generated PNGs below the 32-pixel resize factor (16×16, 64×31, 31×64) and at a
201:1 aspect ratio must raise the same `VLMError` from the factory's
`Qwen3VLProcessor` (the single-Mac path) and from the pair's metadata pass,
both answered with the invalid-media 400 and no outstanding host charge; the
scheduler refuses a 16×16 image before any lease, and 32×32 is served with the
single-Mac grid. `EngineV2VisionRoutingTests` pins the same 400 for every
`VLMError` media case on the single-Mac route, and the retriable refusal for a
processor configuration fault.

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
listed above. Its two ranks, like those of `QwenTensorParallelMTPSessionTests`,
run on threads created for each test (`TensorParallelRankThreads`): MLX keys a
compiled function's traces by the calling thread's default GPU stream, not by
the Swift device scope, so on reused worker threads a CPU-mode rank replayed
traces that earlier GPU suites had recorded, and a full-target run reported
cold and restored bytes that differ (`MLX_DISABLE_COMPILE=1` removed the
difference; alone the suite passed). `QwenTensorParallelBatchDriverTests`
checks that donation follows
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

### Qwen27 TP speculative ownership tests

Run SDK `QwenMTPPagedHistoryTests` for paged assistant append/trim/copy/restore and failed-constructor custody. Native `QwenTensorParallelMTPPolicyTests`, `QwenTensorParallelMTPBudgetTests`, `QwenTensorParallelBatchMTPBudgetTests` and `QwenTensorParallelAssistantQuoteTests` check exact inventory, complete singleton/cohort reservations and metadata/native quote equality. `QwenTensorAssistantStartupTests` exercises real bilateral worker arguments; Process `TensorAssistantReadinessCheck` checks real child READY mismatch rejection. Provider `DistributedAutomaticBatchPlannerTests` covers automatic inline discovery, malformed/off cases, complete initial quote and saved-policy preservation through wider replans.

Set `QWEN_TP_MTP_GPU=1` only in an isolated native test run with the matching Metal resource. Run `QwenTensorParallelBatchMTPWindowTests` and `QwenTensorParallelBatchMTPTransitionTests` with `--no-parallel` so suites do not race global MLX state. Actual tiny targets test unequal histories/keep counts, rejected-suffix settlement, greedy target-column continuation, singleton/wider transitions, independent accepted-token credits, survivor retirement, mixed ordinary rows and poisoned-cohort cleanup. The trained head remains single-row; the decoder creates the target cohort. Tied-head transition fixtures do not establish full-model acceptance behavior or sampled equivalence.

Exact drafts (`QWEN_TP_MTP_GPU=1`): `QwenTensorParallelExactDraftRowsTests` runs a round's later draft steps for two to eight requests through one assistant forward (`Qwen35InlineMTPAssistant.draftHiddens`) and checks every row byte for byte against the same request's one-row step, over unequal histories, for two consecutive steps, at the suites' and the 9B's head ratios. `QwenTensorParallelMTPHeadRowsTests.exactDraftProjectionsKeepEachRowsOwnProductAtQwen27Shapes` checks the head and assistant projections at Qwen27's shapes, and `QwenTensorParallelBatchMTPTransitionTests.exactDraftRowsEqualTheirSoloRunsAndThePlainTargetAtEveryWidth` checks that every row of one to eight concurrent requests equals its solo run (tokens, MTP statistics and native state on both ranks) and emits the plain target's greedy tokens, with exact and with MLX drafts, with every proposal accepted and with proposals rejected. `QWEN_TP_ACCEPT_BENCH_MODEL=<model directory> QWEN_TP_ACCEPT_BENCH_PROMPTS=<JSON {"prompts": [[token id]]}>` runs `QwenTensorParallelMTPAcceptanceRealTests`: the real row's two ranks in one process, each prompt decoded plainly and speculatively with each draft kernel; it requires lossless output and reports rounds, tokens per round, acceptance by position and where the two kernels' proposals differ.

Retain the exact executable, imported module/object/resource hashes and all fixtures resolved relative to compiled `#filePath` on each host. These fixtures use an in-process paired reduction and establish neither RDMA nor installed-product qualification. Run full-artifact automatic setup, bilateral READY, ordinary/media/logprob/history requests, prefix reuse, concurrent MTP, cancellation and retirement before a release claim. Compile ProviderCore tests against the actual final product module built with `-enable-testing`; do not reuse a pre-policy test binary with changed contract modules.

### Cluster service stop ordering

`ClusterServiceRecoveryTests.plannedStopWaitsForOwnedServiceChildBeforePeerAndRetainsFailureIntent`
runs the actual service loop with an owned process held after SIGTERM. It checks
that the peer stop is withheld until exit and idle publication, including local
timeout/retry and missing-peer failure. Additional cases cover a recycled PID,
an unavailable live-service publication, and a replacement process that must
not inherit the old stop's authority. `ClusterServiceLoginAgentTests` exercises
the actual CLI completion gate: failed pair retirement cannot uninstall the
service or return success. These are isolated CPU/process tests; native graceful
shutdown still requires a fresh installed two-Mac run.

Focused checks: `swift test --filter ClusterServiceRecoveryTests` and
`swift test --filter ClusterServiceLoginAgentTests` from `provider-swift`.
Sources: `provider-swift/Tests/ProviderCoreTests/Inference/Distributed/ClusterServiceRecoveryTests.swift`
and `provider-swift/Tests/DarkbloomCLITests/ClusterServiceLoginAgentTests.swift`.

The planned-stop lifecycle suite also pauses the actual service immediately before Process.run, then requests stop against its stale idle publication. Rewriting ordinary status with a fresh inode must not release the peer. Only a subsequent real supervision-cycle acknowledgement after child retirement permits success. The private initializer callback is nil in production.

Planned-stop lifecycle checks exercise the actual peerLeaseState projection, accepted ClusterControlNode follower lease, ClusterControlIntent recording and follower part selection while the real owned child is retained after TERM, while start is paused, and after retirement. A held outbound lease custody flag must block final peer stop after local child exit. Optional-record compatibility and an already-idle peer are checked separately. No physical peer transport or installed native shutdown is claimed by these CPU cases.

### Qwen27 capacity consistency checks

Every Qwen TP row serves through these request-owned lanes. `QwenTensorParallelBatchSessionTests`
also runs a dense fixture with the 9B's head ratios (`nineBRatioDenseShardsBatchExactly`) and a
routed-expert fixture (`routedExpertShardsBatchExactly`, `routedExpertNativeMixedSamplingKeepsRowsIndependent`,
with `QWEN_TP_BATCH_GPU=1`): rows decoded together equal their solo bytes on both ranks, and a cohort's
collectives do not grow with its width. `QwenTensorParallelSlicerLayoutTests` checks that every
interior-axis cut is a row-major copy whose quantized products equal the former gather view's, and that
batched decode rows on the cached FP32 constants (`QuantizedLinear.independentRowsForward`) equal the call
that widened them inside the matmul and each row alone. `QwenTensorParallelBatchMTPTransitionTests.nineBRatioAssistantSurvivesCreditJoinsRectanglesAndResumedSpeculation`
runs the resident assistant's transitions on the 9B ratio (`QWEN_TP_MTP_GPU=1`).
`QWEN_TP_MOE_BATCH_MODEL=<registered A3B directory>` runs `QwenTensorParallelRoutedCohortRealTests`: the
artifact's real shards, both ranks in one process on the GPU, rows of one cohort against the same rows
alone, byte for byte. The reference rows in these tests (and the singleton owner of the capacity-parity
tests) evaluate each decode step at once (`QwenTensorParallelBatchSession.layerStride` 0) while the
cohort is submitted layer by layer as the product decodes, so the same comparisons prove that layer
submission keeps every byte. `QWEN_TP_MOE_BENCH_MODEL=<directory>` runs `QwenTensorParallelMoEDecodeBenchTests`,
a one-rank decode profile with no peer: local, CPU-hop and evaluate-each collectives with each step split
into graph build, encoding and GPU wait under 16- and 100-operation command buffers
(`QWEN_TP_MOE_BENCH_OPS`), the retired single-lane loop's pipelining, the sparse block's parts, the step
graph's primitives, the batch path at widths 1, 2 and 4 for each layer-submission stride
(`QWEN_TP_MOE_BENCH_STRIDES`), and a byte comparison of the same rows decoded both ways with every
collective on the CPU stream. Its numbers are one Mac's, not the pair's.

Run `swift test --filter QwenTensorParallelBatchSettingsTests`, `swift test --filter QwenTensorParallelBatchBudgetTests`, `swift test --filter QwenTensorParallelAssistantQuoteTests` and `swift test --filter QwenTensorParallelSingletonHostTests` from `libs/darkbloom-cluster`. These CPU checks cover keyed singleton routing, complete plain/assistant quotations, token credit and the bilateral-retirement completion boundary. Run `swift test --filter DistributedAutomaticBatchPlannerTests` from `provider-swift` for retained-share placement, current-memory refusal and handoff compatibility.

With exclusive GPU custody, run `QWEN_TP_BATCH_GPU=1 QWEN_TP_BATCH_KV=paged swift test --filter QwenTensorParallelBatchSessionTests.capacityOneAndTwoKeepExactPagedLogitsAndHistory` from `libs/darkbloom-cluster`. This synthetic two-rank test compares raw logits and attention/conv/SSM state at capacities one and two; `routedExpertCapacityOneAndTwoKeepExactPagedLogitsAndHistory` repeats it on a routed-expert fixture (`QwenTensorParallelFixtures.routedCheckpoint`). The former single-lane path is retired, so there is no scalar comparison any more. It does not establish full-model installed parity or physical peer transport. The installed run must retain the original singleton output and require exact equality after automatic widening, then verify media, tools, logprobs, cancellation and native retirement on both Macs.

### Tensor-parallel share probe checks

Run `libs/darkbloom-cluster/Tests/PlacementChecks/run.sh` for the share-step
line (`ShareProbeChecks`: one probe in proportion, two on their line, bounded
past them, never anchored on the whole model's step), the share probe history's
bounds, ages, build reset and refused files, served calibration scaling every
share point by one factor, unchanged prefill predictions, and constructed M3
Ultra + M5 Max plans of the 27B that move from the prior's 2:1 to 1:1 on the
measured steps, keep 1:1 after a 1:1 load, and keep a split the M5 Max's memory
holds. Golden plans must stay byte-identical. Run
`libs/darkbloom-cluster/Tests/ProtocolChecks/run.sh` for the ready record's
`shareProbe` round trip, bounds and earlier records, and
`provider-swift/Tests/ClusterInstalledSessionChecks/run.sh` for the owner-only
history file.

From `libs/darkbloom-cluster`, `swift test --filter QwenTensorParallelShareProbeTests`
checks the per-mille share and the probe request's shape on the CPU. With
exclusive GPU custody and the matching Metal library, set
`QWEN_TP_SHARE_PROBE_GPU=1`: a synthetic shard's probe must cross nothing to its
counting peer, reduce through it again afterwards, return its request's pages
and cache, and give no probe (keeping nothing) when memory is refused, the
deadline is near, the budget runs out or the load is cancelled midway. These
fixtures time synthetic weights on one Mac; real share steps and the plan they
lead to are paired-hardware checks.

### Served speed build scope checks

Served speed records count only for the worker build that served them.
`libs/darkbloom-cluster/Tests/ObservabilityChecks/run.sh` checks that a record
keeps each rank's build, that a file written before builds were recorded still
reads, and that the bounded file keeps no build apart.
`libs/darkbloom-cluster/Tests/PlacementChecks/run.sh` (`ServedBuildScopeChecks`)
checks which setups a build's plan may use and replays the M3 Ultra + M5 Max
leader's own `served-speed.json` (Golden/served, member and request IDs
relabeled) through the plan tool's `--served`/`--served-build` with c41's share
probes. `provider-swift/Tests/ClusterPlacementChecks/run.sh` runs the same file
through `ClusterPlacementFlow.decide` (`servedBuildRegression`) and checks the
one-line explanation and that request lengths still come from every build;
`run-flow.sh` reads a product-format file from the private home end to end;
`provider-swift/Tests/ClusterInstalledSessionChecks/run.sh` checks the history
read and the router's build-keyed setup. `swift test --filter
DistributedAutomaticBatchPlannerTests` and `--filter ClusterObservabilityTests`
from `provider-swift` cover replacement calibration and the recorded builds.
