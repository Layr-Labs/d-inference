# Bonsai 2 lossless performance and API stability

> Last updated: 2026-09-18 · commit `5fc48d460`

Matched OFF/ON qualification for the performance follow-up to merged
Bonsai support PR1124. Decode improves in the measured workloads; prefill gains
are small and not universal. Active allocation reductions are not blanket
whole-process memory reductions. This is a bounded local qualification report,
not hosted certification or an all-release-gates sign-off.

## Artifact and profile

- Unchanged Prism Ternary Bonsai 2 27B MLX 2-bit artifact, revision
  `3f926b415992eaa2ae9dd7b573706494d6bbf787`.
- Weights: 8,595,477,990 bytes; SHA256
  `130de5925082c168b7866b2e91b52e44abbafc99017e3ca352b77b5b55a269ed`.
- Native `prism_hadamard_qwen35` / dense `qwen3_5`, real vision, no MTP heads.
  No weight, template, normalizer, precision or numerical-baseline changes.
- OFF/ON varies only `DARKBLOOM_BONSAI_PREFILL_CARRY_ASYNC` and
  `DARKBLOOM_BONSAI_F16_CONSTANT_CACHE` together. Both were default OFF when
  these explicit-OFF/ON measurements were taken. The subsequent default-activation
  change makes unset equivalent to ON, preserving explicit `0` rollback and all
  numerical/eligibility paths. These measurements are not relabelled as new runs.
- Earlier submission of the exact compact recurrent carry; reuse of the existing
  exact FP16-to-FP32 constant conversion. The latter retains about 1.60 GB
  decimal of converted constants, with descriptor/stream invalidation and tracing
  fallback. Rejected gather/fusion/recurrence experiments are excluded.
- Timed cells use paged B1, prefix tiers OFF and matched process-level ABBA.
  Independent numerical/cache/concurrency gates are separate from timing.

## Complete native context matrix

Median tok/s; four measured generations/profile/context across two processes,
with warmup. Fixed 128 timed decode tokens plus the first token; EOS intentionally
ignored for this compute benchmark. All 129 token IDs match across every cell.
Effective prefill is prompt tokens divided by submit-to-first-token time, not
pure kernel timing or end-to-end HTTP/tokenization throughput.

| Host | Prompt tokens | Effective prefill OFF → ON | Decode OFF → ON | Prefill change | Decode change |
|---|---:|---:|---:|---:|---:|
| M3 Ultra | 1,024 | 292.67 → 293.93 | 29.49 → 43.32 | 0.43% | +46.90% |
| M3 Ultra | 10,000 | 280.58 → 282.33 | 28.91 → 39.80 | 0.62% | +37.67% |
| M3 Ultra | 20,000 | 265.13 → 267.06 | 28.77 → 36.00 | 0.73% | +25.15% |
| M3 Ultra | 50,000 | 222.52 → 225.08 | 23.89 → 28.10 | 1.15% | +17.64% |
| M5 Max | 1,024 | 654.96 → 669.92 | 38.24 → 46.33 | 2.28% | +21.17% |
| M5 Max | 10,000 | 500.12 → 506.87 | 31.07 → 37.91 | 1.35% | +22.01% |
| M5 Max | 20,000 | 425.35 → 413.12 | 24.77 → 28.40 | -2.87% | +14.68% |
| M5 Max | 50,000 | 338.45 → 330.89 | 17.43 → 18.99 | -2.23% | +8.96% |

M5 long-prefill medians decrease 2.2–2.9%; retain this tradeoff and run-order
spread. Do not characterize the profile as a uniform speed improvement.
An isolated earlier M5 20K constant-cache experiment showed about +3.5% effective
prefill, but that did not persist in the final combined matrix.

## Native memory peaks

GB decimal, including loaded weights. MLX active peak and process lifetime
footprint measure different things; the latter includes loading, warmup and
allocator retention. These are not KV-only growth or full-context estimates.

| Host | Prompt tokens | MLX active peak OFF → ON GB | Process peak OFF → ON GB |
|---|---:|---:|---:|
| M3 Ultra | 1,024 | 12.55 → 12.59 | 15.47 → 15.50 |
| M3 Ultra | 10,000 | 16.28 → 14.18 | 23.86 → 22.93 |
| M3 Ultra | 20,000 | 19.18 → 17.01 | 25.82 → 25.90 |
| M3 Ultra | 50,000 | 29.48 → 27.31 | 34.85 → 35.92 |
| M5 Max | 1,024 | 12.55 → 12.58 | 15.28 → 15.31 |
| M5 Max | 10,000 | 16.28 → 14.18 | 23.84 → 22.75 |
| M5 Max | 20,000 | 19.18 → 17.01 | 25.62 → 25.68 |
| M5 Max | 50,000 | 29.48 → 27.31 | 34.68 → 35.65 |

The 50K process high-water mark increases despite lower active allocation.
These results do not establish a 2–4 GB full-context KV budget or a universal
memory-leak fix. They preserve native FP32 recurrent/KV state.

## Authenticated API tool-history workload

Real local Chat API, synthetic tool-result histories, 128 actual output tokens,
eight samples/context across ABBA, observed cached_tokens zero. All visible output
matches exactly. Effective prefill here is prompt tokens / visible TTFT; it
includes API handling and is distinct from the native timer above.

| Host | Actual prompt tokens | API effective prefill OFF → ON tok/s | API decode OFF → ON tok/s | Decode change |
|---|---:|---:|---:|---:|
| M3 Ultra | 1,213 | 286.98 → 288.96 | 28.37 → 43.22 | +52.35% |
| M3 Ultra | 4,505 | 284.91 → 287.18 | 27.89 → 41.63 | +49.30% |
| M5 Max | 1,213 | 539.37 → 518.16 | 36.68 → 45.16 | +23.12% |
| M5 Max | 4,505 | 485.08 → 473.96 | 34.26 → 42.71 | +24.67% |

Median process peak across both history sizes and short concurrency controls:
M3 19.531 → 16.807 GB (−13.95%); M5 19.327 → 18.057 GB (−6.57%).
M5 API effective prefill decreases 2.29–3.93%, with material run-order spread.
This is synthetic authenticated traffic, not recorded user traffic.

## Latest M3 20K confirmation

A later matched ABBA on the HTTP-qualified runtime, one warmup and one measured
generation/process (two samples/profile), confirmed all 129 tokens exactly:
decode 27.80 → 35.90 tok/s (+29.14%); effective prefill 262.03 → 264.74 tok/s
(+1.03%); active peak 19.180 → 17.013 GB (−11.30%); process peak
25.791 → 25.895 GB (+0.40%, effectively flat in this short series).
Controls were stable. A separate M5 long-repeat had large OFF-control drift
and was stopped; it is not accepted as clean timing evidence or a completed
50K rerun. M3 percentages must not be extrapolated to M5.

## Regression evidence and remaining gates

### Default-activation follow-up

The default-on change keeps the previously qualified numerical paths intact:
absent and exact `1` overrides enable each eligible path; explicit `0` and other
explicit spellings disable it. Diagnostics remain opt-in. Shape/dtype/stream,
tracing, deferred-fill, native write-fault and retirement checks are unchanged.

Fresh M3 Ultra optimized, test-enabled native component build: 199.87 seconds.
Tests are exact copies of the committed Swift/SDK tests, linked against the
updated libraries and unchanged source-matched Metal. No downloaded model or
HTTP endpoint was loaded for this follow-up.

| Separate process profile | Passed | Deliberately skipped | Failures |
|---|---:|---:|---:|
| Both overrides absent (new default) | 26 | 0 | 0 |
| Both overrides `1` | 26 | 0 | 0 |
| Both overrides `0` | 22 | 4 ON-only scheduling tests | 0 |
| Both overrides `invalid` | 22 | 4 ON-only scheduling tests | 0 |

The tests cover all half bit patterns, exact packed outputs and dtypes,
parameter-tree/mutation/tracing invariants, generic BF16/MXFP4 behavior,
eligibility exclusions, process-default policy, actual carry submission,
deferred fills, write faults, cleanup and same-ID recovery. All four owned guards
terminate normally. All31 resolved remote dependencies match the unchanged lock.
This is default-policy/component evidence, not a new full-model benchmark or a
new hosted/release gate. The earlier explicit-ON numerical/API evidence retains
its original scope and the known failures below remain visible.

Test executable SHA256:
`82aa893bce3ef070a0ba577581112e6280267ec7d71d9981e4df16e5457b8944`.
Source heads: Swift `d7c1d3dcd114aa0e96ac6030da633ec7d4bd8254`, SDK
`b16fc9235452fde903502a6285bb7097dc8504e2`. Raw operator logs stay private;
immutable test-output SHA256 values:

- Default: `37641b2620098c7fda1376e423e9ee6a6b3a660210b3d5c22ab98a8299edd55c`
- ON: `f546af1011c52953243d76fd96e72ea995e2d15242c7c3cd054b5da4c6c3e36f`
- OFF: `9dfb4577a8970a30ea7e43d2ee1df7c21e3dae6c328db86a4710c1567a34a3e9`
- Invalid: `fe4f1e97d394d098c01b9b22db927cbf91ba9f5bc4906addd0e4d9d8687d862a`

### Recorded broader qualification

- Independent frozen raw logits, all 48 recurrent states and 16 paged-KV layers,
  B1/B2 on both machines, plus tail/chunk cases: exact comparisons pass.
- Native ragged/mixed text/tool/image/video cohorts, actual concurrency,
  quiet/content cancellation, drain/readmission, ownership/reload, encoded RAM
  prefix and encrypted-fixture cold/hot/reopen/tamper/isolation checks pass.
  M3 encrypted-write fixture and six isolated filters pass after real disk
  cleanup, without changing the storage reserve or assertions.
- Swift 561 executed / 11 explicit opt-in skips; SDK XCTest909 executed /
  23 skips and Swift Testing1256 reported / 14 skip lines: zero failures in
  those recorded scopes. Updated server213 and provider/router15 tests pass.
- Ordinary serving15/15, HTTP lifecycle3/3 and negative late-error framing2/2
  pass on both hosts; final source-compatibility follow-up rechecked on M3.
- Original strict tool-success matrix remains **24/28**. Four strict-copy stress
  cases fail: reasoning OFF overquotes a JSON-string-value; reasoning ON exhausts
  tested768/1536 budgets without a valid call. Performance-OFF/frozen controls
  reproduce these. Ordinary weather, tool history and raw-literal OFF pass.
- Full provider suite retains four GPTOSS cases/129 numerical issues reproduced
  on an independently built frozen baseline; a TF32-disabled diagnostic is not
  substituted for default qualification.
- Fixture encryption is not release-signed Keychain restart. Ordinary ad-hoc
  persistence reports cache_init_failed; signed/trusted/hosted gates remain open.
- [ ] All required end-to-end release gates complete, with current evidence.

The HTTP repair emits sanitized terminal errors after committed headers instead
of truncating transfers. It does not fabricate tool calls, unquote guessed
arguments, convert cancellation to success or change model math. The original
one-argument SDK service/function-reference contract is retained.

## Provenance and reproduction

[Sanitized measurement summaries](evidence/bonsai2-performance-2026-09-18/measurements.json)
retain medians, ranges, sample counts, exactness results and executable hashes.
No credentials, operator paths, raw private prompts/media or local endpoints
are included.

The complete native matrix used executable
`eedc10f9b02ec10edd09616944e620515d36cd4fae4bff6c7b4a7c5747a6acaa`.
Fresh API/20K evidence used
`327cc709c835c31afeead38dd9d190affb989f71fb80d8e683e1cf66125d31ca`.
The pre-default-activation source-compatible ordinary runtime is
`0db475ecee9f0d5cc96d37c8892c871641cdd1dd79eb301218b2fdb8f2f37cfc`.
All use Metal
`38ceb8a1113b373ccaa89355d895fc8ded3bafc81076dc4ffdb426e2eee03a93`
and the four source-matched SwiftPM resource bundles. Later HTTP/overload/pin
changes leave the native numerical and benchmark sources byte-identical; the
original evidence is not relabelled as freshly measured on another binary.

See [qualification commands](../developer/test.md#bonsai-performance-qualification),
[configuration](../reference/configuration.md#bonsai-performance-qualification)
and [build provenance](../developer/build.md). Focused suites include
Float16ConstantCastTests, PrismPrefillCarrySubmissionTests,
ChatStreamingFailureHTTPTests, LocalStreamingFailureTests and
BonsaiEncryptedCheckpointLiveTests. Use an exclusive GPU lane and exact artifact;
do not infer a live-test pass from test discovery or opt-in skips.

## Integration and rollback

Public review order is Swift → SDK → provider. Each consumer pins a public
immutable dependency; after an authorized merge, replace draft pins with the
observed merge SHA and recheck the clean composed build. Model publication,
catalogs, signing/release and deployment are separate actions.

Set both new controls explicitly to `0` for the original performance paths;
unset now selects the qualified ON path. Other explicit spellings except `1`
remain disabled. The generic
MLX_QUANTIZED_CONSTANT_CACHE=0 kill switch remains effective. Reverting the
separate API fixes requires their matching code/dependency rollback. No weight
or disk-format migration is involved.
