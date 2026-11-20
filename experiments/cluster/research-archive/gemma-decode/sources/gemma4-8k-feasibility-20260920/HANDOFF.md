# Gemma 8K source feasibility, 2026-09-20

No native, compiler, GPU, model-weight, or remote operation was run for this audit. `prediction.json` describes the unchanged qualified v7 binary `6115f51db204f8afe59b1e6b68d47074c7cad14bfde11e5acda477c290305034`. It is an arithmetic projection, not an admission or performance result. Decimal GB below means 1,000,000,000 bytes; all original 6/4/2 GiB floors remain exact binary units.

## Recommendation for the existing binary

Run the six 15-second metadata commands in `metadata-commands.json` under the root's existing owned subprocess runner. Each command is exactly `GemmaResidentBenchmark --describe JOB` or `--check-arguments JOB`; neither enters `--execute`. Three jobs cover cut7/C64, cut6/C128, and cut6/C64, P8192/O16, capture enabled. Each description includes full/stage0/stage1. Jobs use the retained registered tokenizer packet and captured metadata, with an output path that must remain absent. The controller must check the actual selected executable against the retained build receipt; its declared job identity alone is insufficient. This author did not rehash the binary.

| Candidate | Full initial / loaded free requirement | Rank0 initial / loaded | Rank1 initial / loaded |
|---|---:|---:|---:|
| cut7/C64 | 32.383 / 17.134 GB | 11.733 / 7.285 GB | 26.129 / 14.166 GB |
| cut6/C128 | 35.923 / 20.675 GB | 11.555 / 7.575 GB | 29.853 / 17.422 GB |
| cut6/C64 | 32.383 / 17.134 GB | 10.841 / 6.862 GB | 27.020 / 14.589 GB |

These apply the retained 16 KiB allocator upper-bound policy to each named array independently. `--describe` uses logical sizes and explicitly reports `actualAllocatorBoundsApplied:false`; compare its logical fields with `initialFreeLogicalLowerBound`, not the allocator column above. Real admission also checks actual active memory, recommended working set, pressure=1, AC, zero swap, observation age, deadline, and resource ownership throughout the run.

Cut6/C64 is the most plausible unchanged-binary pair candidate. Cut7/C64's loaded rank0 requirement is only 13,006,773 bytes below the actual 4K overlap parent minimum of 7,298,449,408 bytes, before additional 8K state/live costs. Cut6/C128's full initial requirement exceeds the recent 48 GB host free observation of 33,530,806,272 bytes. The full C64 reference is also uncertain: its projected loaded requirement exceeds the actual 4K solo parent minimum (16,094,822,400 bytes) by 1,039,506,124 bytes. Fresh free-memory observations and all existing continuous gates are mandatory; no fit or TPS prediction is asserted.

If root accepts that risk after metadata and fresh quiescent memory checks, the existing exact commands are:

```sh
python3 -B /Users/developer/DarkbloomDev/cluster-research/gemma4-execution-20260920/run_case.py prepare --name p8192-cut6-c64-serial-v7 --prompt 8192 --cut 6 --chunk 64 --policy serial --capture
python3 -B /Users/developer/DarkbloomDev/cluster-research/gemma4-execution-20260920/prepare_memory.py --output /Users/developer/DarkbloomDev/cluster-research/gemma4-execution-20260920/cases/p8192-cut6-c64-serial-v7/memory-before-solo.json
python3 -B /Users/developer/DarkbloomDev/cluster-research/gemma4-execution-20260920/run_case.py solo --name p8192-cut6-c64-serial-v7
```

Only after successful full-reference retirement: fresh memory preparation, then `run_case.py pair --name p8192-cut6-c64-serial-v7`, followed by `compare_results_v2.py CASE_PATH`. For overlap, prepare `p8192-cut6-c64-overlap-v7` with the same arguments except `--policy oneChunkLookahead --match p8192-cut6-c64-serial-v7`, fresh memory preparation, then `pair`. Use the existing `gemma4-prefill-lookahead-20260920/compare_results_overlap.py SERIAL_CASE OVERLAP_CASE`. All phases use root-owned regular output files and existing bounded subprocess ownership. Any failure ends that cohort; do not reuse incomplete reference evidence.

C64 gives 128 prefill +15 decode frames per request. Even the first iteration's probe/control traffic remains below the existing 512-send cap (conservative rank1 count 309). C32 would exceed that cap and is not an admitted alternative. The same binary reports internal ready-to-agreement timing; it does not measure external HTTP request-to-first-content TTFT.

## Separate narrow window-bound draft

`window-bound.patch` changes only five named allocation dimensions in the saved exact v7 `Gemma4BenchmarkResourceBudget.swift`: K copy, V copy, scores, probabilities, and mask. All counts, F32 ceilings, concurrent selected-layer charges, state/ring/old-ring/chunk/probe/cast/host/transport charges and 6/4/2 GiB floors remain unchanged. Nothing is applied to the workspace or current binary. Preimage and 14 source files are pinned in `window-bound-context.json`.

The source proof is specific:

1. `Gemma4ForwardModel.freshCaches` creates ordinary CBv2 caches. `CBv2OwnedRequestState` makes fresh contiguous rows, and `CBv2RequestGeometry+Attention` refuses shared KV, sinks, bidirectional attention and mismatched actual local/global kinds.
2. `ContiguousKVBackend.makeRow` selects `CBv2WindowedSequenceKV` for sliding layers. A multi-token update returns at most `min(retainedCount, W-1)+L` keys; decode returns at most W. The retained chunk geometry is also checked after native evaluation by `CBv2AttentionStateValidation`.
3. Gemma's `forwardV2` passes those row views into `AttentionV1`. The exact admitted arithmetic environment pins query blocks to 128; C64/C128 do not enter query-block splitting. No image span or speculative transaction is created by this benchmark.
4. `AttentionV1.updateAndAttendRow` forwards the returned views and their actual `dim(2)` to `attend`. Its dtype conversion preserves shape; masks use `[L,kL]`. The native SDPA fallback derives scores from `Q @ Kᵀ`, masks from that same key shape, and probabilities preserve the score dimensions. It receives no total-request length that could expand a sliding key axis. The actual headDim256/C64-or128 path selects this fallback; decode/fused copies also use actual input shapes.

Therefore the key-axis bound for these five terms is `full ? N : min(N, W-1+C)`. With W1024, C64, N8208, the sliding bound is 1087. Across 25 sliding layers the logical ledger difference is 4,386,536,000 bytes; this is not a measured peak-memory reduction. Native workspace/allocation multiplicity is not newly certified by this proof, and no other ledger assumption is reduced.

`window-bound-prediction.json` separately projects the draft: full 8K/C64 initial 27,996,829,192 / loaded 12,748,331,724 bytes; full C128 initial 30,120,224,776 / loaded 14,871,727,308 bytes. The draft requires a new source-bound build, exact metadata controls (full remains N; sliding first chunk/wrap/decode <= bounded key axis; all other terms byte-identical), and fresh full/pair numerical and resource qualification before any use. Existing CBv2 window/attention fixtures and the real capture comparator should remain in that qualification. No throughput estimate follows from this accounting correction.

## Status update

`STATUS_20260920_REVIEW.md` now includes the actual v7 cut7 4K cohort. `status-evidence.json` binds five actual parent/native terminal and raw-log joins plus comparison `f625a609a44943561ee66b5bc0325ae021c74e42d2e8d4d695159945e12d9a87`: overlap 452.192428 prefill TPS /22.212139 decode, matched solo 363.686216 /44.866064, serial pair 318.466920 /22.607147. The comparator reported exact eight full rows/720 state components. This audit verified retained receipts and logs, and did not reread all state bytes or rerun the comparator. Earlier refusals and slower pair decode remain visible.
