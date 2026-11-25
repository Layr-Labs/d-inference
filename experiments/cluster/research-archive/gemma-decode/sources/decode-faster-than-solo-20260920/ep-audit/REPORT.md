# Gemma exact expert parallelism: decode assessment, 2026-09-20

**The qualified EP16/112 implementation is a correctness result, not a promising speed configuration. A balanced expert-only follower is the useful next EP design; a resident version of the existing 607-control trace should not be the next benchmark.** This audit read source and small retained metadata/results only. No build, model execution, remote action, weight/binary hashing or existing-source edit occurred. `derive.py` reproduces `arithmetic.json`; its counts are analytic proxies, not measured GPU operations or DRAM traffic.

## What actually passed

The retained P32/C16/O2 EP16/112 pair agrees with ordinary full execution on both selected IDs `[1813,496]`, both complete 262,144-value rows and all 90 canonical state components on each rank, with no numerical tolerance. Its report explicitly says throughput measurement is invalid. The 46.19/46.21-second native lifetimes include loading, probe, trace and evidence; they are not decode times. The pair sent 5,778,432 / 42,882,048 tensor bytes and 607 controls in each direction. No encryption or serving qualification follows from it.

The comparison target **47.068 TPS** is the separately qualified padded-control **ordinary solo P4096/C64/O16**, one excluded warmup and three measured requests. It is not yet an O128 baseline. Same-build, same-prompt P4096/C64/O128 solo must be measured before an O128 EP speed claim.

## Parallel work and bandwidth

`Gemma4ExpertParallelModel` replicates all 30 attention layers, full/window KV, dense branches, router, embedding and output head. Only complete sparse expert banks are partitioned. `Gemma4Text.callAsExpertParallel` reconstructs unweighted outputs in original top-K slot order and calls the original `weightedExpertSum`. This preserves per-expert projection/reduction arithmetic; replacing it with rank-local weighted sums plus a cross-rank reduction would be a different arithmetic mode.

Registered geometry is H=2816, dense width2112, sparse width704, top8 of128, 16 query heads, 25 sliding layers (8 KV heads×256, window1024), five full layers (2×512, K=V), vocab262144. Useful matrix MACs per token:

| Work | MACs | Replicated? |
|---|---:|---|
| Selected sparse expert projections | 1,427,374,080 | Partitioned |
| Dense branch | 535,265,280 | Yes |
| Q/K/V/O projections | 1,110,179,840 | Yes |
| Router | 10,813,440 | Yes |
| Full output head | 738,197,504 | Yes |
| QK and attention-value products at context4097 | 545,341,440 | Yes |

Sparse experts are **32.68%** of these MACs at the first 4K decode and **32.61%** at frontier4223; 37.35% if attention products are omitted. Norms, GELU, softmax, dequantization, copies, guards and kernel scheduling are excluded. These are neither an elapsed-time fraction nor a throughput ceiling.

The actual single decoded token assigned **27/240 expert rows to rank0 and 213/240 to rank1**. Rank0 was empty in 10/30 layers. Thus only 11.25% of expert work was removed from the heavy rank: about **3.7% of the useful MAC proxy**, before communication and duplicate work. Static64/64 does not guarantee4/4 routing per layer either; actual top8 imbalance remains on the critical path.

Bandwidth does not reverse this conclusion. Expert banks are 88.79% of stored text weights, but a token reads only8/128 selected experts. Dense/router projections use8-bit weights; experts, attention and head use4-bit. From exact tensor headers, one read of the selected parameter operands is **2,424,219,708 B**, of which sparse expert rows are **802,897,920 B (33.12%)**. With F32 scale/offset operand bytes that proxy becomes2,663,084,092 B, experts892,108,800 B (33.50%). F32 cache reserves are charged by the owner; this is not evidence that every such cast is materialized on the BF16 path. Adding one BF16 K/V read at context4097 (293,621,760 B) reduces the expert share to **29.54–30.17%**. Cache reuse, repeated kernel loads, conversions and wrapped-KV copies are unmeasured. Do not substitute stored model size for hot-path memory bandwidth.

For scale only: if elapsed time followed that last proxy, perfect4/4 expert balance could remove about15% of solo token time before overhead (~3.1ms at21.246ms/token). Across30 layer dependencies that leaves roughly0.10ms per layer for **all** added routing, communication, synchronization and guards. Observed16/112 routing leaves only~0.7ms/token (~24µs/layer). These are conditional break-even budgets, not predicted TPS.

## Can window accounting make replicated64/64 fit?

Each64-expert rank retains **8,044,505,148 B selected tensors**, including the entire trunk/head, and **1,634,406,400 B possible persistent F32 projection casts**. The source-only adjacent-liveness proposal saves393,709,568 logical bytes at C16, adds4096 host bytes, and explicitly refuses C64/C128. It has not been executed. Its proof depends on the existing synchronous input eval, completed CPU/GPU communication fences, graph detachment, autorelease scope and concrete Wire. A new asynchronous wire cannot inherit that proof automatically.

Extending that same two-slot formula to C64 would charge112,488,448 logical EP-array bytes instead of1,687,326,720: a1,574,838,272-byte reduction before allocator rounding. Correct sliding attention exposure at C64 is at most **1024−1+64=1087**, not4224; global layers still require full context. The complete ring, previous ring and retained chunk views remain charged. This is a valid source direction for a future ledger, not current admission.

It still does **not** make replicated64/64 fit the retained machine state. An intentionally optimistic initial-free lower bound is **15,405,201,468 B**, already including only selected weights, the existing F32 cast/head reserves, complete F32 full/window state, one maximum host read plus native copy, aligned-read scratch and unchanged4GiB loading headroom. It omits every other trunk temporary, EP array, report/host buffer, transport reserve and allocator rounding. Retained EP16 launch actual free was12,527,714,304 B; the64/64 lower bound alone exceeds that by2,877,487,164 B. The earlier24/104 run refused before construction at12,141,969,408 free versus12,206,449,881 required. A cleaner future24GB host might have more free memory; the recorded availability does not admit balanced replicated EP. No floor should be lowered to force it.

## Communication and the 607-control trace

Every layer executes a bilateral scope agreement and both directions' rows-header / rows-ready / payload / rows-consumed protocol. Each JSON control itself uses a separately completed UInt32 length transfer and a completed JSON transfer. This is four sent plus four received controls per rank per layer: **16 completed control operations**, plus up to two data operations. The actual one-token decode used **534 completed operations per rank**, including its commit and ten empty-rank omissions. All150 layer exchanges in the short run produce2428 control operations per rank, separate from data.

The repeated CPU path evaluates routes, copies IDs, builds assignment/padding maps, copies and hashes input/weights/output, canonicalizes scope JSON, scans/decodes/re-encodes strict control JSON, retains150 scope receipts, and compacts/reassembles output. All of this is useful correctness evidence but is not an efficient resident protocol. Simply widening the current schedule to P4096/C64/O128 would require5790 layer exchanges and23,355 controls **per direction**, exceeding both its1024 lifetime cap and fixed150-observation contract. Do not just enlarge those arrays/caps.

Unweighted expert results alone total45,056 logical bytes/layer across both directions, or1,351,680 B/token. There are still30 sequential dependency boundaries. JACCL rounds posted scratch frames, not just logical payload bytes: `rdma.h` selects4KiB frames on pre26.3 systems, with larger bins available from26.3; `SharedBuffer` posts its complete capacity, and the qualified tail fix zeroes the remainder. A4-byte prefix therefore still posts at least4KiB. Link bandwidth alone is insufficient; completed-transfer and dispatch latency dominate small records. No retained EP per-layer timing establishes that latency yet.

## Recommended reusable split, before another resident EP benchmark

Use a **leader-owned target plus expert-only follower**, keeping original expert kernels and top-K order. The leader owns all CBv2 attention/window state, dense branch, head and sampling. The follower loads only its selected expert banks and returns unweighted rows; it has no duplicate target KV/head/dense model. Existing `ExpertAxisBank`/selection/projection policy and the SDK borrowed expert hook are the reuse points. This removes the largest unnecessary follower residency and does not introduce a second token/state owner.

The follower's64 expert banks alone are6,423,183,360 B; the conservative possible F32 expert-cast charge is1,427,374,080 B. Source read/copy overlap, C64 temporaries, transport and unchanged4GiB loading headroom still make this tight on the observed24GB host. Build a complete bank-only ledger and inspect fresh availability before promising64/64; an asymmetric bank ownership may be the first admitted candidate. Choose ownership from separate calibration prompts, then evaluate on held-out prompts; do not optimize it against the measured token trace alone.

Use one bounded input/route packet and one bounded result packet per layer, with typed fixed framing, exact epoch/request/frame/layer/ownership/ordinal and admitted shape. The result acknowledges actual input consumption only after completed expert execution; the next request may acknowledge the previously consumed result, with an explicit final flush. Keep old output storage until the real receipt or terminal retirement. The leader reconstructs original global slots and performs the unchanged weighted sum. It can compute its local experts while the peer computes, without simultaneous model evaluation during its own synchronous P2P call. Overlapping the already-built dense branch requires an explicit rooted evaluation plan and resource accounting; do not infer it from lazy graph construction. Full-duplex/async transport requires a separate completion/lifetime proof.

Retain fresh OS/native/resource checks at every remaining admitted operation and failure boundary, the6/4/2GiB policy, deadlines, poisoned-session refusal and actual group/process/lease retirement. Consolidating control transfers removes their associated redundant work; it is not permission to cache OS observations across operations or claim peer ACKs early. Keep detailed hashes/rows/states in a separate correctness mode and retain bounded scalar counters/timing in resident mode. Any encrypted run must use the qualified protected endpoint and include its actual framing/allocation costs; the current EP evidence is plaintext only.

First qualify the bank-only operator at P32/C16 against the ordinary reference, then C64 with exact full rows and all leader state, including window wrap. Only after a complete admitted ledger and layer exchange measurements justify the break-even budget should a resident P4096/C64/O128 cohort be built. Reuse the existing resident model loader, fresh request sessions, warmup/three measured requests, same-process clock, parent supervision and final comparator. Run a fresh same-build O128 solo with identical prompt, arithmetic/cache settings, capture and guard policy. This is a better EP path than benchmarking the existing correctness wire; remote-assistant target verification remains a separate potentially more favorable use of the second Mac.

## Exact source/evidence entry points

- [Actual EP comparison](../../gemma4-full-model-ep-physical-20260920/cases/p32-c16-o2-ep16-112-v1/comparison.json), [rank0 native result](../../gemma4-full-model-ep-physical-20260920/cases/p32-c16-o2-ep16-112-v1/pair/expert0/native/worker-0.stdout), [current solo/pipeline comparison](../../gemma4-decode-optimization-20260920/review-padded/actual-padded-1/REPORT.md).
- [Full model](../../gemma4-full-model-ep-20260920/SDK/Gemma4ExpertParallelModel.swift), [unchanged global-slot reduction](../../gemma4-full-model-ep-20260920/SDK/Gemma4Text.swift), [CPU dispatch/reassembly](../../gemma4-full-model-ep-20260920/Runtime/Gemma4ExpertCollectiveOperation.swift).
- [Wire scope/counters](../../gemma4-full-model-ep-execution-20260920/Runtime/Gemma4ExpertWire.swift), [payload ACK/ownership](../../gemma4-full-model-ep-execution-20260920/Runtime/Gemma4ExpertWirePayload.swift), [closed schedule](../../gemma4-full-model-ep-execution-20260920/Runtime/Gemma4ExpertExchangeSchedule.swift).
- [Existing owner](../../gemma4-full-model-ep-execution-20260920/Runtime/Gemma4ShortResourceOwner.swift), [all-layer budget](../../gemma4-full-model-ep-execution-20260920/Runtime/Gemma4ShortResourceBudget.swift), [unexecuted liveness proof](../../gemma4-full-model-ep-temporary-liveness-20260920/HANDOFF.md).
- [Bank reuse](../../gemma4-expert-projection-policy-20260920/Runtime/ExpertAxisBank.swift), [projection branch/alignment policy](../../gemma4-expert-prefill-bound-20260920/Runtime/ExpertAxisProjectionPolicy.swift). Full source and small evidence hashes are in `source-pins.json`.
