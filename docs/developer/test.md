# Test Provider And Native Contracts

> Last updated: 2026-10-22

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

```bash
make provider-test
```

The Make target builds test products, stages source-matched metallibs and uses
`scripts/run-provider-tests.sh`. The runner isolates daemon-state and loaded-model
snapshots. Preserve its watchdog, cleanup and state isolation when using a focused
selector. Use `scripts/run-nested-suite.sh` for documented nested Swift Testing
cases and `scripts/run-exclusive-native-gpu-test.sh` for exclusive native work.

The SDK has independent test products under `libs/mlx-swift-lm`. CI validates
native memory ownership, cancellation, media decoding, paged KV and resource
packaging there as well as provider behavior. Preserve all retained lane gates;
do not treat the repository split as permission to skip native regressions.

MiMo preparation uses `scripts/prepare-mimo-prompt-fixtures.py` for metadata,
`scripts/prepare-mimo-provider-fixtures.py` for bounded synthetic target/vision
weights, and `scripts/prepare-mimo-audio-fixtures.py` for hash-pinned public inputs
including the genuine audio codec. Keep output directories isolated. Routine
fixtures use symmetric 128-context geometry; the separate complete-prefix
process uses `--asymmetric` for K64/V128 and 1,024-context geometry. Audio gates
exercise PCM8 and AAC-video with a small target, not full-model quality or peak
memory. Release-only builds do not provision test fixtures or opt into native
qualification.

The MiMo FP32 preflight-refusal fixtures convert both ordinary and router
weights, so they update `dtype` and `moe_router_dtype` together. This keeps the
inventory valid until the strict BF16-only load-profile gate rejects it;
an earlier inventory error does not exercise that gate. The four `testFP32`
cases in `MiMoV26ManagedSlotTests` and `MiMoV26ServingLoadTests` require
`MIMO_V26_SERIAL_NATIVE_TESTS=1` and `MIMO_V26_SERIAL_LOAD_FIXTURES` pointing to
the symmetric synthetic fixture directory.

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
cache immutability, bounded recovery and refusal to retry ambiguous writes.
Request tests verify native schema projection preserves local bounds; workflow
tests keep current trusted scanner code separate from pinned threat-model data.
Bedrock usage tests preserve Sol cache-write input and reject malformed cache
counts; finding-text and both scan paths' analysis tests enforce raw character
limits including padding.
Lifecycle tests ensure failed backup accounting also stops a recovered primary
while preserving already validated findings.
Response-repair tests inject empty analysis in Sonnet, Opus and Sol source and
integration passes, preserve original findings and uncertainty, and stop at a
second invalid response, exhausted call budget or failed checkpoint. PR closure
has a distinct lifecycle stop code and cannot grant merge clearance.
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
