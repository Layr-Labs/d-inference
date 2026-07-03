# DRAFT upstream issue for ml-explore/mlx — not yet filed

File manually after validating the standalone repro below on an M5 (the repro
must not depend on our fork). Status: repro steps written, pending validation
on a box with a source-built mlx.

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
