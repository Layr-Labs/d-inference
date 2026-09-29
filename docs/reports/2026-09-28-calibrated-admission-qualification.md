# Qwen3.8 calibrated admission qualification

> Last updated: 2026-09-28 · commit `ad42fb0ce`

The initial dedicated M5 Max screen completed real Qwen3.8 inference with active
MTP. It is **screening evidence, not a qualified serving profile**: the initial
host was in High Power mode, and independent deadline/lifecycle qualification
had not completed. A fresh 9,000-body prompt-count corpus passed all six bounded
fallback cells after the initial smaller corpus failed. A fresh cooled cohort
completed all 40 training trials; its independently generated 100-trial
validation cohort completed with all 100 observations covered by the frozen
bound and no posture/runtime failures. The closest observation retained
1,047.625 ms of coverage margin. Authoritative lifecycle checks passed on the isolated observer correction.
Strict evaluation qualified the narrow cooled deadline profile; final-build
admission proof remains outstanding, and no concurrency/chunk default is certified.
This first deadline-policy revision is AC-only: both measured cohorts used AC
Automatic, and Battery Automatic remains ineligible even while older AC rates
are fresh. A regression verifies source changes invalidate captured atomic guards
and that 30 seconds on battery cannot restore eligibility.

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

Fresh training and validation use a predeclared minimum 20-second cooldown
before each measured request, ending with at least five continuous nominal,
non-Low-Power seconds, with a 180-second recovery limit. Before/after posture
and 500-ms observations during inference are retained; any observed fair state
invalidates the cohort. Applying this evidence requires the same whole-Mac
quiescence, stable nominal posture and Automatic power conditions described
below. It does not change fan policy or claim a sustained fair-temperature
serving default.

## Cooled training cohort

Signed candidate `78889be8cd55363ab4926aef2fb333c0448392c4`, with merged SDK
`748db5d967350dfdf17036bec3615a312090fd1e`, completed a managed clean release
build and the executing-image identity test. The
[build receipt](evidence/2026-09-28-calibrated-admission/m5-clean-build/build-receipt.json)
and [build log](evidence/2026-09-28-calibrated-admission/m5-clean-build/build.txt)
bind source-tree SHA-256
`54e69e0ab2bd4f5691ec0a2a9e8b1164c9fbab6b4456bc709c326de3f49c98df`
to actual executable SHA-256
`15675d3afe7e3f6e3d3ca44e72e06cb3cdf5eecba114f1dc22ee654edd7bd304`.
The image reported both `DEBUG` and debug assertions disabled. The build log
is archived as `build.txt`; its bytes match the original `build.log` digest.

All 40 independent tool/history training trials passed the fixed cooldown,
whole-trial nominal/Low-Power checks, actual MTP observation and request
retirement checks. Source, executable and artifact hashes were unchanged;
the supervisor observed no foreign work. The full
[receipt](evidence/2026-09-28-calibrated-admission/m5-cooled-training/receipt.json),
[provenance](evidence/2026-09-28-calibrated-admission/m5-cooled-training/provenance.json)
and [derived measurements](evidence/2026-09-28-calibrated-admission/m5-cooled-training/summary.json)
retain all observations. Actual first-content times ranged from 4.489 to
15.325 seconds across the declared 4,096–12,288-token band.

The [training fit](evidence/2026-09-28-calibrated-admission/m5-cooled-training/training-fit.json)
was frozen before starting independent validation. It uses the minimum
training prefill rate, 779.752 tokens/s, and minimum confirmed-token decode
rate, 55.842 tokens/s. The measured error envelope selected a ratio of
`1.0000000000000002` and zero additive milliseconds. For 8,828 prompt tokens
plus the bounded 33 early decode tokens, this gives 11,912.506 ms, inside the
incident's 14,369-ms remaining budget by 2,456.494 ms. This is a fitted estimate
from new dedicated hardware evidence, not a replay of the historical request.

The [collection plan](evidence/2026-09-28-calibrated-admission/m5-cooled-plan.json)
preserves the failed sustained cohort and fixes the new 40/100 split. The 100
held-out requests use new independently generated bodies on the same exact
binary. Their results cannot refit the frozen rates or margin. Training alone
does not qualify a deadline profile or any concurrency/chunk change.

Review found that nominal state at admission alone does not reproduce this
cooled distribution. An exploratory replay of sustained-cohort iteration 2,
which ended nominal, gives a frozen/live-capped bound of 15,087.866 ms against
15,322.195 ms observed first content (15,293.784 ms from engine submit).
That earlier cohort does not become validation evidence; it demonstrates why
the runtime must retain the measured 20-second whole-Mac quiescence and
five-second stable nominal/Automatic prerequisites. New admission checks enforce
those conditions without waiting and invalidate stale idle references after
request, retirement or load activity.

## Independent cooled validation

The fixed 100-request validation cohort completed on the same `78889be8` source,
release image, model artifact, MTP configuration and Metal library as training.
All 100 independent tool/history bodies stayed inside the frozen training bound;
none were dropped or used to refit it. All cooldowns and before/during/after
posture checks passed, with no request, retirement, instrumentation or foreign
work failures. The [raw validation receipt](evidence/2026-09-28-calibrated-admission/m5-cooled-validation/receipt.json),
[supervisor provenance](evidence/2026-09-28-calibrated-admission/m5-cooled-validation/provenance.json),
[derived results](evidence/2026-09-28-calibrated-admission/m5-cooled-validation/summary.json)
and [execution log](evidence/2026-09-28-calibrated-admission/m5-cooled-validation/run.txt)
retain the complete cohort.

Actual prompt counts span both endpoints, 4,096–12,288. First content ranges
from 4,489.233 to 14,848.442 ms; p50 is 9,975.199 ms and p95 is 14,142.536 ms.
These percentiles combine different prompt lengths and are not a fixed-size
latency promise. The closest observation remains 1,047.625 ms below its own
frozen prediction. The minimum measured confirmed-token decode rate is
67.308 tokens/s, and its p10 is 71.749 tokens/s.

Cancellation remains a separate prerequisite. A task's cancellation flag does
not prove that the engine cancelled before a natural terminal. The isolated
signed correction `1719b40b1aaea0ea5b0d80855034a886f855cabd` records the settled
engine finish reason and accepts only `cancelled`. The
[measured source manifest](evidence/2026-09-28-calibrated-admission/m5-cohort-source-manifest.json)
and [lifecycle source manifest](evidence/2026-09-28-calibrated-admission/m5-lifecycle-source-manifest.json)
rehash to their respective source-tree identities. Only three qualification
test files differ; every production, dependency, package and script file is
identical. The [managed lifecycle build receipt](evidence/2026-09-28-calibrated-admission/m5-lifecycle-build/build-receipt.json)
and [build log](evidence/2026-09-28-calibrated-admission/m5-lifecycle-build/build.txt)
bind that source to executing image SHA-256
`b8276aad27accb191adcfe6e02c7a1c5fdf71424e7b55971afd5a118bbc9eef2`,
with the same compiler, release flags and Metal library.

The [real lifecycle receipt](evidence/2026-09-28-calibrated-admission/m5-lifecycle/receipt.json),
[provenance](evidence/2026-09-28-calibrated-admission/m5-lifecycle/provenance.json)
and [execution log](evidence/2026-09-28-calibrated-admission/m5-lifecycle/run.txt)
passed both phases. Prefill cancellation confirmed/accounted zero output tokens;
after-MTP cancellation confirmed/accounted seven. Each phase recorded the
engine's `cancelled` terminal, exactly one workload retirement, no remaining KV
or whole-Mac service ownership, and an identical subsequent greedy result.
All five cooldowns and all control/request posture observations passed.

The [assembled qualification receipt](evidence/2026-09-28-calibrated-admission/m5-deadline-qualification-receipt.json)
references the unchanged raw 40/100 runs and scoped prerequisite files. Its
SHA-256 is `6d3b6a5e48171689dff6b1a4053c5103464536d5f214764f61e86d19013603cb`.
The [strict review result](evidence/2026-09-28-calibrated-admission/m5-deadline-qualification-review.json)
qualified the exact cooled, isolated, cold 4,096–12,288-token profile with no
errors. Empirical coverage is 100/100; the one-sided 95%-confidence lower bound
is 0.9704869503929601. Every fitted cell, runtime identity and measured-build
field equals the training-only record frozen before validation. Actual context
bounds include only the bounded 33 early decode tokens: 4,129–12,321.

This profile certifies deadline prediction under its recorded prerequisites.
It does not change concurrency, chunk size or universal serving policy, and it
does not certify reused/contended requests, prompts beyond the measured band,
or a sustained hot workload. The final catalog-containing runtime still needs
the original 8,828-token/14,369-ms admission proof.

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
remain unchanged. The collector verifies actual weight/configuration bytes
before and after counting. A fresh 9,000-body run through that collector passed
in 1,660.671 seconds, with both actual artifact hashes matching the target.
Its entire numeric receipt is byte-for-byte identical to the committed receipt,
SHA-256 `333807e1899620390559a0464f45792ef8360c77a4dfbd9e68d00552d5b762f8`.
Re-evaluation still qualifies all six groups. The
[verification record](evidence/2026-09-28-calibrated-admission/prompt-count-artifact-reverification.json)
and [actual test log](evidence/2026-09-28-calibrated-admission/prompt-count-artifact-reverification-tests.txt)
retain that check; its duration is functional-test runtime, not inference timing.
All six records are promoted unchanged in `coordinator/api/promptwork/catalog/`.
Regression tests reproduce every held-out covered count and exercise all 6,000
training shapes through the production estimator.

## SDK validation scope

Focused deadline, constraint, isolation and checkpoint tests pass on the merged
SDK. Its hosted full suite is not green: the
[pre-172 baseline](https://github.com/Layr-Labs/mlx-swift-lm/actions/runs/36487630997),
[PR 172 run](https://github.com/Layr-Labs/mlx-swift-lm/actions/runs/36503042824),
[merged-172 run](https://github.com/Layr-Labs/mlx-swift-lm/actions/runs/36505279055),
and [PR 173 run](https://github.com/Layr-Labs/mlx-swift-lm/actions/runs/36508355311)
report the same 112 issues in four DiffusionGemma suites, with identical
per-test totals. The [numeric comparison](evidence/2026-09-28-calibrated-admission/sdk-ci-baseline-comparison.json)
retains all four revisions, run links, log hashes, totals and separate XCTest
failures. The merged-172 and PR 173 runs have no XCTest failures.
These existing failures remain unresolved; they are not reported as passing
SDK coverage or used as qualification prerequisites.

A separate intermittent checkpoint assertion observed one live host-manifest
permit after request/GPU retirement. The same test passed in the full-suite
rerun and on merged-main hosted CI; the pre-172 baseline exposed the same
fixture lifetime issue in its MoE test. Test-only
[SDK PR 173](https://github.com/Layr-Labs/mlx-swift-lm/pull/173) adds a deterministic
held-callback regression and waits for final callback owners before checking a
zero total ledger. Immediate GPU/request retirement assertions remain intact.
It merged as `71678411330e37cb76d1a10134411433dfa5c9a9`, which is now the final
provider pin. Comparing with `748db5d` shows only its two test files changed;
runtime libraries and package files are byte-identical. Historical timing
receipts retain their actual `748db5d` revision; final-build proof uses the new pin.
On merged `7167841`, local checkpoint suites pass all 15 XCTest cases, and
constraint/isolation coverage passes 37 XCTest plus 23 Swift Testing cases.
The full provider suite also passes on this pin: 208 XCTest cases (eight
expected skips), 3,442 Swift Testing cases in 458 suites, and 12 isolated checks.
The separate [scoped receipt](evidence/2026-09-28-calibrated-admission/constraint-isolation-sdk173-receipt.json)
and [test log](evidence/2026-09-28-calibrated-admission/constraint-isolation-sdk173-tests.txt)
preserve that exact revision without replacing the earlier cohort's evidence.

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
new cohorts declare 4k–12k, both endpoints and varied actual tool/history
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
