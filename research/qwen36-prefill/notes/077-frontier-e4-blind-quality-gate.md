# 077 — Frontier E4/E8 blind 128-token semantic quality gate

Status: **E4 and E8 both FAIL even for an explicitly approximate, default-off
cold-prefill policy**

This review compares:

- native baseline: `artifacts/e30-quality-baseline-128.json`;
- frontier E4 candidate: `artifacts/e49-quality-frontier-e4-128.json.gz`;
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

## E8 follow-up

The more conservative E8 candidate in
`artifacts/e49-quality-frontier-e8-128.json.gz` uses the same committed prompts,
corpus/model hashes, greedy fixed-length generation, and 128-token cutoff as the
native report. Its semantic score again excludes run/profile labels, policy
metadata, token identity, checksums, agreement, prefixes, and timing.

Unlike E4, E8 is prospective relative to this note's explicit approximate
screen: commit `273cafe7` fixed the four criteria above at
`2026-08-24T20:03:06Z`, while the E8 report records creation at
`2026-08-24T20:05:38.624Z`.

### E8 per-case scores

| Case | Native T/F/K/I/C/X | Frontier E8 T/F/K/I/C/X | Relative quality | Semantic judgment |
|---|---:|---:|---|---|
| `reasoning-rate-plan` | 3/5/—/3/4/0 | 2/3/—/2/3/0 | native win | E8 correctly retains the cutter, polisher, and operation order, but incorrectly treats the explicit precedence as an assumption and stops before the 4/6-minute rates, schedule, result, or bottleneck. |
| `reasoning-constraint-order` | 3/4/—/3/4/0 | 0/0/—/0/2/3 | native win; candidate fatal | E8 treats prompt words such as “Five,” “every,” “valid,” and “briefly” as puzzle entities. The named talks and every ordering constraint disappear. |
| `reasoning-estimation` | 3/4/—/3/4/0 | 3/4/—/3/4/0 | tie | Both preserve the 37 hikers, 9 hours, warm weather, assumptions, and safety-margin direction, then stop before selecting rates or doing arithmetic. |
| `code-python-bug` | 3/—/3/3/4/0 | 1/—/1/1/2/1 | native win | E8 falsely says the function does not track run length, then mutates `longest_run` into a different partial function. It provides neither the actual two-fault diagnosis, a correction, nor tests. |
| `code-swift-actor` | 2/—/3/2/4/0 | 1/—/2/1/3/1 | native win | E8 keeps keyed strings, expiration, and concurrency as topics but makes `actor` only one option beside `struct`/`class`, loses the exact `ExpiringCache` API and stale-delete behavior, and emits no Swift code. |
| `factual-heat-pump` | 3/4/—/3/4/0 | 4/5/—/3/4/0 | E8 win | E8 correctly reaches the substantive mechanism: a heat pump moves environmental heat, COP can exceed one, and conservation includes electrical work plus transferred heat. It still stops before naming two degrading conditions. |
| `factual-database-index` | 4/5/—/3/4/0 | 4/5/—/3/4/0 | tie | E8 correctly retains B-tree versus hash, equality, ranges, write amplification, and generality, then begins accurate B-tree characteristics. Like native, it does not complete both query examples. |
| `factual-probability` | 4/5/—/3/4/0 | 2/3/—/2/3/1 | native win | E8 correctly identifies PPV and the low-prevalence issue but loops on whether 96% is sensitivity or specificity, loses 92%, 3%, and 10,000, and performs no calculation. |
| `long-context-expedition-log` | 4/5/—/3/4/0 | 1/1/—/1/2/3 | native win; candidate fatal | E8 recognizes an expedition question but invents `Team 1`/`Team 2` as prompt content, extracts no authoritative identifier, and reaches none of the four answers. |
| `long-context-incident-summary` | 3/5/—/3/4/0 | 1/1/—/1/3/2 | native win; candidate fatal | E8 notices attachments and manifests but invents a side effect in which R40 workers unexpectedly handle load. It misses the repeated inner-loop fetch, process-local flag, stable database, and required actions. |
| `instruction-json-only` | 0/3/—/0/4/0 | 0/0/—/0/0/5 | inherited fatal; native win | Both violate the JSON-only envelope immediately. E8 additionally corrupts the supplied sentence into a continuation-long `Hello` loop, producing neither JSON nor any requested field. |
| `instruction-rewrite` | 3/5/—/2/4/0 | 3/5/—/2/4/0 | tie | Both accurately separate concrete facts from emotional language and preserve the delayed/recovered record counts, but neither reaches the 70–100-word update or final next step. |

### E8 relative aggregate

| Metric | Native | Frontier E8 | Candidate delta |
|---|---:|---:|---:|
| Mean final-answer trajectory | 2.92 | 1.83 | -1.08 |
| Mean applicable correctness (`F/K`) | 4.25 | 2.50 | -1.75 |
| Mean instruction adherence | 2.58 | 1.58 | -1.00 |
| Mean coherence | 4.00 | 2.83 | -1.17 |
| Mean corruption severity | 0.00 | 1.33 | +1.33 |
| Adjusted quality total | 225/300 (75.00%) | 149/300 (49.67%) | **-25.33 percentage points** |

Pairwise result: **3 ties, 1 E8 win, and 8 native wins**. E8 retains
**66.22%** of the native adjusted score. It improves materially over E4's
90/300 and six candidate-only fatal cases, but remains far outside the accepted
region.

### E8 fatal failures and decision

- **Candidate-only fatal failures: 3.**
  `reasoning-constraint-order`, `long-context-expedition-log`, and
  `long-context-incident-summary`.
- **Inherited fatal failures: 1.** `instruction-json-only` already violates
  the envelope in native; E8 adds an independent catastrophic repetition mode
  within that failed case.
- E8 has three `X >= 3` cases: the ordering-task substitution, expedition
  source corruption, and repeated-`Hello` collapse.
- E8 breaches the policy's mean-loss limit in trajectory (-1.08), applicable
  correctness (-1.75), and coherence (-1.17); instruction adherence lands
  exactly on the -1.00 boundary.

**FAIL; not a viable quality frontier.** E8 fails every top-level acceptance
criterion: 66.22% score retention is below 95%, it adds three fatal cases and
three `X >= 3` cases, and three mean dimensions exceed the allowed loss.

The supplied B4x2K performance context is **2.41x**, 0.09x below the 2.5x
research objective; that measurement is not contained in the semantic-quality
artifact and is therefore not independently revalidated here. E8 is a
directional quality improvement over E4, but trading away speed still leaves
severe prompt loss and corruption. It is outside both the measured performance
target and the semantic feasible region, so it should not be retained as the
quality/speed frontier.
