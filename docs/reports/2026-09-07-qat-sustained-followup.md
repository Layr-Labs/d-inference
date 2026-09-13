# QAT sustained generation and matched prompt control

> Last updated: 2026-09-07 · commit `32a756317`

Gemma 4 26B QAT sustains paged generation for more than 18 seconds on a 19,711-token, nonrepetitive prompt, with direct batch-one forward traces and clean cancellation, accounting and retirement. Its earlier short refusal also reproduces on contiguous attention with the identical request. The exact 2,048-token benchmark verdicts remain failed: the new paged responses end naturally at 1,878 tokens, while the matched contiguous responses reach their 2,048-token cap.

## Results

| Request and backend | Prompt tokens | Main output tokens | Decode seconds | Original gate result |
| --- | ---: | ---: | --- | --- |
| Original repetitive request, paged (142) | 21,621 | 70 / 62 | 0.670 / 0.593 | Sustained exposure failed |
| Identical original request, contiguous (145) | 21,621 | 64 / 64 | 0.709 / 0.710 | Diagnostic controls passed; no sustained claim |
| New nonrepetitive request, contiguous (145) | 19,711 | 2,048 / 2,048 | 22.823 / 22.803 | Exact sustained gate passed |
| Same new request, paged (145) | 19,711 | 1,878 / 1,878 | 18.047 / 18.089 | Exact token-count/finish gate failed |

Both backends refuse the original request because it asks for 160 tightly constrained entries over repeated padding. This matched control shows that the refusal is not specific to paged attention. The new request uses a contiguous excerpt from the previously frozen Alice corpus and asks for a detailed reading companion, explicitly allowing a partial draft. It preserves normal model behavior, the 2,048-token output cap, production memory grants, disabled MTP and disabled SSD caching.

The two new paged responses are identical, coherent literary prose with natural stopping. Their observed target and compiled-component traces have one live and physical batch row; no abandoned, dropped, pending or unobserved calls are reported. The original strict failure consists of the two main-row token-count/finish checks, with no additional input, ordering, width, cancellation or accounting error. The three owned processes retire completely, and all 203 original evidence files are verified.

A retained tenant-control response from 142 also generated 2,048 tokens over 20.193 seconds on paged attention at a 21,621-token prompt. That control has no direct per-request forward-shape trace. It supplies additional duration and token exposure; the new 145 main rows supply the direct batch-one traces. Neither observation rewrites the failed 142 or 145 main-row verdict.

## Quality and acceptance scope

The new outputs satisfy the purpose of an extended, coherent writing workload. They do not establish perfect literary accuracy or delivery of the suggested 5,000-word draft. Review found factual detail errors on both backends: the contiguous text links “curiouser” to shrinking and misattributes Alice's C/D initials to the Mouse; the paged text attributes growth to liquid and places the feet/boots discussion during shrinking. These limits remain recorded alongside the full outputs.

The combined evidence supports sustained paged exposure separately from the preserved exact-cap benchmark failures. Root explicitly accepts the combined evidence for the release’s sustained-workload requirement. This separate release assessment does not replace either failed benchmark verdict. This is one artifact and one long-form request pair; it does not establish general answer quality, multibatch throughput or persistent SSD behavior. Gemma 8-bit is outside the release scope.

## Evidence

The [summary](evidence/qat-sustained-followup-2026-09-07/evidence.json), [selected original evidence](evidence/qat-sustained-followup-2026-09-07/evidence.tar.gz) and [member manifest](evidence/qat-sustained-followup-2026-09-07/manifest.json) retain the original requests, outputs, forward traces, failed verdicts, runtime bindings and cleanup records. The capsule is a publication projection; it does not claim original filesystem modes. Full original archives remain retained.

The native binary and QAT artifact are unchanged from the [verified final build](2026-09-07-release090-final-build.md). See the [release acceptance criteria](../design/release-090-acceptance.md) for the distinction between model wording, material regressions, actual workload exposure and cache correctness.
