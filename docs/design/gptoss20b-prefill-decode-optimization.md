# GPT-OSS 20B prefill and decode optimization

> Last updated: 2026-09-05 · commit `4d9811f7c`

Status: **In progress** — 2026-09-05. Local implementation and paired measurements; no production rollout.

The goal is to reduce fresh-prompt time to first token first, then increase sustained aggregate decode throughput at B=1, B=2, and B=4. Prefix reuse and speculative decoding are excluded. All experiments use the existing `research/gptoss20b-profile` worktree on the local M4 Max in AC High Power mode. The M5 Max is reserved for other work.

## Starting evidence

The checkpoint is `mlx-community/gpt-oss-20b-MXFP4-Q8`, snapshot `773a7da77e569019bb0fd17a554b263738d669a3`: 24 layers, 32 experts with four selected per token, hidden width 2880, and vocabulary 201088. Alternating full and 128-token sliding-window attention already uses fused attention with sinks. The saved uninstrumented baseline measured about 0.44 seconds for 512-token prefill, 8.32 seconds for 8K request TTFT, and 47.63 seconds for 32K request TTFT. Short-context aggregate steady decode was 105.1, 157.8, and 156.2 tokens/second for B=1, B=2, and B=4. These are orientation values; new changes require fresh paired controls.

The 8K diagnostic capture projects all 8192 hidden positions through the large vocabulary head although the caller needs only the final position. Expert matrix multiplication is another major source of work. Decode repeatedly widens immutable BF16 constants to FP32. Diagnostic command-buffer durations overlap and contain mixed operators, so they cannot be added as exclusive operator costs. Compiled primitive scopes also overcount selected-step activation dispatches; that count is excluded from the optimization case.

## Implementation sequence

| Priority | Change and first-principles reason | Required evidence before enabling |
|---|---|---|
| 1 | Skip the output head on intermediate prefill chunks. Preserve all transformer and KV work; the scheduler only needs an evaluation handle until the final chunk. | Exact same-shape final logits and KV state; chunk-boundary and continuation tests; fresh 512/4K/8K/32K timing. |
| 2 | Project only the final hidden position on the final prefill chunk. This removes remaining vocabulary work, but changes the head's GEMM/GEMV geometry. | Separate arm, logit error and greedy continuation checks; measure against intermediate-only pruning. |
| 3 | Increase MXFP4 expert GEMM tile reuse for actual GPT-OSS shapes. Wider tiles amortize packed-weight unpacking and improve arithmetic reuse. | Ragged expert boundary, dtype and shape parity; compare 16x64x32, 32x64x32, and 32x64x64 tiles; retain a safe fallback. |
| 4 | Fuse expert gate and up projections using concatenated checkpoint rows. Reuse the same input and routing while preserving biases, clipping, and activation arithmetic. | Float/affine/MXFP4 packing and output checks; real-model token parity; load peak and resident-memory checks; separate performance arm. |
| 5 | Reuse BF16-to-FP32 conversions of unchanged scales, affine offsets and biases. Repeating a conversion does not add information and consumes launches/bandwidth. | Detect direct array and module updates, bypass traced transforms, preserve parameter trees and U8 MXFP4 scales; exact outputs; B=1/2/4 throughput. |
| 6 | Specialize gathered MXFP4 matrix-vector multiplication for width 2880, including the tail beyond five 512-element blocks. | Tail and expert routing parity, B=1/2/4 measurements, no out-of-bounds access or silent shape dispatch. |
| 7 | Narrow the final layer to its last query on the final prefill chunk, using the existing cache capability to preserve every K/V write. | Same K/V bytes and offsets, batched continuation and legacy-cache fallback, real-checkpoint logits and greedy output. |
| 8 | Experiment with temporary expert-weight dequantization before large sorted dense GEMMs. This may exchange unpacking work for more memory traffic and temporary memory. | Default-off screening; actual peak memory first, then numerical parity and speed. The existing GPT-OSS activation floor is 3.5 GiB and must not be exceeded by a promoted path without new measurements and a coordinated floor update. |
| 9 | Reassess the remaining attention, routing and scheduling cost after the above changes. Test stripe size and launch reductions only where measured work remains material. | Full/windowed cache correctness, B=1/2/4 scheduling invariance, long-context latency and memory. |

Changing activation precision is a separate numerical experiment, not an automatic consequence of launch reduction. Memory admission reserves, cache semantics, prefix policy and generation defaults are not part of this optimization.

## Measurement and acceptance

Use the production CBv2 engine and real checkpoint. Bank each executable, its matching metallib, source diff, commit pins and build command. GPU timing is serialized with builds and other GPU tests. Warm the measured geometry; collect fresh-process controls interleaved with candidates. Start with a small screening matrix, then repeat only promising arms. Record TTFT, common-overlap decode throughput, per-sequence throughput, token IDs, KV backend, power state and peak memory. B=2 and B=4 results report aggregate throughput explicitly.

Same-shape arithmetic-preserving changes must retain outputs. Geometry-changing kernels require numeric tolerances justified by reference comparisons plus actual-model greedy continuation and scheduler coverage. A faster run with row failures, incomplete generation, insufficient overlap, changed controls or model loading in the timing window is not a win. B=8 is an additional stress/correctness case because the baseline already exhibits prompt-chunk geometry sensitivity; it cannot establish a new regression without a matched baseline.

Ship successful changes in focused commits and reviewable PRs, with dependencies linked across MLX core, its C/Swift wrappers, the language-model library and this provider integration. Archive losing experiments and explain the result. Document measured improvements separately from targets. The previous 1.3–1.5x prefill and 20–40% decode aspirations remain experiment targets until paired results establish them.

## Code map

- `libs/mlx-swift-lm/Libraries/MLXLLM/Models/GPTOSS.swift` (`GPTOSSModel`): model forward and checkpoint loading.
- `libs/mlx-swift-lm/Libraries/MLXLMCommon/SwitchLayers.swift` (`QuantizedSwitchLinear`): gathered expert projections.
- `libs/mlx-swift/Source/MLXNN/Quantized.swift` (`QuantizedLinear`): quantized dense projections.
- `libs/mlx-swift/Source/Cmlx/mlx/mlx/backend/metal/quantized.cpp`: quantized Metal dispatch.
- `provider-swift/Sources/ProviderBenchmark/SchedulerPrefillBenchmark.swift` (`SchedulerPrefillBenchmark`): production-engine prefill measurements.
- `provider-swift/Sources/ProviderBenchmark/ThroughputSweepDecodeTiming.swift`: common-overlap aggregate decode measurements.
- `scripts/profile-gptoss.py`: pinned executable/model benchmark runner.

See the [initial profiling report](../reports/2026-09-05-gptoss20b-quick-profile.md) and [improvement estimate](../reports/2026-09-05-gptoss20b-improvement-estimate.md) for the evidence and limitations that led to this sequence.
