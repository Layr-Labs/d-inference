# GPT-OSS 20B prefill and decode improvements

> Last updated: 2026-09-05 · commit `94c7c31eb`

Local implementation and measurements on Apple M4 Max (40 GPU cores, 128 GB), AC High Power mode, using `mlx-community/gpt-oss-20b-MXFP4-Q8` snapshot `773a7da77e569019bb0fd17a554b263738d669a3`. All workloads use the production CBv2 engine with contiguous KV, synthetic fixed prompts, greedy output, and no prefix reuse or MTP. No remote benchmark or production deployment is part of this work.

## Changes selected

- **Prefill output pruning:** intermediate chunks retain every transformer/KV dependency but omit the unused vocabulary projection. The final chunk projects only its final hidden position. Full and intermediate-only rollback policies remain available.
- **Exact constant reuse:** unchanged BF16 scales, affine offsets and biases reuse their FP32 conversion. A retained backing-array descriptor detects supported in-place updates and prevents identity reuse; compiled/autodiff transforms bypass the cache, and cached tensors stay outside the parameter tree.
- **GPT-OSS 20B expert fusion:** compatible gate/up packed rows, scales and biases concatenate without requantization. Quantization-policy conflicts keep split modules. The loader releases its staging owners, then checks one fused projection at a time; measured load peak falls from **18.857 GB to 12.362 GB**, compared with **12.079 GB** for split loading. Post-load active memory is effectively unchanged. Provider/coordinator admission floors are unchanged.
- **M4 Max gathered MXFP4 decode:** a guarded width-2880 matrix-vector kernel handles five full 512-element blocks and a masked 320-element tail. Only 20 SIMD lanes read tail data. The automatic default is restricted to physical `applegpu_g16s`; unsupported geometries and explicit rollback retain the original route.

The optional `last-layer` policy also narrows the final full-attention layer's query and output work while writing all K/V positions. It reduced 512-token TTFT another 4–5% relative to head-only pruning in paired screening, but did not show a repeatable 8K gain. A 32-row expert prefill tile and compiled expert graphs remain opt-in because their gains were small or batch-dependent. See [configuration controls](../reference/configuration.md#gpt-oss-performance-controls).

## Final default comparison

Final validation is running. The final results table will replace this paragraph after every scheduled cell is validated; candidate measurements below are not substituted for final-default evidence.

## Candidate comparisons

Every completed pair uses two A–B–B–A cycles, one measured run per fresh process after warmup. These descriptive paired ratios are not confidence intervals. They are preferable to comparing the earlier busy-desktop baseline directly with an idle machine.

| Candidate | Paired outcome | Selection |
|---|---|---|
| Final-position head, 8K | 12.4% lower TTFT in both cycles; about 1.2 GiB lower peak | Default |
| Final-position head, 512 | 11.5–11.7% lower TTFT | Default |
| Constant reuse + decode tail + fusion, 512 | B=1 +12.7–12.8%, B=2 +9.5–9.9%, B=4 +6.0–7.0% aggregate decode | Default components; final executable rechecked below |
| Decode tail alone | B=1 +3.0–3.5%, B=2 +1.9–2.4%, B=4 +1.3–3.3%; every output sequence exact | Default only on measured M4 Max architecture |
| Last-layer pruning, 512 | 4.3–5.1% lower TTFT relative to head-only | Opt-in |
| Last-layer pruning, 8K | One cycle slower, one faster | No universal default |
| Expert tile 32×32×32, 8K | 1.1–3.0% lower TTFT | Opt-in |
| Expert tile 16×32×64, 8K | 7.4–8.0% slower | Removed |
| Wider 64-column expert tiles | Initial screen lacked a clear gain and had long-cell drift | Removed |
| Query block 64/256 and solo stripe 4096 | Mixed or slower paired results | Existing defaults retained |
| Temporary expert dequantization, 512 | About 1.04 s and 17.95 GiB peak; substantially worse than packed kernels | Removed; no long-context run or reserve increase |
| Compiled expert graphs | Exact generated sequences; gains varied across B and cycles, including a B=2 regression | Opt-in |

Early GPU submission between model layers was investigated but is not included: the nonthrowing model seam cannot safely stop after a recorded asynchronous MLX failure without an engine error-aware interface. Intermediate final-layer K/V-only pruning likewise needs an explicit cache update/offset capability; mutating row storage behind the cache would violate its cached-offset contract. These are documented follow-ups, not implemented speedup claims.

## Correctness and limits

The real checkpoint suite compared 42 output-policy/fusion/batch/prompt arms across B=1/2/4 and 512/2065-token prompts. All generated continuations and prefill KV receipts matched. Across 1,568 equal-prefix positions, top-1 choices agreed and the maximum logit difference was 0.0000515. Same-shape intermediate pruning and fused full-head arms were bit-exact in that test. Shape-changing reductions are not generally guaranteed bit-exact.

Focused release tests cover full/sliding cache offsets, sinks, chunk boundaries, embeddings, rollback policy, quantization aliases, checkpoint loading, native expert boundaries and tails, mutation and parameter-tree invariants. The final focused run passed 58 Swift Testing cases and 8 XCTest cases; the optional real-checkpoint test was run separately. The Python benchmark/control suite passed 25 tests. The C++ doctest additions are source coverage; this run executed the equivalent Swift GPU tests rather than a separate native CMake test build.

The benchmark reports aggregate decode only inside the shared interval where every row makes progress, with at least 32 measured tokens per row. Aggregate divided by B is fair-share throughput, not an independently timed row metric. TTFT is time to the first generated token, including reasoning tokens, not necessarily visible answer text. The final benchmark warms the requested generation length; the original executable used an eight-token warmup, which may not form the full long-context batch before early rows finish. Completed paired repetitions and this warmup difference are retained in the evidence.

B=8 is a separate stress case: the original baseline already has prompt-chunk geometry-dependent greedy variation. Results on B=1/2/4 do not prove broad generation invariance across every admission schedule. These are workstation measurements on one checkpoint and architecture, not a fleet-wide performance guarantee or a claim of a 2× speedup.

The initial final-validation 8K B=2 comparison is excluded from the speedup claim: one optimized repetition admitted row 1 before row 0 and produced different continuations. All other repetitions admitted row 0 first and matched. The schema-6 benchmark submitted from concurrent child tasks; schema 7 now submits in row order before consuming streams concurrently, records that contract, and validates timestamps. The order correlation is evidence of a changed workload geometry, not by itself proof that every numerical difference is harmless. Ordered long-context reruns are recorded separately.

## Evidence and reproduction

The [portable evidence directory](data/gptoss20b-optimization/README.md) contains paired measurements, output hashes, test summaries and artifact hashes. The [implementation plan](../design/gptoss20b-prefill-decode-optimization.md) records the scope and hypotheses; the [initial profile](2026-09-05-gptoss20b-quick-profile.md) preserves the earlier measurements and corrected diagnostic limitations.

Build with `swift test -c release -j 8 --skip-update --force-resolved-versions --package-path provider-swift --filter 'GPTOSSOptimizationTests|ThroughputSweepDecodeTimingTests|BenchmarkArrivalPromptTests'`, and build the matching Metal library with `scripts/fetch-metallib.sh provider-swift/.build/release`. Bank the executable, resource bundles and metallib together before timing. `scripts/profile-gptoss.py` runs explicit cells; `PYTHONPATH=scripts python3 -m gptoss_profile.controls <design.json> --output <directory> --cycles 2` performs paired prefill or decode controls. The [developer test guide](../developer/test.md) describes the raw-artifact contract.
