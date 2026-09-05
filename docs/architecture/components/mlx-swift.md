# MLX stack: the three pinned submodules and the metallib

> Last updated: 2026-09-05 · commit `7b6afb181`

What the provider links from `libs/`, at which commits, what each submodule
contributes, how the Metal kernel library (`mlx.metallib`) is built from the
same source and pinned at runtime, and what the provider actually takes from the
upstream `MLXLMServer` library. Build steps live in
[`../../developer/build.md`](../../developer/build.md); the serving path in
[`../inference.md`](../inference.md).

## Context

The provider is one Swift package (`provider-swift/Package.swift`) whose
`ProviderCore` target links the MLX array framework and the language-model
libraries as **local path dependencies** — `.package(path: "../libs/mlx-swift")`
and `.package(path: "../libs/mlx-swift-lm")` — so every MLX byte in a build
comes from the git submodule commits the superproject pins. Nothing about MLX
is fetched at build time: `provider-swift/Package.resolved` has no `mlx-swift`
or `mlx-swift-lm` entry, and `libs/mlx-swift-lm/Package.swift`'s own
`Layr-Labs/mlx-swift.git` (`branch: "main"`) dependency resolves to the root
package's path dependency of the same identity.

## Mechanism

### The pinned submodules

`.gitmodules` declares three submodules, all Layr-Labs forks. The pin is the
gitlink in the superproject tree; read it with `git ls-tree HEAD libs/`:

| Submodule | Fork | Pinned commit (`2df9d5c1b`) | What the provider gets from it |
|---|---|---|---|
| `libs/mlx-swift` | `Layr-Labs/mlx-swift` | `6b0505cc790f512ae49d740b21e13f80802946bd` | `MLX` (arrays, lazy evaluation, Metal device) and `MLXNN`; its `Cmlx` target compiles the C++ core from the **nested** submodules `libs/mlx-swift/Source/Cmlx/mlx` (`734241bb`) and `libs/mlx-swift/Source/Cmlx/mlx-c` (`9ff12fab`) — the tree the metallib is built from |
| `libs/mlx-swift-lm` | `Layr-Labs/mlx-swift-lm` | `394ffdbb` — a **DEV pin** on the fork branch `feat/qwen38-flash-next-runner`, not a commit on the fork's `main`. It is fork PR #140, the one consolidated runner PR: the `MLXRunners` package with `Runner.adopt` (a runner takes over a module the caller already holds, so nothing is loaded twice, multimodal wrappers included), the Qwen VLM text extraction and its parity gate, `EngineBuild.pagedPool` verified against the constructed pool, the Qwen 3.8 Flash-Next runner, the n-gram table reader, the loader's tensor-name exclusion seam, and the per-request timing stamps. Dev pin; it moves to fork `main` after #140 merges | `MLXLMCommon` (model loading, tokenizer integration, ContinuousBatchingV2 engine, tool-call formats), `MLXLLM` and `MLXVLM` (model implementations), `MLXRunners` (the runner boundary: one runner and one manifest per model family), `MLXLMServer` (OpenAI request types, tool and reasoning parsers, local HTTP router) |
| `libs/mlx` | `Layr-Labs/mlx` (`branch = main`) | `0a725e3000edabc4911cde345270ca950bfa152f` | A separate checkout of the C++ core. Neither `provider-swift/Package.swift`, `Makefile`, `scripts/`, nor `.github/` reads it; bumping it alone changes no provider bytes (`CLAUDE.md`) |

The `libs/mlx-swift-lm` row is the only pin that is not a fork `main`
commit. A dev pin is allowed while the fork PR it depends on (#140) is open;
it is re-pinned to `main` before the release that ships it.

A bump is a superproject commit that moves a gitlink (check out the new commit
inside the submodule, `git add libs/<name>`); the checkout procedure is step 1
of [`../../developer/build.md`](../../developer/build.md). Engine facts in the
architecture pages are read at the pinned `libs/mlx-swift-lm` commit.

### What `ProviderCore` links

| Product | Package (`provider-swift/Package.swift`) | Why |
|---|---|---|
| `MLX`, `MLXNN` | `mlx-swift` (path) | Arrays, Metal backend, layers |
| `MLXLLM`, `MLXVLM`, `MLXLMCommon`, `MLXLMServer` | `mlx-swift-lm` (path) | Models, CBv2 engine, request types and parsers |
| `MLXRunners` | `mlx-swift-lm` (path) | The runner boundary: `RunnerRegistry` is the provider's advertise gate, and `Runner.makeEngine(EngineBuild)` is how a slot's policy reaches a family without the provider naming one |
| `Transformers` | `swift-transformers` `from: "1.3.0"` | First release whose `TokenizerModel.knownTokenizers` includes `TokenizersBackend`, the tokenizer class of Qwen 3.5 / Qwen3-VL checkpoints |
| `Jinja` | `swift-jinja` `from: "2.3.5"` (also linked by `ProviderCoreFoundation`) | `TemplateRenderCheck` compiles chat templates with the exact engine the runtime tokenizer uses |
| `Hummingbird` | `hummingbird` `exact: "2.23.0"` | Matches the `from: "2.23.0"` that `MLXLMServer` declares |

Platform floor: `provider-swift/Package.swift` and `libs/mlx-swift-lm/Package.swift`
both declare `.macOS(.v14)`; `libs/mlx-swift/Package.swift` declares no
`platforms:` at all. There is no runtime macOS-version gate — `darkbloom doctor`
only warns below `recommendedMacOSMajorVersion`, whose value is in
[`../hardware-support.md#constants`](../hardware-support.md#constants).

### What `MLXLMServer` is used for

The provider does not run the upstream inference server. Generation goes
`MultiModelBatchSchedulerEngine` → `EngineV2Bridge` → `EngineV2` (CBv2), and
`MLXLMServer` contributes contracts and parsers around that path:

| Provider code | `MLXLMServer` symbols used |
|---|---|
| `provider-swift/Sources/ProviderCore/Inference/MultiModelBatchSchedulerEngine.swift` | Conforms to `MLXServerEngine`; consumes the OpenAI `ChatCompletionRequest` types; resolves tool parsers with `ServerToolParser.resolve` |
| `provider-swift/Sources/ProviderCore/ProviderLoop.swift` | `ReasoningParser`, `ReasoningParserFormat` (`inferReasoningParser`) |
| `provider-swift/Sources/ProviderCore/Server/StandaloneServer+HTTP.swift`, `provider-swift/Sources/ProviderCore/Server/LocalInferenceHTTP.swift`, `provider-swift/Sources/ProviderCore/Server/LocalChatUploadResponder.swift` | `MLXServerApplication` router, `MLXOpenAIService`, `InMemoryResponseStore`, `ServerMetrics`, `OpenAIErrorEnvelope` — the local / standalone OpenAI-compatible HTTP surface, served by the same `MultiModelBatchSchedulerEngine` |

The upstream `MLXModelContainerEngine` (the server's own generation engine) is
never instantiated by the provider.

### The source-matched metallib

SwiftPM does not compile the `Cmlx` target's Metal shaders, so the kernels
ship as a separate `mlx.metallib` that must match the compiled C++ exactly.

```mermaid
flowchart LR
    S[libs/mlx-swift/Source/Cmlx/mlx] -- cmake, deployment target MLX_METALLIB_DEPLOYMENT_TARGET --> M[mlx.metallib beside the binary]
    M -- locateRuntimeMetallib --> C[mlx.metallib, then Resources/mlx.metallib]
    C -- makeRuntimeMetallibSnapshot: copy to unlinked fd + SHA-256 --> A[/dev/fd/N snapshot]
    A -- darkbloom_mlx_set_metallib_path --> MLX[MLX loader, before the first GPU op]
    A -- digest --> H[template_hashes.mlx_metallib in RuntimeHashes]
```

- **Build.** `scripts/fetch-metallib.sh` cmake-builds the kernels from
  `MLX_SRC = libs/mlx-swift/Source/Cmlx/mlx`, with a
  `MLX_METALLIB_DEPLOYMENT_TARGET` default high enough that the `_nax`
  kernels are compiled, and refuses a library missing any symbol of its
  `COMPLETENESS_CONTRACT` (`_nax`, `gemv`, the Gemma 4 expert-tile builders
  and the `affine_qmv_wide_*` kernels). Default, invocation and cache knobs:
  [`../../developer/build.md#5-provider-cli-swift-with-source-matched-metallib`](../../developer/build.md#5-provider-cli-swift-with-source-matched-metallib).
- **Locate.** MLX's C++ loader tries the colocated `mlx.metallib` before
  `Resources/mlx.metallib` (`load_colocated_library`,
  `libs/mlx-swift/Source/Cmlx/mlx/mlx/backend/metal/device.cpp`);
  `locateRuntimeMetallib` mirrors exactly that order relative to the running
  executable and ignores `MLX_METALLIB_PATH`, which MLX does not read
  (`provider-swift/Sources/ProviderCore/Security/BinaryHasher.swift`).
- **Pin.** `bindRuntimeMetallibForMLX` copies the located file into an
  unlinked open descriptor while hashing it (`makeRuntimeMetallibSnapshot`) and
  points MLX at `/dev/fd/N` through `darkbloom_mlx_set_metallib_path`
  (`provider-swift/Sources/ProviderMetallibControl/ProviderMetallibControl.cpp`).
  `ServeRuntimePreparer` and `StartCommand` do this before any Metal probe
  (`provider-swift/Sources/darkbloom/ServeRuntimePreparer.swift`); rebinding
  with a different source or different bytes fails closed
  (`RuntimeMetallibBindingError`).
- **Report.** The snapshot digest is added to the runtime hashes as
  `template_hashes["mlx_metallib"]` (`augmentRuntimeHashesWithMetallib`,
  `provider-swift/Sources/ProviderCore/ProviderLoop+Serve.swift`).

## Invariants

1. Every MLX byte in a build comes from the pinned gitlinks: both MLX packages
   are path dependencies and `provider-swift/Package.resolved` carries no MLX
   entry — `provider-swift/Package.swift`.
2. The metallib is compiled from the same tree the `Cmlx` target compiles —
   `scripts/fetch-metallib.sh` (`MLX_SRC`).
3. MLX loads only the anonymous snapshot bound before the first GPU
   operation; replacing the colocated file afterwards cannot change loaded
   kernels — `BinaryHasher.swift` (`makeRuntimeMetallibSnapshot`,
   `bindRuntimeMetallibForMLX`).
4. The digest the coordinator sees describes the inode MLX loaded, not a
   pathname — `BinaryHasher.swift` (`RuntimeMetallibSnapshot`),
   `ProviderLoop+Serve.swift`.
5. Generation never runs through an upstream `MLXLMServer` engine —
   `MultiModelBatchSchedulerEngine.swift` implements `MLXServerEngine` over
   `EngineV2Bridge`.

## Failure modes

| Symptom | Cause | Where |
|---|---|---|
| `swift build` succeeds, Metal work fails at start | No `mlx.metallib` beside the executable (or under `Resources/`) | `BinaryHasher.swift` (`locateRuntimeMetallib`); fix: [`../../developer/build.md`](../../developer/build.md) |
| `fetch-metallib.sh` fails on a missing `_nax` symbol | Built with a deployment target below the `MLX_METALLIB_DEPLOYMENT_TARGET` default or an SDK without Metal 4 | `scripts/fetch-metallib.sh` (`COMPLETENESS_CONTRACT`) |
| Bumping `libs/mlx` changes nothing | The compiled core is `libs/mlx-swift/Source/Cmlx/mlx`, a different gitlink | `CLAUDE.md`, `scripts/fetch-metallib.sh` |
| Qwen 3.5 load fails with `.unsupportedTokenizer("TokenizersBackend")` | `swift-transformers` below `1.3.0` | `provider-swift/Package.swift` |
| Metallib rebind refused | Second bind with a different source or digest | `BinaryHasher.swift` (`RuntimeMetallibBindingError`) |

## Code map

| Concern | File / symbol |
|---|---|
| Package graph, pins as path dependencies | `provider-swift/Package.swift`, `provider-swift/Package.resolved` |
| Submodule declarations | `.gitmodules` (superproject), `libs/mlx-swift/.gitmodules` (nested `mlx`, `mlx-c`) |
| Metallib build | `scripts/fetch-metallib.sh` |
| Metallib locate / snapshot / bind / hash | `provider-swift/Sources/ProviderCore/Security/BinaryHasher.swift`, `provider-swift/Sources/ProviderMetallibControl/ProviderMetallibControl.cpp` |
| Bind before first GPU op | `provider-swift/Sources/darkbloom/ServeRuntimePreparer.swift`, `provider-swift/Sources/darkbloom/StartCommand.swift` |
| Digest on the wire | `provider-swift/Sources/ProviderCore/ProviderLoop+Serve.swift` (`augmentRuntimeHashesWithMetallib`) |
| `MLXLMServer` contracts used | `provider-swift/Sources/ProviderCore/Inference/MultiModelBatchSchedulerEngine.swift`, `libs/mlx-swift-lm/Libraries/MLXLMServer/` |
| CBv2 engine | `libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/` — [`../inference.md`](../inference.md) |

## Related

- [`provider.md`](provider.md) — the process these libraries are linked into
- [`../inference.md`](../inference.md) — the CBv2 serving path
- [`../hardware-support.md`](../hardware-support.md) — hardware gates, `recommendedMacOSMajorVersion` and the memory model
- [`../../developer/build.md`](../../developer/build.md) — submodule checkout and metallib build steps
- [`../../operations/provider-release.md`](../../operations/provider-release.md) — release builds ship the same source-matched metallib
