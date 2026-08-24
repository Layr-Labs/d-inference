# 047 — Exact real-weight structure audit for hostile review

Status: **complete — the exact per-projection rank/zero/duplicate branch cannot
delete the required 39% of linear MACs**

This closes the real-weight half of R4 in `notes/032`. It does not close the
separate real-routing histogram requirement, and it makes no approximate-rank
claim.

## Pinned input and bounded execution

The Swift probe read this immutable snapshot directly on the `Mac15,9` M3 Max:

```text
/Users/gaj/.cache/huggingface/hub/models--qwen3.6-35b-a3b-vl-mtp-mxfp8/snapshots/local
```

The successful run pins:

```text
root source commit     2e261c6789cb0f3190ad0dcea0ffb739839f347b
pinned MLX gitlink     0a725e3000edabc4911cde345270ca950bfa152f
probe source-set SHA   baae56560b4fa52b01dc46a7c1288b9cdccb3b677bed901d2db61863170a0659
raw archive SHA-256    638abddb4aa87ccb939367a56c1b43bc1a2c49a21c7b830542c4356f48f1b8b7
```

The scanner maps only the current packed weight/scales/biases triplet and uses
one fixed 16 MiB POSIX buffer while hashing shards. It does not construct an
MLX model and uses no mock weights. `/usr/bin/time -l` recorded 726,859,776
bytes maximum resident set size, 445,629,424 bytes peak memory footprint, and
zero swaps while scanning the roughly 20 GiB snapshot in 271.61 seconds.

The archived input hashes are:

| File | Bytes | SHA-256 |
|---|---:|---|
| `config.json` | 25,638 | `b852ada32203b112e217e5cb48afeadaf16594c0f5d3f5f7a380897e5e8732c2` |
| `model.safetensors.index.json` | 218,332 | `9799f7d4f5bfa79b909be4a222931137744d0464afd11a7d5b64073049d91a27` |
| `model-00001-of-00004.safetensors` | 5,296,588,934 | `c34931f1e0056846d5e68bdbeb31b94721e93505161c8144a92578d057b9c8a6` |
| `model-00002-of-00004.safetensors` | 5,360,637,067 | `5d41d9eea6d3810155396ce20316a9e7b34495c366684f824f08c30d6a132f8d` |
| `model-00003-of-00004.safetensors` | 5,368,328,247 | `a4cc7d8943c0c0c5721c775d3630762dbb00b3ea93cbde170fb22381f4bcfa5f` |
| `model-00004-of-00004.safetensors` | 5,256,335,788 | `90bea9bf00f8944e08c5e30d0c6ba158f29be634e7bda043f315eb2948ca361f` |

## Coverage and decode contract

Coverage is asserted against the snapshot rather than inferred from a model
catalog:

| Item | Count |
|---|---:|
| quantized packed tensors | 522 |
| routed expert tensors | 123 |
| dense quantized tensors | 399 |
| logical routed expert matrices | 31,488 |
| logical dense matrices | 399 |
| all logical matrices | 31,887 |
| exact decoded values visited | 35,495,165,952 |

The routed set is every gate/up/down matrix for 256 experts in all 40 language
layers and the inline MTP layer. The dense set is every remaining rank-2 `U32`
quantized weight, including embeddings, LM head, routers, attention, GDN,
shared experts, vision, and MTP projections.

Affine 4/8-bit group-64 weights use the root-pinned MLX contract: BF16
multiply, BF16 rounding, then BF16 add and rounding. MTP MXFP8 group-32 weights
use the exact E4M3 code times E8M0 scale decode to BF16. The raw JSONL retains
per-tensor and per-logical-matrix packed-code histograms, raw scale/bias
histograms and identity statistics, payload hashes, and decoded hashes.

For every logical matrix, the probe counts exact decoded positive/negative
zero, zero rows/columns, zero row segments of width 8/16/32/64, zero column
blocks of width 8/16/32/64, and aligned all-zero blocks at 8×8, 16×16, 32×8,
32×32, 32×64, and 64×64 when the shape permits. Row, column, quantization-group,
metadata-row, and whole-expert hash candidates are verified by direct decoded
or raw-metadata comparison before being called duplicates.

## Exact rank certificate

For an `N × K` matrix, an exact rank-`r` factorization costs
`r(N + K)` MACs rather than `NK`. Deleting at least 39% is possible only if

```text
r <= floor(0.61 * N * K / (N + K)).
```

The sufficient target is therefore

```text
t = floor(0.61 * N * K / (N + K)) + 1.
```

Every finite BF16 value is a dyadic rational. The probe maps decoded values
exactly into GF(3), with deterministic GF(5)/GF(7) fallbacks. Gaussian
elimination identifies source rows and pivot columns, and the archive hashes
the selected indices and all field values of the resulting `t × t` minor. A
nonzero determinant modulo an odd prime is nonzero over the rationals, so
`rank_Q(W) >= t`; this is an exact certificate, not an SVD heuristic.

The normal target is `t + 64` for margin. If exact zero/duplicate structure
puts the structural rank upper bound below `t`, the probe targets that upper
bound instead. Reaching it proves the exact low rank. Results are labeled
`exact-rank` only in that case; all other successes are labeled
`exact-lower-bound`.

All 31,887 matrices received certificates in GF(3); no fallback was needed and
none is uncertified. Of these, 569 reached the exact structural upper bound.
The other 31,318 records claim only their archived lower bound.

## Result

```text
decoded zeros          4,567,901,228
zero rows                    118,658
zero columns                   1,736
duplicate rows               117,886
duplicate columns            123,665
duplicate groups           3,806,046
duplicate whole experts            0
```

Only 841 of 138,652,672 generic aligned BN32×BK8 blocks are wholly zero
(0.0006065%).

For the 40 language-model routed layers:

```text
BN32 compactable gate/up tiles     3,308 / 327,680
BN32 aligned all-zero tiles            0 / 327,680
BK8 dead-activation fragments            89 / 655,360
BK8 zero-weight column fragments          0 / 655,360
exact routed removable MAC fraction          0.006775411
```

The MTP routed layer has no removable aligned tile or MAC. Gate and up zero
masks agree in every routed layer, and there are no duplicate experts.

Every dense matrix individually rules out 39% rank-factor deletion; the
largest dense deletion upper bound is 36.5234375%. There are 196 routed
matrices whose individual upper bound exceeds 39%, all explicitly retained in
the raw records rather than averaged away. For each routed layer, the proof
combines gate/up/down bounds per expert and then chooses the eight experts with
the largest deletion bound. This adversarial top-8 choice gives:

```text
40-layer language-model worst-top-8 upper     24.4598389%
MTP-layer worst-top-8 upper                   23.3398438%
all-matrix MAC-weighted diagnostic upper      24.3116885%
```

Because every dense matrix is below 39% and every layer's adversarial complete
top-8 routed triplets aggregate below 39%, any mixture of those audited
per-projection exact rank factorizations is also below 39%. This is the
mathematically sufficient lower-bound argument; it does not assume uniform
expert use.

## Limits and decision

This result rules out exact zero, duplicate, aligned BN32/BK8, and independent
per-projection rank-factor shortcuts large enough to delete 39% of linear MACs
for the pinned decoded matrices. It does not claim complete exact ranks for
31,318 matrices, does not use approximate singular values, and does not rule
out quality-changing pruning/approximate rank, joint factorizations across
separate projections, layer/token deletion, changed state construction, or
runtime routing regularity. Real prompt routing remains the uncompleted half
of R4.

Artifacts:

- probe source: `probes/real-weight-audit/`;
- concise result and resource proof:
  `artifacts/e21-real-weight-audit-result.txt`;
- manifest with config and input shard hashes:
  `artifacts/e21-real-weight-audit-manifest.json`;
- summary and layer/model tile evidence:
  `artifacts/e21-real-weight-audit-summary.{txt,json}` and
  `artifacts/e21-real-weight-audit-routed-tiles.json`;
- complete config/index/tensor/matrix/progress raw records:
  `artifacts/e21-real-weight-audit-raw-results.tar.gz`;
- archive/result checksums:
  `artifacts/e21-real-weight-audit-artifacts.sha256`.
