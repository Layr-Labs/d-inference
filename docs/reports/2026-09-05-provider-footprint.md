# Provider allocator accounting and SSD candidate lookup

> Last updated: 2026-09-05 · commit `055a76364`

Provider tests now verify native allocation promises and backing coverage against
the real coherent MLX allocator. Optional telemetry distinguishes retained
allocator padding from unused reservation allowance. Complete SSD lookup checks
only the request's prefix candidates, eliminating its scan of unrelated entries.

## Observed allocation lifecycle

The isolated fixture reserves three independent buffer bounds before its first
evaluation, then inspects their actual allocator sizes. C is reserved memory,
M is backing already covered by that reservation, and U is active plus cached
allocator memory; process admission projects U + (C − M).

| Boundary | Observed bytes |
|---|---|
| Before first buffer evaluation | C = 163,837; M = 0; U = 6 |
| Evaluated segments | C = M = 81,920; U = 81,926 |
| Unused preparation allowance returned | 81,917 |
| Raw alias after native charge/coverage retirement | 24,576 logical bytes retain 32,768 allocated bytes; U = 32,772 |
| Final alias dropped and allocator cache cleared | U = 4; another owner can reuse the released 32,768 bytes |

A competing 4,096-byte promise fits exactly at both the pre-evaluation and
materialized boundaries; one additional byte is refused. The pre-evaluation cap
is deliberately restored before allocation. This proves boundary accounting,
not a continuously constrained serving factory, whole-graph scratch envelope or
OS-pressure behavior. The OS availability constraint is non-binding in this test.

## Changes and checks

`allocator_padding_bytes` reports nonusable retained bytes;
`last_allocation_allowance_bytes` reports the last released preparation allowance.
Neither is an additive total or a new admission authority. The same canonical
wire fixture is checked by Swift, Go and TypeScript, including optional omission.

`SSDBlockIndex.freshFileBytes` reads size and TTL under one lock. The complete
checkpoint store probes deepest-first without building a set of every expired
entry. Probes do not extend TTL; authenticated use and existing file/epoch checks
still control reuse. The lookup tests cover expiry boundaries, clock extremes,
touch, replacement, eviction and unrelated entries. No lookup timing was measured.

| Validation | Result |
|---|---|
| Swift provider | 68 functions / 68 cases pass, zero skip/failure; build 141.46 seconds |
| Go protocol, registry and API | Six focused functions pass with the race detector |
| TypeScript | 14 tests across 3 files pass; touched-file ESLint passes |
| Source identity | 8 exact provider/fixture files, 664 provider inputs, 455 native inputs, 1,356 dependency inputs and 27 Jinja inputs verified |

The provider selection includes the prior 49 process-memory cases, two paged
footprint cases, 15 SSD cases and two real-allocator cases. Test groups execute
in separate processes. The final 16-file source union preserves the earlier
process-memory TypeScript fields; focused Go and TypeScript checks were rerun
after integration. Whole-project TypeScript and the full provider test suite
were not run in this milestone.

## Evidence and limits

The [manifest](evidence/provider-footprint-2026-09-05/manifest.json)
(SHA-256 `b8824c2e141020c755764ae84dc62d33e4a2c35fdcf9e98c1c250c6b0fcc12e7`) records 80 verified
payloads. The [archive](evidence/provider-footprint-2026-09-05/payloads.tar.gz)
has SHA-256 `e17546f2c0117d7945643f0b36c84a742ebe4aa948b9c3f812a6ebe5b53d2656`. The accepted provider
validation manifest is
`bfb58c3337fda3ffd7fc84c48cfab6b50caac48cd2b1d352424d3a0a95055967`.
Build products and model weights are excluded.

The complete Qwen/GPT-OSS/Gemma checkpoint union, production factory binding,
normal-MTP model runs, concurrent capacity, HTTP and signed-key restart remain
separate release gates. No model speedup, cache default or rollout is claimed.
Current field meanings are in the [protocol reference](../reference/protocol-messages.md#slotspaged_storage);
lookup flow is in [prefix caching](../architecture/prefix-cache.md).
