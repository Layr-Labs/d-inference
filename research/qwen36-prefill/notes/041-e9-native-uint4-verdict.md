# 041 — E11 native uint4 MPP Candidate B

Status: **rejected by the preregistered adversarial correctness gate; no
timing run**

The standalone probe retained its original internal `e9-native-uint4`
name; the shared experiment ledger records this result as E11 because
E9/E10 were assigned to BK64 and BM64×BN64.

## Question

Can Metal 4 on the M3 Max consume unsigned packed W4 codes directly with
`bfloat × uint4b_format → float`, then reconstruct one affine group in FP32:

```text
sum_i x_i * (s*q_i + b)
  = s * dot(x,q) + b * sum(x)
```

The serving incumbent reconstructs every weight in FP32, rounds that weight to
BF16, then supplies BF16 activation and weight operands to FP32 MMA. Factoring
scale and bias after the code dot moves that per-weight BF16 rounding boundary.
E9 tests that risk before taking any timing.

## Isolated implementation

`probes/e9-native-uint4/` is not linked by MLX, ProviderCore, or the serving
binary. Its only Metal symbol is `e9_native_uint4_affine_group64`.

The fixed M=16, K=64, N=32 tile represents one group/tile of the Qwen
`gate_up` M=64, K=2048, N=1024 cell:

- BF16 row-major activations;
- packed logical `[K,N]` unsigned codes, low nibble first;
- BF16 scale and bias for one group of 64;
- `matmul2d_descriptor(16, 32, 64, false, false, false, multiply)`;
- `bfloat × uint4b_format → float`;
- manual FP32 `scale*q_dot + bias*row_sum` epilogue.

The standalone layout is deliberately the MPP-friendly `[K,N]` test layout,
not an MLX storage integration. A serving packing/transpose path was not
implemented or timed because correctness failed first.

## Metal 4 API result

Host:

```text
Apple M3 Max (Mac15,9), macOS 26.4
Xcode 26.5 (17F42)
Apple metal 32023.883
AC power, powermode=2
```

The kernel compiles, links, and executes on M3. Native `uint4b_format`
represents all unsigned values 0 through 15 correctly: a position-sensitive
fixture covering both nibbles produced 512/512 exact outputs.

Two SDK typing constraints were found and handled:

1. A format tensor's storage pointer is `device uchar*`, not
   `device uint4b_format*`. Passing the latter produced:

   ```text
   no known conversion from 'const device metal::uint4b_format *'
   to ... data_handle_type (aka 'const device unsigned char *')
   ```

2. MPP's cooperative-destination template rejects const-qualified operand
   element types. Read-only inputs therefore use mutable `device` pointer
   types in the isolated kernel. The rejected form produced:

   ```text
   static_assert failed ... "cooperative tensor source data type can only be
   one of uint8_t/int8_t/uint4b_format/int4b_format/float/half/bfloat"
   ```

These are source-level binding requirements, not an unsigned-code or runtime
blocker.

## Adversarial gate

The fixture uses BF16 values:

```text
x0 = -7.125      q0 = 15
x1 =  8.125      q1 = 13
s  =  3.609375   b  = 2.984375
```

Candidate B computes:

```text
s * (-7.125*15 + 8.125*13) + b * (-7.125 + 8.125)
= -1.52734375
```

The incumbent reconstructs and rounds each weight:

```text
BF16(15*s+b) = 57
BF16(13*s+b) = 50
-7.125*57 + 8.125*50 = 0.125
```

Measured:

```text
UNSIGNED_CODE_MAPPING=pass mismatches=0/512 max_abs=0
FACTORED_ALGEBRA=pass mismatches=0/512 max_abs=0
ADVERSARIAL_INCUMBENT=fail mismatches=512/512 max_abs=1.65234375
ADVERSARIAL_INCUMBENT_BF16_OUTPUT=fail mismatches=512/512 max_abs=1.65625
TIMING=skipped reason=adversarial_incumbent_tolerance
VERDICT=reject reason=per_weight_bf16_rounding_contract
```

Both FP32 and BF16-output comparisons use the existing ordinary-QMM
`rtol=1e-3, atol=1e-3` gate. The failure is large and uses only two nonzero
terms, so it is not attributable to long-reduction association.

The complete machine-readable result is
`artifacts/e9-native-uint4-result.txt`.

## Build and run on the Mac

From a checkout containing this probe:

```bash
cd research/qwen36-prefill/probes/e9-native-uint4
./run.sh /tmp/e9-native-uint4-result
sed -n '1,240p' /tmp/e9-native-uint4-result/result.txt
```

Equivalent compiler commands:

```bash
xcrun -sdk macosx metal \
  -std=metal4.0 -mmacosx-version-min=26.4 \
  -c kernel.metal -o /tmp/e9-native-uint4.air
xcrun -sdk macosx metallib \
  /tmp/e9-native-uint4.air -o /tmp/e9-native-uint4.metallib
xcrun swiftc -O -framework Metal \
  main.swift -o /tmp/e9-native-uint4
E9_ALLOW_TIMING=1 \
  /tmp/e9-native-uint4 /tmp/e9-native-uint4.metallib
```

`run.sh` treats probe exit 2 as a recorded candidate rejection and verifies
that `TIMING=run` is absent. A compiler, linker, or runtime API failure is
captured verbatim in the output directory and also rejects without timing.

## Verdict

Metal 4 native unsigned W4 is available and behaves correctly on this M3.
This particular factored affine Candidate B does not preserve the incumbent
per-weight BF16 rounding contract and fails the unchanged tolerance
adversarially. Reject it. No serving default changed, no performance number was
taken, and no speedup is claimed.
