# Build

> Last updated: 2026-09-06 · commit `ab992bef4`

How to build every component of Darkbloom from a fresh clone: the Go
coordinator, the Rust prompt-contract sidecar, the Swift provider CLI (with its
source-matched `mlx.metallib`), the native macOS app, and the Next.js UIs.
`make build` builds the coordinator, sidecar, Swift products, and console UI;
app bundle staging and the admin UI have separate steps below.

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

- **macOS on Apple Silicon** for the provider runtime (MLX + Metal) and app workflow.
  `DarkbloomApp` itself links only `ProviderCoreFoundation`, with no
  `ProviderCore` or MLX dependency (`provider-swift/Package.swift`,
  `DarkbloomApp` target); SwiftPM still resolves the package's local submodules.
  The coordinator, sidecar, e2e harness, and UIs build on macOS or Linux.
- **Xcode Command Line Tools + `cmake`** (`brew install cmake`) — the metallib
  helper compiles MLX's Metal kernels with cmake.
- **Git submodules** checked out: `libs/mlx-swift`, `libs/mlx-swift-lm`,
  `libs/mlx` (`git clone --recurse-submodules …` or
  `git submodule update --init --recursive`). `provider-swift/Package.swift`
  depends on `../libs/mlx-swift` and `../libs/mlx-swift-lm` by local path.
- **Xcode with the Metal toolchain** for staging the native app: the launch
  script invokes `xcrun metal` and `xcrun metallib` for its visual shader.
- **Docker** only for the coordinator container image (step 10).

### Repository layout for builders

| Path | Toolchain | Notes |
|---|---|---|
| `go.mod` (repo root) | Go | Single module `github.com/eigeninference/d-inference`; contains `coordinator/...` and `e2e/...`. There is no `go.work` and no nested `go.mod`. |
| `coordinator/cmd/coordinator/` | Go | The coordinator binary (`main.go`). |
| `coordinator/promptsidecar/` | Rust | Crate `promptsidecar`, edition 2024, `Cargo.lock` committed; built with `--locked`. |
| `provider-swift/` | SwiftPM | Products include `DarkbloomApp` (GUI), `darkbloom` (CLI), `darkbloom-enclave`, `darkbloom-fan-helper`, `darkbloom-publish`; libraries `ProviderCore`, `ProviderCoreFoundation`, `DarkbloomFan*`. Package platform `macOS 14+`; runtime readiness is checked separately. |
| `script/build_and_run.sh` | SwiftPM + Xcode Metal tools | Builds a DEBUG GUI, stages `dist/Darkbloom.app`, and launches only that checkout's bundle. |
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
step 10 instead. `scripts/verify-prompt-sidecar-linux.sh <binary>` runs the
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

### 6. Native macOS app

From the repository root, select a fixture destination for UI development:

```bash
./script/build_and_run.sh --preview chat --verify
./script/build_and_run.sh --no-build --preview local-api
```

The script builds `DarkbloomApp` in debug configuration, copies its fonts and
SwiftPM resources, and compiles `DarkbloomSpatialField.metal` into the staged
resource bundle's `default.metallib`. This is the app's visual shader; the
script does not stage the provider CLI or its inference `mlx.metallib`.
The development bundle uses `dev.darkbloom.app` and is not a Developer ID
release artifact. For a combined shipping bundle, use the
[app release runbook](../operations/app-release.md#distribution-layout).
`scripts/bundle-macos-app.sh` assembles the CLI as the main executable of
`Contents/Helpers/DarkbloomProvider.app`, with colocated enclave/metallib files.
`scripts/stage-swiftpm-resource-bundles.sh` stages real runtime bundles beside
that helper and in the outer app. The release workflow embeds the matching
profile, signs the canonical helper code, seals the helper, copies signed
compatibility payloads to the outer app, and seals the GUI. Local assembly
alone does not qualify that signed artifact.

Build and staging finish before the script asks the previous app at this
checkout's exact bundle and executable paths to quit. It waits for graceful
termination, retains the previous bundle through launch verification, and
prints the verified PID. A failed launch can leave the previous bundle at the
reported recovery path. It does not identify apps by process name alone.

| Option | Effect (`script/build_and_run.sh`, `usage` / `app_control`) |
|---|---|
| `run` (default) | Build, stage, and launch the checkout app |
| `--no-build` | Relaunch a validated debug bundle previously staged by this script; skips SwiftPM and shader builds, but still interprets the Swift AppKit control helper |
| `--preview <destination>` | Fixture services for `overview`, `chat`, `local-api`, `my-macs`, `contributions`, `availability`, `activity`, `models`, or `machine` |
| `--verify` | Wait for that PID's visible main-sized window (at least 900 × 620); verifies launch/window presence only |
| `--debug` / `--logs` / `--telemetry` | Attach LLDB, stream logs, or stream `dev.darkbloom.app` subsystem logs for the exact launched PID |
| `--recover-lock` | Remove the checkout run lock only after its recorded owner has exited, then exit |

For preview appearance and sizing, export
`DARKBLOOM_PREVIEW_APPEARANCE=light` or `dark` and
`DARKBLOOM_PREVIEW_WINDOW_WIDTH` / `DARKBLOOM_PREVIEW_WINDOW_HEIGHT` before
launch. Existing preview/capture environment settings are inherited. Capture
flags or a debug phase alone do not select fixture services
(`provider-swift/Sources/DarkbloomApp/App/AppBootstrapConfiguration.swift`,
`isPreviewSession`).

For live development, omit fixture settings and use an installed managed CLI.
`provider-swift/Sources/DarkbloomApp/Services/DarkbloomCLILocator.swift`
(`SystemDarkbloomCLILocator.locate`) accepts `DARKBLOOM_CLI_PATH` only in DEBUG;
otherwise it validates the real managed helper CLI at
`~/.darkbloom/Darkbloom.app/Contents/Helpers/DarkbloomProvider.app/Contents/MacOS/darkbloom`.
A legacy regular outer CLI is accepted only when the helper is absent; a
malformed helper fails validation. The outer CLI alias is not a managed launch
path. There is no PATH or Downloads fallback. Read-only screens use CLI/file
contracts; pressing a runtime or setup action can change the real provider state. See the
[product verification procedure](../operations/app-release.md#product-flow-and-session-verification)
for exploration, network setup, and session lifetime.

### 7. Console UI (Next.js)

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

### 8. Admin UI (Next.js)

No `make` target. From `admin-ui/`:

```bash
npm install
npm run lint     # eslint src/
npm test         # vitest run
npm run build    # next build
npm run dev      # next dev -p 4001
```

### 9. Landing page

Static files in `landing/` (`index.html`, `earn-calculator*.js`, `terms.html`,
`privacy.html`); nothing to build. Run its one test with
`node --test landing/earn-calculator-core.test.js`.

### 10. Coordinator container image

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
| `provider-test` | `swift build --build-tests`, stage `mlx.metallib` into the bin dir and every `*PackageTests.xctest/Contents/MacOS`, then both required partitions in `scripts/test-provider-suites.sh` |
| `provider` | `provider-build` + `provider-test` |
| `app-unit-test` | `swift test --package-path provider-swift --filter 'DarkbloomAppTests\|ProviderCoreFoundationTests'`; no app launch, but may build the package test graph |
| `app-bundle-test` | `scripts/test-bundle-macos-app.sh`; temporary executables and shader fixtures, no Swift/Metal build or app launch |
| `app-check` | `app-unit-test` + `app-bundle-test`; opt-in checks, not a release qualification |
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
| App script rejects `--no-build` | no validated debug bundle from this script | rerun without `--no-build` |
| App script reports a held run lock | another checkout launch is active, or its owner exited without cleanup | let an active owner finish; use `./script/build_and_run.sh --recover-lock` only for an exited owner |
| Live app reports missing/incompatible provider | managed CLI absent, invalid, or too old for the app's JSON contract | install the matching release; DEBUG development can explicitly select a compatible CLI with `DARKBLOOM_CLI_PATH` |
| `cargo build --locked` fails on lockfile | `Cargo.lock` out of date with `Cargo.toml` | run `cargo update -p <crate>` deliberately and commit the lock; never drop `--locked` in CI |
| `go build` picks a different Go | `mise` not activated in this shell | `eval "$(mise activate bash)"` (or zsh) then retry |
| `docker build` fails at `file … statically linked` | sidecar not statically linked (musl target missing) | the Dockerfile adds the target itself; check Docker platform is `linux/amd64` |

## Related

- [test.md](test.md) — unit, e2e, CI.
- [../operations/app-release.md](../operations/app-release.md) — combined GUI/CLI packaging and signed, live release qualification.
- [../operations/provider-release.md](../operations/provider-release.md) — provider release runbook.
- [`../operations/coordinator-deploy.md`](../operations/coordinator-deploy.md) — container build and deploy on GCP.
- [`../architecture/components/mlx-swift.md`](../architecture/components/mlx-swift.md) — why the metallib must match the MLX source.
