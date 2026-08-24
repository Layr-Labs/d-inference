# 079 — Suffix-frontier E4 blind 128-token semantic quality gate

Status: **suffix64/128 semantic FAIL; suffix192 + top-k4 semantic PASS;
all supplied performance cells PASS**

This review compares:

- native baseline: `artifacts/e30-quality-baseline-128.json`;
- suffix64 E4 candidate: `artifacts/e50-quality-suffix64-e4-128.json.gz`;
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

## Suffix128 E4 follow-up

The more conservative candidate in
`artifacts/e50-quality-suffix128-e4-128.json.gz` uses the same 12 prompts,
corpus/model hashes, greedy generation, 128-token cutoff, and length finish as
native. The semantic scores below again use only prompt and generated text.
The supplied exact-continuation count, token agreement, profile identity, and
speed were withheld from every score and considered only after the table was
fixed.

### Suffix128 per-case scores

| Case | Native T/F/K/I/C/X | Suffix128 E4 T/F/K/I/C/X | Relative quality | Semantic judgment |
|---|---:|---:|---|---|
| `reasoning-rate-plan` | 3/5/—/3/4/0 | 3/5/—/3/4/0 | tie | Both correctly establish the two-stage scheduling task and machine times, then stop before the 52-minute schedule and polisher bottleneck. |
| `reasoning-constraint-order` | 3/4/—/3/4/0 | 3/4/—/3/4/0 | tie | Both correctly frame all entities and constraints but list no ordering. |
| `reasoning-estimation` | 3/4/—/3/4/0 | 3/4/—/3/4/0 | tie | Both preserve the group, duration, conditions, safety margin, visible-arithmetic, and water-separation requirements, then stop before assumptions or arithmetic. |
| `code-python-bug` | 3/—/3/3/4/0 | 3/—/3/3/4/0 | semantic tie | Both identify the empty-input and terminal-run faults and every requested deliverable, but provide no corrected implementation or tests within the window. |
| `code-swift-actor` | 2/—/3/2/4/0 | 2/—/3/2/4/0 | tie | Both accurately preserve the actor, deadline, API, stale-delete, Sendable, and dependency requirements but emit no Swift code or usage. |
| `factual-heat-pump` | 3/4/—/3/4/0 | 3/4/—/3/4/0 | tie | Both preserve the correct COP, external-heat, conservation, and performance-condition direction but stop before the explanation. |
| `factual-database-index` | 4/5/—/3/4/0 | 4/5/—/3/4/0 | tie | Both begin the requested comparison with the correct general B-tree equality path. |
| `factual-probability` | 4/5/—/3/4/0 | 4/5/—/3/4/0 | tie | Both preserve all rates, PPV, and the 10,000-person method, then stop before cohort arithmetic. |
| `long-context-expedition-log` | 4/5/—/3/4/0 | 2/1/—/1/3/1 | native win; candidate fatal | Suffix128 preserves useful identifiers and origins but fabricates the chronology: A-06R was collected on Day 3, not Day 1; Kestrel transferred E-14 on Day 5, not Day 3; and delivery to Lab Cedar occurred on Day 7, not Day 5. It also mutates Nia into “Team A-06R” and reaches none of the four answers. |
| `long-context-incident-summary` | 3/5/—/3/4/0 | 4/3/—/2/4/0 | native win; material nonfatal error | Suffix128 advances to the restart/recovery and repeated-manifest root cause, but falsely labels those 09:27 and 09:34 events as 09:09 and 09:14. The core events are otherwise source-faithful; no summary, factors, or three actions appear yet. |
| `instruction-json-only` | 0/3/—/0/4/0 | 0/3/—/0/4/0 | inherited fatal tie | Both start with prose, irreversibly violating the exact JSON-only envelope despite accurately preserving the requested fields and rules. |
| `instruction-rewrite` | 3/5/—/2/4/0 | 3/5/—/2/4/0 | tie | Both accurately separate concrete facts from emotional language but do not produce the required final update. |

### Suffix128 relative aggregate

| Metric | Native | Suffix128 E4 | Candidate delta |
|---|---:|---:|---:|
| Mean final-answer trajectory | 2.92 | 2.83 | -0.08 |
| Mean applicable correctness (`F/K`) | 4.25 | 3.75 | -0.50 |
| Mean instruction adherence | 2.58 | 2.33 | -0.25 |
| Mean coherence | 4.00 | 3.92 | -0.08 |
| Mean corruption severity | 0.00 | 0.08 | +0.08 |
| Adjusted quality total | 225/300 (75.00%) | 213/300 (71.00%) | **-4.00 percentage points** |

Pairwise result: **10 ties, 0 suffix128 wins, and 2 native wins**. Suffix128
retains **94.67%** of the native adjusted score.

### Suffix128 fatal failures and policy decision

- **Candidate-only fatal failures: 1.**
  `long-context-expedition-log` fabricates three source chronology facts in the
  exact-identifier retrieval task.
- **Inherited fatal failures: 1.** `instruction-json-only` violates the
  envelope in both reports.
- `long-context-incident-summary` has a material candidate-only timestamp
  error, but its core root-cause and recovery facts remain coherent; it is
  scored as a nonfatal correctness regression.
- Suffix128 has **zero `X >= 3` cases**. All four mean quality dimensions remain
  within the policy's 1.0-point limit.

**Semantic verdict: FAIL, narrowly on aggregate and decisively on the fatal
gate.** Suffix128 satisfies two of the four explicit policy criteria, but:

- 94.67% score retention misses the 95% floor by 0.33 percentage points;
- one candidate-only fatal source-grounding failure violates the zero-fatal
  rule.

After scoring, the identity diagnostics show **9/12 exact continuations** and
**79.30% token-position agreement**. Those values explain why most rows tie,
but identity cannot erase the two changed long-context errors.

The supplied B4x2K speed is **2.580x**, 0.080x above the 2.5x performance
threshold; it is performance context rather than a value independently
revalidated from this semantic artifact. This is the closest measured
state-river quality/speed point so far, but the semantic kill-switch still
binds. Do not label or ship suffix128 E4 as quality-approved without eliminating
the expedition source fabrication and passing a fresh blind run.

## Suffix192 + top-k4 E4 follow-up

The candidate in
`artifacts/e50-quality-suffix192-topk4-e4-128.json.gz` uses the same 12 prompts,
corpus/model hashes, greedy generation, 128-token cutoff, and length finish as
native. Scoring again used only prompt and generated text; profile metadata,
token identity, checksums, agreement, prefixes, and timing did not enter any
semantic judgment.

### Suffix192 + top-k4 per-case scores

| Case | Native T/F/K/I/C/X | Suffix192 + top-k4 T/F/K/I/C/X | Relative quality | Semantic judgment |
|---|---:|---:|---|---|
| `reasoning-rate-plan` | 3/5/—/3/4/0 | 4/5/—/3/4/0 | candidate slight win | The candidate correctly reaches both 4- and 6-minute service times; native stops at the cutter-time line. Neither reaches the 52-minute schedule or polisher bottleneck. |
| `reasoning-constraint-order` | 3/4/—/3/4/0 | 3/4/—/3/4/0 | tie | Both correctly preserve the entities, slots, constraints, and exhaustive-ordering task, then stop before listing either valid ordering. |
| `reasoning-estimation` | 3/4/—/3/4/0 | 3/4/—/3/4/0 | tie | Both retain 37 hikers, 9 hours, warm weather, assumptions, safety margin, arithmetic, and the drinking/non-drinking split, then stop before selecting a rate. |
| `code-python-bug` | 3/—/3/3/4/0 | 3/—/3/3/4/0 | tie | Both accurately identify the empty-input and terminal-run faults and requested implementation/tests, then stop while quoting the original function. |
| `code-swift-actor` | 2/—/3/2/4/0 | 2/—/3/2/4/0 | tie | Both accurately preserve the actor, deadline, API, stale-delete, Sendable, and dependency requirements but emit no implementation or usage. |
| `factual-heat-pump` | 3/4/—/3/4/0 | 3/4/—/3/4/0 | tie | Both preserve the correct COP, external-heat, conservation, and real-world-condition direction but stop before the substantive explanation. |
| `factual-database-index` | 4/5/—/3/4/0 | 3/4/—/3/4/0 | native win | The candidate accurately enumerates the requested comparison dimensions but reaches no index behavior. Native begins the actual comparison with the correct general B-tree equality path. |
| `factual-probability` | 4/5/—/3/4/0 | 3/3/—/3/4/0 | native win | The candidate correctly frames PPV, prevalence, and the 10,000-person method but ends on the visibly false/incomplete `96% = 0.9`. Native preserves all supplied rates. |
| `long-context-expedition-log` | 4/5/—/3/4/0 | 3/5/—/3/4/0 | native slight win | The candidate remains source-faithful, recognizes all seven days and four text-only questions, and invents no identifier or fact, but extracts no requested answer. Native begins exact Day-1 fact extraction. |
| `long-context-incident-summary` | 3/5/—/3/4/0 | 3/3/—/2/4/0 | native win | The candidate preserves R41, feature flags, object-store metadata calls, latency, queues, manifests, and code review, but introduces a nonexistent `09:09` timestamp and reaches no summary or actions. |
| `instruction-json-only` | 0/3/—/0/4/0 | 0/3/—/0/4/0 | inherited fatal tie | Both start with prose, irreversibly violating the JSON-only envelope, while accurately preserving the requested fields and normalization rules. |
| `instruction-rewrite` | 3/5/—/2/4/0 | 3/5/—/2/4/0 | tie | The candidate preserves the full source note and every rewrite constraint but, like native, does not produce the requested final update. |

### Suffix192 + top-k4 relative aggregate

| Metric | Native | Suffix192 + top-k4 | Candidate delta |
|---|---:|---:|---:|
| Mean final-answer trajectory | 2.92 | 2.75 | -0.17 |
| Mean applicable correctness (`F/K`) | 4.25 | 3.83 | -0.42 |
| Mean instruction adherence | 2.58 | 2.50 | -0.08 |
| Mean coherence | 4.00 | 4.00 | 0.00 |
| Mean corruption severity | 0.00 | 0.00 | 0.00 |
| Adjusted quality total | 225/300 (75.00%) | 217/300 (72.33%) | **-2.67 percentage points** |

Pairwise result: **7 ties, 1 candidate win, and 4 native wins**. Suffix192 +
top-k4 retains **96.44%** of the native adjusted score.

### Suffix192 + top-k4 fatal failures and policy decision

- **Candidate-only fatal failures: 0.**
- **Inherited fatal failures: 1.** `instruction-json-only` violates the exact
  envelope in both reports.
- The probability arm has one candidate-only boundary-local math defect, and
  the incident arm has one false timestamp. Both are scored as material
  correctness regressions, not repetition, unrelated-task collapse, or a
  completed false answer.
- There are **zero `X >= 3` cases**, and every mean quality dimension remains
  inside the policy's 1.0-point loss limit.

**Semantic verdict: PASS for the explicit approximate policy.** The candidate
satisfies all four criteria:

1. 96.44% adjusted-score retention exceeds the 95% floor;
2. it introduces zero candidate-only fatal failures;
3. it has zero `X >= 3` cases;
4. its largest mean-dimension loss is 0.42 points.

The supplied B4x2K speed is **2.635x**, 0.135x above the 2.5x performance
threshold; it is performance context rather than a value independently
revalidated from this semantic artifact. Suffix192 + top-k4 is therefore the
first suffix-frontier candidate in note 079 to pass both the supplied
performance threshold and the explicit semantic screen.

This is an explicitly approximate, default-off research-screen PASS, not
semantic parity or a full ship gate. The visible math/timestamp regressions, the
inherited JSON-only failure, the small synthetic corpus, and the fixed
128-token analysis-heavy cutoff remain limitations. Notes 051–053 still require
larger task, long-state, distributional, open-generation, and confidence-bound
evaluations before deployment acceptance.
