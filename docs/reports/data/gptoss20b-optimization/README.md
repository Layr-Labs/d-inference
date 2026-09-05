# GPT-OSS optimization evidence

> Last updated: 2026-09-05 · commit `94c7c31eb`

Evidence for the [implementation report](../../2026-09-05-gptoss20b-optimization-results.md).

[Comparison index](comparison-index.json) lists the candidate experiments and paired cycle ratios. Each named JSON contains the measured per-run values, timing distributions, model-independent output hashes, validation outcomes, and cycle comparisons. `tokenParityPassed: null` on prefill comparisons means the benchmark emits no token sequence; numerical correctness comes from the separate checkpoint tests. An incomplete decode comparison can report false parity until every scheduled run exists; only completed comparisons are evidence.

[Real-checkpoint summary](real-parity-summary.json) records 42 model-policy/batch/context arms, exact prefill KV receipts, and 1,568 teacher-forced positions. The full local report also contains prompts, generated tokens, top-two margins and per-position logit differences. This is bounded correctness coverage, not a broad model-quality evaluation.

[Dequantization screen](phase3-dequant-512.json) records the rejected temporary-weight experiment. [Fusion screen](phase3-fusion-load-512.json) records the runtime result after incremental load materialization. Load peak itself is printed separately by the benchmark and retained in the implementation report.

[Evidence index](evidence-index.json) records hashes of the portable files and their source artifacts. Full executable/metallib banks, complete raw stdout/stderr, source patches, process and host snapshots remain in the local worktree under `artifacts/gptoss20b-profile`; binaries and large traces are deliberately not committed. Benchmark prompts are synthetic; no consumer traffic or private user prompts were used.
