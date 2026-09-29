# Qwen3.8 calibrated admission qualification

> Last updated: 2026-09-28 · commit `d89ef42be`

The initial dedicated M5 Max screen completed real Qwen3.8 inference with active
MTP. It is **screening evidence, not a qualified serving profile**: the initial
host was in High Power mode, and independent deadline/lifecycle qualification
had not completed. A fresh 9,000-body prompt-count corpus passed all six bounded
fallback cells after the initial smaller corpus failed. Deadline timing profiles
still require final-candidate qualification; no concurrency/chunk default is
certified by this screen.

## Hardware and artifact

The user selected an Apple M5 Max with 40 GPU cores, 128 GiB unified memory and
18 CPU cores, running macOS 26.5.2 and Swift 6.3.1. The installed provider was
stopped through its normal drain path: one accepted request drained, the
coordinator acknowledged the drain, and the service remained stopped. No
coordinator deployment or provider installation was made.

The target was `EigenLabs/Qwen3.8-27B-4bit-mtp`, with verified serving hash
`bbd0e0adcfe74e095073fefd0b9e116e4311d606ad9989cf81f8175e8ac18463`.
All four weight files, configuration, template and tokenizer were freshly
SHA-256 checked on that host. The [artifact inventory](evidence/2026-09-28-calibrated-admission/qwen38-artifact-files.json)
matches the combined target/inline-MTP artifact from catalog revision
`06d517d395dfc5588090f7f534112bee331f7b4a`. No separate assistant or similarly
named historical Qwen4 checkpoint was substituted.

The screen used the production engine/OpenAI streaming path, paged KV and
configured context 262,144. Actual inline MTP was active: maximum draft depth
7, maximum speculative batch 8, rectangular verification, automatic-rectangular
limit 0. Its assistant identity was inline index SHA-256
`8bf770b4b22fa4cffe3000a16314c41ea52d7556ad1acafb2e7bb33d96fd4e23`.
The verified prompt contract was
`2dcff358f55d07c26bf238d15184148b78b50dc277e59ae7ef9a758534687064`.

## Initial cold screen

The optimized release binary used `-enable-testing`, without `DEBUG`. Its
explicitly dirty source snapshot was based on `d89ef42be`, with Swift source
hash `f0c0eab12eab8784002e4bd20b3848744bed5bab5422190d6140919724913295`.
The matched metallib hash was
`20972c37e53fe6db3b3191a0434f6604c4ffc4f5ac62b370574f9922585b0fdb`.
[Provenance](evidence/2026-09-28-calibrated-admission/m5-initial-screen/provenance.json),
[raw numeric receipts](evidence/2026-09-28-calibrated-admission/m5-initial-screen/receipt.json)
and [derived results](evidence/2026-09-28-calibrated-admission/m5-initial-screen/summary.json)
are preserved together.

Each point used three sequential executions, one active request and 128 output
tokens. Fixed synthetic padding is sufficient for this screen; changing its
trial nonce does not establish an independent calibration workload. The engine
cap was one, so these results also do not certify a larger ordinary serving cap.

| Actual prompt | First-content range | Confirmed-token decode range | Outcome |
|---:|---:|---:|---|
| 4,096 | 4.468–4.862 s | 85.26–87.70 tokens/s | 3 completed |
| 16,384 | 22.508–22.759 s | 67.48–71.33 tokens/s | 3 completed |
| 32,768 | 46.646–47.520 s | 50.57–53.97 tokens/s | 3 completed |

Actual MTP rounds and accepted token counts were observed, without dropped
observations or ordinary-request retirement/accounting failures. Decode rates
use first-to-last confirmed-token time; host content-frame gaps remain separate.
Cold 16k and 32k actually exceeded a 20-second first-content budget. Removing a
conservative multiplier cannot make these measured executions finish on time.

Explicit post-screen inspection found `powermode 2` on AC and battery. A false
`ProcessInfo.isLowPowerModeEnabled` did not exclude High Power mode, so the
screen cannot certify Automatic-mode behavior. The supervisor now records
actual current-source power policy before and after each run. After the user
supplied authorized privileged access, both sources were changed to Automatic
and verified at `powermode 0`; original values were recorded for restoration.
Final qualification needs a new signed-candidate run in that posture. Earlier
measurements are not relabeled.

## Automatic-mode sustained cohort

A subsequent clean signed candidate `5e8fbcfc15292b8c83773609d76c7d341073c0b4`
with SDK `5df381f4b27d5bb63c2905ddb6599e7f4bd62d28` completed all 40
independently generated 4k–12k tool/history training requests. The executing
release image reported `DEBUG=false`, debug assertions disabled, and SHA-256
`aadbbcab068d403e90e82e587e3f69f3f9cc44deeeb58db351a13e4044b73046`.
Actual source, artifact and executable hashes remained unchanged throughout.

This cohort **failed qualification**: the first eight requests ended nominal,
then all remaining 32 ended in fair thermal state. Automatic power policy
remained enabled. First-content times ranged from 4.497 to 16.797 seconds;
confirmed-token decode ranged from 48.79 to 86.36 tokens/s. There were no request,
retirement or observation failures, but numerical completion does not satisfy
the nominal-only posture gate. The complete [40-request receipt](evidence/2026-09-28-calibrated-admission/m5-automatic-sustained/receipt.json),
[supervisor provenance](evidence/2026-09-28-calibrated-admission/m5-automatic-sustained/provenance.json),
[derived measurements](evidence/2026-09-28-calibrated-admission/m5-automatic-sustained/summary.json)
and [failed qualification status](evidence/2026-09-28-calibrated-admission/m5-automatic-sustained/qualification-status.json)
retain every observation. No held-out cohort was run against this failing
training cohort, and its hot observations are not removed to obtain a pass.

Fresh training and validation will use a predeclared minimum 20-second cooldown
before each measured request, followed by at least five continuous nominal,
non-Low-Power seconds, with a 180-second recovery limit. Before/after posture
and 500-ms observations during inference are retained; any observed fair state
invalidates the cohort. This qualification applies only while the provider's
existing nominal-only activation gate holds. It does not change fan policy or
claim a sustained fair-temperature serving default.

## Initial rendered-count corpus

The actual tokenizer/template rendered 504 synthetic chat bodies in 39.94
seconds, with zero template failures. The production Go routing estimator and
shape extractor consumed the exact original JSON bytes. The declared stress
distribution includes prose, code, JSON, multilingual text, identifiers,
Markdown, schemas, assistant tool calls and tool results; it is not a sample of
customer traffic.

Each group had 24 independent training and 60 held-out bodies. Training alone
fit its upper count bound and serialized-shape domain. Out-of-domain held-out
bodies remained uncovered in the denominator.

| Group | Covered / held out | Outside training domain | Qualified |
|---|---:|---:|---|
| Plain, first size band | 56 / 60 | 3 | No |
| Plain, second size band | 55 / 60 | 5 | No |
| Plain, third size band | 51 / 60 | 8 | No |
| Tools/history, first size band | 33 / 60 | 21 | No |
| Tools/history, second size band | 45 / 60 | 13 | No |
| Tools/history, third size band | 39 / 60 | 18 | No |

The [provider counts](evidence/2026-09-28-calibrated-admission/prompt-count-initial-receipt.json),
[Go projections](evidence/2026-09-28-calibrated-admission/prompt-count-initial-projections.jsonl)
and [failed review](evidence/2026-09-28-calibrated-admission/prompt-count-initial-review.json)
preserve every observation. None may populate a reviewed fallback catalog.

## Qualified rendered-count corpus

A fresh predeclared 9,000-body corpus used seed `20261001`, with 1,000 training
and 500 held-out observations per group. Actual tokenizer/template collection
completed in 707.87 seconds with no rendering failures. Training and validation
bodies were independently generated; the larger corpus did not reuse the
failed corpus or expand domains using held-out shapes.

| Group | Estimated-token domain | Covered / held out | Outside training domain | 95% coverage lower bound |
|---|---:|---:|---:|---:|
| Plain, first size band | 3,327–4,192 | 498 / 500 | 1 | 98.746% |
| Plain, second size band | 13,173–16,461 | 498 / 500 | 2 | 98.746% |
| Plain, third size band | 26,276–32,839 | 498 / 500 | 1 | 98.746% |
| Tools/history, first size band | 3,341–4,203 | 495 / 500 | 5 | 97.909% |
| Tools/history, second size band | 13,172–16,485 | 493 / 500 | 7 | 97.387% |
| Tools/history, third size band | 26,285–32,876 | 493 / 500 | 6 | 97.387% |

All six pass the predeclared one-sided 95% confidence lower bound of 95%.
Out-of-domain and uncovered observations stay in the denominator. The measured
upper ratios of 3.479–3.515 and additive terms reflect this deliberate tokenizer
stress distribution; they are not estimates of median customer traffic.
Applicability also requires every serialized body/message/tool/history shape
field to fall inside its training-only domain, plus the exact artifact and
prompt contract above. Outside those domains the fallback remains heuristic.

The [numeric provider receipt](evidence/2026-09-28-calibrated-admission/prompt-count-qualified-receipt.json),
[canonical Go projections](evidence/2026-09-28-calibrated-admission/prompt-count-qualified-projections.jsonl)
and [qualified candidate review](evidence/2026-09-28-calibrated-admission/prompt-count-qualified-review.json)
are linked by combined evidence SHA-256
`73b526e3df76ee31f409e8a6e74a228c419a85342d67cdd9bbf4b1f3bbf12ad9`.
These CPU-only exact-render receipts qualify prompt-count fallback bounds;
they do not qualify engine timing or hardware scheduling policy.

Exported confidence lower bounds are rounded downward to 12 decimal places.
This conservative rounding avoids an amd64/arm64 last-bit difference at the
strict binomial threshold; it changes no observations, fitted coefficients,
shape domains or acceptance threshold. Raw counts and the evidence digest
remain unchanged. The collector now verifies actual weight/configuration bytes
before and after counting, and a fresh verification run is required before
retaining these reviewed records on the final candidate.
All six records are promoted unchanged in `coordinator/api/promptwork/catalog/`.
Regression tests reproduce every held-out covered count and exercise all 6,000
training shapes through the production estimator.

## Qualification boundaries and reproduction

The [qualification procedure](../developer/serving-performance-qualification.md)
contains release-build, supervised-runner, corpus and evaluator commands.
Numeric receipts contain observation-local row ordinals, counts, relative
clocks, hashes and configuration. They do not contain prompt/output text,
token IDs or customer identifiers. Synthetic inputs stay in temporary files.
No production request body was used or retained.

Universal concurrency/chunk promotion retains the full configured-context
matrix, actual forward widths and the original throughput/gap/tail gates.
Separate deadline-only profiles can cover a narrower measured prompt/context
band while binding the full engine configuration. They cannot raise concurrency,
change chunk policy, lower memory reserves or qualify out-of-cell work. The
next cohort declares 4k–12k, both endpoints and varied actual tool/history
bodies, covering the incident's 8,828-token example without extrapolating 4k.

Actual cancellation checks must prove prefill and post-MTP-content cancellation,
native KV/service-lease retirement, exact partial-work accounting and unchanged
subsequent greedy output. Ordinary successful requests do not satisfy these
checks. Independent deadline validation requires 95% coverage with a one-sided
95% confidence lower bound at least 95%; refused/censored failures stay visible.

[Aggregate monitoring SQL and definitions](../../scripts/serving_performance/monitoring/README.md)
separately measure logical 429s, real first-content timeouts, matched prompt-band
p50/p95 and attempts per logical request. Production telemetry has no individual
confirmed-token-gap distribution; dedicated engine receipts supply that metric.
No new production query or before/after success claim accompanies this screen.
