# Qwen 3.6 real-weight structure audit

This probe reads the named safetensors snapshot directly with bounded `mmap`
windows. It never constructs an MLX model and never retains more than one
quantized tensor triplet (`weight`, `scales`, `biases`) at once.

It covers every `U32` packed weight in the snapshot:

- all 40 main-model routed gate/up/down tensors and the inline MTP routed
  gate/up/down tensors, expanded into 31,488 logical expert matrices;
- all 399 rank-2 quantized tensors, including embeddings, routers, attention,
  GDN, shared experts, LM head, and MTP projections.

For each tensor it records raw payload SHA-256, packed-code histograms, and raw
scale/bias histograms. For each logical matrix it records exact decoded zeros,
aligned zero row segments and 8/16/32/64 block shapes, row/column/group
duplicates with collision candidates verified by direct value comparison,
whole-expert duplicate evidence, and removable BN32/BK8 structure.

## Exact-rank certificate

BF16 values are dyadic rationals. The scanner maps each decoded BF16 value
through the exact homomorphism into GF(3), with a GF(5) fallback. A rank-`r`
factorization deletes at least 39% of dense MACs only when

```text
r <= floor(0.61 * N * K / (N + K)).
```

The scanner deterministically constructs and hashes a finite-field minor at
least one rank above that cutoff. A nonzero minor modulo an odd prime is also
nonzero over the rationals, so this is a proof, not a floating SVD heuristic.
The probe normally continues 64 ranks past the cutoff for margin. It reports
`exact-rank` only when the lower bound reaches the structural upper bound;
otherwise it explicitly reports `exact-lower-bound`.

Affine tensors use the root repository's pinned MLX gitlink contract
(`0a725e30`): BF16 multiply followed by BF16 add. The unpinned local
FP32-dequant experiment changes the matrix and is intentionally excluded.
MXFP8 uses MLX's exact E4M3 code times E8M0 scale decode.

## Run on the M3

```bash
research/qwen36-prefill/probes/real-weight-audit/run.sh \
  /Users/gaj/.cache/huggingface/hub/models--qwen3.6-35b-a3b-vl-mtp-mxfp8/snapshots/local \
  /tmp/qwen36-real-weight-audit
```

The output directory contains human-readable `result.txt`/`summary.txt`,
machine-readable JSON/JSONL, archived model config/index, full shard hashes,
and `raw-results.tar.gz`.
