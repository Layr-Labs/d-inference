# Coordinator cache restore cost

> Last updated: 2026-09-05 · commit `1a9c78d84`

Routing now includes an SSD restore that costs more than the prefill it saves.
Previously that hint was discarded and the provider kept its cold score, even
though the provider would still attempt the restore. The signed adjustment lets
a cold peer win when its estimated service cost is lower.

## Behavior

An actual Prepare/Lookup/Ready/Reserve fixture advertises a 4,096-token checkpoint
on a provider estimated at 5,000 prefill tokens/s, with a 900 ms restore. For a
4,352-token request, its prefill-related cost becomes 951.2 ms instead of the
cold 870.4 ms. A cold peer at 4,800 tokens/s costs 906.667 ms and wins. These are
deterministic scheduler estimates, not model or network timing measurements.

`cacheServiceCost` applies the same prefill weighting to either sign. Benefits
retain their optional discount caps; excess restore cost increases `ThisReqMs`.
Stage cost is counted once. Queue, decode, backlog, health, full-request memory
admission and normal TTFT gates remain intact. An expensive holder remains
eligible when it is the only usable provider. Live hint adjustments use minimum
adjusted cost; pools without adjustments retain existing load spreading.

`RoutingDecision` and its debug log expose signed estimated savings and the
cache tier. Existing aggregate savings telemetry remains positive-benefit-only;
it must not be interpreted as net cache performance.

## Verification

| Scope | Result |
|---|---|
| Isolated registry/API/protocol packages | 2,563 top-level tests and 1,517 subtests pass; two existing opt-in skips |
| Isolated focused race checks | 95 top-level tests and 173 subtests pass |
| Final new fixtures on unchanged baseline | Four top-level functions and seven subtests fail as expected |
| Integrated cost and footprint race checks | 101 top-level tests and 173 subtests pass; zero skip/failure |

The broader isolated run skips `TestPerfE2E_ChatCompletions` and
`TestVerifyProviderViaMDM_TimeoutTransient`. Evidence preserves initial fixture
mistakes, corrected baseline failures and successful final candidate runs.
Seven Go files are copied unchanged from the tested source. Documentation and
the changelog merge alongside the earlier allocator milestones.

Five 200 ms microbenchmark samples per revision on the shared Apple M3 Max
show the cost helper near 49 ns/op with zero allocations. The 350-provider
selector's observed median increased by 209 ns for cold pools and 68.3 ns for
cache pools. The hint index is unchanged and retains 1,166 allocations in its
bounded fixture. These diagnostic samples establish no routing speedup or
statistical latency result; some baseline index samples overlapped API tests.

## Evidence and limits

The [manifest](evidence/cache-stage-cost-2026-09-05/manifest.json)
(SHA-256 `5abb7ace1c9a1fd99218b3d27220fc79c658e775627fb51ba566969e8b536f62`) records 37 verified
payloads. The [archive](evidence/cache-stage-cost-2026-09-05/payloads.tar.gz)
has SHA-256 `2b7ad75cedde142395c8f01f3851f79513048ef4ac1f29f3d260d951d5190838`. The source freeze is
`e2b9817404fd662a372c578f4eb8648afa9e97048e7b651d59ecbdccd59c017f`.

No provider execution, cache wire contract, rollout default or live configuration
changed. Concurrent Prepare/reconfiguration ownership is a separate active fix.
Current scoring and telemetry semantics are in
[cache-aware routing](../architecture/cache-aware-routing.md#scheduler).
