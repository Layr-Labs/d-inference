# Qwen checkpoint cache with normal MTP: model check

> Last updated: 2026-09-05 · commit `1cbeb87cb` (immutable artifact source manifests below).

The resident checkpoint prototype preserves complete generated token IDs with the normal Qwen inline MTP assistant. A compact fallback makes a 12,091-token conversation reusable within the same 1 GiB bank: its repeat saves 8,192 prompt tokens and reduces measured TTFT from 15.115 to 5.086 seconds. These are single ordered groups on one provider, not repeated-run medians or measurements of the subsequently requested SSD-default implementation.

## Method and artifact boundaries

The dedicated M5 Max uses the pinned `EigenLabs/Qwen3.8-27B-4bit-mtp` snapshot `06d517d395dfc5588090f7f534112bee331f7b4a`; the [model manifest](evidence/2026-09-05-radix-prefix-cache/model-manifest.json) records every file hash. Requests use greedy sampling, identical input order, an excluded eight-token warmup, and the normal production Qwen assistant loader and verification policy. Compare each MTP mode to its own baseline: the existing baseline can produce different outputs with MTP enabled versus disabled.

| Artifact | Scope | Engine SHA-256 |
|---|---|---|
| baseline-mtp-build2 | Clean `e928d395f`, pinned submodules, extended engine harness | `740ce1b31783509f7e545712aa5002e5c6918aaf0160393ad7cec169a17add21` |
| candidate-mtp-build3 | Exact MTP checkpoint restore; before the final retirement overlay and compact fallback | `13712390cec5e5af9d6ebad8c87e1ef358d28f17545366442a81d7a22e399d93` |
| candidate-compact-build4 | Compact fallback over LM `9115719`; before the auxiliary admission follow-up | `54aaa34913b4b4d7f1b9e089be7299f9ec3f03cc0c34551fc25422013039d9c7` |

The [baseline artifact](evidence/2026-09-05-radix-prefix-cache/baseline-mtp-build2-artifact.json), [build3 artifact](evidence/2026-09-05-radix-prefix-cache/candidate-mtp-artifact.json.gz), and [compact evidence manifest](evidence/2026-09-05-radix-prefix-cache/candidate-compact-evidence-manifest.json) retain source and binary provenance. Build4 adds two candidate-only counters, `kv_compactions` and `kv_compaction_bytes`, after request timing ends. It uses the same prompts, sampling, MTP configuration, 16 GiB total factory grant, and 1 GiB/32-entry/two-checkpoint bank. Direct runs exercise the production engine factory; the separate HTTP runs exercise provider slot and bridge wiring.

## Normal-MTP replay

All seven measured rows in both candidate engine artifacts match the clean same-mode baseline in prompt IDs, generated IDs, token counts, and finish reason. Tenant separation, cancellation, and recovery also pass. Five warm rows save exactly 4,096 tokens. These results are single observations per row.

| Request | Baseline engine TTFT (s) | Build3 (s) | Compact build4 (s) |
|---|---:|---:|---:|
| First conversation | 6.515 | 6.576 | 6.108 |
| Exact repeat | 6.564 | 1.736 | 1.757 |
| Shared-prefix branch | 6.698 | 1.807 | 1.814 |
| Branch repeat | 6.768 | 1.825 | 1.832 |
| Second turn | 6.886 | 1.918 | 1.920 |
| Second-turn repeat | 6.894 | 1.906 | 1.907 |

The [build3 verdict](evidence/2026-09-05-radix-prefix-cache/candidate-mtp-verdict.json) and [compact verdict](evidence/2026-09-05-radix-prefix-cache/candidate-compact-control-verdict.json) link the exact comparisons to retained raw reports. The baseline single decode control is 53.970 tokens/s, build3 is 53.507, and compact build4 is 56.364. This variation does not establish a decode improvement; the demonstrated mechanism is reduced prefill work.

Both production HTTP candidates also match all seven complete text/reasoning outputs, usage counts, and finish reasons against the same-mode baseline. HTTP repeat TTFT is 6.566 seconds baseline, 1.756 seconds build3, and 1.769 seconds compact build4; second-turn TTFT is 6.896, 1.937, and 1.941 seconds respectively. HTTP does not expose generated token IDs: those equality claims come from the companion engine runs. See the [build3 HTTP report](evidence/2026-09-05-radix-prefix-cache/candidate-build3-mtp-http-report.json.gz) and [compact HTTP report](evidence/2026-09-05-radix-prefix-cache/candidate-compact-http-report.json.gz).

## Long prefix and compact ownership

The original build3 long run preserves output IDs but cannot publish a useful checkpoint under 1 GiB: all three main requests miss, save zero tokens, and increment capacity refusals. The [original failed cache-hit verdict](evidence/2026-09-05-radix-prefix-cache/candidate-mtp-long-verdict.json) is retained.

Compact build4 passes the same three-row output and expected-hit checks, plus tenant, cancellation, and budget checks. The full donor allocation need not stay resident: publication copies only through the deepest retained exact checkpoint.

| Request | Actual prompt tokens | Baseline TTFT (s) | Compact TTFT (s) | Saved tokens |
|---|---:|---:|---:|---:|
| Donor | 12,091 | 14.644 | 14.924 | 0 |
| Exact repeat | 12,091 | 15.115 | 5.086 | 8,192 |
| Continuation | 12,099 | 15.367 | 5.222 | 8,192 |

After the donor, the bank holds exactly **970,637,304 bytes**, one entry and two checkpoints. One compact copy writes a 536,870,912-byte KV destination. The repeat and continuation retain the same backing: no further compactions, evictions, or capacity refusals occur for these measured requests. The donor's observed terminal tail rises from 0.055 ms to 7.655 ms; the cold TTFT difference is an observation, not an isolated estimate of capture cost. See the [long verdict](evidence/2026-09-05-radix-prefix-cache/candidate-compact-mtp-long-verdict.json) and [raw report](evidence/2026-09-05-radix-prefix-cache/candidate-compact-mtp-long-report.json.gz).

A different tenant remains cold with identical output. Its publication evicts the previous tenant's entry under the bounded bank. Cancellation publishes no checkpoint; recovery recomputes and matches the baseline IDs. Thus the hit is neither a cross-tenant reuse nor a cancelled donor leaking a checkpoint.

## Validation and limits

- Core retirement-overlay validation: 82 XCTest and 2,468 Swift Testing cases; [retained provider output](evidence/2026-09-05-radix-prefix-cache/candidate-mtp-final-provider-tests.txt.gz). The first attempt had two signed-bundle tests fail because the test harness staged an external Metal-library symlink; regular copies of the identical hashed library fixed the fixture, and the full suite passed.
- Compact fallback: 81 native tests pass; [native manifest](evidence/2026-09-05-radix-prefix-cache/compact-native-initial/manifest.json).
- Later auxiliary admission fix: 66 XCTest plus 29 Swift Testing cases pass; [auxiliary manifest](evidence/2026-09-05-radix-prefix-cache/auxiliary-native/manifest.json). These tests include accounting for target KV that was prepaid during adoption. The real-model build4 artifact predates this fix.
- Cleanup-plus-core integration: 287 Swift Testing cases across 35 suites pass, including both actual slot/bridge checkpoint wiring cases; [integration manifest](evidence/2026-09-05-radix-prefix-cache/integrated-initial/manifest.json). Its first semantic build found a missing `await` in the new test; the corrected incremental build and affected suites passed. This intermediate integration uses LM `9115719`, not the compact or auxiliary overlay.

Compact control/long run GPU entry temperatures are 34.23/25.03 °C, maxima 85.31/85.90 °C. Sampled whole-system RAM maxima are 62.18/75.59 GB; these include the loaded model, active request allocations, allocator caches, and other system memory, and are not the checkpoint bank size. Swap remains 1,310,720 bytes in both runs. Complete telemetry is retained beside each raw report. Different thermal histories and ordered shape warmup limit small timing comparisons.

No multi-provider live-model run, RAM-budget sweep, concurrent-serving throughput result, default-policy recommendation, or SSD-streaming result is claimed here. Coordinator cross-machine routing scenarios are covered separately by the [Go routing evidence](evidence/resident-routing-2026-09-05/manifest.json). Reproduce new measurements with the [benchmark build](../developer/build.md#resident-prefix-benchmark-executable) and [validation](../developer/test.md#resident-prefix-benchmark-validation) instructions, preserving immutable artifacts and same-mode output oracles.
