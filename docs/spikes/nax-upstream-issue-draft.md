# DRAFT upstream issue for ml-explore/mlx — not yet filed

File manually after validating the standalone repro below on an M5 (the repro
must not depend on our fork).

**Status 2026-07-03: DO NOT FILE YET — the pure-Python repro below did NOT
reproduce.** Upstream `main` (de7b4ed9, v0.32.0.dev) built from source on the
M5 Max box (`uv pip install ./mlx` with `MACOSX_DEPLOYMENT_TARGET=26.2`;
metallib contains the `*_nax` kernels) ran the failing shape 63 times with
zero drift. Also checked: the 19 upstream commits between our fork base
(b410f6c81) and de7b4ed9 contain no NAX/steel-GEMM changes, so "fixed
upstream" is unlikely. Before filing, the gap between the drifting Swift
op-stress and the clean Python loop must be closed — see "Validation next
steps" at the bottom. Build artifacts live on the box under `~/nax-repro/`
(clone, venv with the built wheel, `drift.py`).

---

**Title:** Nondeterministic results (intermittent garbage/NaN) from NAX bf16
matmul for some shapes on M5 Max / macOS 26.5

**Body:**

On M5-generation hardware with NAX enabled (source build,
`MACOSX_DEPLOYMENT_TARGET=26.2`), repeated `matmul` on identical bf16 inputs
returns different results run-to-run for some shapes, occasionally including
garbage-scale values that surface as NaN in downstream softmax. The same
binary with NAX compiled out (`MLX_DISABLE_NAX` / gen<17 hardware) is
bit-deterministic.

- Observed on: M5 Max (128GB), macOS 26.5.1, Xcode 26.4.1 / Metal Toolchain
  17F109, mlx v0.32.0 (also reproduced at <fork sha>, which includes #3631 and
  #3560).
- Failing shape (reliable within ~16 iterations): `x[7, 4096] @ w[4096, 1024]`,
  both bfloat16. Several other shapes tested clean (affine/mxfp4 qmm,
  gather-qmm, rope, SDPA; a Gemma-family model is end-to-end deterministic on
  the same box) — the drift appears shape-dependent, so suspicion falls on a
  specific steel_gemm_fused_nax tile/dispatch configuration.
- pip wheels do NOT reproduce (built with deployment target < 26.2, NAX
  never engages at runtime) — this needs a source build on M5.

Repro (Python, source build):

```python
import mlx.core as mx
mx.random.seed(0)
x = mx.random.normal((7, 4096)).astype(mx.bfloat16)
w = mx.random.normal((4096, 1024)).astype(mx.bfloat16)
mx.eval(x, w)
ref = None
for i in range(32):
    y = mx.matmul(x, w).astype(mx.float32)
    mx.eval(y)
    if ref is None:
        ref = y
    else:
        d = float(mx.abs(y - ref).max())
        if d != 0.0:
            print(f"iter {i}: max|Δ| = {d}")
print("done")
```

Expected: silence (bit-identical). Observed on M5 + NAX: intermittent nonzero
Δ, sometimes astronomically large (~1e12), i.e. corrupted output tiles.

Happy to run diagnostics/patches on the affected machine.

---

Notes for whoever files it:
- Validate the Python repro first (needs a source-built mlx at deployment
  target 26.2 on the M5 box; ~15 min). If the pure-Python loop does NOT
  reproduce but our Swift op-stress does, bisect what differs (buffer reuse
  pattern, donation) before filing — the report must be self-contained.
- Attach: macOS/Xcode/Metal toolchain versions, `sysctl hw.model`,
  chip gen, and whether MLX_METAL_JIT was on (ours: OFF, AOT metallib).

## Validation next steps (2026-07-03, after the failed Python repro)

The pure-Python loop on upstream main was clean (0/63 drift). Ordered
hypotheses to test, each on the box (`~/nax-repro/` has the venv + clone):

1. **Prove/disprove NAX engagement in the Python build.** The dispatch gate
   (`is_nax_available()` = runtime macOS ≥ 26.2 + gen ≥ 17; box qualifies)
   plus per-shape conditions in `matmul.cpp` should select NAX for
   `[7,4096]×[4096,1024]` bf16, but verify empirically: build a second wheel
   from the same source with the NAX kernels compiled out (the tree defines
   `MLX_METAL_NO_NAX` automatically when `CMAKE_OSX_DEPLOYMENT_TARGET < 26.2`,
   so `MACOSX_DEPLOYMENT_TARGET=26.0 uv pip install ./mlx`) and compare
   logit-level outputs for the same seeded inputs. NAX and non-NAX kernels
   round differently — **identical outputs across the two wheels mean NAX
   never ran** and the Python "no repro" is void.
2. **Build the fork SHA as a Python wheel.** `Layr-Labs/mlx` @ d5a24040
   (branch `darkbloom/mlx-0.32.0-nax`) — same drift.py. If the fork wheel
   drifts where upstream doesn't, bisect the fork-only commits (prime
   suspect: aa480bd8 "Bound Metal buffer COUNT, not just bytes, in
   MetalAllocator" — premature buffer reuse while a NAX kernel still reads
   the buffer would look exactly like this).
3. **Stress the loop harder.** 63 iterations may be too few and too gentle:
   the Swift op-stress drifts within ~16 iters but interleaves other ops and
   allocations. Run ≥1024 iters, add allocator churn (alloc/free garbage
   arrays between matmuls), run 2-3 shapes concurrently on the default
   stream, and try donation (`y = mx.matmul(y_prev_input, w)` patterns).
4. If only the Swift stack reproduces after all of the above, the report to
   upstream needs the Swift op-stress as the repro (still self-contained via
   mlx-swift) or a C++ loop mimicking the allocator pattern.
