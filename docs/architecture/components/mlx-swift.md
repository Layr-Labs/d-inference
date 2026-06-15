# MLX-Swift

MLX-Swift is the machine-learning stack that runs inside the provider. Darkbloom vendors two upstream repositories under `libs/`:

- `libs/mlx-swift` — the core MLX array framework for Apple Silicon.
- `libs/mlx-swift-lm` — language-model and vision-model implementations, tokenizers, downloaders, and an OpenAI-compatible inference server built on top of MLX-Swift.

Both are git submodules/forked vendored copies. The provider links them as Swift Package Manager dependencies from `provider-swift/Package.swift`.

## Responsibilities

| Responsibility | Where it lives |
|---|---|
| Array framework + Metal GPU backend | `libs/mlx-swift/` |
| LLM/VLM model implementations | `libs/mlx-swift-lm/Libraries/MLXLLM/`, `MLXVLM/` |
| Common model loading, tokenization, chat templating | `libs/mlx-swift-lm/Libraries/MLXLMCommon/` |
| OpenAI-compatible inference server | `libs/mlx-swift-lm/Libraries/MLXLMServer/` |
| Integration packages for model downloaders and tokenizers | `libs/mlx-swift-lm/` and its transitive dependencies |

## Key modules

### MLX-Swift core (`libs/mlx-swift/`)

MLX-Swift exposes the MLX array framework to Swift. It targets macOS 14 and later and uses Metal for GPU acceleration on Apple Silicon. The provider links:

- `MLX` — arrays, device placement, and lazy evaluation.
- `MLXNN` — neural network layers used by model implementations.

See `libs/mlx-swift/README.md` for build instructions and platform notes. SwiftPM command-line builds cannot compile Metal shaders; release builds typically use `xcodebuild`.

### MLX-Swift-LM (`libs/mlx-swift-lm/`)

MLX-Swift-LM provides high-level LLM and VLM support. The provider consumes these products:

- `MLXLLM` — large language model implementations.
- `MLXVLM` — vision-language model implementations.
- `MLXLMCommon` — shared loading, tokenizer integration, chat templates, and `LLMModelFactory` / `VLMModelFactory`.
- `MLXLMServer` — an OpenAI-compatible HTTP inference server used by the provider's batch scheduler and optional unified local endpoint.

Version 3.x of MLX-Swift-LM decoupled from specific tokenizer/downloader packages, so the provider also declares `swift-transformers` (≥ 1.3.0) and pins `swift-jinja` for template rendering parity.

## Provider integration

`provider-swift/Package.swift` declares the vendored packages as local path dependencies:

```swift
.package(path: "../libs/mlx-swift"),
.package(path: "../libs/mlx-swift-lm"),
```

The `ProviderCore` target links:

- `MLX`, `MLXNN` from `mlx-swift`
- `MLXLLM`, `MLXVLM`, `MLXLMCommon`, `MLXLMServer` from `mlx-swift-lm`

The provider's `BatchScheduler` and `MultiModelBatchSchedulerEngine` (`provider-swift/Sources/ProviderCore/Inference/`) translate coordinator requests into MLX-Swift-LM calls, manage model loading/unloading, and implement continuous batching with prefix caching.

## Privacy-relevant boundaries

- **In-process execution**: MLX-Swift and MLX-Swift-LM are linked directly into the `darkbloom` binary. There is no separate Python interpreter or subprocess; model weights, activations, and KV cache stay inside the hardened provider process.
- **No network access for inference**: The libraries operate on tensors already loaded from local storage. Network access is limited to the provider's own coordinator client and model download/prefetch paths.
- **Model weights integrity**: The provider computes SHA-256 weight hashes (`ProviderCoreFoundation/WeightHasher`) and advertises them to the coordinator. The coordinator cross-checks hashes against the model catalog before routing.

## Outdated claims corrected

- The old `ARCHITECTURE.md` described inference via a fork of `mlx-swift-lm` and `swift-sodium` for NaCl Box. The Swift stack is still forked/vendored under `libs/`, but the provider also uses `swift-sodium` directly for coordinator↔provider NaCl Box compatibility; MLX-Swift-LM itself does not handle network encryption.
- The old doc claimed "no embedded Python interpreter and no local inference server." The first half remains true; the second half is partially outdated because `MLXLMServer` exposes an OpenAI-compatible server that the provider optionally surfaces via `LocalInferenceHTTP.swift` for local/unified mode.
- The old doc's hardware support table listed specific chip/memory/model mappings. These are illustrative only; actual supported models depend on the model catalog's `min_ram_gb` and the provider's runtime memory check.
