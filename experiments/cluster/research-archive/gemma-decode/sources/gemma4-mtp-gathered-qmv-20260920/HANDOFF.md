# Small-width packed QMV source experiment — 2026-09-20

Source only. No compiler, GPU, model payload, native entry, remote action, or new product admission was executed by the author. This package changes no default kernel dispatch, environment flag, model implementation, or current workspace. Root must compile and run the exact-source qualifier before considering model integration.

## Immediate integration and execution

Preferred: add every `Runtime/*.swift` to the existing DarkbloomClusterRuntime target and compose the two unique `BenchmarkEntry.patch` edits into the current `Gemma4BenchmarkEntry.swift`. The source mapping and exact existing Entry preimage are in `source-inputs.json`. Pipeline owns composition with remote/width branches. Build the existing **GemmaResidentBenchmark** product with the existing native flags and compiler owner.

Under the original root process/lease/resource supervisor, run separately:

```
GemmaResidentBenchmark --qualify-small-qmv dense
GemmaResidentBenchmark --qualify-small-qmv gathered
```

Both have a native 300-second alarm. The existing product main returns the JSON result; **exit zero alone is insufficient**: require schema, exact mode/count, every finite exact-byte result, final cache zero, and actual parent process/lease/resource retirement. Numerical failure returns `passed:false`; do not discard its report. The optional separate `Entry/main.swift` and `Package.patch` add `GemmaSmallGatherQMVCheck --describe|--dense|--gathered` if a future standalone product is useful; they are unnecessary for the preferred build and its standalone main exits2 on numerical mismatch.

Dense runs108 cases: nine actual W4/W8 matrix geometries × widths1/2/3 × BF16/F32 × mixed/cancellation input. Candidate acceptance is exact bytes against independent ordinary M1 calls, which select actual current qmv/qmv_fast. Current default batched quantizedMM is reported separately (exactness, maximum absolute/relative RMS error, primitive duration); its difference is not a candidate failure. Gathered runs288 cases: gate/up/down seeds × two broadcast layouts ×12 width/route packets × BF16/F32 × two inputs. Reference is actual unsorted gatherQuantizedMM; all96 down cases additionally execute unchanged weightedExpertSum in original slots. Twelve real device malformed-route controls require nonfinite refusal (out-of-range or repeated expert within a token), never unsafe plane access. Actual compiled output-byte equality is required, with no tolerance.

One warmup and three paired samples alternate candidate/reference order. Timers include new graph construction, eval, and checked GPU+CPU C completion, excluding fresh guard/copy/CPU comparison. Default dense batch always runs after the pair, so its timing is diagnostic rather than an order-balanced speed claim. Output contains raw nanoseconds, not model TPS. No per-trial model/environment result is inferred.

## Arithmetic and ownership

`GemmaSmallQMVArithmetic` retains M1 packed-affine operation order: masked packed dot, separate input sum, `scale*dot + bias*sum`, increasing per-lane K blocks, and a32-lane simd_sum. W4 uses four-term masked groups; W8 uses sequential byte terms. Dense uses the actual M1 fast eligibility: two packs/lane if K is aligned to `32*(32/bits)*2`, otherwise one. Supported N is8-aligned and K64-aligned, so every live lane has a full4/8/16-value chunk. Gather K2816/704 uses8values/lane and preserves the safe192-value final block at K704. No dense K64/128 quad or non-affine path is admitted.

For gathered assignments, only the first occurrence of each expert computes. It gathers at most one assignment per input token, shares each packed weight and affine metadata load across those1...3 independent rows, and writes directly to each original `[token,topKslot,output]` address. No padding, CPU routing readback, weighted partial sum, sorting, or route-trust shortcut is introduced. Invalid device routes poison their affected outputs and never index an invalid expert plane. Actual model routing and finite-result admission remain the caller's responsibility; this private kernel is not wired into model code.

Dense shares packed weights across up to3 input rows with the same arithmetic body. Compiler contraction/reassociation and SIMD code generation can still differ: mathematical source matching is **not** a bitwise proof. Both dtypes and tail/fast variants must pass actual microqualification. A kernel exact to independent M1 calls may intentionally differ from existing M3 qmv_wide, which dequantizes each weight first and reduces different groups with an8-lane shuffle ladder.

## Memory and lifecycle

One stored synthetic projection matrix is live at a time. Largest gathered fixture is24 experts (needed for three disjoint top8 routes), not a full128-expert bank. Stored W4 bytes plus F32 scales/biases are29,736,960B; the preflight doubles every matrix root and separately rounds inputs, eight output/conversion worksets and4MiB diagnostic overhead. Each geometry must fit the actual MLX allocation-bound sum within **67,108,864B =64MiB** native and the separate same-size host bound before construction. Dense matrices are smaller. Input patterns include signs, cancellation and mixed magnitudes; no model/checkpoint weights are loaded.

Fresh AC, low-power, thermal, pressure1, zero swap, deadline and native fault checks remain. Actual-free minimum is10GiB +128MiB (10,871,635,968B), covering both explicit reserves; allocator admission retains2GiB and64MiB future native allowance. Active extra bytes are observed and must stay within64MiB; freed-buffer cache is disabled and final cache must be zero. Eval is followed immediately by native-error inspection; checked C GPU/CPU fences precede copying/releasing sample roots. Original external process/lease owner remains required. There is no serving, request, model, or transport lifecycle framework here.

## Why existing dispatch is insufficient

Actual SwitchLayers MTP T≤3 gives at most24 gathered assignments, below its64-assignment sorting threshold. Current GatherQMM sorted route additionally requires `M==1`, B≥16, a truthful sorted hint and B/E≥4. Expert-slices then requires thousands of assignments and specific larger geometries. `MLX_GATHER_QMM_EXPERT_SLICES` cannot legitimately activate this small unsorted regime. Padding/trust flags would change the contract.

Current dense M≥2 on affine gen15+ already uses qmv_wide and reuses weights, so there is no unused generic dense batching flag. Its arithmetic differs from M1: weight dequantization before dot and an8-lane reduction. This candidate tests whether M1 arithmetic can coexist with weight reuse. The actual checkpoint uses W4 attention q/k/v with K2816, W4 o with K4096/8192, W8 dense MLP K2816→2112 and K2112→2816, and W8 router K2816→128. The262144-row vocabulary head is excluded from this≤64MiB fixture; extending it requires separate admitted integration, even though its inner arithmetic is represented.

The observed P128 local MTP36.20 TPS versus solo59.57 requires approximately1.646× speedup, or39.2% less current latency. If experts were37% of time (hypothetical, not measured), even eliminating them gives only1.587×; ideal3× expert acceleration gives1.327×. Dense/head/state work must therefore be measured too. Gather reuse depends on actual expert overlap and can lose when routes are disjoint. Register pressure, route scanning and memory cache effects require actual hardware measurement. No end-to-end speed prediction is made.

## Required next gates

1. Source pins/replay, same-source build, actual metadata/invalid argv, then dense and gathered under original supervisor.
2. Require exact primitive bytes and weighted slot results; preserve any failing report. Compare timing only on passed cases; no globally enabled flag.
3. Only then stage explicit per-model callsite selection with original memory ownership. Run ordinary/verify1/verify3 keep3/keep1 on identical forced token sequences and compare full262144 rows and all90 state components before performance.
4. A model candidate must retain actual conditioning/retirement and pass matched solo/MTP cohorts. Existing MTP batch-versus-serial numerical mismatch is not waived by this experiment.
