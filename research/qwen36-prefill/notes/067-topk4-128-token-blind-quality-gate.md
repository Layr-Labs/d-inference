# 067 — Top-k4 blind 128-token semantic quality gate

Status: **PASS for an explicitly approximate profile; not semantic parity**

This review compares:

- baseline: `artifacts/e30-quality-baseline-128.json`
  (`baseline-top8-128`);
- candidate: `artifacts/e30-quality-topk4-128.json`
  (`topk4-128`).

Both reports match the committed
`provider-swift/Benchmarks/QualityCorpus/qwen-quality-v1.json` prompts and
categories. They share corpus SHA-256
`9986606cac444cfbe22d6b2d1d4a9ce1b95036255e30d5bc972740dbcb27e575`,
model-artifact SHA-256
`d932e96b00404b0575fff47e2dac8ed113056b3f22d0040c3c8d3f9ef25b09ed`,
greedy decoding, and 128 generated tokens with `finishReason=length` in all 12
cases. The candidate alone sets
`DARKBLOOM_QWEN35_PREFILL_MOE_TOP_K=4`.

## Blind protocol and rubric

Each pair was presented in a case-wise anonymized A/B order. Scoring used only
the committed prompt and generated `text`; profile labels were mapped back
afterward. Generated token IDs, checksums, token agreement, common-prefix
length, and throughput did not enter any semantic judgment.

Scores use 0–5:

- `T` final-answer trajectory: 0 is unrelated or irrecoverably off-course; 5
  reaches a substantive correct answer.
- `F` factual/math correctness for non-code cases: 0 is materially false; 5
  means every substantive visible claim is correct.
- `K` code correctness for code cases: 0 is unusable; 5 is a correct visible
  implementation. A requirements restatement with no implementation earns at
  most 3.
- `I` instruction adherence: 0 irreversibly violates an explicit constraint; 5
  satisfies every observable constraint.
- `C` coherence: 0 is unusable; 5 is clear and internally consistent.
- `X` corruption severity: 0 is clean; 5 is catastrophic repetition,
  control-token leakage, or unrelated language collapse.

Each row contributes `T + F/K + I + C + (5 - X)`, at most 25. `F/K` means `F`
for non-code cases and `K` for code cases. Because these are forced,
fixed-length continuations, `T` judges the observed path rather than requiring
a complete answer. An already irreversible format violation still scores
immediately.

## Per-case scores

| Case | Baseline T/F/K/I/C/X | Top-k4 T/F/K/I/C/X | Relative quality | Semantic judgment |
|---|---:|---:|---|---|
| `reasoning-rate-plan` | 3/5/—/3/4/0 | 4/5/—/3/4/0 | top-k4 slight win | Top-k4 reaches both correct service times; baseline stops at an incomplete cutter-time line. Neither reaches the 52-minute schedule or polisher bottleneck. |
| `reasoning-constraint-order` | 3/4/—/3/4/0 | 3/4/—/3/4/0 | tie | Both correctly frame the constraints but list no ordering. Neither makes a false placement claim; the actual valid set is `AECBD` and `CBEAD`. |
| `reasoning-estimation` | 3/4/—/3/4/0 | 3/4/—/3/4/0 | tie | Both preserve group size, duration, warm weather, safety margin, and separation requirements, then stop before choosing a rate or doing arithmetic. |
| `code-python-bug` | 3/—/3/3/4/0 | 3/—/3/3/4/0 | tie | Both correctly identify the empty-input and terminal-run faults, then merely begin quoting the original function. Neither supplies a correction or tests, so implementation correctness is not established. |
| `code-swift-actor` | 2/—/3/2/4/0 | 2/—/3/2/4/0 | tie | Both accurately restate the actor API, deadline, stale-delete, and Sendable requirements. Neither emits Swift code, a Sendable argument, or usage. |
| `factual-heat-pump` | 3/4/—/3/4/0 | 3/4/—/3/4/0 | tie | Both identify COP, the external heat source, conservation, and performance conditions as topics but make no substantive physics claim yet. |
| `factual-database-index` | 4/5/—/3/4/0 | 3/4/—/3/4/0 | baseline win | Baseline begins the actual comparison with the correct B-tree `O(log N)` equality path. Top-k4 only restates the requested dimensions before the cutoff. |
| `factual-probability` | 4/5/—/3/4/0 | 3/3/—/3/4/0 | baseline win | Baseline preserves `0.96`, `0.92`, `0.03`, PPV, and the 10,000-person method. Top-k4 ends on the visibly false/incomplete `96% = 0.9`; the correct cohort path is 288 true positives, 776 false positives, and about 27.1% PPV. |
| `long-context-expedition-log` | 4/5/—/3/4/0 | 3/4/—/3/4/0 | baseline slight win | Baseline starts extracting exact Day-1 facts (`LARK-17`, western moraine, `1008 hPa`); top-k4 stops at `LARK-`. Neither reaches the four requested answers, and neither invents a fact. |
| `long-context-incident-summary` | 3/5/—/3/4/0 | 3/5/—/3/4/0 | tie | Text is identical. It preserves the no-database-blame constraint and first timeline fact but does not yet reach the attachment-manifest loop or stale process-local flag. |
| `instruction-json-only` | 0/3/—/0/4/0 | 0/3/—/0/4/0 | fatal tie | Both begin with prose and Markdown-like analysis, making “exactly one valid JSON object and no Markdown” impossible regardless of later continuation. |
| `instruction-rewrite` | 3/5/—/2/4/0 | 2/5/—/1/4/0 | baseline win | Baseline begins separating facts from emotional language. Top-k4 spends the window quoting the source and requirements. Neither produces the requested status update, but both remain coherent and fact-preserving. |

## Relative aggregate

| Metric | Baseline | Top-k4 | Candidate delta |
|---|---:|---:|---:|
| Mean final-answer trajectory | 2.92 | 2.67 | -0.25 |
| Mean applicable correctness (`F/K`) | 4.25 | 3.92 | -0.33 |
| Mean instruction adherence | 2.58 | 2.50 | -0.08 |
| Mean coherence | 4.00 | 4.00 | 0.00 |
| Mean corruption severity | 0.00 | 0.00 | 0.00 |
| Adjusted quality total | 225/300 (75.00%) | 217/300 (72.33%) | **-2.67 percentage points** |

Pairwise result: **7 ties, 1 top-k4 win, and 4 baseline wins**. Top-k4
retains **96.44%** of the baseline adjusted score. The quality-run prefill
measurements, excluded from scoring, have a 1.340× median per-case candidate
ratio (1.325× mean).

## Fatal failures

- **Candidate-only fatal failures: 0.**
- **Inherited fatal failures: 1.** `instruction-json-only` irreversibly breaks
  the exact output envelope in both reports.
- The top-k4 probability arm has one candidate-only visible math defect:
  `96% = 0.9`. It occurs at the exact forced boundary and can become `0.96`
  with another token, so it is scored as a real correctness regression but not
  as irreversible corruption or a completed false answer.
- No candidate case contains garbled language, repetition collapse,
  special/control-token leakage, an unrelated answer, fabricated source facts,
  or incorrect code.
- The database-index, expedition-log, and rewrite losses are progress-at-cutoff
  losses. They matter to the relative score but do not establish a wrong final
  answer.

## Verdict

**PASS** for retaining top-k4 as a clearly named, opt-in, explicitly
approximate prefill profile. It remains coherent in all 12 cases, introduces no
candidate-only fatal failure or corruption, and retains 96.44% of the baseline
score under this trajectory rubric.

This is not evidence of semantic parity. The candidate has a visible
boundary-local math regression and a measurable aggregate loss. The corpus has
only 12 synthetic prompts, and the forced 128-token outputs still spend most of
their budget on analysis preambles rather than final answers. Top-k4 must not be
called exact, silently replace the baseline profile, or be presented as
full-answer-quality-equivalent without a separate completion-length gate.
