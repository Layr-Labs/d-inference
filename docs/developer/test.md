# Test

The root test aggregate is:

```bash
make test
```

It runs the coordinator, Rust prompt-sidecar, provider, Console UI, and Gemma
benchmark-wrapper unit suites. It does not run prompt-sidecar workstation
probes, live/provider hardware lanes, system E2E tests, or E2E benchmarks
([`Makefile`](../../Makefile)).

## Coordinator (Go)

The local unit command is:

```bash
make coordinator-test
```

For local race detection:

```bash
cd coordinator && go test -race ./...
```

Coordinator CI has a more exact package split. It first races the fast E2E
testbed helpers, then races every Go package except the top-level system E2E
package:

```bash
go test -race ./e2e/testbed/...
go test -race $(go list ./... | grep -vxF 'github.com/eigeninference/d-inference/e2e')
```

The second selector still includes `coordinator/internal/e2e` and all E2E
helper subpackages. CI supplies a Postgres 16 service through `DATABASE_URL`
([`.github/workflows/ci.yml`](../../.github/workflows/ci.yml)).

### Running a local coordinator

Store selection is explicit. Without a database URL, opt into the non-durable
development store:

```bash
cd coordinator
EIGENINFERENCE_ALLOW_MEMORY_STORE=true go run ./cmd/coordinator
```

To exercise the durable store instead:

```bash
cd coordinator
EIGENINFERENCE_DATABASE_URL='postgres://user:password@127.0.0.1:5432/darkbloom?sslmode=disable' \
  go run ./cmd/coordinator
```

The coordinator refuses to start with neither setting. The memory store is for
development and tests only; its state is lost on restart
([`coordinator/store/config.go`](../../coordinator/store/config.go)).

## Prompt-contract sidecar (Rust)

The default Rust lane runs all targets:

```bash
make prompt-sidecar-test
```

CI additionally runs formatting, `cargo check`, Clippy, a static Linux
container build, and the production Linux contract-load proof. Ignored,
workstation-only latency and overload probes are a separate explicit lane:

```bash
make prompt-sidecar-probe
```

The probes are not part of `make test`
([`Makefile`](../../Makefile), [CI](../../.github/workflows/ci.yml)).

## Provider (Swift)

The default provider lane is:

```bash
make provider-test
```

This builds all provider tests, builds a source-matched `mlx.metallib`, places
it beside the XCTest runner, and runs `swift test --skip-build`. Tests outside
the opt-in directories below are the default lane. The hermetic
`ProviderCoreTests/CoordinatorIntegrationTests.swift` suite is also default: it
uses a loopback mock coordinator and canned inference output, not a real model.

Provider test directories are posture declarations:

| Directory | Gate and prerequisites |
|---|---|
| `ProviderCoreTests/Live/` | `DARKBLOOM_LIVE_MLX_TESTS=1`; Apple Silicon, a source-matched metallib, and the selected checkpoint in the local Hugging Face cache. Large Gemma cases also require `DARKBLOOM_LIVE_MLX_GEMMA=1`; two-model cases also require `DARKBLOOM_LIVE_MLX_MULTI_MODEL=1`. |
| `ProviderCoreTests/Hardware/` | `DARKBLOOM_HARDWARE_TESTS=1`; a usable Secure Enclave and Keychain. |
| `ProviderCoreFoundationTests/Resource/` | `DARKBLOOM_RESOURCE_TESTS=1`; sufficient memory for the explicit resource bound. |
| `DarkbloomCLITests/Integration/` | `DARKBLOOM_CLI_INTEGRATION_TESTS=1`; executes the built `darkbloom` binary. |
| `DarkbloomFanServiceTests/Integration/` | `DARKBLOOM_FAN_SERVICE_INTEGRATION_TESTS=1`; executes real `dscl` account lookup. |
| `ProviderCoreTests/Probes/` | Per-probe opt-in; these are measurements, not default correctness tests. See commands below. |
| `ProviderCoreTests/ReleaseGates/` | The production prompt-parity script supplies `PROMPT_PARITY_REQUIRED`, generated working vectors, and an artifact root. Do not invoke the Swift filter without those inputs. |

Once `make provider-test` has staged the metallib, representative opt-in
commands are:

```bash
cd provider-swift
DARKBLOOM_LIVE_MLX_TESTS=1 swift test --filter InferenceLiveTests
DARKBLOOM_LIVE_MLX_TESTS=1 \
  DARKBLOOM_LIVE_MLX_GEMMA=1 \
  DARKBLOOM_LIVE_MLX_MULTI_MODEL=1 \
  swift test --filter InferenceLiveTests
DARKBLOOM_HARDWARE_TESTS=1 swift test --filter CodeAttestationHardwareTests
DARKBLOOM_RESOURCE_TESTS=1 swift test --filter WeightHasherMemoryTests
DARKBLOOM_CLI_INTEGRATION_TESTS=1 swift test --filter CLIDispatchTests
DARKBLOOM_FAN_SERVICE_INTEGRATION_TESTS=1 \
  swift test --filter FanUserIdentityIntegrationTests
```

Opting into a live lane turns a missing required model or metallib into a lane
failure. The base live gate does not download checkpoints.

The direct probe entry points are:

```bash
cd provider-swift
DARKBLOOM_SSD_STAGE_LATENCY_PROBE=1 \
  swift test --filter SSDPrefixCacheStageLatencyProbeTests
DARKBLOOM_LIVE_MLX_TESTS=1 DARKBLOOM_PAGED_DIVERGENCE_PROBE=1 \
  swift test --filter PagedDivergenceProbeTests
DARKBLOOM_LIVE_MLX_TESTS=1 DARKBLOOM_LIVE_MLX_GEMMA=1 \
  swift test --filter Gemma4DecodeProfileTests
```

The supervised MTP probes must run through the process-group timeout wrapper,
which supplies their complete gate contract:

```bash
python3 scripts/run-mtp-benchmark.py
```

Production prompt parity is exercised through the canonical cross-language
script, not a bare Swift filter:

```bash
./scripts/verify-prompt-parity.sh
```

It derives a working vector file from the checked-in manifest snapshots and
corpus, compares it byte-for-byte with the checked-in inventory, then makes
Rust, Go, and the real Swift serving tokenizer consume the same working file
([prompt-contract sidecar](../architecture/prompt-contract-sidecar.md)).

### Relocated MLX package CI suites

Provider CI first runs `swift build --build-tests` in `libs/mlx-swift-lm`, so
the whole nested test package is compiled. It then executes exactly these 12
suites:

1. `CBv2PagedSafetyTests`
2. `CBv2PrefixCacheHasherTests`
3. `CBv2PrefixCacheTests`
4. `CBv2PrefixCacheEvictionTests`
5. `CBv2PrefixCacheWindowedPolicyTests`
6. `CBv2PrefixCacheRequestSaltTests`
7. `CBv2PagedEligibilityTests`
8. `CBv2PagedBackendTests`
9. `CBv2PagedSpeculativeRowTests`
10. `CBv2PagedKernelTests`
11. `CBv2KVSharingParityTests`
12. `SequenceStateMachineTests`

Every explicit suite goes through:

```bash
../../scripts/run-swift-suite.sh <SuiteName> --skip-build
```

The wrapper is framework-agnostic: it accepts XCTest or Swift Testing output,
fails when the filter executes zero tests, and fails on any skip. All other
tests in the nested package are compile-only in this workflow.

Provider CI separately compiles `libs/mlx-swift` and executes exactly one suite
from it: `QMVWideMetalTests`. That regression is owned by `MLXTests` because it
directly exercises the core QMV Metal routing and numerics rather than provider
integration. The lane stages the same source-matched `mlx.metallib` beside the
relocated test runner, then invokes the guarded wrapper with
`QMVWideMetalTests --skip-build`; all other `mlx-swift` tests are compile-only
in this workflow. Across both relocated packages, provider CI therefore runs 13
explicitly selected suites
([`scripts/run-swift-suite.sh`](../../scripts/run-swift-suite.sh),
[provider CI](../../.github/workflows/ci.yml)).

## Console UI and benchmark wrapper

```bash
make ui-test
make benchmark-wrapper-test
```

`make ui-test` runs Vitest. It is part of the local `make test` aggregate; the
current Console UI CI job runs lint and build but not Vitest. The Python
benchmark-wrapper tests require neither a GPU nor model weights.

## System E2E

The local convenience lanes are:

```bash
make e2e-integration
make e2e-benchmark
```

The E2E harness starts an ephemeral Postgres 16 instance itself: Docker is used
when available, otherwise a native `postgres` executable must be on `PATH`.
The harness also builds the Swift provider and stages its source-matched
metallib unless `DARKBLOOM_PROVIDER_BINARY` names an executable with
`mlx.metallib` beside it. Model checkpoints are never downloaded silently.
The ordinary model is `mlx-community/gpt-oss-20b-MXFP4-Q8`; override it with
`DARKBLOOM_TESTBED_MODEL` only with another supported, locally cached model
([`e2e/testbed`](../../e2e/testbed)).

The current integration contracts cover real non-streaming and streaming
inference, greedy determinism, billing accounting, concurrent requests,
provider metadata, exact-cache routing, full-network multi-model routing, and
mixed-version compatibility. They do not claim a real attestation
challenge-response or model-alias migration E2E.

### E2E lanes and selectors


Within this Markdown table, `\|` only escapes a column delimiter; the Go
regular expressions use ordinary `|` alternation.

| Lane | Exact selector and posture | Additional prerequisites |
|---|---|---|
| Default-posture blocking smoke | `^(TestIntegration_NonStreamingInference\|TestIntegration_StreamingContentValidation)$`; no testbed backend/cap override, and `DARKBLOOM_TESTBED_EXPECT_KV_BACKEND=contiguous` | gpt-oss checkpoint |
| Paged blocking contracts | `^(TestIntegration_GreedyDeterminism\|TestIntegration_BillingAccounting\|TestIntegration_ConcurrentRequests\|TestIntegration_ProviderMetadata)$`; `DARKBLOOM_TESTBED_KV_BACKEND=paged`, `DARKBLOOM_TESTBED_MAX_CONCURRENT=8`, `DARKBLOOM_TESTBED_EXPECT_KV_BACKEND=paged` | gpt-oss checkpoint; `DARKBLOOM_CBV2_PAGED_KV` must be unset |
| Exact-cache informational probe | `^TestIntegrationExactCacheRouting$`; explicit paged/8 | executable Rust sidecar and the pinned `mlx-community/gemma-4-e2b-it-4bit` snapshot; CI keeps this known fixture exception expected-red with `continue-on-error` |
| Full-network multi-model smoke | `^TestIntegration_FullNetworkSingleSwiftProviderMultiModelRouting$`; `DARKBLOOM_FULL_NETWORK_SMOKE=1` | gpt-oss plus `mlx-community/gemma-4-26B-A4B-it-qat-4bit` |
| Mixed artifact tier | `^(TestIntegrationMixedVersionGateContract\|TestIntegrationMixedVersionArtifactOnlyV0712)$`; `DARKBLOOM_MIXED_VERSION=1`, `DARKBLOOM_MIXED_VERSION_EXPECT=artifact` | hash-pinned v0.7.12 bundle from `scripts/fetch-v0712-provider.sh`; verifies but does not boot it |
| Mixed full tier | `^TestIntegrationMixedVersionFullV0712Provider$`; `DARKBLOOM_MIXED_VERSION=1`, `DARKBLOOM_MIXED_VERSION_EXPECT=full` | SIP-enabled runner, the same verified v0.7.12 bundle, and the locally cached e2b checkpoint |
| Benchmarks | `^TestBenchmark_` | gpt-oss and Gemma 4 26B checkpoints; PR CI runs this in the separate, approval-gated `benchmarks` environment |

The lane definitions and model revisions live in
[`integration.yml`](../../.github/workflows/integration.yml) and
[`benchmarks.yml`](../../.github/workflows/benchmarks.yml). The mixed full tier
is intentionally not run on the current SIP-disabled integration runner.
