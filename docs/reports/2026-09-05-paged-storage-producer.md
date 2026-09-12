# Paged storage telemetry and private checkpoint transfers

> Last updated: 2026-09-05 · commit `c8ec9469f`

The Swift provider now emits queue-captured paged storage observations through
the coordinator ingestion already banked in `92a2fc235`. Native commit
`326d9a27a9227e1636a7a584687193d425f0b4b0` also adds private page-native
checkpoint filling and bounded export. Fifty native cases and 82 provider
functions passed. Live SSD adoption and the complete paged codec remain unfinished.

## Behavior and ownership

`PagedKVPool.segmentStorageSnapshot` captures a pool generation, increasing
sequence, monotonic timestamp, ownership gauges and four cumulative refusal
counters. Nominal KV and physical-floor overhead come from the same Admission
lock and include detached owners until their resources retire. Grant publication
classifies stale epochs and grant refusals under its own lock; failure accounting
counts one failed transaction once, including rollback across allocation groups.

`PagedStorageTelemetryAdapter` copies scalars from the engine capacity snapshot
into `BackendSlotCapacity.pagedStorage`. It maps pool UUIDs to positive numeric
generations below `1 << 53`, preserves native sequence and capture time, and ages
repeated captures without changing their values. Missing, uncaptured or future
observations are omitted. A new pool resets the baseline. Off-queue grant updates
change the separate logical capacity fields immediately and leave the entire
allocator observation unchanged until a new queue capture.

The native checkpoint plan prices the actual checkpoint length M without
allocating page tables or native buffers. Its private storage allocates evaluated
segments and fills them from bounded packed tensor spans. Export captures page
owners and the write fence on the engine queue, then copies only the requested
span, using at most 17 source bindings per dispatch. Unsigned bit copies preserve
BF16, FP16 and FP32 payloads, including non-finite bit patterns. A completion
fence precedes host reads. There is no full-prefix contiguous gather in this seam.

The caller must reserve native destination storage before allocating it. The
exporter's future codec integration must reserve 6 MiB of native transfer
scratch: at most 4 MiB of output plus 2 MiB for metadata. Returned `Data` belongs
to separate provider I/O scratch. These private helpers do not attach pages to
a live pool, prove donor pinning through a durable write, or implement the full
import lifecycle. Windowed and borrowed-row plans remain refused.

## Validation

Tests ran locally with Swift's shared debug build and the matching Metal
library. The final native build reported 11.41 seconds; the final provider
build reported 71.94 seconds. These are build timings, not serving measurements.

| Native suite | Actual cases | Test duration |
|---|---:|---:|
| Private checkpoint storage | 8 | 0.787 s |
| Queue storage telemetry | 4 | 0.913 s |
| Physical admission | 12 | 0.902 s |
| Paged grant | 4 | 0.592 s |
| Segmented storage and attention | 19 | 5.380 s |
| KV resize | 3 | 0.254 s |

The 47 Swift Testing cases span 29 functions; the resize suite contributes
three XCTest cases. Coverage includes a successful first one-element export,
page/head/segment seams, more than 17 source segments, second-group allocation
failure, exact failure counters, detached owners, immutable capture provenance,
native buffer retirement, window decode and grant resizing.

The final provider run passed all 82 functions in three suites in 2.041 seconds,
with zero failures or skips. It covers optional wire fields and omission,
nil-versus-zero instrumentation, capture aging and reloads, existing capacity
and protocol contracts, and an actual paged engine snapshot reaching the bridge
and disappearing after shutdown. Native inputs match 444 source hashes; the
provider build matches 1,117 selected provider, native and dependency hashes.

Retained failures explain the test corrections: a mutating call inside a
`#require` macro expansion; an asynchronous startup test that assumed no newer
capture could arrive; and a native test expecting an injected raw error instead
of the backend's existing normalized capacity error. An oversized test filter
also exceeded the wrapper's temporary filename limit. Direct invocation was
checked for nonzero selection and no skips; an initial 76-function run was
expanded to the original complete 82-function selection. No production assertion
or compatibility gate was weakened to address those failures.

## Evidence and limits

The [evidence manifest](evidence/paged-storage-producer-2026-09-05/manifest.json)
records 59 compressed payloads, their stored and original hashes, commands,
source identities, final verdicts and prior failures. Manifest SHA-256:
`69b45d7eff67117726d080557f5470410ca22914490ebe5c2d1e51890b7b210f`.
The 17 changed source files are recorded separately inside that evidence and
were checked against the working tree and native commit before banking.

This milestone adds no real-model run, latency gain, multi-slot capacity proof,
complete paged SSD restore, persistent-key restart proof or default backend
change. Typed stage-to-active ownership, the shared process budget, window
checkpoint support and the full five-model serving matrix remain release gates.
