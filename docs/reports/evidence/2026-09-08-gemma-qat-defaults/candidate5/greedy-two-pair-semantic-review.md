# Candidate 5: two matched speed pairs and semantic review

> Last updated: 2026-09-08 · commit `4ae34f033`

Two pairs use the same candidate5 binary and source tasks, in opposite execution order: adaptive-on1 then off1, followed by off2 then adaptive-on2. All 24 outputs were reviewed either directly or by exact text identity to an already reviewed output. Parent reports zero structural/cache/tenant/cancellation/lifecycle harness errors in all four runs. This records measured behavior and answer defects; it is not a release-readiness declaration.

Evidence: `candidate5-speed-two-pair-semantic-evidence.json`, reproduced by `review_candidate5_speed_combined.py`. Detailed source-fact and first-pair reviews remain in `candidate5-b1-speed-on1-semantic-review.md` and `candidate5-b1-speed-pair1-semantic-review.md`.

## Repeated generated code defect

The source task requires insertion keyed by `(source,event_id)` and source isolation. The completed generated implementation incorrectly imposes global event-ID uniqueness in **on1 code-first, on2 code-first, and on2 code-repeat**. The bounded executable probe inserts station-01 / evt-001, then station-02 / evt-001. Expected second result is True and total valid aggregate 20; actual result is False and aggregate 10. On1 code-repeat passes. All four off code answers pass this source-isolation probe (off2 is text-identical to executed off1).

On2 code-first exactly matches the reviewed failing on1 code-first. On2 code-repeat is a newly reviewed variant with the same global uniqueness logic, and was separately executed to confirm the failure. This is completed implementation behavior, not truncation of the generated unittest section. The precise source requirement and failing assertion are preserved in the JSON evidence.

This repeated answer defect should remain visible alongside the speed improvement. It is one coding prompt observed across four adaptive generations, not four independent coding tasks or a broad quality-rate estimate. The output remains coherent, but coherence alone does not make its source-isolation behavior correct. The observed defect neither identifies a runtime/cache-state fault nor establishes semantic equivalence to off.

Existing defects remain distinct: all reviewed code variants accept naive timestamps despite the timezone-aware requirement. Off documents rejecting conflicting data with ValueError but silently treats changed time/quality/unit/route/note as identical retries when reading and sequence match; this was executed in the first matched review. Adaptive outputs return False for retries/conflicts and preserve the stored event, consistent with their documented rejection policy. Tests and explanation are cut by the explicit output cap; partial implementation is allowed by the source task.

## Other outputs and identity reuse

All six off2 texts equal off1, and all off1 texts equal the reviewed candidate3 baseline. On2 prose-first equals on1 prose-first; on2 prose-repeat also equals that same reviewed prose-first text. Both keep the five district priorities and suggestion/approval distinction, with no invented survey count or funding approval. Previously documented unprovided author/date and broadened interview-group attribution remain; planning measures and hypothetical tradeoffs are proposals.

All eight extraction outputs across modes/runs are text-identical. Eight complete objects P001–P008 match all 72 expected fields/types; the Markdown fence is the unchanged JSON-only instruction defect. P009 is incomplete because the output cap cuts its dependency key.

All 24 rows finish `length` at 1024 tokens with matching token-ID array lengths. No natural-stop/EOS-handling conclusion follows from these speed runs. Repeat SSD hits preserve 8192/4096/6144 tokens for code/prose/extraction, with zero replay in every row. The benchmark uses raw native engine events, one M5 machine and a local assistant artifact override, not a public HF rollout or a fleet load test.

## Confirmed speed measurements

| Task / cache state | Pair 1 adaptive change | Reverse-order pair 2 change |
|---|---:|---:|
| Code first | +10.40% | +10.48% |
| Code repeat | +11.80% | +11.39% |
| Prose first | −1.09% | −0.92% |
| Prose repeat | −0.61% | −0.72% |
| Extraction first | +17.20% | +17.23% |
| Extraction repeat | +17.72% | +17.75% |

Matched prompt token IDs agree in both pairs. Extraction also uses identical generated tokens, providing a direct token-sequence comparison. Code/prose follow different output trajectories and therefore compare matched input tasks. Adaptive code/extraction speed gains and a small prose overhead repeat in reverse order. The controller uses substantial rectangular verification for code/extraction and primarily ordinary decoding after probing prose; per-row round and acceptance deltas are retained in the evidence JSON.

Sampling tests and any further quality assessment are separate evidence. These results confirm the measured workload-specific speed behavior and retain the concrete repeated answer defect without inferring its internal cause.
