# 038 — E9: can MPP reproduce Steel's 8-wide FP32 association?

Status: **preregistered; result pending**

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
