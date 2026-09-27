# Request-owned date and GPT-OSS prompt parity

> Last updated: 2026-09-05 · commit `7190d3bbf`

The exact GPT-OSS template can now participate in prompt-contract planning with a date captured once per request. Four manifest entries pass positive provider identity checks and all 56 Rust-versus-Swift token comparisons. This milestone establishes prompt parity for GPT-OSS and the three existing Gemma entries; Qwen tool-template parity and paged model execution remain separate gates.

## Request and renderer behavior

The coordinator overwrites the reserved `_darkbloom_prompt_date` body field with the request's UTC Gregorian day before endpoint lowering, planning, fallback or retries. Local provider HTTP captures its own date and also overwrites caller input. A retry crossing midnight keeps the original date; a new request receives the new day. Invalid or missing network context retains ordinary provider serving behavior but cannot support exact planning for a clock-dependent template.

Only direct literal `strftime_now("%Y-%m-%d")` calls are eligible. Clock aliases, computed formats and other formats remain cold. No model artifact, process-wide clock or dependency pin changed. The production body, normalization, request-date tests and renderer checks are identified in the [owned-source manifest](evidence/request-date-parity-2026-09-05/request-date-owned-source-manifest.json.gz).

The pinned Swift-Jinja interpreter recreates its environment and overwrites a context value named `strftime_now`. The compatibility compiler now assigns the private request clock through a statement before the template executes. That statement emits no text. Shared Rust/Swift goldens cover six leading-whitespace and trim-marker cases, including a leading statement or comment.

Actual GPT-OSS parity also exposed two normalization differences. Detached Harmony reasoning turns now include explicit empty content, which the exact template requires. Rust now mirrors the provider's existing high-to-medium reasoning-effort policy. The policy itself is unchanged.

Normalization is `darkbloom-request-normalization-v3`; renderer semantics are `swift-jinja-request-date-v2`. These version changes alter every prompt-contract identity, including static templates. Rollout must regenerate exact-artifact allowlists and preloaded contracts. Token output changes only where the corresponding rendering or normalization behavior applies.

## Validation and retained failures

| Check | Result |
|---|---|
| Swift semantic build | Passed, 88.74 s |
| Affected Swift suite | 72 tests across 13 suites passed, 13.630 s |
| Actual prompt artifacts | Four positive identity checks, three unique contracts, 56 token cases passed |
| Shared date whitespace cases | Six explicit outputs checked in both languages |
| Full Rust suite | 87 tests passed |
| Coordinator API and request-contract races | Passed, 4.893 s / 2.942 s |
| Isolated coordinator package coverage | All 25 tested packages have passing coverage, with the reruns described below |

The four manifest entries are GPT-OSS 20B, Gemma 4 26B, its 8-bit alias, and the older Gemma QAT 4-bit entry. The alias shares a prompt contract with the fleet Gemma artifact. All 42 previous Gemma token arrays are unchanged; GPT-OSS contributes 14 newly routable cases. Final vector SHA-256 is `719988470a274209530dffc1be98c0a93adac20fcb38f137077d0df0fd959782`.

The preceding Swift run failed with three issues: two test expectations inherited the unadapted Swift lexer's whitespace behavior, and one GPT effort mismatch. Explicit cross-language whitespace goldens replaced that unsuitable oracle, and the Rust effort normalization was corrected. The complete failed and passing logs are retained alongside 1,073 source/test hashes and five fixture hashes from the passing build.

The isolated full Go run passed 24 packages but hit a supervisor child-startup timeout during concurrent builds. Its unchanged complete package passed three subsequent runs. That first isolated checkout also retained the old production vectors; the final overlay includes all new fixtures and the updated load-proof inventory assertion. Both fixture-sensitive packages passed again (2.646 s / 0.512 s). A separate shared-worktree integration run caught the old assertion expecting GPT-OSS to remain cold; that failure is retained. No supervisor timeout or production behavior was changed to obtain a pass.

The [evidence manifest](evidence/request-date-parity-2026-09-05/manifest.json) binds stored and decompressed logs, both isolated Go source snapshots, the owned source hashes, Rust tests and generation log, and benchmark inputs/results. This is affected-suite coverage, not a full provider suite or full-model inference result.

## Preprocessing cost

Adding request-owned context requires serialization even for previously untouched provider bodies. Two paired local microbenchmarks used Go 1.25.0 on an M3 Max, baseline `ac1dc301c`, three 100 ms samples per case and separate baseline-then-candidate runs. No Swift or model work ran during each pair. Values below are sample medians, with no statistical significance claim.

| Existing rewritten-request helper | Baseline | With request date |
|---|---:|---:|
| 2 KB request | 24.614 μs | 24.756 μs |
| 60 KB history | 589.881 μs | 591.743 μs |
| 60 KB history and tools | 659.054 μs | 662.278 μs |
| 3 MB image body | 20.250 ms | 20.256 ms |

The existing helper always resolves an alias and applies defaults. A second identical temporary benchmark in both checkouts uses a raw build with explicit output bounds and no catalog defaults to expose the previously untouched-body path:

| Previously untouched body | Baseline | With request date | Allocated bytes/op, baseline → candidate |
|---|---:|---:|---:|
| 2 KB request | 15.735 μs | 18.055 μs | 23,389 → 26,210 |
| 3 MB image body | 15.596 ms | 17.627 ms | 28,199,620 → 36,219,473 |

The large-body case therefore adds approximately 2.03 ms and 8.02 MB of cumulative allocations per operation in this helper measurement. Those allocation counts are not peak live memory. The first pair included concurrent development's inactive telemetry/index changes; cache routing was off. The second pair used the isolated date overlay, whose temporary benchmark source is retained. Neither measurement includes encryption, network, sidecar planning, SSD I/O or inference and neither demonstrates an end-to-end speedup.

For artifact provisioning and the production parity procedure, see [prompt-contract test instructions](../developer/test.md#9-prompt-contract-parity-fixtures-and-vectors). Qwen's expanded tool-history corpus has separate renderer differences under investigation; these passing results do not claim Qwen parity or release readiness.
