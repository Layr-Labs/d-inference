# 028 — E3 dense BF16 roof: exact QMM has at most 1.13× headroom

Status: **measured roof; dense-cache idea dead**

## Question

Could Qwen prefill reach 2.5× by dequantizing expert weights once,
retaining a BF16 prefill cache, and replacing W4 gather-QMM with dense
`gatherMM`?

The test uses the exact serving assignment count (M=16,384), E=256
uniform 64 rows/expert, and exact gate_up/down K/N. Dense weights are
dequantized from the same affine W4/g64 tensors. Dequantization itself is
excluded, making this an intentionally generous upper bound.

An additional **illegal arithmetic roof** runs one monolithic GEMM with
the same M/K/N/FLOP count and one shared matrix. It cannot implement MoE;
it only measures how much grouped/expert geometry costs.

Artifact: `artifacts/e3-dense-reference-roof.txt`.

## Result (M3 Max, AC, High Power)

| Projection | W4 sorted gather | BF16 sorted gather | BF16 monolithic roof |
|---|---:|---:|---:|
| gate_up, K=2048 N=1024 | **10.89 TFLOPS** | **10.93** | **12.30** |
| down, K=512 N=2048 | **10.22 TFLOPS** | **8.37** | **11.60** |

Outputs of W4 and dequantized BF16 gather passed the established
quantized-reference tolerance.

## First-principles conclusion

1. **Dequantization is not the bottleneck.** Removing it produces 0% on
   gate_up and regresses down 20%.
2. **Expert grouping is not hiding 2.5×.** Deleting all expert semantics
   and using one large dense matrix gains only 1.13×.
3. The 2.5× gate_up bar would require about **27.2 TFLOPS** at the same
   exact operation count. The measured best legal path is 10.9; even the
   illegal monolithic roof is 12.3.
4. A 60–75 GiB BF16 expert cache cannot pay: it adds load time and
   unified-memory pressure for no arithmetic gain.

Because routed QMM is ~93% of prefill FLOPs (note 011), substituting the
illegal 1.13× monolithic roof and making every non-QMM operation free
still caps aggregate speedup around:

```
1 / (0.93 / 1.13) = 1.22x
```

That is an intentionally impossible upper bound and remains below 2.5×.

## What remains legal

- Tile-shape retuning can recover at most the ~13% grouped-to-monolithic
  gap; BM64/BN64 and BK64 are still worth measuring as cleanup.
- Lower-precision accumulation, fewer experts, sparse attention, low-rank
  factors, or changed weights reduce exact work only by changing the
  numerical/model contract. They are disallowed by GOAL.md unless greedy
  checksums and all quality gates prove otherwise.
- M5 Metal 4 TensorOps do not exist on this M3 Max.

E3 closes the “BF16 prefill cache” and “quantization overhead” branches.
