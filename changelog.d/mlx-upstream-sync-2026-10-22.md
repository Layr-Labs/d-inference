### MLX stack moves to the 2026-10-22 upstream sync

- `libs/mlx` moves from `ad4745a2` to `ff4bb35b`, both at the top level and in the copy nested in `libs/mlx-swift` that Cmlx compiles. `libs/mlx-swift` moves from `67dc7528` to `eedca444` (nested mlx-c `5e9be4da` to `004c735f`), and `libs/mlx-swift-lm` from `6148b6da` to `476cb7c0`, which pins that `libs/mlx-swift`. These forks now contain upstream `ml-explore/mlx`, `mlx-c`, `mlx-swift` and `mlx-swift-lm` as of 2026-10-22.
- The Metal kernel sources change, so the release metallib changes and the first start after updating compiles kernels again.
- The provider follows the SDK API changes: `LanguageModel.prepare` takes the request `state` and `PrefillParameters`, image and video inputs carry their payload in `.source`, Qwen 3.5 target weight sanitizing can throw, and the new `Generation.rejectedToolCall` event is ignored by the benchmark like a tool call.
