# Paged physical ownership and admission check

> Last updated: 2026-09-05 · commit `59e8a7bb2`

The opt-in segmented paged backend now accounts for actual native buffer
ownership under the engine's admission budget, including growth, grant shrink,
failed allocation and terminal cleanup. Native commit
`1236a813f9ac6da47a7028e7baf17fb3ac842f0a` contains the 21 tested paths;
224 actual cases passed. This is a memory-accounting milestone, not a production
backend switch or a five-model performance result.

The [evidence manifest](evidence/paged-physical-admission-2026-09-05/manifest-api.json)
records 437 captured native source/test hashes, the exact commit paths, build
and test logs, and the prefill lifetime corrections. The parent independently
verified all 21 committed source hashes and all 16 stored/raw evidence payloads.
The separately committed JSON Boolean bridge is outside this milestone.

## Ownership and capacity

Each segmented pool has one grant and epoch. Private replacement metadata and
new buffers prepare before publication; a stale epoch publishes nothing. Shrink
may leave existing physical owners temporarily above the grant. Reusing those
owners can proceed without growth, while any additional backing must fit the
current grant. Stable address ranges and generations prevent retired page IDs
from aliasing later owners. Growth does not copy live KV.

One `AdmissionV2` ledger binds one backend physical floor. Only that ledger's
nominal target KV offsets the floor: the charge is the larger of native backing
and prepaid target KV, plus recurrent/MTP state, exact external arrays and other
transients. Another slot's reservations cannot pay for this pool. Growth raises
the floor for existing and private candidate buffers before allocation. Failure
drops private arrays before refund; retirement drops native owners before
lowering the floor. These operations do not hold grant and admission locks
across GPU allocation.

Cold and adopted segmented rows prepay the same maximum-sequence target KV and
auxiliary requirements. Chunk and MTP rollback padding use the same capacity
policy. Deadline probes include poison pages and size-class overhead without
allocating buffers or address maps. The fixed-slab reference and production
backend selection remain unchanged.

The first prefill can attend directly to its input chunk without reading newly
written pages. `PagedLayerCache.innerState` now includes the owning group's
write fence in the normal step evaluation roots, including a request that ends
immediately after prefill. The regression avoids snapshot/gather helpers and
checks both weak wrapper retirement and the actual `Memory.activeMemory`
decrease inside the floor-refund callback. A vanished Swift wrapper alone would
not prove release of storage retained by a native lazy graph.

## Validation and limits

The native build passed in 101.82 s. All final groups passed without skips:

| Group | Actual cases | Seconds |
|---|---:|---:|
| Physical admission, independent ledgers, first-prefill ownership | 12 | 1.827 |
| Segment transfer, native dtypes, growth and grant epochs | 23 | 5.586 |
| Existing scheduler, deadline and frozen-prefix regressions | 163 | 53.036 |
| Resident-prefix regressions | 26 | 2.787 |

Capacity tests include separate ledgers, multiple requests, auxiliary/exact
charges, transient overlap, poison refusal, failed private growth, epoch races,
grant debt and ID reuse. The 36/64/128 GiB device envelopes with 8/16/32 GiB slot
grants are arithmetic tests, not measurements on three physical machines.

The new queue-captured `pagedStorage` diagnostics distinguish grant, committed
backing, reserved/live pages, poison, slack, segment/address counts and grant
debt. Production heartbeat plumbing is a separate follow-up. Mixed per-layer KV
dtypes, recurrent paged execution, page-native SSD checkpoint transfer and full
model/capacity/performance gates are still required before default promotion.
