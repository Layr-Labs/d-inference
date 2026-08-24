# 079 — Suffix64 E4 blind 128-token semantic quality gate

Status: **performance threshold PASS; semantic policy FAIL**

This review compares:

- native baseline: `artifacts/e30-quality-baseline-128.json`;
- suffix64 E4 candidate: `artifacts/e50-quality-suffix64-e4-128.json`;
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

Semantic scoring used only each committed prompt and generated `text`.
Run/profile identity, policy metadata, token IDs, checksums, exact matches,
token agreement, common-prefix lengths, and timings did not enter any score.

Scores use the 0–5 rubric fixed in note 077:

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
  control-token leakage, or unrelated language/task collapse.

Each row contributes `T + F/K + I + C + (5 - X)`, at most 25. The fixed
128-token cutoff means `T` judges the observed path rather than requiring a
complete answer. An already irreversible format violation still scores
immediately.

## Per-case scores

| Case | Native T/F/K/I/C/X | Suffix64 E4 T/F/K/I/C/X | Relative quality | Semantic judgment |
|---|---:|---:|---|---|
| `reasoning-rate-plan` | 3/5/—/3/4/0 | 4/5/—/3/4/0 | suffix64 slight win | The candidate correctly preserves both stages and advances through both 4- and 6-minute service times. Native stops at the cutter-time line. Neither reaches the 52-minute schedule or identifies the polisher bottleneck. |
| `reasoning-constraint-order` | 3/4/—/3/4/0 | 3/4/—/3/4/0 | tie | Both correctly preserve all five named talks, slots, and the constrained-ordering task, then stop while enumerating constraints rather than listing the two valid orders. |
| `reasoning-estimation` | 3/4/—/3/4/0 | 3/4/—/3/4/0 | tie | Both preserve 37 hikers, 9 hours, warm weather, explicit assumptions, safety margin, visible arithmetic, and the drinking/non-drinking split, then stop before choosing a rate. |
| `code-python-bug` | 3/—/3/3/4/0 | 1/—/2/1/1/3 | native win; candidate fatal | The candidate identifies the broad longest-run task but loops through the same prompt paraphrase, never reaches the empty-input or terminal-run faults, and emits no corrected implementation or tests. |
| `code-swift-actor` | 2/—/3/2/4/0 | 2/—/3/2/4/0 | tie | Both preserve `ExpiringCache`, keyed strings, `ContinuousClock`, the four methods, stale deletion, Sendable, and dependency constraints. Neither emits Swift code or a usage example. |
| `factual-heat-pump` | 3/4/—/3/4/0 | 3/4/—/3/4/0 | tie | Both correctly frame COP, environmental heat, conservation, and performance conditions but stop before the substantive explanation. |
| `factual-database-index` | 4/5/—/3/4/0 | 4/5/—/3/4/0 | tie | Both begin the requested B-tree/hash comparison with the correct general B-tree equality path and introduce no product-specific claim. |
| `factual-probability` | 4/5/—/3/4/0 | 4/5/—/3/4/0 | tie | Both preserve 96% sensitivity, 92% specificity, 3% prevalence, PPV, and the 10,000-person cohort, then stop before arithmetic. |
| `long-context-expedition-log` | 4/5/—/3/4/0 | 0/0/—/0/0/5 | native win; candidate fatal | The candidate loses the seven-day source, hallucinates a five-day sensor/lab synopsis, and collapses into a repeated `SST` loop. It produces no authoritative identifier or answer. |
| `long-context-incident-summary` | 3/5/—/3/4/0 | 0/0/—/0/0/5 | native win; candidate fatal | The candidate replaces the timeline with a repeated `09:09` sequence. It retains no release, attachment-manifest, flag, database, root-cause, or action fact. |
| `instruction-json-only` | 0/3/—/0/4/0 | 0/1/—/0/1/2 | inherited fatal; native win | Both irreversibly violate the exact JSON-only envelope by starting with prose. The candidate initially preserves the sentence and no-Markdown rule, then invents a contradictory Markdown requirement and loops on rereading it. |
| `instruction-rewrite` | 3/5/—/2/4/0 | 2/5/—/1/4/0 | native win | The candidate preserves the status-update direction and visible record facts, but omits the 70–100-word, calm/no-speculation, and one-final-step constraints within the window. Neither produces the requested final update. |

## Relative aggregate

| Metric | Native | Suffix64 E4 | Candidate delta |
|---|---:|---:|---:|
| Mean final-answer trajectory | 2.92 | 2.17 | -0.75 |
| Mean applicable correctness (`F/K`) | 4.25 | 3.17 | -1.08 |
| Mean instruction adherence | 2.58 | 1.83 | -0.75 |
| Mean coherence | 4.00 | 2.83 | -1.17 |
| Mean corruption severity | 0.00 | 1.25 | +1.25 |
| Adjusted quality total | 225/300 (75.00%) | 165/300 (55.00%) | **-20.00 percentage points** |

Pairwise result: **6 ties, 1 suffix64 win, and 5 native wins**. Suffix64 E4
retains **73.33%** of the native adjusted score.

## Fatal failures

For consistency with note 077, a fatal case is one whose visible continuation
is already unusable because it irreversibly breaks an exact output contract,
collapses into severe repetition, substitutes an unrelated task, or fabricates
source facts/identifiers.

- **Candidate-only fatal failures: 3.** `code-python-bug`,
  `long-context-expedition-log`, and `long-context-incident-summary`.
- **Inherited fatal failures: 1.** `instruction-json-only` breaks the exact
  envelope in both reports; suffix64 adds prompt confusion inside the
  already-failed case.
- Three candidate cases have `X >= 3`: the Python prompt-paraphrase loop and
  the two hard long-context repetition collapses.
- The candidate emits no executable code, so there is no incorrect
  implementation to run. Its Python failure is prompt-level repetition and
  omission of every requested deliverable.

## Explicit approximate-policy decision

Note 077's policy was committed before this report was generated. A named,
default-off approximate cold-prefill mode must:

1. retain at least **95%** of the native adjusted score;
2. introduce **zero candidate-only fatal cases**;
3. contain **zero cases with `X >= 3`** corruption;
4. lose no more than **1.0 mean point** in trajectory, applicable correctness,
   instruction adherence, or coherence.

Suffix64 E4 fails all four top-level criteria:

- 73.33% score retention is below 95%;
- it introduces three candidate-only fatal cases;
- it has three `X >= 3` cases;
- applicable correctness loses 1.08 mean points and coherence loses 1.17.

**Semantic verdict: FAIL.** Restoring a complete 64-token suffix materially
improves on the E4 and E8 frontier candidates, but it does not produce a usable
approximate policy. The long-context cases still collapse, the Python task
loops, and aggregate quality remains 20 percentage points below native.

The supplied B4x2K result is **2.692x**, 0.192x above the 2.5x performance
threshold. That speed is not contained in the semantic-quality artifact and is
not independently revalidated here. The performance cell passes, but the
semantic gate is a binding kill-switch: do not retain or ship suffix64 E4 as a
quality-approved frontier.
