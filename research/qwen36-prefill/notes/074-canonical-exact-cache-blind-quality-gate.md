# 074 — Canonical exact-cache blind 128-token semantic quality gate

Status: **PASS for the opt-in canonical numerical policy; not exact native
continuation parity**

This review compares:

- native baseline: `artifacts/e30-quality-baseline-128.json`;
- canonical candidate: `artifacts/e47-quality-canonical-128.json.gz`;
- committed corpus:
  `provider-swift/Benchmarks/QualityCorpus/qwen-quality-v1.json`.

Both reports contain the same 12 committed prompts and categories, corpus
SHA-256
`9986606cac444cfbe22d6b2d1d4a9ce1b95036255e30d5bc972740dbcb27e575`,
model-artifact SHA-256
`d932e96b00404b0575fff47e2dac8ed113056b3f22d0040c3c8d3f9ef25b09ed`,
greedy decoding settings, and 128 generated tokens with
`finishReason=length` in every case.

## Blind protocol and rubric

Scoring used only each committed prompt and generated `text`. Run labels,
engine/profile metadata, token IDs, checksums, common-prefix lengths, and
timings did not enter a semantic score. The arm mapping and token comparison
were considered only after the scores were fixed.

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

Each row contributes `T + F/K + I + C + (5 - X)`, at most 25. Because these
are forced fixed-length continuations, `T` judges the observed path rather than
requiring a complete answer. An already irreversible format violation still
scores immediately.

## Per-case scores

| Case | Native T/F/K/I/C/X | Canonical T/F/K/I/C/X | Relative quality | Semantic judgment |
|---|---:|---:|---|---|
| `reasoning-rate-plan` | 3/5/—/3/4/0 | 3/5/—/3/4/0 | tie | Both correctly establish the two-stage scheduling task and machine times, then stop before the 52-minute schedule and polisher bottleneck. |
| `reasoning-constraint-order` | 3/4/—/3/4/0 | 3/4/—/3/4/0 | tie | Both correctly frame the entities and constraints but list no ordering. The visible text makes no false placement claim. |
| `reasoning-estimation` | 3/4/—/3/4/0 | 3/4/—/3/4/0 | tie | Both preserve the group size, duration, warm-weather assumption, safety-margin requirement, and drinking/non-drinking split, then stop before arithmetic. |
| `code-python-bug` | 3/—/3/3/4/0 | 3/—/3/3/4/0 | tie | Both identify the empty-input and terminal-run faults but provide no corrected implementation or tests within the window. |
| `code-swift-actor` | 2/—/3/2/4/0 | 2/—/3/2/4/0 | tie | Both accurately restate the actor, deadline, stale-delete, API, and Sendable requirements but emit no Swift code or usage example. |
| `factual-heat-pump` | 3/4/—/3/4/0 | 3/4/—/3/4/0 | tie | Both identify COP, the external heat source, conservation, and performance conditions as required topics but make no substantive physics claim yet. |
| `factual-database-index` | 4/5/—/3/4/0 | 4/5/—/3/4/0 | tie | Both begin the requested comparison with the correct general B-tree `O(log N)` equality path. |
| `factual-probability` | 4/5/—/3/4/0 | 4/5/—/3/4/0 | tie | Both preserve `0.96`, `0.92`, `0.03`, PPV, and the 10,000-person method, then stop before the cohort arithmetic. |
| `long-context-expedition-log` | 4/5/—/3/4/0 | 3/5/—/3/4/0 | native slight win | The native arm advances from task analysis into exact source-fact extraction (`LARK-17`, western moraine, `1008 hPa`). The canonical arm remains accurate and identifier-preserving but spends the rest of the window enumerating the questions, so it reaches no source fact or answer. Neither invents a fact. |
| `long-context-incident-summary` | 3/5/—/3/4/0 | 3/5/—/3/4/0 | tie | Both preserve the no-database-blame constraint and first timeline fact but do not yet reach the attachment-manifest loop or stale process-local flag. |
| `instruction-json-only` | 0/3/—/0/4/0 | 0/3/—/0/4/0 | inherited fatal tie | Both begin with prose and Markdown-like analysis, making “exactly one valid JSON object and no Markdown” impossible regardless of later continuation. |
| `instruction-rewrite` | 3/5/—/2/4/0 | 3/5/—/2/4/0 | tie | Both begin separating concrete facts from emotional language but do not produce the requested 70–100-word status update or final next step. |

## Relative aggregate

| Metric | Native | Canonical | Candidate delta |
|---|---:|---:|---:|
| Mean final-answer trajectory | 2.92 | 2.83 | -0.08 |
| Mean applicable correctness (`F/K`) | 4.25 | 4.25 | 0.00 |
| Mean instruction adherence | 2.58 | 2.58 | 0.00 |
| Mean coherence | 4.00 | 4.00 | 0.00 |
| Mean corruption severity | 0.00 | 0.00 | 0.00 |
| Adjusted quality total | 225/300 (75.00%) | 224/300 (74.67%) | **-0.33 percentage points** |

Pairwise result: **11 ties and 1 native slight win**. The canonical arm retains
**99.56%** of the native adjusted score.

After scoring, the identity check showed that 11 case texts are identical. The
only divergent case is `long-context-expedition-log`: it shares a 27-token
prefix and then follows the accurate but less-progressed question-enumeration
path described above. Token disagreement itself is not a score penalty.

## Fatal failures

- **Candidate-only fatal failures: 0.**
- **Inherited fatal failures: 1.** `instruction-json-only` irreversibly breaks
  the exact output envelope in both reports.
- The divergent canonical expedition continuation contains no false answer,
  identifier mutation, fabricated log fact, unrelated text, repetition,
  control-token leakage, or language corruption.
- Its one-point loss is progress at the forced cutoff, not evidence of a wrong
  eventual answer.

## Verdict

**PASS** for the default-off, opt-in canonical numerical policy. It introduces
no candidate-only fatal failure, factual/math/code error, instruction
regression, or corruption; 11 of 12 continuations are semantically identical,
and the remaining arm is coherent, source-faithful, and only one trajectory
point behind at the forced boundary.

This is not bitwise or exact native continuation parity: the long-context case
diverges after 27 tokens. The corpus is also only 12 synthetic prompts, and
fixed 128-token generations still spend much of their budget on analysis
preambles. The result supports the canonical policy as an explicit exact-cache
opt-in, not as proof that every native and canonical numerical trajectory is
identical or as justification for silently changing cache-free default
inference.
