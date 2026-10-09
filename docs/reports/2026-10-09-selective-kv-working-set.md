# Selective full-attention KV working-set experiments

> Last updated: 2026-10-09

An opt-in contiguous working-set experiment removes about 47% of retained
full-attention KV bytes in two initial native-model pilots. Supplied continuation
top-1 IDs match the dense control; dense prefill still owns the allocation peak.
These results do not qualify general model quality, serving, concurrency, or
combination with a quantized KV backend.

## Candidate and measurement scope

The candidate uses `CBv2SelectiveSequenceKV` and the explicit
`DARKBLOOM_CBV2_SELECTIVE_KV=half` benchmark gate. It retains dense prefill, first
four entries, at least 512 recent entries, and half of older full-attention
history in 16-token chunks. It preserves native sliding windows and absolute
positions. Prefix reuse and MTP are disabled. See the
[implementation and ownership boundaries](../architecture/inference.md#selective-full-attention-working-set-experiment).
The SDK implementation is proposed in
[mlx-swift-lm PR #295](https://github.com/Layr-Labs/mlx-swift-lm/pull/295).

The measured local candidate is based on parent `c93380dab` and SDK `3fd4944`;
it is a Debug provider build, not a signed release artifact. Both arms of each pilot use identical
binary, metallib, model, prompt IDs, memory grant and Gemma switches. Machine:
Apple M4 Max, 128 GiB. [Compact raw results and hashes](../assets/2026-10-09-selective-kv-pilots.json)
retain exact artifact/input hashes and predicted token IDs. The compressed
[GPT input](../assets/2026-10-09-gpt-oss-selective-pilot.json.gz) and
[Gemma input](../assets/2026-10-09-gemma-selective-pilot.json.gz) preserve the
original synthetic token contexts; decompress them before passing them to
`darkbloom benchmark --teacher-forced-input`.

## Initial teacher-forced pilots

| Model | Prompt / forced tokens | Top-1 agreement | Mean NLL delta | Retained full-attention bytes | Pruning events |
|---|---:|---:|---:|---:|---:|
| GPT-OSS 20B | 17,534 / 6 | 6/6 | -0.1446703 | 52.896% | 36 |
| Gemma 4 26B QAT | 21,436 / 7 | 7/7 | -0.000000545 | 52.362% | 15 |

Events count owning layers across three scoring passes, not requests: GPT has
12 participating full layers and Gemma five. Byte percentages cover those full
layers; they exclude unchanged sliding windows, weights and other allocations.

The GPT input forces a final answer phrase where the ordinary Harmony prompt
initially expects analysis. Its absolute NLL is not answer-quality evidence.
The pilot checks the storage/attention path at the same supplied contexts.
Gemma's mean forced NLL is approximately 0.00000654 in the selective arm.

Dense/selected MLX allocation peaks are 14,399,778,448 / 14,399,780,880 bytes
for GPT and 17,248,135,354 / 17,248,151,754 bytes for Gemma. These effectively
unchanged peaks are expected: this candidate compacts after dense prefill.
They do not establish a larger admissible prompt or more concurrent requests.

The score matrix is bounded by four query rows, but that does not bound all
scratch: non-FP32 keys are cast in full to FP32 before scoring. Its payload is
`4 * kvHeads * history * headDim` bytes per owning layer, in addition to the
score/normalization intermediates and the compact destination overlapping its
source. GPT's FP32 keys alias; Gemma's BF16 keys incur this cast. At 32,768
positions, eight KV heads and global width 512, the Gemma cast alone is 512 MiB
for a layer, before allocator rounding. This implementation does not claim
bounded serving scratch or admit-time savings. Decode-event allocator samples
in the generated-output harness are observations of live allocations, not
proof that a between-event transient was absent.

## Backing-allocation check

The fresh-process `allocatorReleasesDenseBackingAfterSparseCompaction` fixture
uses 8,192 FP32 positions, eight KV heads and width 64. After evaluation and
synchronization, active MLX allocations fall from 34,603,008 to 18,874,368 bytes.
The 15,728,640-byte allocator reduction equals the logical storage reduction.
This checks real buffer release on the small fixture; it is not process RSS or
a whole-model peak-memory result.

The dedicated refactor replaces gather-then-copy with one owned gather that
includes bounded spare capacity. Tests cover that spare entries stay unreachable
until overwritten, unequal value widths and native dtypes are preserved, and
rollback keeps confirmed values.

## Remaining qualification

The generated-output matrix covers retrieval at three depths, distant-fact
arithmetic, code reasoning, tool prompts, and long decoding at approximately 4K
and 32K contexts. It must be assessed separately from these pilots, with actual
rendered token IDs, identical decode caps and executed pruning evidence.
`scripts/benchmarks/prepare_selective_kv_cases.py` preserves the deterministic
case recipe without downloading weights.

The complete provider check ran and failed. Failures include missing initial
MiMo fixture prerequisites and the existing native SwiftPM `pagedattention.metal` lookup
defect. The new selective suite and isolated allocator assertion pass; the
nested SDK selective suite passes both tests. Full SDK and generated-output
measurements are still being collected in this draft. Full docs lint separately encounters the existing
frozen-report link to absent `coordinator/registry/cache_match_groups.go`.
Serving remains disabled: temporary compaction/scoring ownership, sparse MTP
assistant capture, general quality and operational value require separate gates.
