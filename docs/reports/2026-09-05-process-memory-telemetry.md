# Process-memory telemetry validation

> Last updated: 2026-09-05 · commit `f2b6bb3ea`

Optional process-memory observations now carry one coherent ledger snapshot
through provider heartbeats, coordinator validation and bounded metrics. Swift,
Go and TypeScript checks pass within the scope below. These observations are
diagnostic; scheduler capacity and routing authority are unchanged.

## Behavior verified

The provider captures active and cached allocator bytes together with charged,
materialized and outstanding commitments, remaining headroom, commitment debt,
policy epoch and live/closing owner counts. Heartbeat serialization advances the
age of the stored observation without resampling memory or incrementing its
producer sequence. Unknown OS headroom remains absent.

The coordinator rejects inconsistent accounting identities and out-of-range
values. Replayed or regressed observations keep aging, including on providers
with no slots. Missing observations clear the diagnostic state. Metrics emit
byte gauges only for a new, fresh capture, use bounded chip/version tags, and
carry no model, provider, generation or owner identifiers. A canonical JSON
fixture pins optional-field and integer behavior in all three languages.

## Validation

| Scope | Result |
|---|---|
| Provider telemetry, ledger, heartbeat wire and events | 49 functions / 49 cases pass; zero failures or skips |
| Go protocol, registry and API packages | 2,557 top-level tests plus 1,497 subtests pass; two opt-in tests skip |
| Focused Go race run | Five functions plus eight subtests pass |
| Focused TypeScript tests | 13 tests across two files pass |
| Touched TypeScript lint | Pass |
| Whole TypeScript typecheck | Fails with diagnostics byte-identical to the primary baseline |

The skipped Go tests require `EIGENINFERENCE_PERF_E2E=1` and
`RUN_MDM_TIMEOUT_TEST=1` respectively. Existing TypeScript errors span dashboard,
earnings, reputation, headers, Privy, RUM and test types; this milestone does not
claim a clean whole-project typecheck.

Swift validation compiled the exact eight owned Swift files and the canonical
fixture over native `990475e3ae6f93615bebe0fc36e352aa601ea4a5` source and the
banked local MLX dependencies. Before/after verification covered 662 candidate
provider inputs, 659 primary inputs, 453 native inputs, 1,353 MLX inputs and
27 Jinja inputs. Actual compiler graphs confirm the isolated source paths.

All four Swift attempts are preserved. The first required regenerating an
isolated Clang module cache after an APFS clone and explicitly selecting local
MLX. A production Swift exclusivity error was fixed by computing the aged
observation before assigning it under the same lock. Test-only corrections use
the existing `ProviderState` type and evaluate mutating sampler calls before
test macros. The final build completed in 95.19 seconds; all 49 cases passed.

## Reproducible evidence and limits

The [manifest](evidence/process-memory-telemetry-2026-09-05/manifest.json) has
SHA-256 `4afbe49bab6c9d49e0760833f80e270fa82acf0f3dc9574689994f43f25e797d`.
Its [archive](evidence/process-memory-telemetry-2026-09-05/payloads.tar.gz)
contains 179 verified payloads: source freezes, passing and failed logs,
compiler graphs, dependency manifests and exact final owned source.
Archive SHA-256 is
`79043d15968bac4bdef82026a49c2b51223474efdbc24063c578eaad9b1e758e`.
The final Swift validation manifest is
`086c67b4366e72fd3754ccc22b6380d6f0b539fa8e37b7630ce33595f37718c9`.

This milestone uses synthetic accounting snapshots to validate diagnostic
semantics. It does not rerun the prior real allocator proof, the entire provider
aggregate, a live coordinator, or fleet models. Allocator-footprint admission,
complete paged SSD integration and release performance remain separate gates.
No rollout or cache default changes are part of this milestone.
