# 063 — E24 top-k4 blind 64-token quality gate

Status: **PASS for an explicitly approximate prefill profile**

This review compares:

- baseline: `artifacts/e23-quality-baseline.json`
  (`baseline-top8-all-layers`);
- candidate: `artifacts/e24-quality-topk4.json`
  (`topk4-all-layers`).

The reports use the same corpus SHA-256
`9986606cac444cfbe22d6b2d1d4a9ce1b95036255e30d5bc972740dbcb27e575`,
the same model-artifact SHA-256
`d932e96b00404b0575fff47e2dac8ed113056b3f22d0040c3c8d3f9ef25b09ed`,
greedy decoding, and 64 generated tokens for every one of the 12 cases.
Candidate policy metadata sets
`DARKBLOOM_QWEN35_PREFILL_MOE_TOP_K=4`.

## Rubric

The continuation text was judged semantically against its prompt; token
identity, common-prefix length, and checksums were not quality requirements.

- `R` relevance: 0 unrelated, 5 directly on task.
- `C` coherence: 0 unusable, 5 clear and internally consistent.
- `F` factual trajectory: 0 wrong direction, 5 correct and specific direction.
- `I` instruction adherence: 0 irreversibly violates an explicit constraint,
  5 satisfies every observable constraint.
- `X` language-corruption severity: 0 clean, 5 catastrophically corrupted.

For one comparable quality total, each row contributes
`R + C + F + I + (5 - X)`, at most 25. Because every sample is a forced
64-token continuation ending with `finishReason=length`, the review scores the
observed trajectory rather than demanding a complete answer. Irreversible
format violations still count immediately.

## Per-case scores

| Case | Baseline R/C/F/I/X | Top-k4 R/C/F/I/X | Relative quality | Strict judgment |
|---|---:|---:|---|---|
| `reasoning-rate-plan` | 5/4/4/3/0 | 5/4/4/3/0 | tie | Both correctly frame the two-stage pipeline and remain coherent; neither reaches the schedule or bottleneck within 64 tokens. |
| `reasoning-constraint-order` | 5/4/4/3/0 | 5/4/4/3/0 | tie | Both identify the complete constrained-ordering task without inventing a placement. |
| `reasoning-estimation` | 5/4/4/3/0 | 5/4/4/3/0 | tie | Both retain group size, duration, and warm-weather planning context; neither reaches assumptions or arithmetic yet. |
| `code-python-bug` | 5/4/4/3/0 | 5/4/4/3/0 | tie | The continuations are identical and correctly identify the function and two fault classes, but stop before the fix. |
| `code-swift-actor` | 5/4/4/3/0 | 5/4/4/3/0 | tie | Both preserve actor, key/value, and deadline requirements with no Swift error introduced. |
| `factual-heat-pump` | 5/4/4/3/0 | 5/4/4/3/0 | tie | Both correctly frame delivered heat versus electrical work and conservation; no false physical claim appears. |
| `factual-database-index` | 5/4/4/3/0 | 5/4/4/3/0 | tie | Both set up the requested B-tree/hash comparison and criteria without product-specific drift. |
| `factual-probability` | 5/4/5/3/0 | 5/4/5/3/0 | tie | Baseline names the supplied rates; top-k4 names PPV and prevalence. Both are correct trajectories toward Bayes/cohort arithmetic. |
| `long-context-expedition-log` | 5/4/4/3/0 | 5/4/4/3/0 | tie | Both recognize the four log-grounded questions and exact-detail constraints; neither hallucinates an identifier. |
| `long-context-incident-summary` | 5/4/4/3/0 | 5/4/4/3/0 | tie | The continuations are identical and stay on root cause, contributing factors, and three actions. |
| `instruction-json-only` | 4/4/4/0/0 | 4/4/4/0/0 | fatal tie | Both start with prose and Markdown-like analysis. That immediately makes “exactly one JSON object and no Markdown” impossible. |
| `instruction-rewrite` | 5/4/4/2/0 | 5/4/3/1/0 | baseline slight win | Baseline begins separating fact from emotional wording. Top-k4 merely restates the note and is less advanced toward the requested calm 70–100-word update. |

## Aggregate relative quality

| Metric | Baseline | Top-k4 | Candidate delta |
|---|---:|---:|---:|
| Mean relevance | 4.92 | 4.92 | 0.00 |
| Mean coherence | 4.00 | 4.00 | 0.00 |
| Mean factual trajectory | 4.08 | 4.00 | -0.08 |
| Mean instruction adherence | 2.67 | 2.58 | -0.08 |
| Mean corruption severity | 0.00 | 0.00 | 0.00 |
| Adjusted quality total | 248/300 (82.67%) | 246/300 (82.00%) | **-0.67 percentage points** |

Pairwise result: **11 ties, 0 top-k4 wins, 1 baseline win**. Top-k4
retains **99.19%** of the baseline adjusted score under this rubric.

The artifact's two exact cases and 55.99% token-position agreement are useful
diagnostics, but neither value affects this semantic verdict.

## Fatal failures

- **Candidate-only fatal failures: 0.**
- **Inherited fatal failures: 1.** `instruction-json-only` irreversibly violates
  the output format in both reports.
- No candidate continuation contains garbled language, repetition collapse,
  special-token leakage, an unrelated answer, or a factual contradiction.
- `instruction-rewrite` is an inherited direct-answer weakness and the sole
  visible candidate regression, but it is coherent rather than corrupted.

## Verdict

**PASS** for shipping top-k4 as a clearly named, explicitly approximate prefill
profile. The candidate introduces no fatal failure or language corruption, and
its small aggregate loss is confined to one already-weak instruction case.

This is a relative screening pass, not proof of full-answer parity. The corpus
has only 12 prompts, and the 64-token cap stops every ordinary case during an
analysis preamble. It does not establish final-answer correctness, exact-format
success, tool behavior, or long-generation stability; top-k4 should not be
described as exact or silently substituted for the baseline profile.
