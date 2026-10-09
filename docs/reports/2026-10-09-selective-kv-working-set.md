# Selective full-attention KV working-set experiments

> Last updated: 2026-10-09

An opt-in contiguous working-set experiment removes about 47% of retained
full-attention KV bytes in two initial native-model pilots, but the generated
GPT-OSS evaluation exposes a capped-answer regression. Serving remains disabled.
The pilots' supplied continuation top-1 IDs match the dense control; dense
prefill still owns the allocation peak. These results do not qualify general
model quality, concurrency, or combination with a quantized KV backend.

## Candidate and measurement scope

The candidate uses `CBv2SelectiveSequenceKV` and the explicit
`DARKBLOOM_CBV2_SELECTIVE_KV=half` benchmark gate. It retains dense prefill, first
four entries, at least 512 recent entries, and half of older full-attention
history in 16-token chunks. It preserves native sliding windows and absolute
positions. Prefix reuse and MTP are disabled. See the
[implementation and ownership boundaries](../architecture/inference.md#selective-full-attention-working-set-experiment).
The SDK implementation is proposed in
[mlx-swift-lm PR #295](https://github.com/Layr-Labs/mlx-swift-lm/pull/295).
All measured requests are text-only; media-token retention remains unqualified.
Both arms disable prefix reuse and MTP, so they do not measure the tradeoff
against current cached or speculative serving configurations.

The initial pilot was a local Debug build of these changes on parent base
`c93380dab` and SDK base `3fd4944`, not a signed release artifact. The later
generated-output matrix uses parent `393aa0007` and SDK `46477f0`; its exact
binary, metallib, model and input hashes are retained with the linked results.
Both arms of each pilot use identical binary, metallib, model, prompt IDs,
memory grant and Gemma switches. Machine:
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
positions, Gemma 26B's two global KV heads and width 512 require a 128 MiB cast
per global owning layer, before allocator rounding (640 MiB across its five
global layers if their graph lifetimes overlap). Its eight-head local layers
do not enter this selector. This implementation does not claim
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

## Generated-output qualification

The generated-output matrix covers retrieval at three depths, distant-fact
arithmetic, code reasoning, tool prompts, and long decoding at approximately 4K
and 32K contexts. It must be assessed separately from these pilots, with actual
rendered token IDs, identical decode caps and executed pruning evidence.
`scripts/benchmarks/prepare_selective_kv_cases.py` preserves the deterministic
case recipe without downloading weights. All four matrix arms completed,
including observed cancellation, exact recovery against their own completed
donor, and clean shutdown with zero outstanding request-allocation owners.

| Model | Native answer/tool oracles | Selective answer/tool oracles | Identical complete token arrays |
|---|---:|---:|---:|
| GPT-OSS 20B | 12/12 | 11/12 | 6/14 |
| Gemma 4 26B QAT | 8/12 | 8/12 | 14/14 |

The completed GPT matrix exposes a qualification failure. The dense control
passes all 12 answer/tool oracles; the selective arm passes 11. At 4K, the dense
control answers the arithmetic case in 164 tokens, while the selective arm
reaches the same computed value in reasoning but exhausts the 256-token cap
without a final answer. It is scored as a failed completion. All three 32K
needle depths pass in both arms. Both long-decode cases preserve their ordered
item prefixes at the fixed 768-token cap; they do not finish the requested
2,000-item list. Both arms pass actual cancellation, exact recovery against
their own completed donor, and clean shutdown checks.

A separate frozen-binary replay then isolates that same 4K arithmetic request
at its original cap. All six complete native observations (main request, three
fresh scopes, donor and recovery) answer correctly in 164 tokens. All six
selective observations exhaust 256 tokens without a final answer. Original
prompt IDs, model, binary, metallib and memory grant match. This targeted
reproduction strengthens the observed regression; it is not six new held-out
cases and does not replace the original campaign. The
[reproduction summary](../assets/2026-10-09-gpt-oss-arithmetic-repro.json),
[native raw replay](../assets/2026-10-09-gpt-oss-arithmetic-repro-native.json.gz)
and [selective raw replay](../assets/2026-10-09-gpt-oss-arithmetic-repro-half.json.gz)
preserve those observations.

Bounded allocator observations at the eighth emitted token show 95–99 MiB less
live memory at 4K and 752–758 MiB less at 32K. Single-cell decode-throughput
ratios range from 0.68 to 1.55, which does not establish a reliable speed
improvement. These observations do not override the completion regression.
The actual GPT prompt renders `Reasoning: medium`; the helper's template hints
did not change that canonical prompt setting. Both arms use identical rendered
prompt IDs, binary, model and memory grant. The
[comparison and provenance](../assets/2026-10-09-gpt-oss-selective-generation.json),
[native raw report](../assets/2026-10-09-gpt-oss-selective-generation-native.json.gz)
and [selective raw report](../assets/2026-10-09-gpt-oss-selective-generation-half.json.gz)
retain the original observations.

Gemma's dense content controls complete with 8/12 answer/tool oracles passing:
all six retrieval depths and both tool payloads are correct, while arithmetic
and code answers are wrong at both lengths. Its 4K long response abbreviates
after ten items and jumps to item 2,000; its 32K response sustains the 768-token
cap with 146 correctly ordered completed items. All 14 selective outputs are
identical to their native counterparts, so those baseline failures remain
unchanged. The [comparison and provenance](../assets/2026-10-09-gemma-selective-generation.json),
[native raw report](../assets/2026-10-09-gemma-selective-generation-native.json.gz)
and [selective raw report](../assets/2026-10-09-gemma-selective-generation-half.json.gz)
preserve the complete observations.

| Model | Lower active allocation at 4K | Lower active allocation at 32K |
|---|---:|---:|
| GPT-OSS 20B | 95–99 MiB | 752–758 MiB |
| Gemma 4 26B QAT | 39.6–41.3 MiB | 314.7–316.3 MiB |

These are matched eighth-token allocator observations from responses continuing
beyond eight tokens, not process RSS, admission credit, or a guarantee about
unobserved transients. Whole-run allocation peaks remain effectively unchanged
at approximately 14.96 GiB for GPT and 17.23 GiB for Gemma. Gemma's 32K tool
response decodes at 15.47 tokens/s natively versus 6.59 with selection; its
768-token long response measures 14.59 versus 15.17. A single paired run does
not isolate the selector cost, but it exposes substantial short-response
overhead and does not justify a general speedup claim.

The storage geometry provides an independent payload check. GPT has twelve
full owners with eight KV heads, width 64 and four-byte elements:
`12 * 8 * 64 * 2 * 4 = 49,152` bytes per full-history token. Gemma has five
full owners with two KV heads, width 512 and two-byte elements:
`5 * 2 * 512 * 2 * 2 = 20,480` bytes per token. Their raw full-history payloads
at 32,768 positions are 1,536 MiB and 640 MiB, respectively. Retaining half of
older history while preserving anchors, recent tokens and append slack predicts
savings near the observed 756 MiB and 315 MiB. This calculation excludes local
windows, weights, allocator rounding and scoring scratch.

## Validation gates

Hosted provider unit, SDK and prompt-parity checks pass on `393aa0007`.
The standalone SDK PR's build/tests, lint, fork-map and CodeQL checks pass on
`46477f0`. These hosted results are separate from the local environment failures.
Locally, the complete provider check ran and failed. Failures include missing initial
MiMo fixture prerequisites and the existing native SwiftPM `pagedattention.metal` lookup
defect. The new selective suite and isolated allocator assertion pass; the
nested SDK selective suite passes both tests. The full nested SDK command also
returned failure: paged tests cannot resolve their Metal resource, and both
MLXLM test targets terminate when Qwen4's required `gemm` Metal header cannot be
found. Those terminated targets do not provide complete test counts. The other
targets finish. Focused provider/teacher-forced checks, the isolated allocator
assertion, the two nested selective tests, 34 radix-harness tests, six comparator
tests and 14 native-CI routing tests pass. Full docs lint separately encounters the existing
frozen-report link to absent `coordinator/registry/cache_match_groups.go`.
Serving remains disabled: temporary compaction/scoring ownership, sparse MTP
assistant capture, general quality and operational value require separate gates.

## Follow-up hypotheses

The observed arithmetic regression motivates protecting instruction structure,
not just four initial sink positions. In its actual GPT prompt, the first 20
tokens end at the system's knowledge-cutoff label; the channel rules and the
user's concise-answer instruction appear later. A separately matched experiment
should protect the full trusted role prefix, or first test bounded 128/256-token
prefixes. This is a hypothesis, not an established cause of the regression.
Preserving more instructions must trade against older-history selection under
the same capacity accounting.

A fused native-key importance operator could remove the full FP32 key cast.
It would accumulate native K/Q products in FP32 registers, compute per-head/query
normalizers including sinks, then reduce a second tiled pass directly to chunk
scores. It must preserve `sum_tokens(max_heads(mean_queries(probability)))`;
taking the maximum of per-head chunk sums would change the selection policy.
Kernel parity, bounded scratch, compaction destination ownership and evaluated
retirement must all be measured before this can become a serving path.
