# Coherent allocator memory snapshots

> Last updated: 2026-09-05 · commit `966eac55c`

The existing Swift `Memory.snapshot()` now captures active, cached and peak
allocator bytes under one native allocator lock. CPU, Metal and the Swift C
bridge pass focused checks. A separate copy using the old independent getters
produced 30 inconsistent totals in 20,000 observations. This is an accounting
primitive for shared admission; it does not establish model capacity or latency.

## Change and source identity

| Repository | Base | Validated source commit |
|---|---|---|
| `mlx-swift` | `6b0505cc790f512ae49d740b21e13f80802946bd` | `eafd98a7c53c145ff40faa486c5f696b7104ae92` |
| Nested MLX | `734241bbff26467bb33eff8adc65b82d17b33578` | `9b3f4d1ec6bd65314e06825658334e5788ee3167` |
| Nested `mlx-c` | `9ff12fab2634d6d76276823164dc8ceeea68dca9` | `720953eff635e772d9f3d73e46942bc49fac04c3` |

Native `get_memory_snapshot()` reads the existing counters under each backend's
allocator mutex. The generated C bridge exposes one call, including its generator
override and both Swift header layouts. `Memory.snapshot()` calls that bridge
once. Existing individual getters and allocation policy remain unchanged.

The call does not synchronize streams, acquire the Swift memory queue, walk
allocator containers or call an engine. Initialize the allocator singleton before
taking a future process ledger lock. The allocator mutex can wait behind existing
allocator work; the snapshot is a constant-size capture, not a lock-free promise.

## Validation

One isolated Apple M3 Max, 36 GiB, macOS 26.4 lane executed these checks. The
source manifests cover all 15 changed files and 1,353 selected tracked inputs
across the three repositories. Root independently verified their hashes before
committing the exact tested bytes.

| Check | Result |
|---|---|
| Metal cache-to-active-to-cache transfers | Pass: 20,000 coherent observations |
| Metal capture while CPU stream work is blocked | Pass: capture completes before stream release |
| CPU allocator equivalents | Both pass |
| Separate CPU copy with the old independent getter implementation | Expected failure: 30 inconsistent observations out of 20,000 |
| Restored CPU candidate after the negative control | Both pass |
| Swift `MemoryTests/testCoherentSnapshotTracksRetainedBuffer` | Pass: actual retained 64 KiB MLX array through the C bridge; 0.022 s |
| Swift build | Pass; 51.03 s reported build time |

The first Swift runtime invocation failed because the isolated XCTest location
had no default metallib. Placing the source-matched library beside the executable
fixed the test without changing source or relaxing assertions. Both invocations
are preserved. CUDA has the symmetric source implementation but was neither
compiled nor executed on this host.

## Evidence and limits

The [evidence manifest](evidence/coherent-memory-snapshot-2026-09-05/manifest.json)
contains 45 compressed payloads: original commands and logs, negative-control
source, source manifests and patches, the source archive, executable hashes, and
the nested commit record. Every stored and decompressed hash was verified against
the original. Manifest SHA-256:
`f31694a336c96796ea9ccbc40745dbd0cafebf6b43bf9d2d9938642b4755604b`.

Allocator accounting is not process RSS or a physical-residency measurement.
Fresh allocations performed outside the mutex enter these counters at the
existing registration step; release can unregister before OS release. Shared
admission must retain promises across these windows, credit only exact evaluated
owned backing, and withdraw that credit before backing can disappear. This
milestone does not integrate that provider ledger, change backend defaults, or
prove real-model serving, capacity, latency or restart persistence.
