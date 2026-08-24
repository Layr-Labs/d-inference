# 041 — Can MPP reproduce Steel's 8-wide FP32 association?

Status: **complete — portable MPP survives; forced MLX/NAX register mapping does not**

## Question

E8 proved that MLX's strict
`matmul2d_descriptor(16, 32, 16, ..., relaxed_precision=false,
multiply_accumulate)` produces the same incorrect M3 result as its relaxed
form. It did not test whether Metal 4 permits the incumbent association:

```text
C0 = Steel-FP32-dot(K[0..<8])
C1 = Steel-FP32-dot(K[8..<16]) + C0
```

This experiment asks only whether a legal MPP schedule can reproduce that
order closely enough for the unchanged QMM gates. It does not integrate with
serving and takes no performance result.

## Fixed-shape probe

`probes/mpp-reduction/` compares an actual 8x8
`simdgroup_multiply_accumulate` reference, called twice over K=16, against:

1. static K=16 MPP multiply-accumulate with cooperative inputs (the MLX/NAX
   shape);
2. static K=16 MPP multiply-accumulate with tensor inputs;
3. static K=16 MPP multiply without C;
4. dynamic-K MPP invoked twice with runtime K=8 and MPP accumulation;
5. dynamic-K MPP invoked twice in `multiply` mode, with the two cooperative
   FP32 result tensors added explicitly;
6. two legal static-K=16 `multiply` calls, each with one K=8 half zero-padded,
   followed by explicit cooperative-tensor FP32 addition.

The shape is M=16, N=32, K=16, BF16×BF16→FP32, strict precision. Inputs include
QMM-scale pseudorandom values, mixed exponents, and cancellation patterns.
The artifact reports FP32-bit and BF16-output differences, maximum absolute
and ULP error, and the existing ordinary-QMM and Qwen random-test tolerances.

## Preregistered decision

- A static K=8 descriptor is legal only if the Metal compiler accepts and
  executes it; a source-level constructor accepting `8` is not evidence.
- A dynamic K=8 descriptor survives only if it executes without command-buffer
  error and passes existing tolerances on all three fixtures.
- Separate `multiply` survives only if explicit FP32 addition improves on the
  K=16 control and passes all fixtures.
- Zero-padding survives correctness but is not a performance candidate by
  implication: it performs two K=16 operations for 16 useful terms and would
  require a later isolated timing gate.
- If static K=8 is compiler-rejected and every executable MPP schedule fails
  unchanged tolerances, close Candidate A on this SDK/M3 runtime. Do not infer
  an M5 result or a hardware theorem.

## Environment

The probe ran on an Apple M3 Max (`Mac15,9`) under macOS 26.4 build `25E246`.
It compiled with Xcode 26.5 (`17F42`), Metal language 4.0, and deployment
target macOS 26.2. The complete output and expected compiler failure are:

- `artifacts/mpp-reduction-order-m3.txt`;
- `artifacts/mpp-static-k8-compiler-m3.txt`.

The captured sources have these SHA-256 hashes:

```text
probe.metal  3fb88825fe8c9fd8b0c08181339244a5a494d4893e6912f6fcc59edadd7830ed
main.swift   52079abc84fb965b96e5be3a4666cab6d43da80eba27b205fb671edad0f0fade
```

## Compiler result: static K=8 is illegal

The public descriptor constructor accepts `K=8`, but instantiating and running
BF16×BF16→FP32 at SIMD-group scope fails compilation in
`MPPTensorOpsMatMul2dImpl.h`:

```text
static_assert failed ... "K must be dynamic or a multiple of 16"
```

This is a hard compiler result for the tested SDK. Static K=8 is not a viable
descriptor on this toolchain.

## Runtime result

Every executable kernel completed without a command-buffer error. Results
below compare 512 FP32 outputs per fixture against two incumbent Steel K=8
`simdgroup_multiply_accumulate` calls:

| MPP path | QMM-scale | Mixed exponent | Cancellation |
|---|---|---|---|
| static K=16, cooperative `load`/`store` | bit-identical | bit-identical | bit-identical |
| static K=16, transposed B, cooperative `load`/`store` | bit-identical | bit-identical | bit-identical |
| static K=16, direct tensor run | bit-identical | bit-identical | bit-identical |
| static K=16, `multiply` | bit-identical | bit-identical | bit-identical |
| dynamic K=8 twice, MPP accumulate | bit-identical | tolerance pass | bit-identical |
| dynamic K=8 twice, `multiply` + explicit FP32 add | bit-identical | tolerance pass | bit-identical |
| static K=16 twice, zero-padded halves + FP32 add | bit-identical | tolerance pass | bit-identical |

All three staged-half variants produced the same mixed-exponent result:

```text
fp32_changed=171/512
bf16_changed=0/512
max_abs=0.00390625
max_ulp=45
qmm allclose(atol=1e-3, rtol=1e-3)=pass
Qwen existing tolerance=pass
```

The full K=16 controls were bit-identical on all 1,536 tested outputs. This
falsifies the E8 inference that the M3 fallback necessarily uses an
incompatible opaque 16-term reduction at this shape.

## Why forced MLX NAX failed

MLX's `BaseNAXFrag` does not use cooperative-tensor `load` and `store`. It
copies its assumed per-lane 16×16 fragment registers directly into numeric
cooperative-tensor elements and copies numeric result elements back out. MLX
enables that route only on its NAX generation gate.

The probe separately replaced the supported input load, output store, or both
with the exact `BaseNAXFrag` coordinate/index assumption. Every such variant
failed every fixture:

- manual inputs: 448–512 BF16 outputs changed;
- manual output: 256–448 BF16 outputs changed;
- manual inputs and output: 384–512 BF16 outputs changed;
- transposed-B manual inputs and output: 511–512 BF16 outputs changed.

The transposed-B manual path, which mirrors the forced QMM descriptor and uses
contiguous transposed weights, had maximum absolute errors of `42.5933228`,
`66645.0859`, and `819180` across the three fixtures. In contrast, the same
descriptor with cooperative-tensor `load`/`store` was bit-identical.

Therefore E6/E8 crossed MLX's generation gate and exercised an incompatible
cooperative-tensor register-layout assumption on the M3 optimized-shader
fallback. Their failures do not isolate MPP reduction order.

## Decision

The reduction-order objection does **not** close Candidate A. Two legal
arithmetic schedules survive this fixed-shape M3 gate:

1. ordinary static K=16 MPP through supported tensor/cooperative-tensor
   load/store, which was bit-identical to Steel in this probe;
2. dynamic K=8 staged MPP, including separate `multiply` plus explicit FP32
   addition, which passed unchanged QMM and Qwen tolerances.

The existing MLX NAX direct-register implementation remains dead on M3. A
custom portable route must preserve supported cooperative-tensor loading and
storing instead of reusing `BaseNAXFrag` indexing. Zero-padded K=16 halves are
correct but perform twice the useful multiply work.

This experiment deliberately provides no serving integration or performance
claim. Candidate A itself remains unproven until a supported implementation
passes full-shape QMM, greedy, KV, and GDN gates. The next ratchet, if it is
pursued, is an isolated timing probe for the supported static K=16 load/store
route and dynamic K=8 route before any serving integration.
