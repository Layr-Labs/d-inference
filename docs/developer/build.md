# Build

> Last updated: 2026-09-06 · commit `d01b82078`

How to build every component of Darkbloom from a fresh clone: the Go
coordinator, the Rust prompt-contract sidecar, the Swift provider CLI (with its
source-matched `mlx.metallib`), and the two Next.js UIs. `make build` does all
of it; the per-component steps below explain what each target runs.

Model publishing can pass `HUGGING_FACE_ARTIFACT_JSON` through
`scripts/publish-model.sh` to registration. See the
[model publishing procedure](../operations/model-migration.md).

## Prerequisites

- **Toolchain via [`mise`](https://mise.jdx.dev/).** Every version is pinned in
  [`mise.toml`](../../mise.toml); `mise install` installs them all.

  | Tool | Pin | Used by |
  |---|---|---|
  | `go` | `1.25.0` | coordinator, e2e (matches `go 1.25.0` in [`go.mod`](../../go.mod)) |
  | `rust` | `1.88.0` | `coordinator/promptsidecar` (matches `rust-version = "1.88"` in `coordinator/promptsidecar/Cargo.toml` and the `rust:1.88.0-alpine` builder in `coordinator/Dockerfile`) |
  | `node` | `22` | `console-ui`, `admin-ui` |
  | `swift` | `6.3` | `provider-swift` (the local `libs/mlx-swift` package declares `swift-tools-version: 6.3`; `provider-swift/Package.swift` itself is `6.1`) |
  | `python` | `3.12` | `scripts/*.py`, benchmark wrapper tests |
  | `jq`, `gh`, `awscli`, `gcloud` | `latest` | scripts, release and deploy tooling |

- **macOS on Apple Silicon** for anything under `provider-swift/` (MLX + Metal).
  The coordinator, sidecar, e2e harness, and UIs build on macOS or Linux.
- **Xcode Command Line Tools + `cmake`** (`brew install cmake`) — the metallib
  helper compiles MLX's Metal kernels with cmake.
- **Git submodules** checked out: `libs/mlx-swift`, `libs/mlx-swift-lm`,
  `libs/mlx` (`git clone --recurse-submodules …` or
  `git submodule update --init --recursive`). `provider-swift/Package.swift`
  depends on `../libs/mlx-swift` and `../libs/mlx-swift-lm` by local path.
- **Docker** only for the coordinator container image (step 9).

### Repository layout for builders

| Path | Toolchain | Notes |
|---|---|---|
| `go.mod` (repo root) | Go | Single module `github.com/eigeninference/d-inference`; contains `coordinator/...` and `e2e/...`. There is no `go.work` and no nested `go.mod`. |
| `coordinator/cmd/coordinator/` | Go | The coordinator binary (`main.go`). |
| `coordinator/promptsidecar/` | Rust | Crate `promptsidecar`, edition 2024, `Cargo.lock` committed; built with `--locked`. |
| `provider-swift/` | SwiftPM | Products: `darkbloom` (CLI), `darkbloom-enclave`, `darkbloom-fan-helper`, `darkbloom-publish`; libraries `ProviderCore`, `ProviderCoreFoundation`, `DarkbloomFan*`. Platform `macOS 14+`. |
| `console-ui/` | Next.js 16 / React 19 | `npm`; tests with Vitest. |
| `admin-ui/` | Next.js 16 / React 19 | `npm`; dev/start on port `4001`. |
| `landing/` | static HTML/JS | No build step; `earn-calculator-core.test.js` runs with `node --test`. |
| `Makefile` | — | Every target below; `make help` lists them. |

## Steps

### 1. Install the toolchain and hooks

```bash
mise install                          # installs every pin in mise.toml
git submodule update --init --recursive
git config core.hooksPath .githooks   # enables pre-commit + pre-push (see "Git hooks")
```

`mise` activates the pinned versions per shell; on macOS the system Xcode
`swift` is also acceptable for `provider-swift`.

### 2. Build everything

```bash
make build      # coordinator-build prompt-sidecar-build provider-build ui-build
make all        # test + build (see test.md)
```

Continue with the per-component steps when you need one piece or want to
understand what `make` runs.

### 3. Coordinator (Go)

The owned two-host Go fixture embeds `e2e/testbed/provider_host.py`; rebuild
its test binary after helper changes. The helper waits within the existing
five-minute prelaunch bound for GPU ≤42°C and load1 ≤4, under the same control
lease used after launch. See the [test procedure](test.md#connected-coordinatorprovider-http-cache-gate).

CI checks formatting of tracked Go source while preserving frozen report
evidence bytes; see the [coordinator checks](test.md#2-coordinator-go).

```bash
make coordinator-build            # cd coordinator && go build ./cmd/coordinator
make coordinator-build-linux      # GOOS=linux GOARCH=amd64 CGO_ENABLED=0 → coordinator/coordinator-linux
```

The host build writes `./coordinator/coordinator`. Version identity is injected
only by the container build (`-ldflags -X …api.BuildVersion/BuildCommit/BuildDate`
in `coordinator/Dockerfile`); a local `go build` reports `dev`/`unknown` on
`GET /health` (`coordinator/api/consumer.go`, `handleHealth`).

### 4. Prompt-contract sidecar (Rust)

```bash
make prompt-sidecar-format   # cargo fmt --all -- --check
make prompt-sidecar-check    # cargo check --locked --all-targets; cargo clippy --locked --all-targets -- -D warnings
make prompt-sidecar-build    # cargo build --locked --release --bin promptsidecar
make prompt-sidecar          # format + check + test + build
```

Output: `./coordinator/promptsidecar/target/release/promptsidecar`. The
coordinator container needs a **statically linked Linux binary**, built the way
`coordinator/Dockerfile` does it (stage `prompt-sidecar-builder`):

```bash
cd coordinator/promptsidecar
rustup target add x86_64-unknown-linux-musl
cargo build --locked --release --target x86_64-unknown-linux-musl --bin promptsidecar
file target/x86_64-unknown-linux-musl/release/promptsidecar   # must say "statically linked" or "static-pie linked"
```

On macOS cross-compiling to musl needs a Linux linker; use the Docker build in
step 9 instead. `scripts/verify-prompt-sidecar-linux.sh <binary>` runs the
production prompt vectors against a Linux sidecar binary (CI job "Prompt
Sidecar Tests").

### 5. Provider CLI (Swift) with source-matched metallib

```bash
make provider-build
# = cd provider-swift && swift build
#   ./scripts/fetch-metallib.sh "$(cd provider-swift && swift build --show-bin-path)"
```

`swift build` produces `./provider-swift/.build/debug/darkbloom` (plus
`darkbloom-enclave`, `darkbloom-fan-helper`, `darkbloom-publish`). MLX loads
`mlx.metallib` from **beside the running executable**, and SwiftPM does not
compile the Metal kernels, so [`scripts/fetch-metallib.sh`](../../scripts/fetch-metallib.sh)
builds them with cmake from `libs/mlx-swift/Source/Cmlx/mlx` (the exact source
the host side links) and copies the result next to the binary. Despite its
name it builds, it does not download.

MLX also embeds shader source in Cmlx for runtime compilation. After changing
an MLX kernel header, regenerate the affected embedded sources with
`libs/mlx-swift/Tools/update-mlx.sh` from a clean, isolated `libs/mlx-swift`
checkout and review its generated diff. For `quantized.h`, keep both
`Source/Cmlx/mlx-generated/quantized.cpp` and
`Source/Cmlx/mlx-generated/metal/quantized.h` synchronized with the core header.
Rebuild Cmlx and relink the provider as well as rebuilding `mlx.metallib`;
replacing the Metal library alone leaves the embedded QMV implementation intact.
Run the [bias-accumulation regression](test.md#quantized-bias-accumulation-regression)
against the resulting runtime.

```bash
./scripts/fetch-metallib.sh            # next to the latest debug build
./scripts/fetch-metallib.sh release    # next to the release build
./scripts/fetch-metallib.sh /some/dir  # → /some/dir/mlx.metallib
```

Knobs: `METALLIB_CACHE_DIR` (default `/tmp/mlx-metallib-cache`; cache key
includes the MLX tree SHA, toolchain hash and deployment target) and
`MLX_METALLIB_DEPLOYMENT_TARGET` (default `26.2`; the `_nax` kernels are only
compiled at SDK/deployment target ≥ 26.2). The script fails if required kernel
symbols (`_nax`, `gemv`, the `affine_qmv_wide_*` variants) are missing from the
produced library.

#### Restored SwiftPM runtime resources

The Provider Tests job removes restored metallibs and resource bundles from
all macOS build configurations in both package caches before building its debug
test product (`.github/workflows/ci.yml`). An inactive package's cached debug
bundle can contain older source just as a release bundle can. Each subsequent
package build recreates its own resources; compiled objects and dependency
checkouts remain cached. Runtime lookup accepts byte-identical copies and
continues to reject divergent copies.

The separate [signing-validation workflow](../operations/provider-release.md#environment-free-signing-validation)
checks packaging and Apple signing without selecting a deployment environment.

Release configuration, as the release workflow builds it:

```bash
cd provider-swift && swift build -c release --product darkbloom
swift build -c release --product darkbloom-fan-helper
cd .. && ./scripts/fetch-metallib.sh release
```

`darkbloom --version` must print the value of `ProviderCore.version`
(`provider-swift/Sources/ProviderCore/ProviderCore.swift`);
`scripts/check-release-version.sh` enforces this against the coordinator's
`LatestProviderVersion` (see [../operations/provider-release.md](../operations/provider-release.md)).

For a signed provider bundle needed by isolated tests, use the
[validation-only signing workflow](../operations/provider-release.md#signed-validation-bundle).
It retains an Actions artifact after the normal signing and final-bundle checks.

#### Standalone attention operator replay

[`scripts/benchmarks/attention-replay`](../../scripts/benchmarks/attention-replay/Package.swift)
links only MLX and MLXLMCommon. It consumes validated packet bytes without loading
a model or provider. Use an isolated build directory and the reviewed dependency
pins/local MLX package binding from the replay validation manifest:

```bash
REPLAY_SOURCE_ROOT=/absolute/path/to/pinned-worktree
ATTENTION_REPLAY_SOURCE_ROOT="$REPLAY_SOURCE_ROOT" \
  swift build --package-path "$REPLAY_SOURCE_ROOT/scripts/benchmarks/attention-replay" \
    --scratch-path /absolute/path/to/replay-build \
    -c release --product attention-replay --jobs 4 --disable-automatic-resolution
```

Retain the executable SHA-256, source/dependency inventory, build graph,
`mlx.metallib` and SwiftPM resource bundles. An executable hash alone does not
bind external Metal resources. The Python driver never builds or downloads them.
Use the [offline NumPy environment](#offline-attention-analysis-environment) for
packet validation and the independent reference. See [replay validation](test.md#attention-operator-replay)
and the [source/test milestone](../reports/2026-09-06-attention-operator-replay.md).

#### Segmented metadata profiler

Build the native `BenchSegmentedDecode` target in an isolated directory with the
same pinned local MLX dependency used by the nested native tests:

```bash
swift build --package-path libs/mlx-swift-lm --scratch-path /absolute/path/to/segment-profiler-build \
  -c release --product BenchSegmentedDecode --jobs 4 --disable-automatic-resolution
```

Stage the matching `mlx.metallib` and SwiftPM resource bundles beside the binary,
and retain their hashes with the build's source/dependency inventory. See
[profiler validation](test.md#segmented-metadata-profiler) for the bounded run.

<a id="resident-prefix-benchmark-executable"></a>

#### Prefix-cache benchmark executable

[`scripts/benchmarks/radix-engine`](../../scripts/benchmarks/radix-engine/Package.swift)
links the real provider factory and MLX packages from an explicitly selected
worktree. Keep baseline and candidate source worktrees separate, with recursive
submodules pinned. From the repository root:

```bash
RADIX_BENCH_SOURCE=/absolute/path/to/pinned-worktree
cp "$RADIX_BENCH_SOURCE/provider-swift/Package.resolved" scripts/benchmarks/radix-engine/Package.resolved
RADIX_SOURCE_ROOT="$RADIX_BENCH_SOURCE" RADIX_CANDIDATE_BUILD=0 \
  swift build --package-path scripts/benchmarks/radix-engine \
    --scratch-path "$RADIX_BENCH_SOURCE/provider-swift/.build" \
    -c release --product radix-engine --jobs 4 --disable-automatic-resolution
```

Use `RADIX_CANDIDATE_BUILD=1` for a source tree containing
`EngineV2Factory.makeBenchmarkSession` and the current cache APIs. The same
harness source compiles against the older baseline with `0`. Candidate SSD mode
uses the normal slot factory after a fresh pre/post-load weight-hash check;
`--cache-mode resident` explicitly reproduces the earlier resident-cache arm.
The baseline conditional and resident reproduction use the direct production
engine factory (`BenchmarkLoader.swift`).

The paired persistent-test namespace/access-group options require a candidate
build containing `SSDPersistentTestKeyNamespace`; historical builds reject them.
The same `RADIX_CANDIDATE_BUILD=1` define also enables the namespace test target.
Building this source does not authorize a Keychain group or establish persistent
restart. See [isolated persistent namespace validation](test.md#isolated-persistent-test-namespace).

Archive the source manifest, compile define, binary hash, matching
`mlx.metallib`, and SwiftPM resource bundles before changing that source tree.
Stage the Metal library beside `radix-engine`, as for the provider CLI. Before
model loading, the candidate SSD harness calls `bindRuntimeMetallibForMLX`, the
normal startup binder, and requires a valid immutable digest; placing the file
beside the binary alone does not establish the identity used by the complete
cache (`provider-swift/Sources/ProviderCore/Security/BinaryHasher.swift`). The
benchmark session is exposed only through `@_spi(Benchmarking)`; its raw events
preserve token IDs. Segmented storage uses the shared native process owner;
bridge dispatch, contiguous bridge admission and HTTP framing require the
separate provider HTTP probe. See [cache validation](test.md#prefix-cache-benchmark-validation)
for replay, key-mode and process-restart requirements.

The current candidate accepts `--concurrency 1|2|4` and either
`--production-kv-grant` or `--kv-budget-gib N` after its positional arguments.
Archive one binary for all compared arms. Use `--production-kv-grant` for the
single-model production-capacity run: the existing slot session derives its
logical grant from loaded target and assistant weights using the
[production grant policy](../architecture/hardware-support.md#kv-slot-grants).
Archive the Python evaluator source with the binary evidence as well: the
schema-2 cache comparator requires an off-to-on pair and validates idle/shutdown
ownership. A binary whose terminal snapshots precede publication of retired
engine gauges cannot satisfy that idle gate; preserve the raw refusal and use
a harness with coherent observations for the final comparison
(`scripts/benchmarks/radix_engine_evidence.py`, `retirement_errors`).
The current candidate includes bounded observation of published idle snapshots.
Its pure `BenchmarkIdleObservationTests` target can be run with `swift test`
using the same package, pinned source environment and scratch path as the build.
Keep test and release artifacts distinct, and use the final release binary for
both compared arms. Preserve logs that name the executed Swift Testing cases;
an XCTest runner may report zero tests before Swift Testing executes its suite.
It retains the separate post-build live OS/activation headroom gate.
The mode requires the candidate SSD serving path; it cannot be combined with
resident reproduction, native-probe-only mode or an explicit grant
(`provider-swift/Sources/ProviderCore/Inference/EngineV2Factory+BenchmarkGrant.swift`,
`benchmarkProductionGrant`; `BenchmarkOptions.swift`).

For explicit envelope controls, use `--kv-budget-gib N`. Without either flag,
the existing default remains one request and a 16 GiB explicit slot grant.
Explicit mode retains its measured post-load allocator guard; that diagnostic
does not size a production grant. Candidate `paged_storage` metrics separately
report committed backing and the mutable logical grant. Follow the
[validation steps](test.md#prefix-cache-benchmark-validation) to retain policy
inputs, live headroom and actual engine capacity with each result.

For a bounded target diagnostic, append `--native-kv-probe-only` with
`cache-off mtp-off` and concurrency one. This candidate-only mode loads the
verified model and runs the same native KV type probe used before paged backend
construction: two prefill tokens followed by one decode token. It records each
attention row's actual K/V types and shapes, with model and metallib hashes.
It creates no serving engine or SSD store.

The standalone product also includes optional bounded target-logit capture through
`--logit-diagnostic-position` and `--logit-diagnostic-candidates`. Build it with the
matching native submodule; follow the [diagnostic procedure](test.md#prefix-cache-benchmark-validation)
to preserve the original request and compare observation against an uninstrumented
control. These flags belong to the standalone benchmark, not the provider CLI.

The matching native submodule also supports `--attention-packet-position` and
`--attention-packet-layer` for a bounded native-byte capture from one attention
owner. Follow the [capture procedure](test.md#prefix-cache-benchmark-validation)
before passing the exported packet to the offline analyzer below.

#### Offline attention analysis environment

The optional [attention packet analyzer](../../scripts/benchmarks/attention_packet/FORMAT.md)
uses a separate Python environment and the pinned NumPy requirement. It needs
no Swift build, model weights or GPU.

```bash
python3 -m venv /tmp/darkbloom-attention-venv
/tmp/darkbloom-attention-venv/bin/python -m pip install -r scripts/benchmarks/attention_packet/requirements.txt
```

Use that interpreter for [packet analysis and its tests](test.md#offline-attention-packet-analysis).

### 6. Console UI (Next.js)

```bash
make ui-install   # cd console-ui && npm install
make ui-lint      # npx eslint src/
make ui-test      # npm test  (vitest run)
make ui-build     # npm run build  (next build)
make ui           # install + lint + test + build
```

Local dev server: `cd console-ui && npm run dev`. Bundle budget check:
`npm run bundle:check` (`console-ui/scripts/analyze-bundle.mjs`). CI uses
`npm ci`.

### 7. Admin UI (Next.js)

No `make` target. From `admin-ui/`:

```bash
npm install
npm run lint     # eslint src/
npm test         # vitest run
npm run build    # next build
npm run dev      # next dev -p 4001
```

### 8. Landing page

Static files in `landing/` (`index.html`, `earn-calculator*.js`, `terms.html`,
`privacy.html`); nothing to build. Run its one test with
`node --test landing/earn-calculator-core.test.js`.

### 9. Coordinator container image

The production image is built by [`coordinator/Dockerfile`](../../coordinator/Dockerfile)
from the **repo root** (it copies both `coordinator/` and the sidecar crate):

```bash
docker build \
  --build-arg BUILD_VERSION="$(awk -F'"' '/public static let version =/ {print $2}' provider-swift/Sources/ProviderCore/ProviderCore.swift)" \
  --build-arg BUILD_COMMIT="$(git rev-parse HEAD)" \
  --build-arg BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  -f coordinator/Dockerfile -t coordinator:local .
```

Stages: `prompt-sidecar-builder` (`rust:1.88.0-alpine`, musl static build) →
`builder` (`golang:1.25-alpine`, `-ldflags` version injection) → final image
`FROM eigengajesh/d-inference-base:v1-amd64` with `/usr/local/bin/coordinator`
and `/usr/local/bin/promptsidecar`, OCI labels
`org.opencontainers.image.{version,revision,created}`, `EXPOSE 8080`, entrypoint
`start.sh` (`coordinator/deploy/start.sh`). Cloud Build wraps exactly this in
`deploy/gcp/cloudbuild.yaml` (dev) and `deploy/gcp/cloudbuild-prod.yaml`
(prod); see [`../operations/coordinator-deploy.md`](../operations/coordinator-deploy.md).

## `make` targets

| Target | What it runs |
|---|---|
| `help` | List targets (default goal) |
| `coordinator-test` | `cd coordinator && go test ./...` |
| `coordinator-build` | `go build ./cmd/coordinator` → `./coordinator/coordinator` |
| `coordinator-build-linux` | `GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o coordinator-linux ./cmd/coordinator` |
| `coordinator` | `coordinator-test` + `coordinator-build` |
| `prompt-sidecar-format` | `cargo fmt --all -- --check` |
| `prompt-sidecar-check` | `cargo check --locked --all-targets` + `cargo clippy --locked --all-targets -- -D warnings` |
| `prompt-sidecar-test` | `cargo test --locked --all-targets` |
| `prompt-sidecar-build` | `cargo build --locked --release --bin promptsidecar` |
| `prompt-sidecar` | format + check + test + build |
| `provider-build` | `swift build` + `scripts/fetch-metallib.sh <bin-path>` |
| `provider-test` | `swift build --build-tests`, stage `mlx.metallib` into the bin dir and every `*PackageTests.xctest/Contents/MacOS`, then `swift test --skip-build` |
| `provider` | `provider-build` + `provider-test` |
| `benchmark-wrapper-test` | `cd scripts && python3 -m unittest discover -s gemma_contbatch/tests -t .` |
| `benchmark-gemma-contbatch` | `python3 scripts/benchmark-gemma-contbatch.py $(GEMMA_BENCHMARK_ARGS)` (needs GPU + weights) |
| `ui-install` / `ui-lint` / `ui-test` / `ui-build` / `ui` | `npm install` / `npx eslint src/` / `npm test` / `npm run build` in `console-ui/` |
| `e2e-integration` | `go test ./e2e/... -run TestIntegration -v` |
| `e2e-benchmark` | `go test ./e2e/... -run TestBenchmark -v` |
| `e2e` | `e2e-integration` |
| `docs-check` | `scripts/docs-check.sh` (stamps, links, cited paths, orphans) |
| `docs-stamp` | `scripts/docs-stamp.sh $(FILES)` — refresh freshness stamps |
| `test` | `coordinator-test prompt-sidecar-test provider-test ui-test benchmark-wrapper-test docs-check` |
| `build` | `coordinator-build prompt-sidecar-build provider-build ui-build` |
| `all` | `test build` |
| `clean` | remove `./coordinator/coordinator{,-linux}`, `./coordinator/promptsidecar/target`, `./provider-swift/.build`, `./console-ui/.next`, `./console-ui/node_modules` |

## Git hooks

Enable once with `git config core.hooksPath .githooks`. Both hooks only act on
components that changed.

| Hook | Trigger | Checks |
|---|---|---|
| [`.githooks/pre-commit`](../../.githooks/pre-commit) | staged `coordinator/**.go` | `gofmt -l` on the staged files (fix: `gofmt -w <file>`) |
| | staged `console-ui/**.ts{,x}` | `cd console-ui && npx eslint src/` (fix: `npx eslint --fix src/`) |
| | Swift | skipped — no enforced formatter |
| [`.githooks/pre-push`](../../.githooks/pre-push) | any `coordinator/` change in the pushed range | `gofmt -l .` over `coordinator/`, then `go test $(go list ./... \| grep -v /internal/api)` from `coordinator/` (the slow WebSocket integration tests run in CI only) |
| | any `console-ui/` change | `npx eslint --quiet src/` and `npm run build` |

CI runs the fuller set (`gofmt`, `golangci-lint`, `-race` tests, Swift, Rust,
docs lint); see [test.md](test.md).

## Verify

```bash
make build
ls -l coordinator/coordinator coordinator/promptsidecar/target/release/promptsidecar
ls -l provider-swift/.build/debug/darkbloom provider-swift/.build/debug/mlx.metallib
./provider-swift/.build/debug/darkbloom --version    # prints ProviderCore.version, e.g. 0.8.16
ls console-ui/.next
```

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `swift build` cannot resolve `../libs/mlx-swift` | submodules not checked out | `git submodule update --init --recursive` |
| provider starts but MLX fails to load kernels / "metallib not found" | `mlx.metallib` missing beside the binary | `./scripts/fetch-metallib.sh` (or `make provider-build`) |
| `fetch-metallib.sh` fails on missing `_nax` symbols | deployment target/SDK below 26.2 | update Xcode; or set `MLX_METALLIB_DEPLOYMENT_TARGET` only if you accept a kernel set that differs from release builds |
| `cargo build --locked` fails on lockfile | `Cargo.lock` out of date with `Cargo.toml` | run `cargo update -p <crate>` deliberately and commit the lock; never drop `--locked` in CI |
| `go build` picks a different Go | `mise` not activated in this shell | `eval "$(mise activate bash)"` (or zsh) then retry |
| `docker build` fails at `file … statically linked` | sidecar not statically linked (musl target missing) | the Dockerfile adds the target itself; check Docker platform is `linux/amd64` |

## Related

- [test.md](test.md) — unit, e2e, CI.
- [../operations/provider-release.md](../operations/provider-release.md) — provider release runbook.
- [`../operations/coordinator-deploy.md`](../operations/coordinator-deploy.md) — container build and deploy on GCP.
- [`../architecture/components/mlx-swift.md`](../architecture/components/mlx-swift.md) — why the metallib must match the MLX source.
