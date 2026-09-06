# Test

> Last updated: 2026-09-06 · commit `b6759aa4b`

How to run the unit tests for each component, the end-to-end suite that boots a
real coordinator + Swift provider against ephemeral Postgres, and the docs
lint — and which CI workflow runs what. `make test` runs every unit suite plus
the docs lint locally; CI runs a subset per pull request (see the CI workflow
map: the console UI job lints and builds but does not run vitest, and the
benchmark-wrapper tests run only locally). The e2e suite needs an Apple Silicon
Mac with the test checkpoints cached.

For HF artifact downloads, `HuggingFaceDownloadTests` covers source preference,
checksum rejection, fallback, and cancellation. `scripts/test-publish-model.sh`
checks the artifact workflow payload. `TestHuggingFaceArtifactPostgresAndCache`
in `coordinator/store/hugging_face_artifact_test.go` uses a disposable
`DATABASE_URL` to check storage and cache invalidation.

## Prerequisites

- Toolchain from [build.md](build.md) (`mise install`, submodules, `cmake`).
- **Postgres 16** for the coordinator store tests and the e2e suite: either
  Docker (`postgres:16` image is pulled automatically by the testbed) or a
  native `postgres`/`initdb` on `PATH` (`brew install postgresql@16`, then
  `PATH="$(brew --prefix postgresql@16)/bin:$PATH"`). The testbed prefers
  Docker when `docker` is on `PATH` (`e2e/testbed/deps/postgres.go`,
  `PostgresLifecycle.Start`).
- **Hugging Face cache** with the e2e checkpoints:
  `mlx-community/gpt-oss-20b-MXFP4-Q8` (~12.1 GB, default testbed model),
  `mlx-community/gemma-4-26B-A4B-it-qat-4bit` (~14.5 GB, second model for
  multi-model suites), and `mlx-community/gemma-4-e2b-it-4bit` (exact-cache
  routing test). CI pins revisions `GPT_OSS_REVISION` /
  `EXACT_CACHE_MODEL_REVISION` in `.github/workflows/integration.yml`.
- `golangci-lint` v2.1.6 for the lint job
  (`go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v2.1.6`;
  config in `.golangci.yml`).

## Steps

### 1. Run everything CI runs as unit tests

```bash
make test   # coordinator-test prompt-sidecar-test provider-test ui-test benchmark-wrapper-test docs-check
```

### 2. Coordinator (Go)

The CI formatting step checks tracked Go files with `gofmt`. It excludes
`docs/reports/evidence/`, whose captured source bytes are immutable and bound
by evidence manifests. Live Go source remains subject to the formatting gate.

```bash
make coordinator-test                      # cd coordinator && go test ./...
# what CI runs (repo root, race detector, Postgres-backed store tests included):
DATABASE_URL='postgres://testbed:testbed@127.0.0.1:5432/testbed?sslmode=disable' \
  go test -race $(go list ./... | grep -v /e2e)
gofmt -l .                                 # must print nothing
golangci-lint run                          # .golangci.yml
```

Store tests that need Postgres skip themselves when `DATABASE_URL` is unset
(`coordinator/store/harness_test.go`, `testPostgresStore`); CI provides a
`postgres:16` service with user/password/db `testbed`. The pre-push hook runs
`go test $(go list ./... | grep -v /internal/api)` from `coordinator/` to skip
the slow WebSocket integration tests; run the full set before merging.

### 3. Prompt-contract sidecar (Rust)

```bash
make prompt-sidecar-format   # cargo fmt --all -- --check
make prompt-sidecar-check    # cargo check --locked --all-targets; cargo clippy --locked --all-targets -- -D warnings
make prompt-sidecar-test     # cargo test --locked --all-targets
```

CI additionally builds the static Linux binary through the Dockerfile stage
(`docker build --platform=linux/amd64 --target prompt-sidecar-builder -f coordinator/Dockerfile .`),
checks `file` reports `statically linked|static-pie linked`, and replays the
production prompt vectors against it with
`scripts/verify-prompt-sidecar-linux.sh <binary>`.

### 4. Provider (Swift) — unit tests with a source-matched metallib

CI also applies the [restored-resource cleanup](build.md#restored-swiftpm-runtime-resources)
before building the debug test product.

The general provider suite passes `--no-parallel` explicitly to Swift Testing.
Unrelated cases share process-wide MLX state and executor capacity; overlapping
thousands of them can starve bounded test handshakes. Concurrency tests retain
their own tasks, barriers and interleavings. This does not serialize provider
inference or the separate model-concurrency benchmarks.

`scripts/run-provider-tests.sh` runs exact allocator integration, the controlled
ledger interleaving, the real process-environment projection test and the SSD
sidecar stage-deadline test in separate processes. The general suite excludes
those cases; each isolated invocation uses the existing nonempty/no-skips guard.
A general-suite failure does not silence the isolated gates. Isolation keeps the
stage-deadline assertion at the production budget without unrelated suite load;
it does not change an assertion or runtime resource-selection rule.

```bash
make provider-test
# = cd provider-swift && swift build --build-tests
#   ./scripts/fetch-metallib.sh <bin-path>            (build mlx.metallib from libs/mlx-swift source)
#   cp mlx.metallib into every <bin-path>/*PackageTests.xctest/Contents/MacOS/
#   cd provider-swift && swift test --skip-build
```

The metallib staging is not optional: MLX loads `mlx.metallib` from beside the
running executable, and for tests the executable is the `.xctest` runner.
Without it kernel-backed tests fail or silently exercise a different kernel
set than production. To run a subset: `cd provider-swift && swift test
--skip-build --filter <Suite>` after `make provider-test` has staged the
metallib once.

**Nested `libs/mlx-swift-lm` suites.** The paged-KV correctness gates live in
the submodule, not in `provider-swift/`. Build them once, stage the metallib,
then run each suite through [`scripts/run-nested-suite.sh`](../../scripts/run-nested-suite.sh),
which fails when a suite executes zero tests or skips any (a bare
`swift test --filter` exits 0 on an empty run):

```bash
cd libs/mlx-swift-lm
swift package unedit --force mlx-swift >/dev/null 2>&1 || true
swift package edit --path ../mlx-swift mlx-swift      # use the local mlx-swift, not the remote branch
swift build --build-tests
../../scripts/fetch-metallib.sh "$PWD/.build/debug"            # stage mlx.metallib beside the nested test runner
for b in .build/debug/*PackageTests.xctest; do cp .build/debug/mlx.metallib "$b/Contents/MacOS/"; done
for suite in CBv2PagedSafetyTests CBv2PrefixCacheHasherTests CBv2PagedEligibilityTests \
             CBv2PagedBackendTests CBv2PagedKernelTests CBv2KVSharingParityTests; do
  ../../scripts/run-nested-suite.sh "$suite"
done
```

#### Ordinary teacher-forced score diagnostics

Build and stage the source-matched metallib for both test products as above.
From the repository root, run the numerical/engine controls and the provider
input/CLI controls; the shared runner rejects empty or skipped suites:

```bash
(
  cd libs/mlx-swift-lm
  for suite in CBv2TeacherForcedScoreDiagnosticTests CBv2TeacherForcedScoringTests \
               CBv2TeacherForcedRecurrentTests CBv2TeacherForcedCapacityTests \
               CBv2PagedRuntimeDTypeEngineTests \
               CBv2TopTwoTests CBv2LogitDiagnosticTests CBv2GemmaLogitDiagnosticTests; do
    ../../scripts/run-nested-suite.sh "$suite"
  done
)
(
  cd provider-swift
  for suite in TeacherForcedBenchmarkTests BenchmarkTeacherForcedOptionsTests \
               BenchmarkSchedulerPrefillDecisionTests PrefixCacheCheckpointIdentityTests; do
    ../scripts/run-nested-suite.sh "$suite"
  done
)
```

For an actual model observation, retain exact prompt and continuation token IDs
and the verified model aggregate hash in the [input JSON schema](../provider/cli-reference.md#teacher-forced-scores).
Set `MODEL_ID`, `INPUT_JSON` and `REPORT_JSON` to the matching local model and
absolute input/output paths, then run:

```bash
darkbloom benchmark --model "$MODEL_ID" --kv-backend contiguous \
  --teacher-forced-input "$INPUT_JSON" > "$REPORT_JSON"
```

Use `paged` to observe that backend explicitly. Inspect `status`,
`inconclusiveReasons`, `plainTop1`, `activity`, `diagnostic` and
`repeatedDiagnostic`; retain the JSON even on exit 2. `observed` means the
instrumentation controls passed, not that model quality or speculative
verification passed. The controls compare ordinary forwards only
(`provider-swift/Sources/ProviderBenchmark/TeacherForcedBenchmark.swift`,
`controlReasons`).

Recurrent targets use fresh request-owned state for each scoring call. The
scorer reserves the normal admission peak before forwarding, commits evaluated
state after each chunk or forced token, and retires state and KV before refunding
the reservation. The [recurrent scoring validation](../reports/2026-09-06-recurrent-teacher-scoring.md)
covers tight capacity and open-binding failure recovery on both backends.

#### Quantized bias accumulation regression

`QuantizedBiasAccumulatorTests` covers 216 exact affine-bias cases across
BF16, FP16 and FP32 inputs, quantization widths 2/3/4/5/6/8, aligned and tail
dimensions, and one/two input rows. Zero packed weights and unit bias isolate
input accumulation from weight quantization. Run it after the
[embedded shader rebuild](build.md#swift-provider-macos):

```bash
cd provider-swift
../scripts/run-nested-suite.sh QuantizedBiasAccumulatorTests
```

The provider test target links the canonical test from `libs/mlx-swift`.
The test scopes GPU selection with public `MLX.Device.withDefaultDevice`, so
both targets compile the same test without depending on target-local helpers.
Passing these operator cases does not replace full-model trajectory, cache,
batching or performance validation.

<a id="resident-prefix-benchmark-validation"></a>

#### Explicit Gemma verifier and projection controls

Use the candidate `radix-engine` built from the same provider, native source and
metallib tuple as the test runners. Run the CPU wrapper tests first:

```bash
python3 -m unittest discover -s scripts/benchmarks -p test_run_radix_engine.py
```

After building each package's tests and staging that tuple's metallib as above,
run these filters through `scripts/run-nested-suite.sh` from the listed package:

| Package | Filters |
|---|---|
| `provider-swift` | `EngineV2BenchmarkMTPVerificationTests` |
| `libs/mlx-swift-lm` | `Gemma4Layer0ProjectionDiagnosticTests` |
| `scripts/benchmarks/radix-engine` | `BenchmarkGemmaVerifierOptionsTests`, `BenchmarkGemmaProjectionTests` |

For the radix package, set `RADIX_SOURCE_ROOT` to the absolute combined checkout
and `RADIX_CANDIDATE_BUILD=1` for both build and test commands. The tests cover
scope refusals, unchanged MTP configuration fields, actual tiny-engine rounds
and retirement, native projection shapes/parameter identity, and full-output
difference counts. They do not validate a downloaded model.

For a real-model control, append `--gemma-mtp-verification automatic` or
`--gemma-mtp-verification serial_target` to `scripts/benchmarks/run_radix_engine.py`.
Both require `--mtp on --cache off --concurrency 1 --cache-mode ssd
--production-kv-grant`, a pinned `--expected-model-sha256`, an explicit
`--kv-backend contiguous|paged`, and a compatible loaded Gemma assistant.
Omitting the flag leaves normal verifier selection unchanged. Run fresh
ordinary MTP-off, automatic and serial processes for each backend using the
same reviewed artifact, input bytes, assistant, prompt date and output limit.
Keep all seven completed trajectories and cancellation recovery evidence.

Inspect `gemma_mtp_verification_requested` together with the actual `mtp`
metrics: the selected strategy must have positive rounds and the other strategy
must have zero rounds. Compare complete prompt/output IDs and finish reasons
separately for each pair. Serial agreement cannot pass the automatic gate.

To inspect layer zero, add `--gemma-projection-tokens SEED,SECOND_TOKEN` to one
explicit-verifier invocation, without other numerical diagnostic flags. Preserve
the record or stated inference that selected the second token. The adjacent
`.gemma-projection/projection.json` and native `.bin` files retain actual
embedding, inputLayernorm and Q/K/V outputs for M1/M2, tensor dtypes/strides,
loaded parameter hashes and complete first-column differences. Check embedding
and normalized-input identity before attributing a projection difference.
Internal kernel identity is unmeasured; this process's timing is diagnostic
overhead. Neither capture nor a passing tiny-model test establishes model-token
correctness. Controls: `EngineV2BenchmarkMTPVerification.validateScope` and
`validateObservedMetrics`; export: `BenchmarkGemmaProjection.capture` in
`scripts/benchmarks/radix-engine/Sources/radix-engine/BenchmarkGemmaProjection.swift`.

#### Offline attention packet analysis

Create the [isolated NumPy environment](build.md#offline-attention-analysis-environment),
then run from the repository root:

```bash
/tmp/darkbloom-attention-venv/bin/python -B -W error -m unittest discover -s scripts/benchmarks -p 'test_attention_packet*.py'
PYTHONPATH=scripts/benchmarks /tmp/darkbloom-attention-venv/bin/python -B -m attention_packet /absolute/packet.json --output /absolute/new-analysis.json
```

The output path must be new. Review the reported status, original-query reference,
nonfinite counts and last-row consistency. `analyzed` means the calculation ran;
it does not establish model correctness or pass a release gate. Unsupported or
unconfirmed captures remain inconclusive. The [packet format](../../scripts/benchmarks/attention_packet/FORMAT.md)
defines required native bytes and metadata; [synthetic calibration](../reports/2026-09-06-attention-packet-analyzer.md)
records what the tests prove.

#### Attention operator replay

The [standalone tool](../../scripts/benchmarks/attention-replay/README.md) validates
a confirmed packet v1, then runs native SDPA and fixed/segmented paged decode
sequentially on identical Q/K/V bytes. From `scripts/benchmarks`, use the dedicated
NumPy environment:

```bash
python -B -m unittest -v test_attention_replay test_attention_packet test_attention_packet_numerics
python -B -m attention_replay --packet /owned/capture/packet.json \
  --output /owned/new-replay --prepare-only
python -B -m attention_replay --packet /owned/capture/packet.json \
  --output /owned/another-new-replay --binary /reviewed/attention-replay \
  --binary-sha256 EXACT_SHA256
```

Use a new output directory each time. The Swift CLI checks the input-transfer
hash and raw tensor hashes before MLX allocation. For captured-output reproduction,
use the capture host and reviewed runtime resources; a different device is a
separately labeled numerical experiment.

The native SPI seeds only T−1 tokens with the existing writer, then performs the
real incoming-token write through `updateAndAttend`. Full readback bytes are
checked after evaluation. Paged dispatch is observed through the existing hook;
the synthetic selection is never marked as a confirmed model sample. Native SDPA
identifies the API invoked, not an instrumented internal MLX kernel variant.

`ReplayHostTests` covers bounded transfer/IO/options. `ReplayOperatorTests` executes
24 synthetic operator cases plus one host guard, with all three genuine arms in
each operator case. The existing native reference ceiling `1e-2` and paged bound
`max(3 * contiguous relativeL2, 1e-2)` remain unchanged. Exact storage bytes and
fixed/segmented output identity are separate checks. The [milestone](../reports/2026-09-06-attention-operator-replay.md)
retains exact source and test provenance.

Original Q drives the independent CPU FP32 reference; a narrowed-Q counterfactual
is separate. Storage mismatch, nonfinite output or failure to reproduce the
originally captured backend output makes interpretation inconclusive. Failed arms
stop and retain their process receipt even if log hashing fails. No model-token
or numerical release gate is evaluated. Supplied-history placement does not prove
original model-history correctness; the full-history mirror and cross-backend
Q/K/V identity remain separate investigations.

#### Segmented metadata profiler

Use the [isolated optimized build](build.md#segmented-metadata-profiler) on an idle
Apple Silicon host, with matching runtime resources beside the binary:

```bash
/absolute/path/to/BenchSegmentedDecode --owners 10 --offset 5584 --warmup 8 --steps 64 --repetitions 3 > /absolute/new-measurement.json
```

The tool compares cached and freshly rebuilt metadata on identical synthetic
inputs and refuses differing output or full-history hashes. Inspect per-owner
hit/rebuild counts, resolved geometry and separate host/fenced timings. These
measure attention work; use the real-model benchmark for end-to-end performance.
The [measurement record](../reports/2026-09-06-segment-metadata-profiler.md) retains
the source, boundary tests and observed timing scope.

#### Prefix-cache benchmark validation

The standalone scripts under [`scripts/benchmarks`](../../scripts/benchmarks/radix_prefix_cache.py)
retain complete requests, SSE events, token counts, cache evidence, and GPU
telemetry. Use a dedicated idle Mac with the model already downloaded. The
runner refuses concurrent ranked work and owns only its child processes.

```bash
# Use the attention-analysis environment below for the NumPy-dependent tests.
/tmp/darkbloom-attention-venv/bin/python -m unittest discover -s scripts/benchmarks -p 'test_*.py'
python3 scripts/benchmarks/run_radix_http.py --binary /path/to/baseline/darkbloom \
  --output /path/to/new-baseline-run --mtp off --cache on
python3 scripts/benchmarks/run_radix_http.py --binary /path/to/candidate/darkbloom \
  --output /path/to/new-candidate-run --mtp off --cache on \
  --replay /path/to/new-baseline-run/http/report.json
python3 scripts/benchmarks/run_radix_engine.py --binary /path/to/radix-engine \
  --model-directory /path/to/pinned-model-snapshot \
  --input /path/to/new-baseline-run/http/report.json \
  --output /path/to/new-engine-run --cache on
python3 scripts/benchmarks/compare_radix_engine.py baseline-engine.json candidate-engine.json \
  --expect-cache-hits
```

Build each engine probe using the [pinned-worktree instructions](build.md#prefix-cache-benchmark-executable).
HTTP equality proves full text and token counts; the engine comparison checks
actual generated token IDs, clean termination, saved tokens, tenant separation,
and cancellation recovery. Compare MTP-on and MTP-off against their respective
baselines. A cache lookup with zero saved tokens does not demonstrate reuse.
The connected SSE reader treats `reasoning_content` and `reasoning` as aliases
for one delta: it appends one value and rejects conflicting non-null values.
Different chunk boundaries must not change reconstructed reasoning. The captured
real-stream replay runs under `go test ./e2e -run '^TestConnectedReasoning'`
(`e2e/connected_cache_reasoning_test.go`).
For schema-2 reports, the default cache axis requires cache off then cache on,
with the same requested store/key modes and resolved backend. Every disabled
probe must report zero saved tokens and no hit. Use `--axis backend` for a
contiguous-to-paged pair with identical cache settings. Legacy report support
does not establish the current release gates (`compare_radix_engine.py`, `compare`).
Both runners accept `--mtp on` and `--kv-backend paged`; their defaults are MTP
off and backend auto. The current direct candidate defaults to `--cache-mode ssd`.
It uses the normal slot factory, production prompt/tool normalization, normal
MTP preparation and verified pre/post-load model identity. For an external
assistant, `--assistant-directory` supplies an exact flat artifact to the normal
offline verification funnel; it does not bypass target compatibility.
The directory must contain only `config.json` and its safetensors files; keep
the catalog/provenance manifest outside it. `SpecDecStore.inspectLocalArtifact`
rejects other entries, including `manifest.json`.
`--expected-model-sha256` pins the aggregate and `--prompt-date YYYY-MM-DD`
pins missing request-owned dates for paired runs. Raw media needs the HTTP path. It refuses requested MTP without an active driver,
a cache-on arm without a ready SSD store, and any resident-memory opt-in.
Start TTFT before `session.submit` so authenticated staging is included
(`EngineV2Factory+BenchmarkSession.swift`, `BenchmarkLoader.swift`).

For bounded concurrency, add `--concurrency 2` or `--concurrency 4` to the
engine runner. Each input is submitted as that many simultaneous requests;
reports retain every row, submission failure, batch duration, aggregate output
rate, and capacity/MLX-memory samples at 100 ms intervals. Compare with a cold
oracle from the same binary, concurrency, slot grant, model and MTP mode.
Choose the grant mode explicitly for the measurement. Use
`--production-kv-grant` for a single loaded model's full production grant, or
`--kv-budget-gib N` for an explicit envelope control. With neither flag the
historical explicit default remains 16 GiB. B1/B2/B4 changes request concurrency,
not the number of loaded model slots. Record the observed backend and capacity,
and reject a requested paged arm that falls back. The comparator rejects missing/failed batch rows and unobserved
concurrency in either arm. B4 identifies four submitted requests; the sampled
overlap check does not certify four simultaneously admitted sequences or a
continuous memory peak. It checks staged-memory release after the whole batch drains;
another active request may still own staging when an individual row ends.
These raw-engine batches exercise shared native admission for segmented storage;
they do not cover bridge dispatch, contiguous bridge reservations or HTTP framing.
When the native engine exposes `paged_storage`, before/after metrics and batch
samples retain its queue-captured grant, committed backing, reserved/live pages,
poison, slack, and over-grant bytes, plus segment and address-page counts.
Committed bytes measure physical backing; they are not the logical token limit.

For a production-grant run, add the flag to the existing candidate invocation:

```bash
python3 scripts/benchmarks/run_radix_engine.py --binary /path/to/final/radix-engine \
  --model-directory /path/to/exact-model \
  --input /path/to/pinned-http-report.json --output /path/to/new-run \
  --cache-mode ssd --key-mode persistent --cache on --kv-backend paged \
  --mtp on --concurrency 4 --production-kv-grant \
  --expected-model-sha256 "$MODEL_SHA256" --prompt-date 2026-09-05 --trial 1
```

Set `MODEL_SHA256` to the verified target aggregate. Keep the model's configured
MTP posture: use `--mtp off` for GPT-OSS; supply the verified
`--assistant-directory` for Gemma's normal assistant. Repeat with cache off,
contiguous storage and the other concurrency/trial values required by the plan,
using the same artifact and prompt date. The flag does not promote a different
artifact or silently disable MTP.

Verify `kv_grant_mode = "production_single_slot"` and the recorded
`production_grant`: hard/effective cap, operator reserve, cap fraction, loaded
target/assistant/total weights, activation reserve, zero RAM prefix allowance,
`slot_count = 1`, fleet budget and resulting grant. Require the actual engine
ceiling and shared process cap/reserve to agree with those inputs. The separate
`post_build_headroom_bytes` must pass the normal minimum serviceability gate;
a larger logical grant cannot waive insufficient live OS/activation headroom.
`post_load_maximum_kv_bytes` is the retained Memory.active diagnostic and an
explicit-mode guard only. Production mode uses loaded `SlotSizingSnapshot`
facts, not that allocator observation. See the
[grant mechanism](../architecture/hardware-support.md#kv-slot-grants).

Production mode is unavailable to resident reproduction, native-type-only probes
and callers injecting a multi-session budget. Co-resident tests must use the
real provider lifecycle or explicit grants with one shared process authority.
The comparator requires paired production-grant inputs to match and rejects
missing or inconsistent grant/headroom evidence (`radix_engine_evidence.py`,
`production_grant_errors`; `compare_radix_engine.py`, `compare`).

The candidate's `--native-kv-probe-only` mode requires cache-off, MTP-off and
concurrency one. Preserve its actual prefill/decode K/V observations before
selecting a paged native-type table. This target-only diagnostic does not prove
paged serving, MTP execution or prefix reuse; those require the normal benchmark
arms and their output oracle.

Record actual cache mode, key mode, stage time, saved tokens and idle reservation
counters. The session waits for pending refunds after a serial terminal. The
candidate harness then polls immutable snapshots at known serial, whole-batch
and shutdown boundaries until retirement is observable, with a five-second
monotonic deadline and cooperative yields. It does not advance engine steps or
change native gauges. Concurrent rows retain immediate observations; only their
completed batch has an idle boundary. Its
normal construction, shared native ownership and SSD staging are real; the
raw-engine measurement omits bridge dispatch, contiguous bridge reservations,
HTTP framing and coordinator routing.
Schema-2 SSD acceptance requires zero request activity, live KV and reserved/live
pages after serial rows and complete batches. The idle admission charge may
equal retained free physical backing. Shutdown additionally requires zero
segments, committed backing and process owners/closing owners/C/M/unmaterialized
promises. Logical `address_pages`, model-weight memory, allocator cache and RSS
need not be zero (`radix_engine_evidence.py`, `retirement_errors`).
Inspect `idle_observation`: `status` (`ready`, `timed_out`, `cancelled`),
`shutdown`, `attempts`, `elapsed_s`, `timeout_s`, and `pending_retirement`.
Timeout or cancellation preserves the last observed tuple and fails the result;
later successful cleanup does not replace an earlier failure. The deadline
bounds repeated polling, not an arbitrarily blocked snapshot implementation.
Request TTFT, decode, terminal-tail and batch elapsed timers stop before this
observation wait (`BenchmarkIdleObservation.swift`, `capture`). Archived reports
without coherent observations retain their original idle failures; terminal
delivery alone does not prove that gauges have published or that memory leaked.
Local provider HTTP measurements cover bridge admission and framing. Coordinator
routing has separate Go regression coverage; an end-to-end routing claim requires
a live multi-provider run. Record source and artifact hashes with every result;
[the cache architecture](../architecture/prefix-cache.md) links retained validation
evidence.

Schema 2 writes an atomic initial report before loading, then preserves every
completed, failed, aborted or not-run cell. Raw token IDs, chunks, usage and
errors survive a failure; later cells stop. Use distinct invocations with
`--trial 1`, `--trial 2`, and `--trial 3` for independent process repetitions.
Each invocation uses a fresh payload root unless `--cache-directory` explicitly
selects one for a restart test. Retain binary/model/input hashes, request date,
assistant identity, actual backend, key mode, slot grant and concurrency.

The comparator defaults to `--axis cache`, which requires the same backend.
Use `--axis backend` for contiguous versus paged with cache enabled state and
other settings held fixed. Missing, failed, unmatched or unexercised required
cells fail comparison; a clean fast completion is not cancellation evidence.
The current direct harness records `cancellation_probe_version = 2`. It first
completes a donor in the exact cancellation scope in both compared arms. For
paged SSD cache-on, cancellation must then show a real hit, staged import,
positive matched/saved tokens and a fresh authenticated read-byte increase.
The cancelled output must match a prefix of the donor output, and recovery
must reproduce the full donor output. Keep an eligible long-prompt control;
a short prompt below cache policy thresholds cannot establish this restore
case. The completed donor remains reusable after cancellation. Version 1
reports establish cold cancellation only and cannot be compared as version 2
(`RadixBenchmark.swift`, `BenchmarkGeneration.swift`,
`radix_engine_evidence.py`, `cancellation_errors`).

Decode rate excludes every token in the first nonempty delta and divides the
remaining tokens by elapsed time between the first and last deltas. This avoids
counting a first MTP chunk as later decode work; reports retain both raw counts.
Batch samples also retain process commitments, materialized backing, other
allocator use, retirement debt, allocator padding and write-host ownership.
Sampling observations are not a continuous peak guarantee.

Keep evidence scopes separate. `SegmentedProductionGrantTests` exercises native
page/ring/dtype and normal Qwen MTP accounting in synthetic 36/64/128 GiB
memory envelopes; zero-page construction and pure accounting are not measured
model capacity. `BenchmarkProductionGrantTests` checks policy composition and
the separate live minimum gate. A source freeze documents unrun code; a compiled
test result proves only its exercised fixtures. Neither replaces exact-model
B1/B2/B4 serving, real admission boundaries, latency/memory observations or
co-resident load/unload runs. These changes leave `auto` on contiguous until the
release's real-model/default-promotion gates pass.

The Python runner binds all three isolated-cache controls together: it sets
`DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL=1`, the owned
`DARKBLOOM_PREFIX_CACHE_TEST_ROOT`, and
`DARKBLOOM_PREFIX_CACHE_TEST_PERSISTENT_KEY=1` for persistent/default mode or
`0` for explicit ephemeral mode. These values override inherited test settings.
The root override is ignored without the affirmative isolation opt-in.

`--cache-mode ssd --key-mode persistent` is the SSD default and requires the
normal persistent KEK unless an explicit test namespace is selected;
`--key-mode ephemeral` is a non-restart test control.
Current SSD reports must prove the requested actual `metrics_loaded.key_mode`;
a missing or different mode fails the wrapper after preserving the report.
When invoking the executable directly, set the same environment controls as
well as the final `persistent-key` or `ephemeral-key` argument. That argument
controls acceptance and does not by itself select the key. Cache construction
refusal retains the exact pre-shutdown model status and evidence-source presence
in `EngineV2BenchmarkSession.Failure.ssdUnavailable`.

Assert persistent key mode, expected SSD mode and no resident bank for a restart
claim. Launch a fresh OS
process using the same binary/model,
identity settings, keys and payload root; an in-process `shutdown` is not a
restart or model-unload proof because the session/`Loaded` value can still own
`rawEngine`. Key bytes remain in the selected Secure Enclave/Keychain hierarchy,
never the payload root. Exact controls are in [the SSD reference](../reference/ssd-kv-cache.md#environment-variables).

<a id="isolated-persistent-test-namespace"></a>

For a standalone persistent test that keeps the default key selectors untouched,
provide both `--persistent-test-namespace UUID` and
`--persistent-test-access-group GROUP` alongside explicit `--cache-mode ssd
--key-mode persistent`. Use a fresh owned `--cache-directory` outside protected
cache roots and the concrete access group authorized for the signed benchmark.
For a later restart comparison, retain the same UUID, group, payload root,
binary/model/input identities and launch a new process into a new output directory.

The wrapper sets the three isolation environment controls above and forwards the
paired options unchanged except canonical UUID casing. Direct executable callers
must set the same context themselves. Partial/duplicate options, resident or
ephemeral mode, probe-only mode and unsafe roots refuse before model or key work.
The shared key loader repeats validation and forbids ephemeral fallback for a
namespace even when the isolation opt-in is enabled. Reports bind namespace,
enclave/wrapped-KEK selectors, root, group and observed key mode; cache-off rows can
truthfully report no created key. No key bytes are exported.

CPU wrapper coverage is `test_radix_persistent_test_keys.py`. Candidate Swift
coverage is `SSDPersistentTestKeyNamespaceTests` and
`BenchmarkPersistentTestKeysTests`; the former injects persistent-loader spies,
while the latter also verifies combination with packet/metadata/logit options.
Keep real Secure Enclave/Keychain tests separate from these source fixtures.
The [validated milestone](../reports/2026-09-06-persistent-ssd-test-namespace.md)
records 23 provider and 24 benchmark functions, with exact old/current source
provenance and preserved failures. This seam does not isolate full HTTP provider
attestation and is not evidence of an actual persistent restart.

Use `--cache-mode resident` only to reproduce earlier candidate artifacts.
That arm supplies a 1 GiB, 32-entry bank with two checkpoints per request, or
paged resident blocks on the explicit paged backend. Inspect `capacity_refusals`,
`retained_bytes`, `kv_compactions` and `kv_compaction_bytes` for long prompts.
Paged cancellation may leave finalized prefill blocks reusable; complete SSD
and hybrid-bank publication require natural donor termination. All arms require
exact recovery output. The comparator rejects observed cache-budget violations;
a latency-only plan reports no decode rate.
The historical [M5 baseline report](../reports/2026-09-05-radix-prefix-cache-baseline.md)
retains exact artifacts and measurement limits.
Use the [Gemma QAT4bit observation and paired-run evidence](../reports/2026-09-05-gemma-qat4-initial-pairs.md)
for that exact production artifact; keep it distinct from the earlier 8-bit Gemma
fixture. Native observer shapes describe incoming writes, not accumulated cache length.
The [initial supported backend groups](../reports/2026-09-05-supported-backend-groups.md)
retain passing GPT/Gemma8 comparisons, failing Qwen3.5 backend comparisons and
explicitly unrun historical contiguous-SSD cells. A passing cache pair alone
does not establish attention-backend parity.

To inspect a differing target decision, append both
`--logit-diagnostic-position <zero-based-output-index>` and
`--logit-diagnostic-candidates <id1,id2>` to the unchanged engine-wrapper command.
This requires B1 and explicit `--cache-mode ssd`; preserve the original backend,
MTP, cache-on/off setting, prompt and output budget. Capture observes the first
main request after warmup. Compare its emitted IDs and preceding context with
the corresponding uninstrumented control before interpreting the compact
`logit_diagnostic` records. Rejected speculative suffixes do not prove emitted
history, and missing confirmed records are inconclusive. Additional reductions
can perturb adaptive scheduling; do not use diagnostic runs as performance data.
Diagnostic top-two reduction is model-independent. It reuses a retained MTP
policy reduction when available and otherwise uses the common reducer; enabling
the diagnostic does not grant a model MTP policy eligibility. The
[generic reducer validation](../reports/2026-09-06-generic-logit-diagnostic-reducer.md)
covers the actual Gemma adapter. The [real-model QAT logit rerun](../reports/2026-09-06-gemma-qat-actual-logits.md)
passes four integrity cells and captures confirmed normal-MTP decisions while
retaining the strict backend token failure.
The [diagnostic source and validation record](../reports/2026-09-05-bounded-logit-diagnostic.md)
describes the bounded payload and unmeasured quantities.
The [Qwen3.6 actual-logit record](../reports/2026-09-05-qwen36-actual-logits.md)
retains same-build trace controls and the unresolved backend decision difference.
The [Gemma QAT MTP-off backend controls](../reports/2026-09-06-gemma-qat-mtp-off-controls.md)
pass exact comparison across all seven completed trajectories; the normal-MTP
failure remains a separate acceptance gate.


To observe actual attention input/cache dtypes, append
`--attention-metadata-position <zero-based-output-index>` to an ordinary B1,
MTP-off command with explicit `--cache-mode ssd`. Preserve cache-on/off, backend,
prompt and output budget. Index zero is unsupported because it is a prefill
decision. This flag can accompany the logit flags for the same position. Require
`attention_metadata.status=captured`, complete owner records and confirmed
seed/target identity before interpreting the result. Strides describe graph
construction; no tensor contents are captured. Use identical uninstrumented
controls and keep diagnostic timings out of performance summaries. The
[attention metadata validation record](../reports/2026-09-06-attention-metadata-diagnostic.md)
describes the bounds and lifecycle checks.

To capture native tensor bytes for one full-attention owner, append both
`--attention-packet-position <zero-based-output-index>` and
`--attention-packet-layer <dense-storage-index>` to the same ordinary B1,
MTP-off wrapper command with explicit `--cache-mode ssd`. Preserve backend,
cache-on/off, prompt and output budget. Position zero is unsupported. The dense
storage index is distinct from the original model layer index; verify both in
the captured owner metadata. Packet, metadata and logit selections are independent.

Require a captured, confirmed packet and unchanged completed trajectories against
a control from the same build before interpreting its bytes. The benchmark writes
the descriptor and six hashed native buffers beneath `report.attention-packet`;
use the [packet format](../../scripts/benchmarks/attention_packet/FORMAT.md) and
[offline analysis procedure](#offline-attention-packet-analysis). Unsupported
geometry, incomplete history, a pending graph or an exceeded capture budget makes
the diagnostic inconclusive. Diagnostic timings are excluded from performance
comparisons. The [capture validation record](../reports/2026-09-06-attention-packet-capture.md)
documents native lifetime, byte-integrity and benchmark export coverage.

The [Qwen3.6 owner-0 packet record](../reports/2026-09-06-qwen36-owner0-packets.md)
retains four passing control/capture integrity cells, identical captured Q/K/V,
786 differing BF16 output elements and descriptive CPU reference comparisons.
The [same-input operator replay](../reports/2026-09-06-qwen36-owner0-operator-replay.md)
reproduces each captured output on its corresponding real operator, with exact
full KV readbacks in fixed and segmented paged pools. The strict whole-model
token comparison remains failed; this selected operator result is separate
from model-quality acceptance.
The [dispatch cache runtime comparison](../reports/2026-09-06-qwen36-dispatch-cache-comparison.md)
retains three matched pairs per MTP mode, exact complete trajectories and
chunk-aware delivered throughput, with mixed normal-MTP timing preserved.

For isolated Qwen3.6 attention geometry, run
`swift test --skip-build --filter 'CBv2PagedKernelTests/qwen36'` in the prepared
native package after building its tests. Require all 13 expanded cases and no
skips, then run `CBv2PagedKernelTests`, `CBv2PagedSegmentTests`, and
`CBv2PagedNativeDTypeTests` to cover the existing fixtures. Swift Testing filters
also match source filenames: the last filter includes two
`CBv2NativeKVTypeProbeTests` functions in the same file. Preserve actual suite and
case counts, numerical observations and failures. The [geometry validation record](../reports/2026-09-05-qwen36-attention-geometry.md)
distinguishes synthetic attention/storage coverage from real-model output parity.

For the corresponding unit tests, use the native nested-suite procedure above
with `CBv2PagedPrefixBlockCacheTests`, `CBv2PagedPrefixLeakTests`,
`CBv2PagedPoolGuardTests`, `CBv2FirstTokenWorkProjectionTests`,
`CBv2FirstTokenDeadlineEngineTests`, `CBv2TokenRadixIndexTests`,
`CBv2HybridPrefixCacheTests`, `CBv2RecurrentStateTests`,
`CBv2CompleteCheckpointTests`, and `CBv2CompleteCheckpointEngineTests`. Filters name the
declared test types, which can differ from filenames; the replay-plan class is
`CBv2FrozenReplayPlanTests`. MTP checkpoint checks also use
`Qwen35MTPDraftTrimTests` and `CBv2QwenMTPIntegrationTests`. Provider integration
filters include `EngineV2BridgeTests`, `EngineV2KVBackendGateTests`,
`PrefixCacheReceiptTests`, `SSDPrefixCache`, `ResidentPrefixCacheEvidenceTests`,
`SSDNativePrefixBuilderTests`, `SSDHybridCheckpointStoreTests`, and
`SSDCheckpointStageReservationTests`.
Use `EngineV2BridgePumpReceiptTests` for the real-engine submission/receipt
lifetime and cancellation regression; the [baseline failure and corrected-run evidence](../reports/2026-09-05-prefix-receipt-pump-ownership.md)
records its exact source and validation scope.

**Prompt parity** — `./scripts/verify-prompt-parity.sh` proves the three
prompt-contract implementations agree on the same production vectors; the
procedure, its inputs and the regeneration flow are in
[step 9](#9-prompt-contract-parity-fixtures-and-vectors).

**Installer** — `./scripts/test-install-atomic.sh` exercises the atomic
install/replace path of `scripts/install.sh` in a temp dir (and runs
`scripts/sync-install-embed.sh check` first).

### 5. Console UI and Admin UI

```bash
make ui-test                     # cd console-ui && npm test  (vitest run)
make ui-lint                     # npx eslint src/
make ui-build                    # next build
cd admin-ui && npm test && npm run lint && npm run build
node --test landing/earn-calculator-core.test.js
```

### 6. Scripts and release integrity

```bash
make benchmark-wrapper-test        # python3 -m unittest discover -s gemma_contbatch/tests -t .   (in scripts/)
./scripts/check-release-version.sh # ProviderCore.version == coordinator LatestProviderVersion (see operations/provider-release.md)
python3 scripts/test-provider-release-resolution.py # signed-validation and publication routing before credentials
./scripts/sync-install-embed.sh check   # coordinator/api/install.sh byte-identical to scripts/install.sh
./scripts/test-prod-env-refresh.sh      # deploy/gcp/prod/refresh-env.sh contract
./scripts/test-publish-model.sh         # scripts/publish-model.sh dry-run contract
```

Version checks, release routing, installer parity and production environment refresh
run in CI job "Release Integrity".

For GPT-OSS profiling, first build a release benchmark binary and identify its
loaded Metal library and the exact downloaded model snapshot. Run on an idle
Apple Silicon host; the runner executes one cell process at a time and records
host state before and after each cell. The runner does not build or stop other
processes. Set the paths below to those artifacts, then run:

```bash
PYTHONPATH=scripts python3 -m unittest discover -s scripts/gptoss_profile/tests -v
python3 scripts/profile-gptoss.py run \
  --binary "$GPTOSS_BENCHMARK_BINARY" --metallib "$GPTOSS_METALLIB" \
  --model-dir "$GPTOSS_MODEL_SNAPSHOT" --output artifacts/gptoss-profile/baseline \
  --phase decode --cells decode-512-b1,decode-512-b2,decode-512-b4
python3 scripts/profile-gptoss.py summarize artifacts/gptoss-profile/baseline
```

Omit `--phase` and `--cells` for the full prefill/decode/arrival matrix; defaults
are five measured repetitions and 256 decode tokens. Prefix caching and MTP
are absent from the benchmark factory. The wrapper also disables their process
flags, clears inherited experimental controls, and uses an empty default TOML
unless `--config` is supplied. `--build-receipt` records the supplied build
receipt hash; the current source fingerprint alone does not establish how a
binary was built. The matrix manifest pins the iteration count, decode budget,
and KV backend; changing any of these requires a new output directory, even
when adding different cell names. The binary, metallibs, config, build receipt,
and full model inventory/content hashes are rechecked before and after each
new cell, outside its timing interval. Source: `scripts/gptoss_profile/runner.py` (`execute`),
`scripts/gptoss_profile/config.py` (`cells`, `environment`).

Verify `summary.json` has no failed cells and inspect `summary.csv`,
`summary.md`, and the raw per-cell output. Decode headlines use the common
host-observed interval in which every row is decoding, require at least 32
tokens from each row, and report aggregate/B separately from actual row rates.
This timing does not prove scheduler batch occupancy. Failed or changed
artifacts are not silently reused; use a new output directory for different
provenance or `--rerun` to archive and repeat an identical cell. Instrumented
runs require `--mode diagnostic` and a separate output directory. Source:
`scripts/gptoss_profile/validation.py` (`validate`),
`scripts/gptoss_profile/summary.py` (`summarize`).

For paired prefill or decode comparisons, create a schema-1 design with two
arms (`A`, `B`), explicit binary/metallib/build receipt paths, identical context
length and phase, and explicit environment overrides. Run
`PYTHONPATH=scripts python3 -m gptoss_profile.controls <design.json> --output <directory> --cycles 2`.
Prefill uses `cell: {"phase":"prefill","context":8192,"batch":1}` and compares
TTFT; decode compares aggregate common-window throughput and output hashes.
Prefill token parity is explicitly unavailable in this report schema. Keep
numerical/KV tests separate from uninstrumented timing. The decode warmup now
uses the requested generation length so long prompts can establish the full
batch before measured work. Failed construction, submission, terminals or token
counts in any warmup abort the sweep before decode measurements. Schema 7 submits requests in row-index order before
concurrently consuming their streams; validation checks the recorded order and
timestamps. Batched decode requires schema 7; historical schema-6 raw data remains
available but is rejected for new performance comparisons, including when
re-summarizing saved ABBA runs. Legacy single-row schema 6 remains accepted.
Scaling ratios also require matching backend, decode budget and iteration count
when reading older manifests without the matrix workload field.
This prevents task scheduling from silently changing admission order. Sources: `scripts/gptoss_profile/controls.py`
(`execute_controls`), `scripts/gptoss_profile/control_report.py`
(`summarize_controls`), `provider-swift/Sources/ProviderBenchmark/ThroughputSweep.swift`
(`measureDecode`). See [GPT-OSS optimization results](../reports/2026-09-05-gptoss20b-optimization-results.md).

### 7. Docs lint

```bash
make docs-check          # scripts/docs-check.sh — stamps, relative links, cited paths, orphans
make docs-stamp FILES="docs/developer/test.md"   # refresh a stamp after editing
```

### 8. End-to-end suite

The e2e package (`e2e/`, harness in `e2e/testbed/`) boots ephemeral Postgres,
a coordinator from the current tree, and one or more **real** `darkbloom`
provider processes serving MLX checkpoints, then drives the OpenAI-compatible
API. It is a Go test binary; run it from the repo root with `-p=1` (suites
share GPU/ports).

```bash
# Blocking lane as CI runs it (paged KV @ 8, engine-reported backend asserted):
DARKBLOOM_TESTBED_KV_BACKEND=paged DARKBLOOM_TESTBED_MAX_CONCURRENT=8 \
DARKBLOOM_TESTBED_EXPECT_KV_BACKEND=paged \
go test ./e2e/ -count=1 -v -timeout 25m -p=1 \
  -run 'TestIntegration|TestProfile' -skip '^TestIntegrationExactCacheRouting$'

# Default posture (no TOML written; .auto resolves contiguous as of v0.8.1):
DARKBLOOM_TESTBED_EXPECT_KV_BACKEND=contiguous \
go test ./e2e/ -count=1 -v -timeout 10m -p=1 -run '^TestIntegration_(NonStreaming|Streaming)Inference$'

make e2e-integration     # go test ./e2e/... -run TestIntegration -v   (no posture pins)
make e2e-benchmark       # go test ./e2e/... -run TestBenchmark -v
```

The harness builds the provider itself (`e2e/testbed/provider.go`,
`BuildProvider`): `swift build -c release` (or `TESTBED_PROVIDER_CONFIG=debug`)
and stages `mlx.metallib`, unless `DARKBLOOM_PROVIDER_BINARY` points at a
binary that already has `mlx.metallib` beside it.

| Env var | Read in | Effect |
|---|---|---|
| `DARKBLOOM_REPO_ROOT` | `e2e/testbed/suite.go` | Repo root (auto-detected from cwd when unset) |
| `DARKBLOOM_PROVIDER_BINARY` | `e2e/testbed/provider.go`, `e2e/mixed_version_test.go` | Use this provider binary instead of building; needs `mlx.metallib` beside it |
| `TESTBED_PROVIDER_CONFIG` | `e2e/testbed/provider.go` | `release` (default) or `debug` SwiftPM configuration for the built provider |
| `DARKBLOOM_TESTBED_MODEL` / `DARKBLOOM_TESTBED_MODEL_B` | `e2e/testbed/config.go` | Override the default (`mlx-community/gpt-oss-20b-MXFP4-Q8`) and secondary (`mlx-community/gemma-4-26B-A4B-it-qat-4bit`) checkpoints; must be CBv2-servable |
| `TESTBED_MODEL_ID` | `e2e/testbed/suite.go` | Per-suite model override |
| `DARKBLOOM_TESTBED_KV_BACKEND` | `e2e/testbed/config.go` (`ResolveKVBackend`) | `auto` / `paged` / `contiguous` written to the provider TOML as `engine_v2_kv_backend`; unset = provider default |
| `DARKBLOOM_TESTBED_MAX_CONCURRENT` | `e2e/testbed/config.go` (`ResolveMaxConcurrent`) | `engine_v2_max_concurrent`; unset = the provider default ([`../provider/cli-reference.md`](../provider/cli-reference.md#providertoml-keys-read-by-the-cli)); malformed value is a hard error |
| `DARKBLOOM_TESTBED_EXPECT_KV_BACKEND` | `e2e/testbed/kv_expectation.go` | Pre-warm every slot and fail unless the heartbeat's `kv_backend` equals this |
| `DARKBLOOM_CBV2_PAGED_KV` | `e2e/testbed/config.go` | Provider fleet kill switch; CI refuses to run the paged gate when it is set |
| `DARKBLOOM_PROMPT_SIDECAR_BINARY` | `e2e/exact_cache_routing_test.go` | Path to a built `promptsidecar` for exact-cache routing |
| `DARKBLOOM_EXACT_CACHE_TEST_MODEL` | `e2e/exact_cache_routing_test.go` | Override the exact-cache fixture (`mlx-community/gemma-4-e2b-it-4bit`) |
| `DARKBLOOM_MIXED_VERSION`, `DARKBLOOM_MIXED_VERSION_EXPECT` | `e2e/mixed_version_test.go` | Enable the released-v0.7.12 lane; required tier `artifact` (verify pinned digests) or `full` (boot the released provider — needs SIP enabled) |
| `DARKBLOOM_QWEN38_E2E`, `DARKBLOOM_QWEN38_MTP_PATH`, `DARKBLOOM_QWEN38_MTP_MANIFEST_PATH`, `DARKBLOOM_QWEN38_MTP_REVISION` | `e2e/integration_test.go` | Opt-in Qwen3.8 real-process tools/video lane with a local MTP build |
| `DARKBLOOM_FULL_NETWORK_SMOKE` | `e2e/integration_test.go` | Opt-in full-network multi-model routing smoke |
| `BENCHMARK_MD_PATH` | `e2e/benchmark_test.go` | Where `TestBenchmark*` writes the Markdown results table |

**Inventory** (`rg '^func Test' e2e/*.go` is authoritative):

| File | Tests |
|---|---|
| `e2e/integration_test.go` | `TestIntegration_NonStreamingInference`, `_StreamingInference`, `_GreedyDeterminism`, `_MultipleRequestsAccounting`, `_E2EEncryptionCorrectness`, `_BillingBalanceDeduction`, `_ProviderPayoutSplit`, `_InsufficientBalance`, `_InvalidModel`, `_StreamingContentValidation`, `_ConcurrentRequests`, `_AttestationHeaders`, `_SwiftProviderRealRoutingGates`, `_FullNetworkSingleSwiftProviderMultiModelRouting`, `_ReferralRewardDistribution`, `_Qwen38RealProcessToolsAndVideo`; plus `TestQwen38GatePolicy`, `TestQwen38ExpectedBuiltKVBackend` |
| `e2e/profile_test.go` | `TestProfile_SingleProviderNonStreaming`, `TestProfile_RequestProfilesRecorded` |
| `e2e/exact_cache_routing_test.go` | `TestIntegrationExactCacheRouting` (expected red on paged with the e2b fixture; informational step in CI) |
| `e2e/mixed_version_test.go` | `TestIntegrationMixedVersionReleasedV0712Provider`, `TestIntegrationMixedVersionGateContract` |
| `e2e/benchmark_test.go` | `TestBenchmark_SingleProviderStreaming`, `_SingleProviderNonStreaming`, `_MultiModelMultiProvider`, `_HighConcurrency`, `_QueueSaturation`, `_ManyUsers`, `_SingleModelScaling`, `_HeavyLoad_100Concurrent_10KB`; config tests `TestBenchmarkSuiteConfig*`, `TestBenchmarkControlSuiteIsIsolatedAndMatchesPosture`, `TestBenchmarkCapacitySaturationPolicy` |

### 9. Prompt-contract parity fixtures and vectors

`fixtures/prompt-contract/v1` is shared by the Rust, Go and Swift
prompt-contract tests: `contract_vectors.json` and `block_hash_vectors.json`
(identity and chain vectors), `corpus.json` (complete requests for tools, null
sanitization, Harmony and Gemma normalization, reasoning effort, Unicode, all
four endpoints, exact block multiples and long prompts),
`production_vectors.json` (per-model normalized bodies, token IDs and
boundaries) and `manifests/` (the catalog snapshot the vectors were generated
from). Production tokenizer/template/config artifacts are **not** in the
repository; the vectors are generated only from manifest-pinned,
coordinator-provisioned artifacts. What the vectors protect is explained in
[`../architecture/prompt-contract-sidecar.md`](../architecture/prompt-contract-sidecar.md#parity-fixtures-and-measured-latency).

The pinned inventory contains seven artifacts: the five release models and two
additional Gemma variants. All 14 shared cases run against every artifact,
producing 98 token-array comparisons. The common corpus uses histories and
reasoning settings accepted by each family; family-specific argument and
Harmony regressions remain in the provider's focused test suites.

**Run the gate** (what CI's Provider Tests job runs; needs Go, `cargo +1.88.0`,
Swift and `jq`):

```bash
./scripts/verify-prompt-parity.sh
```

The script, in order:

1. Replays the committed manifest snapshot through
   `go run ./cmd/promptfixtureinput --manifest-source-directory
   fixtures/prompt-contract/v1/manifests …` (from `coordinator/`), which
   downloads only the verified prompt artifacts into a temporary artifact root
   (override with `PROMPT_PARITY_ARTIFACT_ROOT`; artifacts come from
   `PROMPT_PARITY_CDN_URL`).
2. Regenerates the vectors with the Rust generator:

   ```bash
   cargo +1.88.0 run --locked --quiet \
     --manifest-path coordinator/promptsidecar/Cargo.toml \
     --bin prompt-fixtures -- \
     --manifest-directory "$MANIFEST_DIR" \
     --artifact-root "$ARTIFACT_ROOT" \
     --cases fixtures/prompt-contract/v1/corpus.json \
     --output "$WORK/production_vectors.json"
   ```

   `prompt-fixtures` (`coordinator/promptsidecar/src/bin/prompt-fixtures.rs`)
   also accepts one `--manifest <file>` per model instead of
   `--manifest-directory`. The corpus supplies a fixed request-owned UTC date;
   direct literal date calls use it in both renderers. Unsupported clock use
   is written with `cache_routing_eligible: false` and
   `ineligibility_reason: "dynamic_time"` and get no routable vectors.
3. `cmp`s the generated file byte-for-byte against
   `fixtures/prompt-contract/v1/production_vectors.json`.
4. Runs the three implementations against the same vectors: Swift
   `swift test --package-path provider-swift --filter ProductionPromptParityTests`
   (with `PROMPT_PARITY_REQUIRED=1`, `PROMPT_PARITY_VECTORS`,
   `PROMPT_PARITY_ARTIFACT_ROOT` set), Go
   `go test ./promptcontract -run TestProductionPlansConsumeSharedTokenVectors`,
   and Rust `--test shared_vectors production_plans_match_shared_token_vectors`
   plus `--test planner_fixture concurrent_cold_contract_load_is_singleflight`.
5. Builds the release `promptsidecar` and drives it through the real Go
   supervisor with `go run ./coordinator/cmd/promptsidecarloadproof`
   (`PROMPT_LOAD_PROOF_DURATION`, `PROMPT_LOAD_PROOF_QPS`,
   `PROMPT_LOAD_PROOF_MAX_RSS_MIB` tune the run), failing on any plan mismatch,
   timeout, overload, restart, child replacement or RSS escape.
   Preserve the reported cold-load, preload and warm-plan timing totals and
   counts alongside memory measurements. Compute means from totals and counts;
   histogram buckets are cumulative bounds, not exact latency quantiles. When
   comparing tokenizer ownership, use identical artifacts, vectors and proof
   binaries in both arms. A macOS RSS pass does not prove Linux's address-space
   limit; run `scripts/verify-prompt-sidecar-linux.sh` against the static musl
   binary before release.

**Regenerate the fixtures** after a catalog, normalisation, renderer or
tokenizer change:

```bash
PROMPT_PARITY_UPDATE=1 ./scripts/verify-prompt-parity.sh
```

This re-fetches every active public manifest from `PROMPT_PARITY_CATALOG_URL`
(default `https://api.darkbloom.dev/v1/models/catalog`), rewrites
`fixtures/prompt-contract/v1/manifests/` and `production_vectors.json`, then
runs the same parity tests against the new vectors. Commit both. Missing
models, artifacts or corpus cases and unrecognised template incompatibilities
fail the gate (`require_model_manifests`, `require_case_ids`); no fabricated
token IDs are accepted.

## CI workflow map

| Workflow | Trigger | Jobs (name → what runs) |
|---|---|---|
| [`.github/workflows/ci.yml`](../../.github/workflows/ci.yml) | push, PR | **Release Integrity** — `scripts/check-release-version.sh`, `scripts/sync-install-embed.sh check`, `scripts/test-prod-env-refresh.sh` · **Docs Lint** — `scripts/docs-check.sh` · **Coordinator Tests** — `go test -race $(go list ./... \| grep -v /e2e)` with `postgres:16` service + `gofmt` on tracked Go files outside frozen report evidence · **Coordinator Lint** — `golangci-lint run` (v2.1.6) · **Prompt Sidecar Tests** — cargo fmt/check/clippy/test on Rust 1.88.0, static musl Docker stage, `verify-prompt-sidecar-linux.sh` · **Provider Tests** (macOS 12-vcpu) — `swift build --build-tests`, metallib staging, `swift test`, `verify-prompt-parity.sh`, six nested suites via `run-nested-suite.sh` (each its own step, `if: !cancelled()`), `test-install-atomic.sh` · **Swift Build + Cache** — release build of `darkbloom` + `darkbloom-fan-helper`, warms the SwiftPM cache · **Console UI Lint & Build** — Node 22, `npm ci`, `npx eslint src/`, `npm run build` |
| [`.github/workflows/integration.yml`](../../.github/workflows/integration.yml) | push to `master`/`main`, PR | **E2E Integration Tests** (macOS, 120 min budget): install Postgres 16, `swift build -c debug`, cargo sidecar build, metallib staging, HF snapshot downloads; lanes: paged @ 8 blocking gate (`TestIntegration\|TestProfile` minus exact-cache) → exact-cache routing paged @ 8 (expected red, `continue-on-error`) → default-posture smoke (`EXPECT_KV_BACKEND=contiguous`) → current coordinator vs released v0.7.12 provider (`scripts/fetch-v0712-provider.sh`, `DARKBLOOM_MIXED_VERSION_EXPECT=artifact`, fails unless `MIXED_VERSION_TIER_ARTIFACT_OK` appears) → released v0.7.12 coordinator (`git worktree add … v0.7.12`) vs candidate provider (`NonStreamingInference`, `StreamingInference`) |
| [`.github/workflows/benchmarks.yml`](../../.github/workflows/benchmarks.yml) | PR, gated by the `benchmarks` environment (manual approval) | **E2E Benchmarks** — `go test ./e2e/ -count=1 -v -timeout 40m -p=1 -run 'TestBenchmark'`, posts `BENCHMARK_MD_PATH` as a PR comment |
| [`.github/workflows/release-swift.yml`](../../.github/workflows/release-swift.yml) | tag `v*`, manual | Provider release; see [`../operations/provider-release.md`](../operations/provider-release.md) |
| [`.github/workflows/provider-signing-validation.yml`](../../.github/workflows/provider-signing-validation.yml) | manual only | Build an exact signed source revision, validate Developer ID signing/provisioning/notarization in a separate job, and retain an Actions artifact; no GitHub environment, deployment, release registration or model execution |
| [`.github/workflows/register-model.yml`](../../.github/workflows/register-model.yml) | manual | `POST /v1/admin/models/register`; see [`../operations/model-migration.md`](../operations/model-migration.md) |
| `.github/workflows/threat-model-review.yml`, `.github/workflows/claude.yml`, `.github/workflows/codex.yml` | PR / comment | Review automation; not test gates |

## Verify

- `make test` exits 0 and `docs-check` prints `N file(s) OK`.
- `swift test` output lists the `ProviderCore` suites **and** each nested suite
  step prints a non-zero executed count (the tripwire in `run-nested-suite.sh`).
- The e2e run logs `postgres started`, one `using configured provider binary`
  or provider build line per provider, and finishes with `ok  github.com/eigeninference/d-inference/e2e`.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `DATABASE_URL not set — skipping PostgreSQL integration test` | store tests skipped | export `DATABASE_URL` to a Postgres 16 with a `testbed` database |
| `neither docker nor postgres found in PATH` | e2e cannot start Postgres | start Docker, or put `postgresql@16/bin` on `PATH` |
| `configured provider metallib not found beside binary` | `DARKBLOOM_PROVIDER_BINARY` set without `mlx.metallib` next to it | `./scripts/fetch-metallib.sh "$(dirname "$DARKBLOOM_PROVIDER_BINARY")"` |
| provider never registers a model in e2e | checkpoint not in the HF cache, or not CBv2-servable (`gpt_oss`/`gemma4` families only) | download the pinned snapshot; check `DARKBLOOM_TESTBED_MODEL` |
| nested suite step fails with "executed 0 tests" | swift-testing pass routed at an executable target / wrong filter | rebuild with `swift build --build-tests` in `libs/mlx-swift-lm`; keep suite names exact |
| paged gate fails immediately with `DARKBLOOM_CBV2_PAGED_KV=… is set` | kill switch in your shell | `unset DARKBLOOM_CBV2_PAGED_KV` |

## Related

- [build.md](build.md) — toolchain and build commands.
- [`../operations/provider-release.md`](../operations/provider-release.md) — release checks that also run in CI.
- [`../architecture/components/provider.md`](../architecture/components/provider.md) — what the provider does at runtime.
- [`../architecture/prompt-contract-sidecar.md`](../architecture/prompt-contract-sidecar.md) — what prompt parity protects.

## Connected coordinator/provider HTTP cache gate

Owned two-host startup waits up to five minutes for the existing GPU ≤42°C
and load1 ≤4 entry thresholds. Identity, disk, nonfinite measurements and
foreign processes still refuse immediately. Lease pings and cancellation
cover preparation; EOF, stop, signals or deadlines prevent a later launch.
Reports retain `host_lifecycles` for failed and unattempted targets, including
readiness observations, helper/fixture identities, `provider_started`, and
terminal/cleanup receipts. A valid terminal can prove provider startup when its
start acknowledgement was lost; successful startup still requires the acknowledgement.
Without an acknowledgement or valid terminal, `provider_started` is null.
Contradictory identities remain explicit errors; an acknowledged start stays recorded.
A started Go/helper fixture is not evidence that
a provider started, and a refused startup remains a failed correctness run.


`TestIntegrationConnectedCacheHTTP` extends the existing real-provider testbed with
an opt-in ten-case HTTP gate. It starts an isolated in-memory coordinator, two
normal authenticated provider WebSocket connections, and the real supervised Rust
prompt sidecar. Local API keys, provider tokens and the routing master key are
fresh fixture credentials. No production database, Privy, Stripe or deployment
secret is needed. Testbed trust overrides are explicit; this is not attestation or
persistent-key restart evidence. Two providers on one Mac establish connected
control-plane behavior, not independent-machine capacity or latency.

For two independent machines, supply the optional `providers` array described
in the [owned-host fixture reference](../../e2e/testbed/OWNED_HOSTS.md). This uses
the existing loopback relay and owned SSH tunnel, and selects the five-case
`two_host_base_routing` scope. Follow its exact runtime/model inventories,
account binding, fresh-root and entry/cleanup requirements. The
[source integration record](../reports/2026-09-06-two-host-connected-fixture.md)
contains the CPU/race results; it is not an actual two-host model run.

Prepare `DARKBLOOM_CONNECTED_CACHE_INPUT` as the JSON input described by
`connectedCacheInput` in `e2e/connected_cache_input_test.go`: exact target catalog
entry and immutable manifest, current artifact tuple, verified prompt artifact
directory, provider/metallib/sidecar paths and SHA-256 values, explicit backend,
`cache_mode` (`off` or `ssd`), normal MTP mode, authored text/tool fixtures and
per-slot concurrency. Gemma requires its verified flat assistant directory and
an external assistant catalog manifest; the directory itself contains only
config and safetensors files. GPT-OSS uses MTP off and the three exact Qwen models
use MTP on. The normal production loader still verifies assistant compatibility.
Vision-configured artifacts require the original `landing/assets/cube-hero.png`
fixture and its pinned hash. The supplied text must tokenize to at least 2,048
tokens through the real sidecar, leaving room above the unchanged SSD hit floor.
No latest-snapshot discovery or artifact-name substitution occurs.
For the exact prepared five-artifact package, use ordinary `tool_choice: auto`
with explicit call instructions; the fixture checks actual tool name and arguments.
None of these exact artifacts advertises enforced named constraints, including
the Gemma artifact whose template differs from the pinned constraint contract.
Use the [reviewed revision 2 inputs](../reports/2026-09-05-connected-cache-inputs-revision2.md)
for the corrected Gemma assistant path and SSE reasoning-alias reader. Its
launcher verifies the actual declared assistant directory against the external
manifest. The package retains the original CLI/native revision; final release
validation requires a fresh paired package with the final runtime hashes.
Regenerate and review inputs plus CPU plans if the request-owned UTC date changes;
keep frozen packages and failed connected evidence unchanged.

Use a dedicated idle host and the final prebuilt provider plus colocated runtime
resources and Rust sidecar. This gate never builds them. It requires an existing
canonical provider config, verifies its bytes remain unchanged, and refuses a
provider binary with keychain access-group entitlement. Runtime files are copied
into the new output directory; PID/state/local discovery/cache/temporary/guard
paths are isolated, automatic updates and restarts are disabled, and the two exact
retired telemetry queue files must be absent. It never removes or repairs a host
configuration or key. SSD uses an explicitly ephemeral test key and fresh per-process
roots; resident cache and unrelated memory/backend overrides must be unset.

```bash
DARKBLOOM_CONNECTED_CACHE_INPUT=/absolute/off.json \
DARKBLOOM_CONNECTED_CACHE_OUTPUT=/absolute/new-off-output \
  go test ./e2e -run '^TestIntegrationConnectedCacheHTTP$' -count=1 -timeout=45m
DARKBLOOM_CONNECTED_CACHE_INPUT=/absolute/ssd.json \
DARKBLOOM_CONNECTED_CACHE_OUTPUT=/absolute/new-ssd-output \
  go test ./e2e -run '^TestIntegrationConnectedCacheHTTP$' -count=1 -timeout=45m
python3 scripts/benchmarks/compare_connected_cache_http.py \
  /absolute/new-off-output/report.json /absolute/new-ssd-output/report.json \
  --output /absolute/connected-comparison.json
```

The pair must use the same final binary, exact artifacts, backend, normal MTP,
authored request bytes and coordinator-owned UTC date. The comparator checks
served content/reasoning, decoded tool arguments, finish and native/HTTP token
counts; timing-dependent cancellation partial lengths are retained separately.
The runner fences UTC rollover and preserves failed, running and unrun cells in
an atomically replaced partial JSON report. Keep the `go test` log beside it for
setup failures and interrupted process evidence.

A bounded transparent loopback relay records negotiation, checkpoint echo,
receipt positions, cancellation and typed terminal usage/profile without keys,
nonces, raw scopes, token-chain hashes or encrypted bodies. Actual coordinator
acceptance counters and existing scheduler decisions are checked separately.
A read/receipt alone cannot pass the native saved-token hit assertion. The cases
cover cold donation, repeat, tenant isolation, a continuation on another provider,
original-prefix routing, supported tool execution, vision remaining cold, restored
cancellation and recovery, and sidecar-unavailable cold serving. Loaded slots must
report the actual backend with no fallback, and terminal profiles must prove MTP.
Heartbeat memory/SSD read observations are snapshots, not per-request read-byte
measurements. Old-echo, expiry/eviction, reconnect, queued revocation and costly-hit
winner controls remain separate coordinator gates. This harness source and its
loopback fixtures do not themselves establish real-model results.

The [HTTP6 execution record](../reports/2026-09-06-connected-http6-canceled-prefix.md)
passes all ten Qwen3.8 cache-off and SSD cases with the unchanged strict comparator.
Cancellation preserves actual SSD adoption and its accepted lookup before one
terminal; recovery and sidecar outage also pass. This is one B1 pair on one host.

The [HTTP5 execution record](../reports/2026-09-06-connected-http5-cache-and-cancel.md)
retains real donation/hit coverage and the original canceled-settlement failure.
Frozen package verification includes executable permissions before model preflight.
The [cancellation settlement regression](../reports/2026-09-06-canceled-prefix-settlement.md)
records the deterministic real-engine negative control and passing provider fix.
Run `ProviderCancelledPrefixCacheTests` and `CancelledSettlementLifecycleTests` to
check native usage/lookup ordering, delivered-token billing, and pump retirement;
the separate real-model HTTP rerun remains required.

The helper checks run without Swift, Metal or model execution:

```bash
go test -race -short ./e2e/testbed ./e2e \
  -run 'TestProviderWire|TestProviderTOMLExplicit|TestConnected' -count=1
python3 -m unittest discover -s scripts/benchmarks \
  -p 'test_compare_connected_cache_http.py'
```

### Two-host correctness-only continuation

Use `TestIntegrationConnectedCacheCorrectnessHTTP` when validating cache routing
and cancellation across two owned hosts. Prepare the same exact artifact/runtime
inputs and fresh roots described above, with two `providers` and explicit
`correctness_only: true`. Reserve both hosts before running; the existing cold
prelaunch, production admission and owned-process cleanup requirements still apply.

1. Run the cache-off input with the dedicated correctness variables:

   ```bash
   DARKBLOOM_CONNECTED_CACHE_CORRECTNESS_INPUT=/absolute/correctness-off.json \
   DARKBLOOM_CONNECTED_CACHE_CORRECTNESS_OUTPUT=/absolute/new-correctness-off \
     go test -v ./e2e -run '^TestIntegrationConnectedCacheCorrectnessHTTP$' \
       -count=1 -timeout=25m
   ```

2. After cache-off passes, repeat with the paired SSD input, identical runtime,
   artifact and UTC date, and separate fresh provider/output roots. Stop on any
   failure and retain its original report and cleanup receipts.
3. Require report schema `3`, scope `two_host_cache_routing_correctness`, and seven
   passing cases: `cold_donor_a`, `same_prompt_a`, `tenant_isolation_a`,
   `continuation_b`, `original_after_continuation`, `cancel`, `after_cancel`.
   Compare content, reasoning, finish reason and HTTP/native counts for the six
   completed requests. Both canceled requests must independently prove native
   partial settlement and retirement; their streamed partial lengths may differ.

Between requests, this scope retains heat/load observations and requires owned
processes only, exact hardware/RAM, valid telemetry, free disk space and quiescent
model capacity. It does not require running providers to return to cold benchmark
heat/load thresholds (`e2e/connected_cache_correctness_test.go`,
`connectedHostEntryReady`; `connectedSlotsQuiescent`). Cache adoption, tenant,
capability, request/provider identity and cancellation validators remain shared
with the original fixture (`e2e/connected_cache_http_test.go`,
`runConnectedCacheHTTP`). This scope makes no latency, throughput, raw-token-ID,
production-attestation or persistent-key restart claim. The original measured
fixture rejects `correctness_only: true`; preserve its schema-2 evidence and use
a separately reviewed schema-3 comparator for this seven-case pair.
