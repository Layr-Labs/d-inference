# Independent attention reference and packet validation

> Last updated: 2026-09-06 · commit `5ac2b5f3f`

The offline analyzer computes an independent CPU FP32 attention reference from
one confirmed native packet. Twenty-two tests pass, including deliberately
corrupted attention results and files. Real-model capture, backend fidelity and
release performance remain unproven by this milestone.

## Behavior

The [packet interface](../../scripts/benchmarks/attention_packet/FORMAT.md)
binds six original native tensors and one selected-step metadata record by
exact byte counts and SHA-256. It requires B1, one decode query, full causal
attention and one confirmed owner. Unsupported geometry or incomplete samples
remain inconclusive. JSON files are bounded to 256 KiB and total tensors to
32 MiB; paths, native dtypes, shapes, packed strides and hashes are checked
before tensor decoding.

The original query supplies the FP32 softmax reference. GQA maps each query
head to its contiguous KV group without duplicating the KV tensor. Narrowed
queries and output rounding are separate comparisons. Per-head and global
maximum error, RMSE, relative L2 and nonfinite counts remain descriptive;
there is no numerical or model-token acceptance flag.

## Validation

Root independently runs all 22 tests with warnings treated as errors and
verifies all 11 integrated source files. Coverage includes exhaustive finite
FP16/BF16 promotion round-trips, signed zero and NaN payloads, analytic uniform
attention, D256/QH16/KVH2 geometry through 5,585 stored tokens, and refusal of
invalid metadata, files and byte budgets. The one-owner revision rejects
multiple or duplicate owner records before decoding. All eight retained
synthetic packets reproduce their prior reports after that revision.

Synthetic control maximum error is about 1.79e-7 for the retained long BF16
storage case. Planted key transposition, interleaved head mapping and omission
of the last token produce maximum errors of 2.743, 2.055 and 2.932 in their
small fixtures. Truncated files and wrong hashes refuse. These figures calibrate
the diagnostic; they are not model or kernel performance measurements.

A deliberately self-consistent corrupted-history fixture still agrees with
the reference. Therefore gathered K/V and matching decode output cannot prove
full-history storage correctness: an independent history capture and actual
same-input native operator replay remain separate work. The analyzer also
cannot independently prove the native capture's evaluation fence or lifetime.

## Evidence

The [manifest](evidence/attention-packet-analyzer-2026-09-06/manifest.json) and
[archive](evidence/attention-packet-analyzer-2026-09-06/payloads.tar.gz) retain
130 verified payloads: both source revisions, raw tests, eight synthetic
packet/report sets, replay results, environment provenance and root reviews.
They contain synthetic tensor bytes; no model weights or compiled executables.
Manifest SHA-256: `0a74a59eb17c6d58e89f9a9d5faaf5909aa334ce0f7914560591b92782ea91d7`.
Archive SHA-256: `850748747d360ada16e3a5995edf5644c9fb0804955c26311d951bb58322925b`.

See [setup](../developer/build.md#offline-attention-analysis-environment) and
[test instructions](../developer/test.md#offline-attention-packet-analysis).
The [Qwen backend difference](2026-09-05-qwen36-actual-logits.md) remains unresolved.
