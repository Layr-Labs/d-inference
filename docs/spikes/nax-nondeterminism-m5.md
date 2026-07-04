# M5 NAX kernels produce nondeterministic results (bf16 dense matmul)

**Status:** root-caused to the NAX kernel path; mitigation available; upstream report pending
**Date:** 2026-07-03
**Machine:** M5 Max 128GB (`m5-max-128gb-1`), macOS 26.5.1, Xcode 26.4.1, Metal Toolchain 17F109
**Stack:** `Layr-Labs/mlx-swift` @ `df1fdc5` (mlx 0.32.0 + `darkbloom/mlx-0.32.0-nax` branch), metallib built from the same source at deployment target 26.2

## Symptom

Identical single-forward runs of DeepSeek-V4 (fixed 7-token prompt, 6-layer truncated
real-weights checkpoint, greedy, single thread) produce **different logits run-to-run**,
including intermittent NaN (~2 of 6 runs). Inserting `eval()` boundaries between layers
*changes the results* — per-layer evals were consistently finite while the single fused
graph intermittently NaN'd. That "evaluation order changes numerics" signature pointed
at a kernel-level race rather than a math bug in the model port.

## Isolation

`DSV4Smoke --op-stress N` (in `libs/mlx-swift-lm`, `Sources/DSV4Smoke/main.swift`) runs
each DeepSeek-V4-relevant primitive N times on identical inputs and reports run-to-run
drift. On the M5 Max with the standard build:

| op | result |
|---|---|
| dense matmul bf16 `[7,4096] x [4096,1024]` | **DRIFT** (large, occasionally garbage-scale values) |
| qmm affine g64 | stable |
| qmm batched 3D | stable |
| gather-qmm mxfp4 g32 | stable |
| fast.rope (inf NOPE freqs) | stable |
| SDPA + sinks + bool mask | stable |

Rebuilding the identical source with the NAX kernels compiled out:

```bash
swift build -c release --product DSV4Smoke --scratch-path .build-nonax -Xcc -DMLX_METAL_NO_NAX
```

makes **everything deterministic**: the op-stress dense matmul is drift-free and 8/8
full-model forwards are bit-identical. The nondeterminism follows the NAX
(Neural Accelerator) steel-GEMM path exactly.

Cross-check: the Python mlx **0.31.2 wheel** on the same box is deterministic — consistent
with pip wheels not engaging NAX at runtime (wheels are built with a deployment target
< 26.2; cf. upstream PR #3622 "NAX requires MACOSX_DEPLOYMENT_TARGET=26.2"). Local
M3-generation machines are unaffected (no NAX hardware, gen < 17 check in
`metal::is_nax_available`).

Already ruled out: the fork's Sinkhorn Metal kernel (ops-fallback drifts identically),
compiled-decode fusions (`MLX_COMPILED_DECODE=0`), fused gate+up (`BENCH_NO_FUSED_GATE_UP=1`),
bf16 weight conversion (`DARKBLOOM_BF16_WEIGHTS=0`), stale metallib (rebuilt from the
exact pinned mlx source; hash-verified).

Known upstream NAX fixes for silent corruption are already **included** in our pin
(#3631 int16 edge-tile overflow, #3560 steel GEMM safe-load offset), so this is
something else — plausibly a race in `steel_gemm_fused_nax` for small-M shapes, or an
M5-Max-tuning interaction (#3211 added M5 Pro/Max dispatch tuning).

## Impact

- **Not DeepSeek-specific.** Dense bf16/fp16 GEMMs run in every fleet model. Any provider
  on M5-generation hardware running our standard binaries may produce nondeterministic
  outputs and, in deep models where drift compounds, intermittent NaN → in-band failures.
- Weights attestation is unaffected (hashes are computed on files, not activations), but
  output reproducibility — and anything downstream that assumes greedy decode is
  deterministic (golden tests, benchmark comparisons, MTP acceptance checks) — is not
  trustworthy on M5 boxes until mitigated.
- Fleet exposure today is limited (few M5 Max providers), but M5 is the growth SKU.

## Mitigation options

1. **Short-term (recommended):** build provider release binaries with
   `-Xcc -DMLX_METAL_NO_NAX` (and keep building the metallib as-is — the host-side
   dispatch flag alone keeps NAX kernels unused). Perf cost needs an A/B on Gemma-4 /
   GPT-OSS decode+prefill on M5 before shipping: MoE-heavy decode is dominated by
   quantized matmuls (unaffected), so the hit is likely concentrated in prefill.
2. Upstream added a build option `MLX_DISABLE_NAX` (#3593); there is **no runtime env
   switch** (`is_nax_available` is compile-time + hardware gated), so per-box opt-out
   requires a separate binary — another reason to just disable fleet-wide for now.
3. Root-cause upstream: file with a standalone repro (build mlx from source at
   deployment target 26.2 on M5, loop `mx.matmul` on fixed bf16 inputs, compare across
   runs). Also A/B the fork's allocator buffer-count-trim patch (`aa480bd8`) reverted —
   drift persisted in a single-op loop where allocator churn is minimal, so it's very
   unlikely to be the cause, but excluding it makes the upstream report clean.

## Repro (10 seconds, on any M5 box)

```bash
cd libs/mlx-swift-lm
swift build -c release --product DSV4Smoke
./.build/arm64-apple-macosx/release/DSV4Smoke --op-stress 16   # dense matmul drifts
swift build -c release --product DSV4Smoke --scratch-path .build-nonax -Xcc -DMLX_METAL_NO_NAX
./.build-nonax/arm64-apple-macosx/release/DSV4Smoke --op-stress 16   # clean
```

## Fleet perf A/B (2026-07-03, M5 Max, Gemma-4-26B-A4B-4bit)

Measured via DSV4Smoke's single-stream generate path, greedy, 3 runs per build:

| | NAX | no-NAX (`MLX_METAL_NO_NAX`) |
|---|---|---|
| decode (192 tok) | 11.4 tok/s ×3 | 11.4 tok/s ×3 |
| TTFT (525-token prefill) | 2.32 s | 2.07 s |
| run-to-run determinism | deterministic (3× same hash) | deterministic (3× same hash) |

- **Zero measurable cost** to disabling NAX for MoE-family serving: decode is
  quantized-matmul dominated (NAX only accelerates dense GEMM), and even the
  prefill-heavy case showed no NAX win at these shapes.
- Gemma is internally deterministic under NAX — the drift is **shape-dependent**;
  the op-stress repro's failing shape (`[7,4096] × [4096,1024]` bf16) is exactly
  DeepSeek-V4's hyper-connection mixes GEMM, which is why V4 surfaced it.
  NAX-vs-no-NAX outputs differ from each other (different kernels, different
  rounding) — expected and fine.
- Caveat: single-stream harness; the batched engine's large-batch prefill GEMMs
  weren't A/B'd. If batched prefill regresses on fleet telemetry, revisit.

**Decision: build release binaries with `-Xcc -DMLX_METAL_NO_NAX`** (wired in
`release-swift.yml`) until the upstream kernel is fixed. No runtime toggle
exists, and a proven silent-corruption risk outweighs an unmeasurable perf win.

## Root cause (2026-07-03): JIT-compiled NAX kernels, not the kernels themselves

Isolated on the box via a hypothesis ladder (full log in
[nax-upstream-issue-draft.md](nax-upstream-issue-draft.md)):

- Upstream main AND our fork SHA built as default Python wheels (nojit + AOT
  metallib, DT 26.2): **zero drift** over 1024 iterations — with `fprintf`
  probes proving `is_nax_available()=1` and `splitk_nax` dispatch for the
  failing shape. AOT NAX kernels are correct; the fork's allocator patch is
  exonerated.
- Upstream main rebuilt with `-DMLX_METAL_JIT=ON`: **drifts 63/63** with
  progressively exploding deltas (~1e3 → inf → NaN in ~25 iters) — the exact
  Swift signature, pure Python, pure upstream.
- mlx-swift compiles `jit_kernels.cpp` (excludes `nojit_kernels.cpp` in
  `Package.swift`), so the Swift stack always runtime-compiles NAX steel-GEMM
  source via `MTL::Device::newLibrary` at `LanguageVersion4_0`. A minimal
  mlx-swift matmul-loop executable reproduces (56/63); metallib cross-swaps
  and `-mmacosx-version-min=26.2` rebuilds change nothing.

So: the NAX GEMM kernel source is fine when `xcrun metal` compiles it AOT,
and corrupts (stale/uninitialized-read pattern) when the runtime Metal
compiler JITs it. Every mlx-swift user on M5 is exposed; Python pip users are
not (nojit default). `MLX_METAL_NO_NAX` remains the correct fleet mitigation
until upstream fixes the JIT path (or mlx-swift grows an AOT path for these
kernels).

## Follow-ups

- [x] A/B fleet-model perf (Gemma-4) with/without NAX on M5 Max — no measurable cost
- [x] Decide release posture — ship `MLX_METAL_NO_NAX` (see above)
- [x] Standalone upstream repro — validated: pure-Python `MLX_METAL_JIT=ON`
  loop drifts on upstream main; AOT control clean (probe-verified NAX
  engagement in both)
- [ ] File the issue on ml-explore/mlx (text ready in the draft doc — user files)
- [ ] Re-test on each mlx bump; remove the flag when fixed upstream
