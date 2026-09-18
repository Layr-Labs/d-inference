# Five-model quality probe: integrity passes, answer quality remains open

> Last updated: 2026-09-06 · commit `2eebb5412`

All five model jobs pass native integrity checks, but the short output budgets do not establish representative answer quality: 58 of 60 responses hit their caps. Final semantic review records two passing responses, 14 failing responses across seven code tasks, and 44 inconclusive responses; these results alone do not establish a paged-attention migration defect.

## Scope and outcomes

Run `126-serving-quality-grouped1` uses the [reviewed candidate](2026-09-06-release090-candidate-build.md), runtime104 version `0.8.16`, with paged attention, SSD disabled and actual B1 execution. It tests `qwen3.5-35b-a3b`, `qwen3.6-35b-a3b-vl-mtp-mxfp8`, `EigenLabs/Qwen3.8-27B-4bit-mtp`, `gpt-oss-20b` and `gemma-4-26b-qat-4bit`. Qwens use embedded MTP; GPT-OSS and Gemma QAT use ordinary generation.

Each model receives the same six short prose, code and reasoning tasks from the [frozen representative cohort](2026-09-06-representative-quality-cohort.md), with first/repeat observations. All 60 responses and 35 separate native control rows pass integrity, accounting and lifecycle gates; all 30 first/repeat pairs match. Those checks do not grade the answers. Output caps are 128 tokens for prose/code and 256 for reasoning; matching repeats are not independent quality samples.

The two stopped responses are one repeated Gemma QAT solution correctly concluding four weeks. Its model turn delimiter is presentation metadata, not a wrong mathematical answer. Other sound but unfinished responses remain inconclusive. Raw native GPT analysis-channel output does not itself demonstrate an HTTP reasoning leak or a completed final-answer format violation.

Seven code tasks contain substantive errors visible before their caps, each reproduced in both observations:

| Model | Continuation | Observed error |
|---|---|---|
| Gemma QAT | Fractions | Comparisons assume the other operand has Fraction private fields, breaking mixed numeric comparisons. |
| Gemma QAT | Functools | Replacement lookup searches only the concrete MRO, losing virtual-ABC dispatch. |
| Qwen3.5 | Fractions | Inverse can construct a negative denominator. |
| Qwen3.5 | Functools | Registration statements appear in unreachable code inside the preceding type helper. |
| Qwen3.6 | Fractions | Truncation floors negative values instead of truncating toward zero. |
| Qwen3.8 | Fractions | The stated rational divmod contract is impossible for fractional inputs. |
| Qwen3.8 | Functools | Registration can leave stale dispatch-cache entries and mishandles union registration. |

## Evidence and remaining work

The [summary](evidence/five-model-quality-probe-2026-09-06/evidence.json) binds all results. Root verification checks all 296 original files and five exact before/after source, runtime and full-model audit pairs. The [capsule](evidence/five-model-quality-probe-2026-09-06/evidence.tar.gz) preserves 20 original files plus ten review, rubric and source-notice files, including independent blind review and final root adjudication. Its [archive receipt](evidence/five-model-quality-probe-2026-09-06/archive.json) binds all 30 members; original reports remain unchanged. Generated code was not executed.

Prepared follow-up `130` separates two questions: six GPT tasks and the other four models' GSM8K528 tasks receive 1,024-token budgets; eight original non-GPT code tasks receive matched contiguous baselines at the original 128-token cap. These runs are pending in this record. Cap exhaustion is an experiment limit; observed code errors need baseline comparison before attribution to migration. This small cohort is not an official benchmark score, and neither runtime integrity nor this probe closes release-wide quality acceptance.
