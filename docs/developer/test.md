# Test

> Last updated: 2026-09-05 · commit `120ecc9c2`

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
./scripts/sync-install-embed.sh check   # coordinator/api/install.sh byte-identical to scripts/install.sh
./scripts/test-prod-env-refresh.sh      # deploy/gcp/prod/refresh-env.sh contract
./scripts/test-publish-model.sh         # scripts/publish-model.sh dry-run contract
```

The first three are CI job "Release Integrity". The production env refresh test
checks automatic payout activation, preservation of an explicit off switch,
and rejection of missing payout prerequisites before the live env is changed.

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
   `--manifest-directory`. Models whose template needs provider-local dynamic
   time are written with `cache_routing_eligible: false` and
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
| [`.github/workflows/ci.yml`](../../.github/workflows/ci.yml) | push, PR | **Release Integrity** — `scripts/check-release-version.sh`, `scripts/sync-install-embed.sh check`, `scripts/test-prod-env-refresh.sh` · **Docs Lint** — `scripts/docs-check.sh` · **Coordinator Tests** — `go test -race $(go list ./... \| grep -v /e2e)` with `postgres:16` service + `gofmt -l .` · **Coordinator Lint** — `golangci-lint run` (v2.1.6) · **Prompt Sidecar Tests** — cargo fmt/check/clippy/test on Rust 1.88.0, static musl Docker stage, `verify-prompt-sidecar-linux.sh` · **Provider Tests** (macOS 12-vcpu) — `swift build --build-tests`, metallib staging, `swift test`, `verify-prompt-parity.sh`, six nested suites via `run-nested-suite.sh` (each its own step, `if: !cancelled()`), `test-install-atomic.sh` · **Swift Build + Cache** — release build of `darkbloom` + `darkbloom-fan-helper`, warms the SwiftPM cache · **Console UI Lint & Build** — Node 22, `npm ci`, `npx eslint src/`, `npm run build` |
| [`.github/workflows/integration.yml`](../../.github/workflows/integration.yml) | push to `master`/`main`, PR | **E2E Integration Tests** (macOS, 120 min budget): install Postgres 16, `swift build -c debug`, cargo sidecar build, metallib staging, HF snapshot downloads; lanes: paged @ 8 blocking gate (`TestIntegration\|TestProfile` minus exact-cache) → exact-cache routing paged @ 8 (expected red, `continue-on-error`) → default-posture smoke (`EXPECT_KV_BACKEND=contiguous`) → current coordinator vs released v0.7.12 provider (`scripts/fetch-v0712-provider.sh`, `DARKBLOOM_MIXED_VERSION_EXPECT=artifact`, fails unless `MIXED_VERSION_TIER_ARTIFACT_OK` appears) → released v0.7.12 coordinator (`git worktree add … v0.7.12`) vs candidate provider (`NonStreamingInference`, `StreamingInference`) |
| [`.github/workflows/benchmarks.yml`](../../.github/workflows/benchmarks.yml) | PR, gated by the `benchmarks` environment (manual approval) | **E2E Benchmarks** — `go test ./e2e/ -count=1 -v -timeout 40m -p=1 -run 'TestBenchmark'`, posts `BENCHMARK_MD_PATH` as a PR comment |
| [`.github/workflows/release-swift.yml`](../../.github/workflows/release-swift.yml) | tag `v*`, manual | Provider release; see [`../operations/provider-release.md`](../operations/provider-release.md) |
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
