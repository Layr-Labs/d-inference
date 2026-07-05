# DRAFT upstream issue for ml-explore/mlx — VALIDATED, ready to file

**Status 2026-07-03 (late): root cause isolated, pure-Python repro validated
on the box.** The discriminator is **AOT vs JIT kernel compilation**, not
Swift-vs-Python and not the deployment target:

| build | NAX engaged? | drift? |
|---|---|---|
| upstream main, default (nojit + AOT metallib), DT 26.2 | yes (probe-verified: `splitk_nax` dispatch) | none (1024 iters + churn) |
| fork d5a24040, default (nojit + AOT), DT 26.2 | yes | none |
| upstream main, `-DMLX_METAL_JIT=ON`, DT 26.2 | yes | **63/63 iters, deltas → inf/NaN** |
| mlx-swift minimal executable (JIT by design) | yes | 56/63 iters, identical signature |
| mlx-swift rebuilt `-mmacosx-version-min=26.2` | yes | unchanged (still drifts) |

`mlx-swift` compiles `jit_kernels.cpp` (excludes `nojit_kernels.cpp`), so the
Swift stack always runtime-compiles the NAX steel-GEMM kernels via
`MTL::Device::newLibrary(source)` at `LanguageVersion4_0` — that path
produces corrupted output; the identical kernel source compiled offline into
the metallib by `xcrun metal` is deterministic. The fork's allocator patch
(aa480bd8) is exonerated (fork AOT wheel is clean; upstream JIT wheel
drifts). Python pip users are unaffected (nojit default); every mlx-swift
user on M5 is affected.

The drift signature under JIT is progressive corruption: deltas grow
run-over-run (~e3 → e37 → inf → NaN within ~25 iterations), suggesting the
JIT-compiled split-K kernel reads stale/uninitialized accumulator memory.

Box artifacts: `~/nax-repro/` (upstream clone, `venv` AOT, `venv-jit` JIT,
`venv-fork`, `miniswift/`, `drift.py`/`drift42.py`/`drift2.py`).

File the issue below on **ml-explore/mlx** (a companion note on
ml-explore/mlx-swift may be warranted since that's where all users hit it).

---

**Title:** JIT-compiled NAX GEMM kernels produce nondeterministic garbage/NaN
on M5 (MLX_METAL_JIT=ON); identical AOT kernels are correct

**Body:**

On M5-generation hardware, the NAX steel-GEMM kernels produce
nondeterministic, progressively-corrupting output when they are **JIT-compiled
at runtime** (`MLX_METAL_JIT=ON`, i.e. `jit_kernels.cpp` →
`MTL::Device::newLibrary(source)` at `MTL::LanguageVersion4_0`). The **same
kernel source compiled ahead-of-time** into `mlx.metallib` by `xcrun metal`
(default build) is bit-deterministic under identical dispatch — verified with
host-side probes that both builds select the same NAX split-K path for the
failing shape.

This hits every **mlx-swift** user on M5 hardware (mlx-swift compiles
`jit_kernels.cpp` unconditionally), which is where we found it: greedy decode
of a deep model intermittently NaN'd. Python pip users are unaffected (nojit
default; and published wheels < DT 26.2 don't engage NAX at all).

- Observed on: M5 Max (128GB, `applegpu_g17s`), macOS 26.5.1, Xcode 26.4.1 /
  Metal Toolchain 17F109, mlx main @ de7b4ed9 (includes #3631, #3560, #3632).
- Failing shape: `x[7, 4096] @ w[4096, 1024]`, both bfloat16 → dispatches to
  `steel_gemm_splitk_nax` (`bm=bn=64 bk=256`, 2 K-partitions). Drift is
  progressive across iterations in one process — max|Δ| vs the first run grows
  ~1e3 → 1e37 → inf → NaN within ~25 iterations — which looks like the
  JIT-compiled kernel (or its accum pass) reading stale/uninitialized memory.
- The same loop with the default AOT build: zero drift over 1024 iterations,
  probe-confirmed NAX engagement.

Repro (M5, source build):

```bash
git clone https://github.com/ml-explore/mlx && cd mlx
MACOSX_DEPLOYMENT_TARGET=26.2 CMAKE_ARGS="-DMLX_METAL_JIT=ON" pip install . --no-cache
python repro.py   # drifts / NaNs
# control: rebuild without CMAKE_ARGS (AOT metallib) → silent, deterministic
```

```python
# repro.py
import mlx.core as mx
mx.random.seed(0)
x = mx.random.normal((7, 4096)).astype(mx.bfloat16)
w = mx.random.normal((4096, 1024)).astype(mx.bfloat16)
mx.eval(x, w)
ref = None
for i in range(64):
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

Expected: silence (bit-identical across iterations). Observed with JIT: every
iteration drifts, growing to inf/NaN. Also reproduces through mlx-swift (its
only kernel path) with the same signature.

Happy to run diagnostics/patches on the affected machine.

---

Notes for whoever files it:
- Attach: macOS/Xcode/Metal toolchain versions, `sysctl hw.model`, chip gen
  (`applegpu_g17s`), and the AOT-vs-JIT evidence table from the top of this
  file.

## Validation log (2026-07-03, all on the M5 Max box)

The hypothesis ladder that got here, with results:

1. ~~Pure-Python repro at DT 26.2~~ — came back **clean** (0/63), which
   initially suggested "doesn't reproduce in Python".
2. **NAX engagement check**: DT 26.2 vs DT 26.0 wheels produced bit-identical
   outputs — suspicious (different kernels should round differently), so the
   engagement question was settled with `fprintf` probes in
   `is_nax_available()` and the `steel_matmul_axpby` dispatch: NAX **was**
   available and the failing shape **did** dispatch to `splitk_nax` in the
   clean build. Conclusion: AOT NAX kernels are simply correct. (The
   identical outputs across DT levels imply the accum path dominates the
   rounding, or splitk_nax matches non-NAX splitk bit-for-bit for this
   shape — either way, engagement was proven by probe, not inference.)
3. **Fork wheel** (d5a24040, includes the aa480bd8 allocator patch): clean →
   allocator patch exonerated.
4. **Harder stress** (1024 iters, qmm interleave, allocator churn): still
   clean on both AOT wheels.
5. **Minimal mlx-swift executable** (matmul loop only, no mlx-swift-lm):
   drifts 56/63 with the exact production signature; rebuilding it at
   `-mmacosx-version-min=26.2` changes nothing → deployment target
   exonerated; metallib cross-swap between Python and Swift builds changes
   nothing → metallib exonerated. Remaining difference: mlx-swift compiles
   `jit_kernels.cpp` (nojit excluded in Package.swift).
6. **JIT Python wheel** (`-DMLX_METAL_JIT=ON`, upstream main): drifts 63/63
   with exploding deltas → root cause confirmed, self-contained Python repro
   in hand.
