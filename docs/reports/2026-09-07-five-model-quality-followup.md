# Five-model quality follow-up

> Last updated: 2026-09-07 · commit `72be6e10d`

The verified 0.9.0 runtime completes all nine jobs and their structural checks. All 12 arithmetic responses finish with correct answers. Matched code controls reproduce the earlier concerns on contiguous attention; GPT-OSS code and prose need a further matched control before their quality result can be attributed to the migration.

## Execution and answers

The run produces 36 response observations and 63 control rows in 776 seconds. All selected actual-width, request-isolation, cancellation, accounting and cleanup checks pass. The full collection verifies 448 original file hashes and sizes. No semantic verdict is inferred from the successful process exit.

| Model | Arithmetic follow-up | Other observations |
| --- | --- | --- |
| GPT-OSS 20B | Both repetitions of both problems finish correctly: 4 weeks and 172 items | All eight code/prose responses reach 1,024 tokens. Fractions reaches a final code block with an incorrect completed hash method, then truncates. The other tasks remain in repetitive analysis without the requested final result. |
| Gemma 4 26B QAT | Both responses finish correctly with 172 | Four contiguous code controls reproduce incomplete or incorrect continuation behavior seen with paged attention. |
| Qwen 3.5 | Both responses finish correctly with 172 | Four contiguous code controls reproduce the earlier concerns. |
| Qwen 3.6 | Both responses finish correctly with 172; wording differs | Four contiguous code controls reproduce the earlier concerns. |
| Qwen 3.8 | Both responses finish correctly with 172 | Four contiguous code controls reproduce the earlier concerns. |

The 16 contiguous code-control responses use the original 128-token budget. Their canonical prompt arrays exactly match the earlier paged probe: eight generated trajectories are identical, and eight differ. The latter still exhibit corresponding code problems on both backends. This establishes bounded comparative evidence, not successful code generation or universal model quality.

The arithmetic follow-ups use a 1,024-token cap. All 12 arithmetic responses stop naturally; the other 24 responses reach their respective caps. GPT-OSS contributes four correct arithmetic responses, two failed fractions responses and six inconclusive code/prose completions. Its repetitive analysis remains a quality concern. The next diagnostic holds its four unresolved tasks, exact prompts, date and budget fixed while changing only to contiguous attention; increasing the cap alone would not explain the behavior.

## Scope and provenance

All five arithmetic jobs use paged attention. The four non-GPT code jobs use contiguous attention to compare against the preserved earlier paged probe. SSD is off for this quality experiment. Qwen uses its normal embedded MTP configuration; GPT-OSS and Gemma QAT use ordinary decoding. Cache restoration, long generation, HTTP capabilities and routing retain separate acceptance checks.

The native executable and resources are the [verified final candidate](2026-09-07-release090-final-build.md). The subsequent [merged dependency pins](2026-09-07-release090-merged-dependency-pins.md) preserve its selected inference source. Earlier artifacts and reports retain their original identities.

The preceding attempt stopped before model execution because its operational Python wrapper did not accept the telemetry argument expected by the controller. The corrected wrapper restores the already-reviewed telemetry/provenance interface; native inference and semantic criteria are unchanged. The failed attempt is preserved separately.

## Evidence

The [result summary](evidence/five-model-quality-followup-2026-09-07/evidence.json) separates structural acceptance, semantic outcomes and outstanding controls. The [archive](evidence/five-model-quality-followup-2026-09-07/evidence.tar.gz) contains the nine original reports and inputs, metadata, step verdicts, retirement records, original collection manifest and separate manual reviews. An [independent publication review](evidence/five-model-quality-followup-2026-09-07/publication-review.json) checks the counts and selected original identities. Its [member manifest](evidence/five-model-quality-followup-2026-09-07/manifest.json) records each hash and size. Exported files use private local permissions; original file-mode equality is not claimed for that projection.

Related: [earlier short quality probe](2026-09-06-five-model-quality-probe.md), [acceptance criteria](../design/release-090-acceptance.md).
