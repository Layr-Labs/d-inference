# 077 — Frontier E4 blind 128-token semantic quality gate

Status: **FAIL even for an explicitly approximate, default-off cold-prefill
policy**

This review compares:

- native baseline: `artifacts/e30-quality-baseline-128.json`;
- frontier E4 candidate: `artifacts/e49-quality-frontier-e4-128.json`;
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
Run/profile labels, policy metadata, token IDs, checksums, token agreement,
common-prefix lengths, and timings did not enter any score.

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
  control-token leakage, or unrelated language/task collapse.

Each row contributes `T + F/K + I + C + (5 - X)`, at most 25. Because these
are forced fixed-length continuations, `T` judges the observed path rather than
requiring a complete answer. An already irreversible format violation still
scores immediately.

## Per-case scores

| Case | Native T/F/K/I/C/X | Frontier E4 T/F/K/I/C/X | Relative quality | Semantic judgment |
|---|---:|---:|---|---|
| `reasoning-rate-plan` | 3/5/—/3/4/0 | 1/2/—/1/2/0 | native win | The candidate retains cutting and polishing but misstates the explicit machine setup, turns the goal into “Starting workshop needs to be completed,” and spends the window correcting its prompt reconstruction. It never reaches a service time, schedule, or bottleneck. |
| `reasoning-constraint-order` | 3/4/—/3/4/0 | 0/0/—/0/2/2 | native win; candidate fatal | The candidate replaces the named talks and constraints with invented concepts including “First,” “Oracles,” and “Placement.” No valid ordering can follow from the visible reconstructed task. |
| `reasoning-estimation` | 3/4/—/3/4/0 | 1/2/—/1/1/3 | native win; candidate fatal | The candidate remains loosely on hikers and water but loops through the same attempted prompt reread, losing 37 hikers, 9 hours, the safety margin, arithmetic, and the drinking/non-drinking split. |
| `code-python-bug` | 3/—/3/3/4/0 | 1/—/1/1/2/1 | native win | The candidate says the supplied code was not provided, changes “contiguous run of equal values” into a generic sequence problem, and emits neither diagnosis, implementation, nor tests. |
| `code-swift-actor` | 2/—/3/2/4/0 | 2/—/3/2/4/0 | tie | Both accurately restate the actor, expiration, compactness, and Swift 6 direction but emit no implementation, Sendable explanation, or usage example. |
| `factual-heat-pump` | 3/4/—/3/4/0 | 3/4/—/3/4/0 | tie | Both remain on the correct COP-greater-than-one and real-world-performance trajectory but stop before giving the conservation equation, heat source, or two conditions. |
| `factual-database-index` | 4/5/—/3/4/0 | 0/0/—/0/0/5 | native win; candidate fatal | After failing to retain that the comparator is a hash index, the candidate collapses into an `each` loop for nearly the whole continuation. No comparison or query pattern survives. |
| `factual-probability` | 4/5/—/3/4/0 | 1/1/—/1/2/1 | native win | The candidate repeatedly confuses sensitivity with a generic “96% positive/negative” rate, loses specificity and prevalence, and performs no cohort arithmetic or PPV calculation. |
| `long-context-expedition-log` | 4/5/—/3/4/0 | 0/0/—/0/2/3 | native win; candidate fatal | The candidate recasts the log as a game/story and fabricates a shifted Day 2→6, Day 3→7, Day 4→8, Day 5→9 sequence. It preserves none of the requested identifiers or answers. |
| `long-context-incident-summary` | 3/5/—/3/4/0 | 0/0/—/0/0/5 | native win; candidate fatal | The candidate mutates `R41` to `R4`, repeats that token through most of the window, and supplies no root cause, factors, or follow-up actions. |
| `instruction-json-only` | 0/3/—/0/4/0 | 0/0/—/0/2/2 | inherited fatal; native win | Both irreversibly violate the exact JSON-only envelope by starting with prose. The candidate additionally invents a requirement to include `success` and loses the actual keys and normalization task. |
| `instruction-rewrite` | 3/5/—/2/4/0 | 0/0/—/0/3/3 | native win; candidate fatal | The candidate substitutes an unrelated exactly-seven-step action-plan prompt and preserves none of the incident facts, tone, length, or required final next step. |

## Relative aggregate

| Metric | Native | Frontier E4 | Candidate delta |
|---|---:|---:|---:|
| Mean final-answer trajectory | 2.92 | 0.75 | -2.17 |
| Mean applicable correctness (`F/K`) | 4.25 | 1.08 | -3.17 |
| Mean instruction adherence | 2.58 | 0.75 | -1.83 |
| Mean coherence | 4.00 | 2.00 | -2.00 |
| Mean corruption severity | 0.00 | 2.08 | +2.08 |
| Adjusted quality total | 225/300 (75.00%) | 90/300 (30.00%) | **-45.00 percentage points** |

Pairwise result: **2 ties, 0 candidate wins, and 10 native wins**. Frontier E4
retains only **40.00%** of the native adjusted score.

## Fatal failures

For this screen, a fatal case is one whose visible continuation is already
unusable because it irreversibly breaks an exact output contract, collapses
into catastrophic repetition, substitutes an unrelated task, or fabricates
source facts/identifiers.

- **Candidate-only fatal failures: 6.**
  `reasoning-constraint-order`, `reasoning-estimation`,
  `factual-database-index`, `long-context-expedition-log`,
  `long-context-incident-summary`, and `instruction-rewrite`.
- **Inherited fatal failures: 1.** `instruction-json-only` breaks the output
  envelope in both reports; the candidate also corrupts the task within that
  already-failed case.
- Two candidate-only continuations reach corruption severity 5 through hard
  repetition. Three more reach severity 3 through repetition or unrelated-task
  collapse.
- The candidate emits no executable code, so there is no incorrect
  implementation to run; both code cases instead fail to produce one, and the
  Python case additionally loses the supplied source and bug definition.

## Explicit approximate cold-prefill policy

The prior research notes did not preregister a numeric acceptance rule for this
small 12-case screen. To make this decision auditable rather than relying on an
informal “looks acceptable” judgment, a deliberately permissive,
research-screen policy for a named, default-off approximate cold-prefill mode
is:

1. retain at least **95%** of the native adjusted score;
2. introduce **zero candidate-only fatal cases**;
3. contain **zero cases with `X >= 3`** corruption;
4. lose no more than **1.0 mean point** in trajectory, applicable correctness,
   instruction adherence, or coherence.

This rule is formalized after E49 was generated, so even a PASS would not be a
prospective non-inferiority result. That limitation cannot affect this
decision: Frontier E4 misses all four thresholds by wide margins—40% score
retention, six candidate-only fatal cases, five `X >= 3` cases, and mean losses
of 1.83–3.17 points.

The screen is also weaker than the frozen Q0–Q4 ship gate in notes 051–053,
which requires larger task, long-state, open-generation, distributional, and
paired-confidence evaluations. Passing this screen could only justify more
evaluation; failing it rejects the policy immediately.

## Verdict

**FAIL.** Do not retain, ship, or describe the E4 frontier state river as a
usable approximate cold-prefill profile. It is not a marginal trajectory loss:
the candidate repeatedly loses the prompt, fabricates tasks and source facts,
collapses into loops, and fails every requested answer or implementation within
the fixed window.

The result rejects the E4 policy as measured. It does not reject the broader
state-river mechanism: a materially more conservative frontier (more complete
layers, sensitivity-guided restoration, or another state construction) would
need a new artifact and a fresh blind gate against the same native baseline.
