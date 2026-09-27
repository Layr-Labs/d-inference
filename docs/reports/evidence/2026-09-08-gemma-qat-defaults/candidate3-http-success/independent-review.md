# Candidate 3 live default-auto rollout: independent review

> Last updated: 2026-09-08 · commit `4ae34f033`

Reviewed 2026-09-08 from all 38 request/response bodies, 372 metrics samples, 10 fixture events, metadata and report. This uses one real M5 provider serving the target model, through a controlled localhost catalog/CDN with identical verified assistant bytes. The HF hint was deliberately omitted. It validates actual default-auto download/load/idle activation wiring; it is not a public-catalog/HF transport test or a trial on 16 physical providers.

All 38 responses are HTTP 200 and coherent. Each supplies exactly 12 numbered, relevant implementation checks for staged pumping upgrades, canal maintenance and acoustic leak detection. Each item is one sentence. They propose verification, costing, scheduling, downstream-risk monitoring or mitigations; none asserts approved funding or fabricated completed outcomes. These are closely related prompts from one scenario, so the semantic scope is narrow.

All 38 finish naturally with stop, using 169–219 completion tokens under the 256-token cap. This corrects the tentative assumption that responses might all be length-limited. Reconstructing text from every SSE content delta exactly matches each saved answer; reasoning is empty. No raw <turn|>, tested template delimiters or think tags appear in any reconstructed answer, including the 12 requests whose start phase is active. Thus this run does provide observed natural-stop HTTP marker-filtering evidence, while not guaranteeing every possible terminal path.

TTFT was independently recomputed from the timestamp of the first nonempty SSE content delta. Initial cold request: 22.544473 seconds. Remaining 37 requests: median 180.783 ms, range 176.599–183.185 ms. The 12 active-phase requests have median 180.942 ms and maximum 182.554 ms. These are first-content latencies, not complete-response times or an isolated decode speed comparison.

Metrics last show inactive at monotonic 72.066749 and first show active at 72.327921 seconds. Request 24 starts at 70.313389 with 180.850 ms TTFT; request 25 starts within that activation observation bracket at 72.181992 with 180.778 ms TTFT; request 26 starts at 74.320945 with 180.749 ms TTFT. No swap-associated spike is observed in these requests. Requests are sequential with approximately 0.1-second gaps; this result is descriptive, not a guarantee under arbitrary concurrent load. Phase waiting_weights continues through assistant preparation/activation after the fixture has already sent the weights, so it must not be interpreted as literal network transfer for the entire phase.

The 8 failed metrics polls are startup connection refusals before the first serving request, distinct from serving failures. The serving report records 38 valid streams and zero server errors. Counters show real MTP rounds after activation; the known candidate3 fallback behavior limits any throughput claim.

Detailed evidence: candidate3-default-auto-rollout-success1-independent-evidence.json stores per-request text hashes, SSE reconstruction, natural-stop/cap checks, numbering/marker checks and exact latency/activation measurements. No runtime changes or GPU work were performed for this review.
