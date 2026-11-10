# Test Provider And Native Contracts

> Last updated: 2026-11-08

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
successful text afterward. The parity run's fabricated pair acknowledges
retirement at once; a forced-order case holds that acknowledgment until the
client has the answer, so a named `tool_choice` stream the shared pipeline
rejects mid-generation must end with the single-Mac failure frame while the
pair is still finishing the cancelled request. It also requires that the
request was cancelled and its acquisition and HTTP hold freed by then, and its
lane after retirement. Run
`swift test --package-path provider-swift --filter ClusterAPIParityTests` with
the [provider build prerequisites](build.md). These CPU checks prove API wiring,
not native model capabilities, numerical parity or hardware qualification.

The placement checks also cover exact family request scopes, completion-heavy
and long-prompt helper plans, overflow refusal, conservative memory refusal and
unchanged GLM adapter bounds. `GemmaRoutedExpertChecks.swift` builds the Gemma
QAT 4-bit layout from the retained real headers in
`libs/darkbloom-cluster/Tests/StageMetadataChecks/Inputs`, requires it to equal
its golden layout with `routedExperts` included, and requires the per-token
read of the [routed-expert prior](../architecture/inference.md#gemma-routed-expert-prior).
Run `libs/darkbloom-cluster/Tests/PlacementChecks/run.sh`
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

## Provider authorization guidance

After rebuilding the provider test product, run
`swift test --skip-build --no-parallel --filter ProviderAuthorizationReadinessTests`
from `provider-swift/`. The suite exercises the production freshness checks and
summary used by status and both doctor paths: a late but unexpired serving lease
stays visible while removal advice requires the matching fresh decision. It
covers the receipt-window boundary, disabled rollout, missing or mismatched
decisions and exact lease expiry. These checks use fixed snapshots and injected
process identity; they do not run the CLI's host probes, change profiles or
establish native App Attest acceptance.

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

CI runs the provider suite in two shards (`Provider Unit Tests (shard K)`), one
Mac each. Each shard runs the products of the one provider build
([build once](build.md#build-once)) and three selections at the same time. `PROVIDER_TEST_SHARD=K/N` and `PROVIDER_TEST_PROCESSES=P` make
`scripts/run-provider-tests.sh` run selections `(K-1)*P+1` to `K*P` of `N*P`,
each in its own `--no-parallel` process with its own `TMPDIR` and provider
state files; `scripts/provider-test-shards.py` chooses each selection's suites.
The processes start `PROVIDER_TEST_START_GAP` seconds apart (default 15).
SwiftPM in one process can find the build database locked by another's
startup (`unable to attach DB: ... database is locked`); it then runs the
tests and exits 1. Such a selection runs once more, but only when its log
proves that every test passed (`scripts/swift_test_lock_retry.py`: a passing
Swift Testing summary, XCTest summaries with 0 failures, no failed test or
issue). The first attempt's log and xUnit report stay beside the second's as
`attempt-1-shard-<selection>.log` and `.xml`, and both upload.
Without `PROVIDER_TEST_PROCESSES` (the release qualification lane), a shard
runs one selection, as before:

| Class | Process | Suites |
|---|---|---|
| Parallel | After selection 1, in its process slot, with Swift Testing's default parallelism | The test targets whose dependency closure has no MLX, Metal or cluster runtime (`PARALLEL_MODULES`) |
| Serial | One `--no-parallel` process per selection | All other suites. Selections 1 to N-1 take suites by measured seconds (`scripts/provider-test-shard-weights.json`). The last selection runs every suite that no other selection picks, so a new suite always runs |

Shard 1 (the shard of selection 2) also runs Prompt Parity (`scripts/verify-prompt-parity.sh` with
`PROMPT_PARITY_SKIP_BUILD=1`, and `scripts/verify-nemotron-prompt-parity.sh`)
against its own build; a parity failure fails that shard and the
`Provider Tests` gate. The last shard also runs the isolated processes and the
native MiMo, desktop and installer gates, after its selections finish, one at
a time. Each shard then lists the suite with `swift test list` from its own
build and fails unless each of its selections executed exactly its plan
(`provider-test-shards.py audit-job`); shard 1 also checks that each Prompt
Parity run executed every listed test of its suite, and the last shard checks
that the plans of all selections list every test once. With every shard
required to pass, that is the full-suite audit; no Mac job exists only for it.
Each shard reports the coverage of its own processes. When the shards drift
apart, download the `provider-unit-shard-*` artifacts and run
`python3 scripts/provider-test-shards.py weights <their shard-*.xml>` (it ignores a retried selection's `attempt-1-shard-*.xml`) to
refresh the weights file. The last shard's audit warns, and does not fail, when
a serial suite in the list has no weight: the last selection then runs it with
every other new suite, and that selection grows. A
suite moves from the parallel class to the serial class when it fails or flakes
in parallel; when in doubt, a suite stays serial.

The build jobs (the `provider-ci-build` action) and the cluster metadata runners
restore their build cache by the exact key first, then by the key prefix; the
action then tries the loose prefix, which ignores the CI recipe, and builds
once more from nothing if that build fails. The test jobs build nothing: they
download their lane's products and refuse products of another commit or
toolchain version. Only a push to `dev` or `master` saves a build; a pull request
restores its base branch's entry and saves nothing
([CI caching](build.md#ci-caching)). A push whose tree a pull request run
already tested runs no test job; the build jobs of the components the push
changed save their caches.

The last provider shard runs the MiMo audio gate (`testNativeAudioRelease`),
whose fixture needs the 1.87 GB pinned audio codec, only when the gate's
inputs change (`MIMO_AUDIO` in `scripts/ci-component-paths.py`: the MiMo,
audio and media provider code, the MiMo tests, the MLX pins, the audio and
provider fixture scripts and the gate's recipe), on a pull request and on a
push alike. A change outside those inputs neither downloads the codec nor runs
the gate.

The SDK has independent test products under `libs/mlx-swift-lm`: native memory
ownership, cancellation, media decoding, paged KV and resource packaging. They
run in the SDK's own CI (Fork Tests in Layr-Labs/mlx-swift-lm), not here.
d-inference CI had a Provider SDK Tests lane that ran them again, under the
provider's SDK 27 toolchain; it was removed on 2026-11-04 because 226 of its
236 test seconds repeated Fork Tests (the test inventory of PR #1785). Its one
other step, `MiMoV26NativeMediaDeadlineTests`,
is skipped in Fork Tests until the SDK sets `MIMO_V26_SERIAL_NATIVE_TESTS=1`,
`MIMO_V26_NATIVE_MEDIA_DEADLINE_TESTS=1` and `MIMO_V26_SERIAL_LOAD_FIXTURES` for it.
The provider's release qualification still builds the provider, with the SDK
compiled in, and runs its tests under SDK 27.

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

The SDK's `GLM5NextAlignedPayloadReaderTests`, `GLM5NextArtifactCachePolicyTests`
and `GLM5NextArtifactLoaderTests` run in the Fork Tests workflow of
Layr-Labs/mlx-swift-lm. The provider test host does not carry copies of them.
Their inventory fixture, `GLM5NextArtifactCachePolicySDKFixtures.swift`, stays in
`provider-swift/Tests/ProviderCoreTests/Inference/Models/GLM5Next/` because the
provider's GLM cluster tests use it.

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
including the genuine audio codec. The script downloads only the files that its
cache directory lacks. It retries a failed download up to 5 times and ends an
attempt that stays below 100 KB/s for 60 s. It keeps a file only when the size
and SHA-256 match. Keep these output directories isolated from
the ordinary regression inputs. Audio gates exercise PCM8 and AAC-video with a
small target, not full-model quality or peak memory. Release-only builds do not
provision test fixtures or opt into native qualification.

## Prompt Preparation And Admission

```bash
swift test --skip-build --filter 'LocalTokenizerDecodeSpacingTests|PromptTokenCacheTests|ChatTemplateLoopRewritesTests|InboundChatRequestDecodeTests|ServeLoopColdLoadTests'
```

`LocalTokenizerDecodeSpacingTests` requires a tokenizer whose config omits
`clean_up_tokenization_spaces` (Gemma 4's published config does) to decode and
stream text exactly, with the same input IDs and an explicit Boolean kept.

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

```bash
swift test --skip-build --filter 'LocalTokenizerByteFallbackTests'
```

`LocalTokenizerByteFallbackTests` loads a synthetic tokenizer with Gemma 4's decoder
sequence through the production `LocalTokenizerLoader` and requires characters
written as `<0xHH>` tokens to survive a whole decode, a stream, a segment restart
inside the run and a trailing special token, a run cut inside a character to end in
one U+FFFD, and the unknown token not to read as a byte. A literal `<0x41>` token on
another decoder keeps its spelling.

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

## OpenCode and Hermes config writers

The [config writers'](../architecture/tool-integrations.md) suites are CPU-only
and need no model, credential or live provider. The planners' goldens are
inline strings; the writer and end-to-end cases use temp homes and fresh fake
keys, and the live-endpoint case runs in a child process that alone points
`DARKBLOOM_LOCAL_DIR` at a temp folder. Every case that reaches
`IntegrationEndpoint.live` keeps it off this Mac's cluster service: it gives
`pairPart`, binds `ClusterPairSummary.readerForTesting`, or, in a child
process, calls `keepCommandsOffThisMacsCluster()`. None reads a real OpenCode
or Hermes config, or this Mac's cluster service.

```bash
swift test --skip-build --no-parallel \
  --filter 'OpenCodeConfigPlanTests|HermesConfigPlanTests|HermesVersionTests|ToolConfigWriterTests|IntegrationModelsTests|ToolIntegrationTests|ToolSetupWordsTests|ModelLoadWaitTests|ToolAddressTests|AtomicFileTests|keyFileIsTheFileHoldingThePortsKey'
```

| Coverage | Suites |
|---|---|
| New file, an owner's commented JSONC file, strict `.json`, a V1 `provider` map, the default model (also when the other global file sets one, this file's own winning, named when kept; two `model` keys name none; a remembered `/models` pick, and how its `model.json` is read), re-runs, refusals, the config file choice | `OpenCodeConfigPlanTests` |
| New file, Hermes' fresh-install `model: ""`, a file as oMLX writes it (PyYAML's column-0 lists too), the `model:` alias key, the kept default, the main model it replaces, a pair's model as the main one, the 64,000-token floor, quoting, refusals, every written key against Hermes' documented keys; the `key_cmd` version warning | `HermesConfigPlanTests`, `HermesVersionTests` |
| Backups (exact bytes, 0600, five kept), unchanged writes nothing, atomic replace, symlinks, a concurrent edit, dry run, the undo command run through `/bin/sh` | `ToolConfigWriterTests`, `AtomicFileTests` |
| Catalog names, limits and capability aliases; a pair's models named `(your pair)`, with their engine's image input and reasoning; the fetch with the key file's key; `local.json`'s endpoint and key file; the modes of new files; the owner's default in the other global OpenCode file; no written file holds the key | `IntegrationModelsTests`, `ToolIntegrationTests`, `keyFileIsTheFileHoldingThePortsKey` |
| What a start says, in a temp home with a user's two OpenCode files and his Hermes config: the default model's own line (none set, set in either file, set without a name, OpenCode 1's `config.json`, a `/models` pick OpenCode remembers in a fake `model.json`, under `XDG_STATE_HOME` too), Hermes' main model before, the URL for an API on `0.0.0.0`, a pair's API (`(your pair)`, a member's relay, a run again online and offline changes nothing); every `Changed:` wording and default line | `ToolSetupWordsTests` |
| The wait for this Mac's models (a scripted process and a clock that moves only between looks; every fake ends a wait at its bound, so a regression fails instead of hanging, and each suite has a one-minute limit), Ctrl-C (SIGUSR2 stands in for SIGINT), the run-again line; a plain start's notice, the address rule and the start's two hooks | `ModelLoadWaitTests`, `ToolAddressTests` |

`scripts/integrations/opencode-smoke.sh` then runs the real OpenCode 2 on the
written config. It runs the writer through the opt-in `OpenCodeSmokeSetup`
test (enabled only by `DARKBLOOM_OPENCODE_SMOKE_HOME`), against a fake
OpenAI-compatible server on a port the system picks, with HOME, every `XDG_*`
folder, `TMPDIR` and the discovery folder inside one temp folder and OpenCode
under `env -i` with `--standalone`:

```bash
scripts/integrations/opencode-smoke.sh --skip-build --scratch-path <build folder>
```

It checks that OpenCode lists the models and hides the key, that its agent turn
sends the key file's key and `max_tokens` (the model's `limit.output`) and no
`X-Darkbloom-Route`, that a second run changes nothing, that an owner's
`opencode.json` keeps its V1 provider and default model and is restored exactly
by the printed undo command, and that with both global files the owner's
default in `opencode.json` stays the only one OpenCode loads. It proves OpenCode accepts the block, not a real
engine's answers; Hermes is checked against its documentation only.

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

Release SDK qualification uses SDK 27.2 / Swift 6.4.2 (Xcode 27.2, the
[`release` toolchain](build.md#sdk-27-release-builds-and-caches)) and runs independently of
optimized compilation. The `qualify-sdk-shard` jobs run the provider suite in
five shards on separate Macs, with the shard plan of CI
(`scripts/provider-test-shards.py`). Shard 2 also runs Prompt Parity, and the
last shard runs the isolated processes and the audio gate. The `qualify-sdk`
job runs after every shard passes. It audits the executed counts of each shard
against the full suite list. Signing requires `qualify-sdk` and optimized
compilation. GPU suites retain serial execution and exclusive-process isolation.
A cache hit never skips a test.

The SDK 27.2 Date checks run without a Mac. The CI plan checks job of
`provider-tests.yml` (which the `Provider Tests` gate requires) and Release
Integrity run, from the repository root:

```bash
python3 scripts/test-check-date-comparisons.py
python3 scripts/test-check-provider-weak-imports.py
python3 scripts/check-date-comparisons.py
```

The binary tests use `nm -m` and `otool -tV` lines from DevNet build
`0.10.6-dev.branch.87`, which crashed on macOS 27.2 26B5091g. The release lane
runs `scripts/check-provider-weak-imports.py` on the built binaries
([build guide](build.md#sdk-27-release-builds-and-caches)).

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

## Cluster Pair Coordinated Update

`ClusterPairUpdateTests`
(`provider-swift/Tests/ProviderCoreTests/Update/ClusterPairUpdateTests.swift`)
runs two Macs' `ClusterPairUpdateCycle` in one process: each with the real
updater on its own temporary install, a loopback `MockCoordinator` serving the
release, and a real member loop as its part (a scripted pair owner holds rank 0's
request). It checks that a busy pair stages while serving, closes admission only
once both Macs staged, finishes the accepted request uncancelled and then
installs on both; that a request past the drain bound reopens admission and
defers both Macs, and the next cycle updates; that one Mac's failed download
stops both and the next cycle updates both; that a Mac whose partner has
automatic updates off downloads nothing at the slot, while `darkbloom update` on
both Macs updates them; that a part that cannot drain downloads nothing; that a
Mac whose partner cannot be asked goes on alone only while no pair runs on it;
the candidate's promotion (kept under another update's lease) and rollback;
the start check's verdicts on script binaries; the rollback at once of a
candidate that failed its start check; and the other Mac following a rollback
(`followRollback`): after it promoted the release, while its own cycle still
holds the update lease (it waits, then follows), with the other Mac no longer
answering (bounded wait, then a deferral with nothing changed), and the
quarantine on both Macs, with no follow back and no follow to a release the Mac
does not keep; and what is decided before the lease (the Mac that rolled back
names the release the other Mac still runs, a part that cannot drain does not
follow yet, a Mac on another release does not ask for the lease).
`Tests/ClusterSupervisionChecks/run.sh` also checks that a release the other Mac
quarantined is given up, and that an older build's progress decodes without a
quarantine.
`ClusterServiceUpdateTests`
(`provider-swift/Tests/DarkbloomCLITests/ClusterServiceUpdateTests.swift`) drives
the real supervisor with a shell standing in for the cluster service: the
single-Mac gate, a slot fired from a cluster ID whose slot is seconds away, no
slot cycle with automatic updates off (and `disabled` reported again once a
cycle's end is a minute old), `darkbloom update`'s request and the candidate's
rollback and promotion. The start check runs the temporary install's
`darkbloom`, a script: a release whose `--version` exits non-zero, outlasts a
1 s bound or reports another version is rolled back and quarantined without the
re-exec, and the supervisor serves again from the restored binary; a release
that answers is re-executed into as before; a restored predecessor that cannot
start is not re-executed into. A supervisor with automatic updates off still
checks for a rollback of the other Mac to follow, reports its own quarantine in
its progress, and restarts into the restored release. The re-exec is observed,
never performed.
`UpdateRecoveryReconcileTests`
(`provider-swift/Tests/ProviderCoreTests/Update/UpdateRecoveryReconcileTests.swift`)
rebuilds a Mac whose app was installed outside the updater over a stale update
record (0.10.7 installed; the record says 0.9.22 installed, 0.10.6 pending, and
a rollback copy recorded as 0.9.22 that is a 0.10.2 app) in a temporary install
root, with apps whose `Info.plist` names their version; an in-process URL
protocol answers the release check. It checks that the record is reconciled
before the cluster service starts (nothing pending, no rollback copy) and that a
reconcile that died part-way is finished at the next start; that the update slot
finds the running release up to date and installs nothing; that three ends of
the service never restore the copy; that a verified copy recorded as another
release than its app names (0.10.7 recorded as 0.10.6) is relabelled, kept and
restored by three failed starts, while a copy that names no version or whose
files changed is removed; that a damaged install (its `mlx.metallib` gone) still
counts failed starts and is rolled back to the verified copy; that an update
over such an install keeps a copy of the installed app, recorded as the release
that app names; and that the normal install, promotion and rollback are
unchanged.
`Tests/ClusterSupervisionChecks/run.sh` checks the progress rules
(`ClusterPairUpdate.partnerState`) with plain `swiftc`.

```bash
CFFIXED_USER_HOME="$(mktemp -d)" swift test --skip-build --no-parallel \
  --filter 'ClusterPairUpdateTests|ClusterServiceUpdateTests|UpdateRecoveryReconcileTests'
```

Keep `CFFIXED_USER_HOME` (or an isolated user) on a Mac that serves: the member
loops and supervisors otherwise use the real `~/.darkbloom` for their cluster
files. These checks use loopback and temporary roots only; they do not run a
pair, launchd, a signed release or the coordinator's routing of a draining pair.

## Public Fixtures And Private Qualification

Public protocol JSON and prompt golden vectors contain fixed inputs and expected
outputs. Provider tests load them from provider-owned resources or `fixtures/`,
not from a removed backend tree. Preserve exact bytes, attribution, artifact
hashes, enum casing and optional-field omission.

`scripts/verify-prompt-parity.sh` uses `scripts/prepare-prompt-fixtures.py` to
download only the committed manifests' hash-pinned public prompt assets, never
weights. The downloader identifies itself as `darkbloom-prompt-fixtures/1` to
the CDN and retains same-origin HTTPS, byte-budget and integrity checks.
It retries only a cut or failed transfer (a TLS, socket or connection error, a
timeout, a body that ends before its declared size, or HTTP 5xx), at most 3
attempts per artifact with 1 s and 3 s backoff inside the contract's deadline.
The deadline is 120 s plus the time the contract's missing bytes take at
128 KiB/s, at most 900 s: 256 s for the 17 MB Nemotron contract and 376 s for a
32 MB Gemma 4 contract. A full-size body with the wrong SHA-256, an oversize
body, a Content-Length mismatch, a cross-origin response, another non-200
status or the deadline fails at once.

With `PROMPT_PARITY_DOWNLOAD_CACHE` set (CI sets it for both parity scripts),
`--download-cache` names a directory with one file per pinned SHA-256
(`scripts/verified_download_cache.py`). An artifact is copied from it only if
the entry is a regular file with the pinned size and digest; a missing, linked,
special, short, long or changed entry, or one that cannot be read, is
downloaded, and the verified download replaces it. A failure to store an entry
is printed and ignored. The cache's bytes do not count toward the deadline, and
the Gemma 4 and Qwen contracts that share a `tokenizer.json` download it once.
For each contract the script prints how many artifacts came from the cache, how
many it downloaded, their bytes and the seconds it took.

`scripts/prepare-mimo-prompt-fixtures.py` and
`scripts/prepare-mimo-image-http-fixtures.py` apply the same retry rule to each
metadata file, with these differences. The MiMo prompt script has no total
deadline: each connect and read has a 60 s socket timeout. The image script has
a 120 s deadline for each file, and it classifies curl's exit code: a cut
transfer (for example exit 18 or 56) retries, and an oversize body (63) or a
certificate failure does not. curl does not follow redirects for the image
script.

The three downloaders share one redirect rule (`scripts/fixture_redirects.py`),
for at most 10 redirects. A download follows a redirect only when the target
has the scheme, host and port of the URL that answered with it, and the target
has no credentials. The MiMo prompt script also follows an HTTPS redirect from
`https://huggingface.co` to a Hugging Face CDN host on port 443: `hf.co` or a
name that ends in `.hf.co`. Hugging Face answers `tokenizer.json` at the pinned
revision with a 302 to `us.aws.cdn.hf.co`; the other three metadata files take a
same-origin 307. The pinned SHA-256 values still protect the bytes. Any other
redirect (another host, another port or plain HTTP) fails at once, is not
retried, and its target is never requested. The prompt-asset downloader also
refuses a redirect target with a query or fragment. Provisioning failures fail
qualification; they must not silently skip vectors.

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

`fixtures/prompt-contract/v1/native_reasoning_vectors.json` (28 cases) is this
repository's: the template context the provider gives each reasoning control,
or its refusal. `CachePromptParityTests` checks the provider against it, and
the platform's prompt sidecar and first-party pool read the same cases, so a
change lands here first and the platform follows. Since the reasoning-effort
levels ([reasoning effort](../architecture/inference.md#reasoning-effort)),
Qwen 3.8 Flash-Next's `high`, `max`, `minimal` and ` low ` render a level and
`turbo` is refused. `ReasoningEffortValuesTests` checks every family's table
against the rounding rule and sends every effort to every family through the
production prompt pipeline, and
`ReasoningEffortLocalAPITests` sends them to one Mac's local API and a pair
leader's over the `ClusterAPIParityTests` harness. It also renders Nemotron 3.5
Super's refusal of two efforts that differ through `SuperHTTPErrors` and
`CORSResponder`; `NemotronSuperLocalHTTPTests`' live text route sends it, and
an unknown `reasoning.effort`, through the real application (it needs Metal,
so it runs in CI).

`fixtures/prompt-contract/v1/reasoning_effort_vectors.json` (446 cases) is
also this repository's, and it is the contract with the coordinator: every
family's reading of every effort, in both fields and other spellings (a
non-ASCII `HİGH` among them), with the field an unknown effort is refused in,
and cases for every type that reasons. It also lists the sets the table keeps:
the types that reason, the Qwen 3.5 template family's, the types whose effort
sets a thinking switch, and the concrete Qwen 3.8 builds. It is generated,
never edited by hand: `scripts/generate-reasoning-effort-vectors.py` restates
the tables in `ReasoningEffort.swift` and writes it, and running the script
again must leave the file unchanged. Regenerate it with the tables, and check
the result with `CachePromptParityTests.reasoningEffortVectors`, which requires
each set to equal the table's and every type that reasons to have cases, and
runs every case through the production prompt pipeline. darkbloom-platform
copies the file byte for byte from a reviewed commit of this repository (its
provider contract snapshot, which `make contracts-check` verifies there) and
checks its ingress refusal, first-party pool and prompt sidecar against it,
sets included, so a type added or dropped on one side only fails a test on the
other, and a change to a table changes the file in both repositories together.
A new family that reasons adds its model types to the sets, its table (if it
has levels) with a row in
`ReasoningEffortValuesTests.everyFamilyTableCoversEveryEffort`, a `Family` to
the script, and the regenerated file with its new case count; the coordinator
learns the family when the platform takes that commit's file.

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
exits non-zero on a failure. When the classifier selects `cluster` (see below),
CI (`.github/workflows/provider-tests.yml`) runs them in three places. The job
`cluster-release-checks` (Cluster Release Build Checks; its runner is in
[Job sizes](build.md#job-sizes)) runs
`libs/darkbloom-cluster-worker/Tests/CapabilityChecks/run.sh` and
`libs/darkbloom-cluster/Tests/PrefillScheduleChecks/run.sh`, which compile a
release build of the cluster runtime. Shard 2 of `test-cluster-focused`
(Cluster Focused Checks) runs
`libs/darkbloom-cluster/Tests/StageMetadataChecks/run.py`,
`libs/darkbloom-cluster/Tests/GPTOSSStageChecks/run.sh`,
`libs/darkbloom-cluster/Tests/NemotronStageChecks/run.sh`,
`provider-swift/Tests/ClusterModelProvisioningChecks/run.sh provisioning`,
the onboarding checks and `provider-swift/Tests/ClusterConsoleChecks/run.sh`.
Shard 1 runs every other runner under `libs/darkbloom-cluster/Tests`,
`provider-swift/Tests/ClusterPairingChecks/run.sh`,
`provider-swift/Tests/ClusterDiagnosticsChecks/run.sh` and
`provider-swift/Tests/ClusterPlacementChecks/run-flow.sh`. Each runner compiles only its own small source
closure. The provisioning runner runs the
provisioning checks only. Its download cache-policy check
reads how many written pages stay in the file cache, which the host's kernel
and disk decide: on the hosted CI VM 0.75 of the pages written with
`F_NOCACHE` stayed resident. Run `run.sh` with no argument on a Mac for that
check. The capability runner compiles with
`DARKBLOOM_CLUSTER_METADATA_BUILD_JOBS` jobs (4 by default; CI uses 12). CI
keeps its build in `DARKBLOOM_CLUSTER_METADATA_BUILD_ROOT` between runs and
restores source timestamps only for unchanged files, so SwiftPM rebuilds only
what changed. The worker package's tests (built for macOS 26.2) need the GPU
and exclusive device access. A loopback or fixture pass never counts as a
two-Mac hardware pass.

The cluster jobs (Build cluster test products, Cluster Runtime Tests, Cluster
GPU Tests, Cluster Release Build Checks and Cluster Focused Checks) run when the classifier selects `cluster`, on a pull request
and on a push alike (`CLUSTER` in `scripts/ci-component-paths.py`): the cluster packages, the MLX
pins, the provider's Cluster, Distributed and NativePair sources, the
provider-side cluster runners (`provider-swift/Tests/Cluster*Checks`), the
other provider files the cluster runners compile, the cluster plan and the
shared build recipe. The
`Provider Tests` gate accepts a skipped cluster job only when `cluster` was not
selected. A provider-only change runs 3 Macs (the provider build and the 2
provider shards). A cluster change adds 12 Macs (the cluster build, the release
build checks, 5 runtime shards, 2 focused shards and 3 GPU shards). Every
Mac job but the 3 GPU shards is routed; the GPU shards run on Blacksmith
([job sizes](build.md#job-sizes)). A change whose tree a successful run of the
same workflow already tested runs no test job at all
(`scripts/ci-tested-tree.py`).

CI runs the runtime test target (`DarkbloomClusterRuntimeTests`) on the
provider's macOS CI runners (see [CI runner routing](build.md#ci-runner-routing)),
in selections that `scripts/cluster-test-plan.py` defines. Each selection runs
in a process of its own through `scripts/run-nested-suite.sh`, which fails when
the selection runs no test or skips a test. Runtime shard 1 runs `base` alone,
then the share probe alone. The probe times each rank's share against a 1.5 s
budget, so it never runs on a Mac right after the concurrent GPU groups.
Shards 2 and 3 each run two groups at the same time, each in plan order with
its own `TMPDIR`: a Qwen GPU group beside a CPU group of the batch-session
suite (`QwenTensorParallelBatchSessionTests`, 672 s in one process). Shard 2
runs `qwen-tp-batch-gpu` and `qwen-tp-batch-gpu-paged`, then the GLM paged-KV,
invariance and census, TF32 and Gemma selections, beside `base-batch-session`.
Shard 3 runs `qwen-tp-mtp-gpu`, `qwen-tp-aqv-gpu`, `qwen-tp-moe-gpu` and
`glm53-prefix-ssd` beside `base-batch-session-prefix-tiers`, the suite's warm
and SSD prefix tier tests (`BATCH_SESSION_PREFIX_TIER_TESTS`, 325 of the 672 s).
`base-batch-session` skips those tests and runs every other test of the suite,
so a new test of the suite runs there.
The second group starts `CLUSTER_TEST_START_GAP` seconds (default 15) after
the first, as the provider shards' processes do, so their SwiftPM startups do
not meet on the shared build database.
Shards 4 and 5 each run one half of the Gemma 4 base suites (`GEMMA_SUITES`,
610 s in one process) alone: shard 4 runs `base-gemma-tensor-parallel`
(`Gemma4TensorParallelTests`, 296 s), shard 5 `base-gemma` (the other Gemma
suites, 314 s). Each Gemma suite runs whole in one of the two.
Cluster GPU Tests shards 1 and 3 each run one half of the real-geometry rows
check alone ([Qwen27 capacity consistency checks](#qwen27-capacity-consistency-checks));
shard 2 runs the other non-blocking selections one at a time.
A grouped selection that finds SwiftPM's build database locked, and whose log
proves every test passed, runs once more, as in the provider shards; the job
log prints both attempts' logs. Every process starts with
`MLX_QMV_BATCH_INVARIANT=1`, as every cluster process does.

| Selection | Job | Tests |
|---|---|---|
| Base | Cluster Runtime Tests (blocking) | Every test that needs no environment switch. The base selections pass `--skip` for the switched tests and the tests that need a model, so a test that skips there has a gate that the plan does not name |
| Opt-in | Cluster Runtime Tests (blocking) | The tests that one switch (for example `QWEN_TP_MTP_GPU=1`) enables and that pass on the CI runners |
| Opt-in | Cluster GPU Tests (non-blocking) | The switched tests that fail on the CI runners' GPU, the long-running tests and the benchmarks. The job reports their results and does not fail the workflow |
| Needs a model | None | The tests that need a model directory, an artifact or its metadata (`REQUIRES_MODEL`). CI has no model |

`python3 scripts/test-cluster-test-plan.py` (the CI plan checks job, which the `Provider Tests` gate requires, and Release Integrity) checks that the
plan names each gated test in the sources once, each runner under
`libs/darkbloom-cluster/Tests` once, and every Gemma suite in `GEMMA_SUITES`,
each in exactly one base selection of Gemma suites. It also checks that each
test a selection of suite functions names (`functions`) is an ungated test of
that suite, named once, and that one other base selection runs the suite's
other tests. When you add an environment gate to a
runtime test, add the test to a selection or to `REQUIRES_MODEL`.

Build the runtime tests once (`swift build --package-path libs/darkbloom-cluster
-c release --build-tests --triple arm64-apple-macosx26.2 -Xcc -target -Xcc
arm64-apple-macosx26.2 -Xswiftc -enable-testing`), stage the source-matched
`mlx.metallib` in the test bundle's `Contents/MacOS/`, and run `swift test`
with the same flags plus `--skip-build --no-parallel`. Without environment
switches the run evaluates synthetic models on the GPU by default; the GPU-only
cases (`QWEN_TP_BATCH_GPU=1`, `QWEN_TP_MTP_GPU=1`, `QWEN_TP_MOE_GPU=1`,
`QWEN_TP_AQV_GPU=1`, `QWEN_TP_REAL_GEOMETRY_GPU=1`) run each in a process of their own with their filter. On
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

## Focused Gemma 4 tensor-parallel checks

These checks use synthetic weights on one Mac, over loopback only. They prove
neither real-weight numerics, a pair qualification nor speed.

1. Run the model-free plan check (no MLX; it compiles in seconds) and the CPU
   unit tests:

   ```bash
   bash libs/darkbloom-cluster/Tests/TensorParallelPlanChecks/gemma-run.sh
   swift test --package-path libs/darkbloom-cluster --filter Gemma4TensorParallelTests
   swift test --package-path libs/darkbloom-cluster --filter Gemma4TensorParallelRuntimeTests
   ```

   The plan check covers both registered artifacts' text tensors once per rank
   and matches their registered text bytes. The `Gemma4TensorParallelRuntimeTests`
   suite needs the GPU: put a source-matched `mlx.metallib` in the package's
   debug products directory (the one `swift build --package-path libs/darkbloom-cluster --show-bin-path`
   prints), not in the `.xctest` bundle. It covers the resident runtime's pieces:

   - each rank's paged request state: its own KV heads of every layer;
   - two in-process ranks on the paged request path, bit for bit equal, with
     the whole model's tokens and exactly two collectives a layer and one a step;
   - layer submission, which keeps every bit;
   - batch lanes (one joining late): every row equals its request's solo row,
     bit for bit, and the shared batch driver with the Gemma executor
     publishes each request's solo tokens;
   - the request loop on two ranks: a stop token, the owner's stop (also one
     just before a stop token) and one rank's own stop end both ranks after
     the same step, with logprobs;
   - the share probe, timed on one rank with every sum local;
   - each step's choice: greedy with both stop flags, sampled from the gathered
     row exactly as the product's sampler draws, and greedy logprobs from the
     split top-k, also at an exactly tied maximum whose other ID leads the gather;
   - the verified load's cut of every text tensor, and its refusals;
   - the load agreement's fields;
   - what the capability declares of each mode (`ClusterServingFeatures`):
     tensor parallel's prompt-prefix setting is the one its load agreement binds;
   - the product's Gemma layout with its tensor-parallel facts: big Macs keep
     the pipeline on default link costs; on a measured fast link tensor
     parallel is predicted faster on the device index alone and the pipeline is
     kept, until each rank's share probe lets it be chosen; the forced mode
     places it; and each rank is charged its own heads.

   `swift test --package-path libs/darkbloom-cluster --filter Gemma4TensorParallelPrefixTests`
   (GPU, as above) covers the prompt-prefix tiers on two in-process ranks:

   - a repeated prompt, and a longer one sharing it, restores the deepest
     boundary both ranks hold and equals the cold request bit for bit;
   - the restored rows, windows and position offsets equal the cold request's
     at the boundary and after the next chunk;
   - a boundary only one rank holds, or one rank cannot restore, another chunk
     grid and a request whose cache is off all prefill from zero on both ranks;
   - the request loop (greedy and sampled) and batch lanes through the driver
     continue a restored prefix with the cold tokens;
   - the memory tier's budget and eviction, and a capture within its limit;
   - a request's own capture charged in its budget and the LOAD quote, no
     charge for the memory tier, whose budget stays within the measured room;
     with no tier budget a request still captures within its charge and a
     repeat restores from the SSD tier;
   - the SSD tier: records restore bit for bit after both tiers reopen,
     encrypted and owner-only; stale, corrupted and other-key records are
     refused on both ranks; no directory or key is no tier, and the daily write
     cap, the free-space floor and the bounded close hold.

   `libs/darkbloom-cluster/Tests/PlacementChecks/run.sh` also runs
   `GemmaTensorParallelChecks.swift` (model-free). It builds the QAT 4-bit
   layout from the retained real headers and the 8-bit layouts from their
   derived shapes, and requires each to equal its golden layout, tensor-parallel
   facts included. A rank's share must be the plan's exact cut (8,040,450,108 and
   14,915,635,260 bytes), and the rank's reserve (`Gemma4TensorParallelRequestBudget`)
   must be quoted. Under the provider's tensor-parallel-first policy it checks the
   fastest-plan rule on constructed pairs: 2x M5 Ultra 256 GB keeps the pipeline on
   default link costs. Where tensor parallel is predicted faster on the device
   index alone (2x M4 Pro 24 or 32 GB, each rank quoted with its request's
   prompt-prefix capture, and 2x M5 Ultra for a 128 + 128 request on the
   measured 29 us link), the pipeline is kept with the verdict
   `predictedFasterOnPriorOnly`, its plan line and model-list note. Share probes
   of the model on both Macs (through `ClusterShareProbeHistory`) and requests
   served in tensor parallel (through `ClusterServedCalibration`) then decide
   both ways. A probe on one Mac or of another model is no evidence. A kept mode
   still applies, the forced mode still places tensor parallel, and the same
   layout without its choice still takes tensor parallel on the prior.

   The `Gemma4TensorParallelTests` suite covers:

   - the plan against the registered QAT 4-bit artifact's 1,697 header shapes
     (`Tests/StageMetadataChecks/Inputs`), and the 8-bit artifact's derived shapes
     and registered text bytes;
   - refusals of unknown, misaligned and vision tensors;
   - shard parameters against independent slices;
   - two in-process ranks against the split-sum oracle, bit for bit;
   - the packed feed-forward collective against separate collectives, also
     under the registered prompt policy and the scoped batch decode;
   - the vocabulary-split head against the whole head.

2. Build `darkbloom-cluster-tp-check` and put a source-matched `mlx.metallib`
   beside it ([build](build.md)). Then run the GPU oracles:

   ```bash
   bash libs/darkbloom-cluster-worker/Tests/GemmaTensorParallelOracles/run.sh \
     /path/to/darkbloom-cluster-tp-check /new/scratch/dir 58123
   bash libs/darkbloom-cluster-worker/Tests/GemmaTensorParallelOracles/run.sh \
     /path/to/darkbloom-cluster-tp-check /another/new/dir 58125 paged
   ```

   The script synthesizes five variants: 4- and 8-bit, routed and all-expert,
   and FP32. For each, it runs `full`, `split-sum`, `simulated` and two `tp`
   ranks over the sealed local ring on the given port and the next one. With
   `paged` as the fourth argument, every mode but `split-sum` runs the
   resident runtime's own request path: paged KV, the product's CBv2 prompt
   entry, and each step's choice in its own evaluation. The paged path also
   runs `gemma lanes`: three requests served together through the batch
   driver, in one process and over the ring, each of which must take its solo
   tokens. And it runs `gemma run --prefix repeat` in `simulated` and on both
   `tp` ranks: the request served twice through each rank's prompt-prefix tier,
   the repeat restoring the deepest boundary both ranks hold.

3. Verify. Each `tp` rank must equal `simulated` bit for bit (exit status 0).
   Each repeated-prefix run must have restored a prefix and equal its cold run
   bit for bit, and each `tp` rank's repeat must equal `simulated`'s.
   The script also prints QualificationComparator's verdict for each rank
   against `full`.

## Focused MiMo V2.6 tensor-parallel checks

These checks use synthetic weights on one Mac, over loopback only. They prove
neither real-weight numerics, a pair qualification nor speed. Never load the
registered artifact for them.

1. Run the unit tests. The FP32-partial suite runs on the GPU, so stage the
   source-matched `mlx.metallib` in the test bundle first
   (`scripts/stage-test-metallib.sh`):

   ```bash
   swift test --package-path libs/darkbloom-cluster --filter MiMoTensorParallel
   ```

   They cover:

   - the plan against the registered 1,732-tensor inventory and configuration
     (`darkbloom-cluster-worker/Tests/CapabilityChecks/Fixtures`), per-rank
     bytes and the SDK shard's agreement on every cut axis;
   - refusals of renamed, foreign, excluded and odd-shaped tensors;
   - the shard configuration and per-rank KV geometry;
   - shard cuts and byte runs against independent slices;
   - two in-process ranks against each other and the whole model;
   - FP32 partials (`MiMoTensorParallelFloat32PartialTests`, on the GPU): two
     ranks' expert rows add up bit for bit to the exact full-width row that
     one Mac rounds once, through the decode-expert kernel and MLX's sorted
     gather; every partial a rank sums is FP32, and no `o_proj` or dense
     partial was rounded to BF16 first; the contract v2 strings are pinned; a
     speculative round's verify window (every width from 2 to 4 rows, after a
     prompt that wrapped the sliding ring) hands each sum the one-token steps'
     own FP32 partials, row for row and bit for bit, with logits to match
     (`windowPartialsAreTheOneTokenStepsFloat32Partials`);
   - the vocabulary-split head against the whole head;
   - the resident runtime's verified load: each rank reads exactly its shard's
     bytes, and a tampered or foreign checkpoint is refused;
   - its paged requests: ranks agree bit for bit and equal the ordinary caches,
     with per-rank paged geometry, the selection rules, logprobs (an exactly
     tied maximum included), every stop kind (the owner's stop just before a
     stop token included), the request and load agreements, the request budget
     and the text-only launch;
   - speculative rounds (`MiMoTensorParallelSpeculativeTests`, a checkpoint with
     three random trained heads): rounds of the heads' own proposals and of
     proposals scripted from the one-token path's tokens (every one kept, or
     every third moved off) equal the one-token path bit for bit, caches
     included; a stop token inside a window, the owner's stop inside a round
     (and just before a stop token of the same round), a cancel between rounds
     and greedy logprobs for every kept column (the one-token path's own) end
     both ranks together; the LOAD gate's configuration-only drafter charge is
     what the loaded heads declare; a window's rollback
     (`MiMoV26VerifyWindow.settle`) leaves exactly the cache of one-token
     appends on the registered 128-row ring (two 64-token pages, across its
     page boundary and wrap) and on a full layer; exactly tied columns and
     draft readouts choose the lowest token ID; the window contract
     (`windows=row-exact-one-token-float32-partials-v2`) is in the agreement; and
     the product layout quotes what the LOAD gate charges with rounds on by
     default: the heads (42 tensors, 1,975,640,448 bytes, equal to the LOAD
     gate's head inventory over the same headers) and each request's
     speculative charge beside the reserve, no speed-up credited
     (`placementQuotesWhatTheLoadGateChargesWithRounds`);
   - what the text row's capability declares of each mode (`ClusterServingFeatures`):
     tensor parallel decodes in rounds at `ClusterMiMoTensorParallel.speculativeDepth`,
     so it drops nothing of the speculative or compact-decode pipeline and only
     the plain pipeline's batch lanes.

   `libs/darkbloom-cluster/Tests/PlacementChecks/run.sh` also runs
   `MiMoTensorParallelChecks.swift` (model-free). It builds the layout from the
   registered configuration and inventory and requires its tensor-parallel
   facts (97 sums a step, `fastest_v1`), a rank's share of exactly
   84,013,770,176 bytes, the routing prior (10,767,036,288 bytes a step), no
   facts for the image candidate, the same facts in the golden layout, and the
   rank's reserve (`MiMoTensorParallelRequestBudget`) in the quote. With the
   rounds on by default, it prices them as the product layout does (the SDK's
   drafter declaration stands in at its registered 438,426,984 bytes plus the
   window's 36,347,904): each rank holds the 42 head tensors whole in whole pages,
   its request need carries the speculative charge, its need is exactly the
   rank's LOAD gate plus its tensors' page padding, decode is credited nothing,
   and two idle 128 GB M5 Max still fit now (99.9 GiB a rank). Under the
   provider's tensor-parallel-first policy it checks the fastest-plan rule on
   constructed pairs against the plain pipeline: 2x M5 Max 128 GB keeps the
   pipeline where tensor parallel is predicted faster on the device index alone,
   inside the margin and for long prompts; 2x M5 Ultra 256 GB keeps the pipeline
   on default link costs. As the provider plans MiMo (the speculative pipeline
   credited the 1.37x its records measured, a fresh pair's 32,768 + 32,768
   request), both pairs keep the speculative pipeline before a load measures the
   link and on the measured 29 us link, where tensor parallel is predicted faster
   on the prior alone (`predictedFasterOnPriorOnly`), and for 8,192 + 128 or on a
   109 us link. Requests served in tensor parallel decide both ways on both
   pairs. Every tensor-parallel plan (forced, placed first, or chosen on served
   requests) has the serial prefill schedule, the only one MiMo's
   tensor-parallel runtime loads; the speculative pipeline keeps the one-chunk
   lookahead. `provider-swift/Tests/ClusterPlacementChecks/run.sh` checks that the
   guided step credits MiMo's rounds from its shipped records and prints the
   fastest-plan and logprob lines. Through the guided step it also checks feature
   parity (`ClusterModeParity`) before the evidence rule:
   - as this build declares them, MiMo's tensor parallel decodes in rounds, so it
     keeps every feature of the speculative pipeline and the evidence rule
     decides: on two 256 GB Macs the speculative pipeline is kept with no served
     record (prior only) or another build's, and this build's served records
     choose (95 tok/s: tensor parallel; 60: the speculative pipeline);
   - a MiMo record without tensor parallel's rounds holds it back even with this
     build's served records, and where the plain pipeline is the mode it would
     replace (a record without `pipeline_mtp_v1`), that pipeline's 8 batch lanes
     hold one-lane tensor parallel back, served records or not;
   - a Gemma record whose tensor parallel keeps no prompt prefixes (as builds
     before 0.10.7 declared it) keeps the pipeline even with both Macs' share
     probes, after an update that served tensor parallel, and with nothing
     measured; each plan says what tensor parallel would drop; with Gemma's record
     as this build declares it (prefix reuse kept), Gemma follows both Macs' share
     probes;
   - where only tensor parallel fits, the plan refuses and saves no setup; the
     forced mode places it and says what it drops; a record without features
     holds it back, and the forced mode then says what it drops is not known;
     per-mode features cross the capability codec canonically; a GLM record
     declaring a gap plans exactly as without it.

2. Build `darkbloom-cluster-tp-check` and put a source-matched `mlx.metallib`
   beside it ([build](build.md)). Then run the GPU oracles:

   ```bash
   bash libs/darkbloom-cluster-worker/Tests/MiMoTensorParallelOracles/run.sh \
     /path/to/darkbloom-cluster-tp-check /new/scratch/dir 58223
   ```

   The script synthesizes four variants: `kernel`, `tiny`, `kernel` with every
   token taking all 8 experts (no route can flip), and FP32 `kernel`. For
   each, and for a 40-token and a 6-token prompt around the 8-token window, it
   runs `full`, `simulated` and two `tp` ranks over the sealed local ring on
   the given port and the next one. It then runs the socket backend once, and
   one sampled run: temperature 0.8, drawn from the gathered row (by the
   product's sampler on the paged path). It runs this matrix twice:

   - `contiguous`: the foundation's path (tensors read whole and cut, ordinary
     caches);
   - `paged`: the resident runtime's path (`--path paged`: verified load, paged
     KV, the per-step agreement sum, 100-op decode buffers). Paged histories
     are BF16 only, so this matrix skips the FP32 variant.

   The paged matrix also checks that:

   - each rank read only its byte runs;
   - paged `full` and `simulated` equal contiguous ones bit for bit;
   - ranks given different agreements refuse;
   - a checkpoint changed after its manifest is refused;
   - a 192-token prompt (three 64-token pages before decode) gives the same
     results on both paths and over the ring;
   - recording route sets (`--record-routes yes`) changes nothing.

   It also reports, without requiring anything of it, where `simulated` first
   routes a token to other experts than `full`, over the positions whose inputs
   are still equal (`mimo compare` prints a `route sets:` line).

   A third matrix, `mtp`, runs speculative rounds (`--mtp-depth`) on `kernel`
   and `tiny` checkpoints with three random trained heads
   (`mimo synthesize --mtp yes`; the text weights equal the plain variant's).
   For each prompt (40, 6 and, on `kernel`, 192 tokens) it requires every
   round run to equal the one-token path bit for bit (tokens, rows and caches):
   the heads' own proposals (random, so mostly rejected), proposals scripted
   from the one-token run's tokens (`--mtp-script REPORT`, all kept) and every
   fifth scripted proposal moved off (`--mtp-misses 5`: accepts, rejects and
   rollback). Sampled rounds (temperature 0.8: the heads, and the misses scripted
   from the sampled one-token run) must equal the sampled one-token path bit for
   bit. Two `tp` ranks over the ring must equal `simulated` for the heads, the
   misses and a sampled run. `--mode full` with `--mtp-depth` must be refused
   before loading: a verify window runs only on a tensor-parallel rank.

   `MIMO_ORACLE_PATHS=paged` runs one matrix.

3. Verify. Each `tp` rank must equal `simulated` bit for bit, KV caches
   included, and greedy ranks must agree with `full` under
   QualificationComparator (exit status 0). A sampled run's verdict against
   `full` is informational: rows that differ by rounding can draw a
   neighbouring token.

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
python3 scripts/test-provider-release-notes.py
python3 scripts/test-provider-cluster-runtime-models.py
python3 scripts/test-release-dev-branch.py
python3 scripts/test-provider-release-pipeline.py
python3 scripts/test-provider-release-artifact.py
python3 scripts/test-provider-release-cache.py
python3 scripts/test-darkbloom-route.py
python3 scripts/test-ci-tested-tree.py
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
publication. Its cluster runtime rows pin the prod and dev payload bytes without
`cluster_runtime` to their digests from before the block existed, carry a valid
block through `stage` in dev and prod, refuse each malformed block (grants and
parity qualifications included) and a block whose derived approval, grant or
parity qualification IDs exceed 128 bytes, refuse a registration body over the
coordinator's 64 KiB limit before staging (65,536 bytes accepted, 65,537
refused), accept the GLM-5.3-Flash block pinned from the 0.10.5-dev.branch.17
app (its digests are that app's; its grant and parity qualifications are this
build's declaration, so its evidence digest and `qualified_at` follow
`ClusterPublicModels`), and check that registration sends the block in its
canonical form.
`scripts/test-provider-release-notes.py` builds a local origin repository with
GitHub's shapes: merge-commit and squash pull requests, `refs/pull/<N>/head`
refs and release tags. Its five releases are two squash promotions, a hotfix
without a promotion, a merge-commit promotion and a release whose only
promotion is its Prepare pull request, cut from `dev`. They include a `dev` pull
request merged after the promoted snapshot, a sync of `master` into `dev` and
Prepare pull requests. The tests check each release's pull requests through
`dev` and directly on `master`, and that release pull requests are named once.
They publish v1.1.0 through `publish_github_release` with a fake `gh`, once
with GitHub's answer and once with the `FORBIDDEN` answer a token without pull
request access gets. The second still lists every pull request, with its title
from git, escaped as on the first, and an author only where a noreply address
names one. They also check the `CHANGELOG.md` section, the 125,000-character
fallback and a failed generation. Titles and authors are fixture data, and no
test uses the network.
The test needs git 2.31 or newer, as the release notes do, and stops with that
message on an older git.
`scripts/test-provider-cluster-runtime-models.py` runs the release's
model-metadata fetch against a local HTTP registry: the environment's catalog and
CDN, candidate selection, the manifest and `config.json` checks, each candidate's
catalog entry (`id`, `input_modalities`), a listed model the catalog lacks (left out
and named), retries and refusals. It reads no weights
and uses no network. `scripts/provider-cluster-runtime-facts.sh` has no
fake-driven test; the release lane runs it on every final signed app and shows
its result in the job summary.

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
pins the final-app check against the self-updater's designated requirement, and
the cluster runtime facts step: after the final hashes, no secret, the keychain
removed first, its failure fatal only when `CLUSTER_RUNTIME_SEND` is true, and
`prepare` byte for byte today's command when it is not.

`scripts/test-darkbloom-route.py` runs the actual
[CI runner routing](build.md#ci-runner-routing) shell step against a loopback
HTTPS plane with a throwaway certificate; the host needs Bash, Python, jq, curl
and openssl. It covers the default-off switch, fork pull requests, exact label
grants, HTTP errors, the single retry, timeouts, untrusted or plain-HTTP planes
and hostile reply text. It covers [job sizes](build.md#job-sizes) both ways:
while `DARKBLOOM_JOB_SHAPES` is not exactly `on`, CI's request is byte for byte
the request without sizes; while it is on, each lane sends its size and takes
only the labels of that size. It also covers bad sizes and the macOS cap order.
It also pins each routed job's lanes (one per provider or cluster shard,
matching the job's matrix), size, fallback, timeout and read-only permissions,
and keeps release workflows and Cluster GPU Tests on literal Blacksmith
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
syntax.

Run `python3 -m unittest discover -s scripts/models -p 'test_*.py'` for the
**Model Requant Upload** workflow. Release Integrity runs it too. It needs no
network and no credentials:
- The input and manifest rules: the manifest must be what Register and every
  provider read, and the published Qwen3.5-9B manifest must pass.
- The workflow's jobs and steps, run in Bash with a fake `aws` and `python3`:
  - a secret-free preflight, then a job in the `prod` environment;
  - master only;
  - the check tests both R2 key sets and prints only pass or fail;
  - the upload holds only the chosen set, and only after this run's check
    passed for it;
  - tools pinned by hash, and the selftest before any secret.
- `requant.py`'s range reads.
- With numpy installed: the quantizer's selftest digests and a float64 oracle.
  Without numpy those tests skip. These checks do not establish native model quality or serving capacity;
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
it in shard 2 of the `Cluster Focused Checks` job (step `Run cluster onboarding checks`).
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

`GPTOSSPagedKVTests` compares exact rows, masks, offsets, ring metadata and
learned-sink SDPA results with `StandardKVCache` and `RotatingKVCache`. It also
checks demand allocation, bounded sliding retention, copy/trim isolation, owner
release, and that sliding pages restore only ring metadata they can continue,
then continue exactly as that ring.
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

## Pipeline decode command buffer checks

`PipelineDecodeCommandBufferTests` drives random synthetic stages of each
layer-stage family as its stage session does: the prompt under the rank's
16-operation guard, then decode once under a guard and once under
`QwenLayerStageSession.decodeCommandBuffers`. Every output row, verify window
and cache or state array must be byte-equal. The cases are a dense and a
routed-expert Qwen 3.5 on a paged stage KV host (decode steps, a captured verify
window kept to two rows, and two lanes), two Nemotron stages, a Gemma 4 decoder
(one request and two lanes), two GPT-OSS stages (decode and lanes) and the
verified GLM fixture's two stages. The reference run keeps the rank's guard,
except routed Qwen and Gemma, which use `bankGuard`: their expert banks of 2 Mi
elements each commit a buffer, as registered banks do. The Nemotron and GLM
fixtures are too small for any size bound, so every family also runs with a
buffer every second dispatch (`everyOperation`), a finer partition than one
buffer per bank. Build and stage the runtime tests as described for the cluster
runtime tests above, then, with the same build flags:

```bash
swift test --package-path libs/darkbloom-cluster -c release --skip-build --no-parallel \
  --filter 'PipelineDecodeCommandBufferTests|ContextAdmissionTests|ResidentAdmissionNemotronTests|GPTOSSResidentAdmissionTests|ResidentAdmissionGemma4Tests'
```

The admission suites check each family's decode-row charge. These are synthetic
GPU checks: not registered weights, pair runs, speed or peak memory. Served
Qwen, Nemotron and Gemma 4 stages all attend through the paged stage KV, but
only the Qwen cases use it here; the Nemotron and Gemma 4 cases keep
request-owned KV. See
[pipeline decode command buffers](../architecture/inference.md#pipeline-decode-command-buffers).

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
member-installation code. Its generation-mode check also launches MiMo tensor
parallel: both ranks get `--mtp-depth 2` after the mode exactly where the pinned
record declares tensor parallel's rounds, and the status then reports the head
as decoding. `InstalledBatchLanesCheck.swift` launches a real child
with the fixed owner arguments and checks its exact environment, supported
lane widths, out-of-range rejection, malformed-override parity even with an
eight-lane family default, admission/owner/native parity, unsupported
mode and image gates, and both member ranks. No model, GPU or real service is
started. The checks preserve the singleton and GLM tensor-parallel defaults
and the serial-prefill Gemma 4 pipeline's default lanes
(`DistributedInstalledPlan.gemma4PipelineBatchLanes`), which reach the rank,
while a Gemma setup saved with the one-chunk lookahead keeps one lane;
`DistributedInstalledLanesTests` covers the same rules for every adapter and
schedule. Actual multi-lane output, encrypted transport and retirement still require
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

## MiMo pipeline decode command buffers

`MiMoDecodeCommandBufferTests` (cluster runtime, GPU) drives two random MiMo
stages as `MiMoLayerStageSession` drives them. The prompt runs under the rank's
16-operation guard. Decode steps, a verify window rolled back to two rows and
lane steps then run twice: once under the guard and once under
`MiMoLayerStageSession.decodeCommandBuffers`. Every residual crossing the cut,
every logits row and every cache or page array must be byte-equal. The tests
cover a tiny BF16 model and one quantized like the registered row (MXFP4
experts, affine 8-bit projections, key width 192, value width 128), each on
ordinary caches and on request-owned pages. The quantized model's guard scales
MLX's size bound to its small expert banks (`bankGuard`), so each expert launch
commits a buffer, as each registered bank does. Build and stage the runtime
tests as described for the cluster runtime tests above, then, with the same
build flags:

```bash
swift test --package-path libs/darkbloom-cluster -c release --skip-build --no-parallel \
  --filter 'MiMoDecodeCommandBufferTests|MiMoResidentAdmissionTests|MiMoPagedAdmissionTests'
bash libs/darkbloom-cluster/Tests/PlacementChecks/run.sh
```

The admission tests check that every full-attention layer's decode-row scores
are charged at once (`MiMoRequestStateBudget`). The placement run includes
`MiMoRoutedExpertChecks`: the MiMo layout built from the registered headers
names 282 routed-expert tensors (160,859,947,008 bytes). The hardware prior
reads 10,767,036,288 bytes for one decode step, and the golden plans change only
by the layout they echo. These are synthetic and metadata checks. They run no
registered weights and measure no speed.

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
it assembles an independent projection/expert oracle from one-token expert
calls while preserving the original rectangular normalization and elementwise
operations. It requires one expert call, never hinted as sorted, carrying every
token's routes (grouped by expert from 64 assignments), with the oracle's
bytes, at 7 to 512 tokens. A separate expert-only composition
check compares complete singleton calls with the shared branch isolated to
zero, and a decode check requires 2, 3 and 8 independent rows to share one
call with each row's one-row bytes. A direct check compares the shared call
with one-row calls for a single row and for rows that all route to the same
experts. Ordinary and verification paths
remain covered, and the original rectangular call still sorts. These checks do not
claim whole-layer singleton equivalence: existing normalization can depend on
rectangle shape on CPU. With `GEMMA4_EXPERT_ROWS_GPU=1` the suite also
compares the shared call with one-row calls on the GPU for 1 to 2,048 rows,
tied routes included, at
a geometry with the production kernel classes; `=production` adds hidden 2,816,
expert width 704 and 128 experts. Run the GPU case alone, in an exclusive
hardware window.
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

A pair request whose admission deadline passes while a rank is still answering
ends alone. `ClusterWorkerPairAdmissionDeadlineTests` (in
`bash libs/darkbloom-cluster/Tests/RemoteChecks/run.sh`) drives a lane pair over
scripted ranks: rank 0 answers after the request's deadline while another lane
decodes, a request ends before rank 1 was asked, and a link closes during
admission. `bash libs/darkbloom-cluster/Tests/LinkWorkerChecks/run.sh` runs the
same deadline through both stand-in owners (the actual owner service) and the
loopback link, and relays a reservation past its delivery deadline to an
in-process follower. `PartialAdmissionTests` and `ProviderDeadlinePipeCheck` in
`bash libs/darkbloom-cluster/Tests/ProcessChecks/run.sh` run it with actual
children, the latter through the provider's own deadline and owner sources.
None of these is a hardware pass.

The same class checks a consumer that goes away during its prompt: on a lane
pair, a started request whose rank 0 has committed no token takes no clean
stop and is cancelled, both ranks are told at once, its lane retires alone and
the next request is served. A lane that has produced a token, and a pair
without lanes, keep the clean stop. `CleanStopTests` in `ProcessChecks` keeps
the single-lane clean stop before the first token with actual children.

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
misses, media/key isolation, allocator rounding and bounded LRU eviction. It
also checks, for every prompt from 1,100 to 70,000 tokens, that the kept
boundaries reuse at least one Mac's reuse rounded to the 512-token grid (a
repeat, the next turn, a shared system prompt). It checks each request's
charge, LOAD's one capture per lane, the shared-copy eviction order, the
memory tier giving way before a refusing gate, and that a record of another
prefix policy is in another scope. On the GPU (`QWEN_TP_BATCH_GPU=1`),
`QwenTensorParallelPrefixDepthTests` restores a 33,000-token prompt's
boundaries at 32,768, 32,256, 16,384 and 8,192 on two synthetic hybrid
shards and compares the final logits and every attention, convolution and SSM
array with a cold prefill on the same grid, byte for byte, on both ranks. The
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

Set `QWEN_TP_MTP_GPU=1` only in an isolated native test run with the matching Metal resource, and start that process with `MLX_QMV_BATCH_INVARIANT=1` as every cluster process runs (`ClusterQuantizedRowRouting`): MLX reads it once per process, and `QwenTensorParallelBatchMTPWindowTests.sharedWindowCallsKeepEveryRowsQuantizedArithmetic` checks MLX's own grouped quantized calls, which keep each row's bits only with it. Run `QwenTensorParallelBatchMTPWindowTests` and `QwenTensorParallelBatchMTPTransitionTests` with `--no-parallel` so suites do not race global MLX state. Actual tiny targets test unequal histories/keep counts, rejected-suffix settlement, greedy target-column continuation, singleton/wider transitions, independent accepted-token credits, survivor retirement, mixed ordinary rows and poisoned-cohort cleanup. The trained head remains single-row; the decoder creates the target cohort. Tied-head transition fixtures do not establish full-model acceptance behavior or sampled equivalence.

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

### Cluster model file cache before a load

These checks measure the page cache with `mincore` on temporary files they
create, on the Mac that runs them. A file just read must be in the cache first,
or the check fails rather than passing on a host that caches nothing.

- `ClusterServicePartStartCacheTests` runs the actual service loop for the
  follower's part of a saved pair setup (pairing moved away, so nothing
  listens; the part is `/usr/bin/true`). The model folder holds a 64 MiB weight
  file and a 32 MiB file one folder down, both read into the cache. When the
  part starts (`beforePartStart`), each must be under 10 % resident, and their
  bytes unchanged afterwards. Run it from `provider-swift` with
  `swift test --filter ClusterServicePartStartCacheTests`. Like
  `ClusterServiceRecoveryTests`, it gives its service a power-assertion name of
  its own (`powerAssertionReason`). macOS lists a process's assertions
  together, so suites that run services in one test process, in parallel, must
  not share the production name.
- `provider-swift/Tests/ClusterModelProvisioningChecks/run.sh provisioning`
  checks which files `ClusterModelStore.dropCachedPages` drops: regular files in
  the folder and one folder down, no symbolic link, nothing deeper.
- `libs/darkbloom-cluster/Tests/CheckpointChecks/run.sh` (and
  `CheckpointPayloadCacheTests` in the runtime tests) run
  `CheckpointPayloadCacheCheck`: after `bypassTensorPayloadCache`, a 32 MiB
  weight file read into the cache is under 10 % resident, `config.json` keeps
  its cached page, `checkUnchanged` passes, and the uncached aligned read
  returns the original bytes.

Sources: `provider-swift/Tests/ProviderCoreTests/Inference/Distributed/ClusterServicePartStartCacheTests.swift`
and `libs/darkbloom-cluster/Tests/DarkbloomClusterRuntimeTests/CheckpointPayloadCacheCheck.swift`.

### Cluster service listeners after pairing again

`ClusterServicePairingChangeTests` runs the actual service's two listeners on
loopback ports of their own (`ClusterService.Listening`), keyed from real pairing
ceremonies stored in a private home. After the same two Macs pair again, the
earlier listeners refuse the new pairing (`handshakeRejected`) until the next
check starts them again; then the new pairing is answered and the earlier one
refused. A removed pairing stops both listeners, an unchanged or unreadable
pairing store keeps the same ones, and the control node of this Mac's earlier key
is dropped. The other Mac dials without the per-user request lock, which a
cluster service running on the same Mac shares; no production port or
Thunderbolt interface is used. `ClusterConsoleChecks` (`listenersFollowThePairing`)
checks the same refusal and restart on real ceremonies and listeners without the
service, and that a re-read pairing store gives the same identity, a new
ceremony another one and an unsafe store a read failure rather than no pairing.

Focused check: `swift test --filter ClusterServicePairingChangeTests` from
`provider-swift`. Sources:
`provider-swift/Tests/ProviderCoreTests/Inference/Distributed/ClusterServicePairingChangeTests.swift`
and `provider-swift/Tests/ClusterConsoleChecks/ConsolePairingChangeChecks.swift`.

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
`QWEN_TP_REAL_GEOMETRY_GPU=1` runs `QwenTensorParallelRealGeometryRowsTests` (about 3 GB of random
weights): the 27B row contract at its registered per-rank widths (`QwenTensorParallelRowsCheck`), both
ranks in one process; start it with the worker's arithmetic environment. Its two tests each run one half
of the check (`QwenTensorParallelRowsCheck.Part`), and each half compares only against the solo runs it
makes itself: `rowsEqualTheirSoloStepsAndWindowPositionsAtRealWidths` runs the rows of 100 to 4,090
tokens (one- and eight-lane hosts, rows that join and leave, the observed cohort, the verify windows),
and `rowsAcrossKVSegmentsEqualTheirSoloStepsAtRealWidths` runs the rows of 4,000 to 4,600 tokens across
KV segments. CI runs them alone on Cluster GPU Tests shards 1 and 3; as one test they took 1,098 s
(run 42268059756) and set the run's wall time. The tool's `qwen-rows run` runs both halves.
`darkbloom-cluster-tp-check qwen-rows synthesize --output DIR` writes that checkpoint (about 2.1 GB), and
`darkbloom-cluster-tp-check qwen-rows run --model-dir DIR --report FILE` runs the check as two processes
(`MLX_RANK`, `MLX_HOSTFILE` with two free `127.0.0.1` ports; `--backend ring` or `socket`,
`--reduction native` or `sealed-bench`). `qwen-rows layers` takes the same options plus `--target ROW
--other ROW` (rows 0 to 7; default 7 beside 6) and reports, for three decode steps, the first decoder layer
whose output differs between the row alone and beside the other. Both ranks must pass the same command and
rows. `QWEN_TP_AQV_GPU=1` runs `AffineQuantizedVectorsTests`, including the fused SwiGLU against the two
projections and the compiled SwiGLU at every normal bf16 and f16 gate value.
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

A pair that registers with a coordinator is planned with equal shares only
(`ClusterPlacementPolicy.equalTensorShares`): the same `run.sh` places the
weighted check's unequal Macs under that policy as if the family offered no
unequal shares, keeps equal Macs' chosen placement and GLM-5.3-Flash's whole
plan, and refuses a retained unequal partition. From `provider-swift`,
`swift test --filter 'DistributedAutomaticBatchPlannerTests|ClusterApprovalTensorSharesTests'`
checks the guided setup's plan for Qwen3.8 27B on two unequal Macs (unequal for
a local cluster, equal for one served through Darkbloom) and that a cluster
approval beside unequal shares is refused by the leader's check before any part
stops and by the other Mac's before it saves, because a member's registration
names no shares (`NativePairMemberRoster`).

From `libs/darkbloom-cluster`, `swift test --filter QwenTensorParallelShareProbeTests`
checks the per-mille share, the probe request's shape and the probe's rounds
on the CPU: on a constructed clock, a slow prefill and warm-up leave every timed
round, slow timed rounds stop at the budget, and the limit stops every round. With
exclusive GPU custody and the matching Metal library, set
`QWEN_TP_SHARE_PROBE_GPU=1`: a synthetic shard's probe must cross nothing to its
counting peer, reduce through it again afterwards, return its request's pages
and cache, and give no probe (keeping nothing) when memory is refused, the
deadline is near, the budget or the limit runs out or the load is cancelled
midway, and give every timed round after a setup slower than the budget. These
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
