# Connected cache qualification

> Last updated: 2026-09-27

The cache-reliability integration preserves response correctness while restoring
usable state through real local provider/API requests. This report separates
local evidence from fleet hit rates and production signing qualification.

## Tested composition

The integration used upstream `d621f97726d87e6b04a12d7d5715ebe516f72d79`, the
unchanged SDK `6f3d171fb7270ba18fb2432ab4f4aab5ed4b6114`, and the cache planner,
bounded tokenizer preload, attempt-retention, caller-metadata minimization and
SSD-reliability changes. Its production source tree is
`b49a3567ad8e46b660e9982afb96257401b44792`; subsequent TTL/Gemma changes affect
tests only. The optimized provider executable was SHA-256
`c55de5bcac4dbc37e5a299845671aacaad6941b5d87dbd81454d0cd4d7d98c76`.

Tests ran on an M3 Ultra. Model artifacts were unchanged. Cache fixtures used
an external USB APFS SSD, explicit test roots, ephemeral keys and test trust/
billing. Native numerics, cache time/byte budgets, admission safeguards and
publication barriers were not relaxed. Local API checks were SLA-exempt; these
are not hosted OpenRouter certification or production SLA measurements.

## Real inference and reuse

| Gate | Result |
| --- | --- |
| Bonsai default-policy cold/repeat | Same response/usage; 6,144 of 8,261 prompt tokens restored |
| Ten-case API OFF/SSD matrix | All cases and cross-arm content, reasoning, tool arguments, finish and non-cache accounting equal |
| Reasoning-medium tool matrix | Same ten-case matrix passes in both cache modes and across modes |
| Simultaneous B2, OFF/SSD | Both requests succeed, actual native batching and distinct terminals observed; all six serial/concurrent outputs equal |
| Tenant, cancellation, media and outage | Tenant miss, original-branch reuse, image input, cancellation/recovery and sidecar-outage fallback pass |
| Real Gemma reconstruction | Original full artifact hash verified; first request to the rebuilt engine restores 6,144 of 6,846 tokens; output exactly `ALDER-427` with cache on/off; other tenant misses |

The Bonsai matrix has four hits out of four deliberately eligible opportunities
(including cancellation), four out of eight accepted lookup receipts, and three
hit-bearing requests out of nine completed requests. Cached-token coverage is
18,432 / 64,470 (28.59%). These are different denominators. They do not establish
or forecast a 40–48% fleet request-reuse rate.

Observed single-order, OS-warm timings are descriptive, not quiet benchmarks:

| Observation | OFF / cold | Restored |
| --- | ---: | ---: |
| Bonsai repeat first content | about 29.5s OFF | 8.33–8.40s |
| Bonsai restored-state staging | not applicable | 307–334ms |
| Bonsai B2 pair completion | 63.48s OFF | 20.29s |
| Gemma first content, debug native test | 3.751s OFF | 0.681s |
| Gemma total, debug native test | 3.962s OFF | 0.899s |

The B2 test uses equal prompts on one provider; it does not establish arbitrary
mixed cohorts or cross-host behavior. Gemma rebuilds its engine/store with the
same explicit fixture key, not a production Keychain key in a new process.

## Storage and security gates

The latest source passes 131 storage cells across 81 methods and 16 suites, plus
four original tiny-native encrypted-checkpoint tests. They retain exact adopted
state, bounds, one-retry policy, corruption/FIFO/no-follow refusal, epoch and
survivor ownership, cancellation and drained reservations. The strict console
observer required the same two previously source-verified positive fixture
diagnostics to be reconciled; the raw observer failure was preserved, and five
negative controls rejected missing, duplicate, changed or failing output.

Nine additional expiry cells characterize the existing policy at 899/900/901
seconds: attention staging remains eligible until its sweep and refreshes
recency on use; complete-checkpoint reads reject expiry before a sweep. This is
not a stronger erasure guarantee or a retention-policy change. See
`provider-swift/Tests/ProviderCoreTests/KVCacheSSD/SSDPrefixCacheTests.swift`
(`ttlStageBeforeSweepCharacterization`) and
`provider-swift/Tests/ProviderCoreTests/KVCacheSSD/SSDHybridCheckpointRecencyTests.swift`
(`ttlReadBoundaryWithoutSweep`).

## Cold-write cost and remaining release limits

Cold donation remains measurable: Bonsai total 53.98s with SSD versus 31.26s OFF;
cold tool 32.72s versus 19.50s. Gemma donor total 12.07s versus 3.96s OFF. Publication
and retirement remain awaited. No early terminal, uncharged aggregate buffer,
weaker encryption, lower write reserve or altered durability was introduced.

A separate bounded 64MiB framing diagnostic passed ten controls and four
byte-identical cells. A vector writer showed no internal-volume benefit and
about 21% lower whole-cell time on the external volume in one fixed-order run.
It is not included: repeated native benefit and production failure-contract
qualification are absent. Storage placement must accompany cold-write numbers.

Production-key persistence across a genuinely new signed provider process still
requires the approved macOS signing/profile setup or the official release
runner. Synthetic-key multi-process and real-model same-process reconstruction
must not be relabelled as that gate. Fleet uplift requires a defined post-rollout
measurement window; no deployment or fleet improvement is established here.

Reproduce the applicable gates using [the test guide](../developer/test.md),
retaining artifact, source, executable/resource, backend and cache identities.
Keep release signing, hosted routing and fleet-rate checkboxes separate from
the local passes above.
