# Same-binary segmented metadata attribution

> Last updated: 2026-09-06 · commit `e48847902`

A standalone native profiler now compares cached and freshly rebuilt dispatch
metadata through the actual segmented layer-cache path. On one local M3 Max,
three paired synthetic runs reduce host metadata preparation from about
0.162 ms to 0.011 ms per ten-owner step, while every output and full KV history
matches exactly. These are attention-only measurements, not full-model decode
or pure GPU kernel timings.

## Method and source

Native commit `15570242f49858f35e4e6ecfd83eed6c7826ae85` adds four files/target
changes over `a317dde5d678e96cd85327d86cc49a99ca86805c`: a diagnostics SPI extension
on `PagedDecodeProfiler`, the `BenchSegmentedDecode` executable, its package
target, and boundary/equality tests. Production cache logic, Metal arithmetic,
partition policy, FP32 intermediates and default instrumentation remain unchanged.
The profiler explicitly opts into `PagedSegmentDispatchCache.Statistics`.

Both arms run `PagedLayerCache.updateAndAttend` with identical pre-evaluated
BF16 inputs: B1, 16 query heads, two KV heads, D256, scale 0.0625, and ten
full-attention owners. Each arm starts with a fresh pool, prefill at offset 5576,
eight untimed warmup steps, then 64 measured steps from output offset 5585
through 5648. The middle pair runs fresh first; the other pairs run cached first.
Each step rebinds the same ordered rows. The fresh arm clears only the dispatch
metadata before each owner call; current sequence metadata and the normal group
write fence remain live in both arms. A zero-valued output dependency serializes
owner attention graphs. This is synthetic attention work, not a model forward.

The configured pool grant is 256 MiB and segment target 64 MiB. Actual allocation
contains eight resident segments shared by ten owners, with page ranges
`[0,1025)`, `[1025,2050)`, `[2050,3075)`, `[3075,3332)`, `[3332,3461)`,
`[3461,3526)`, `[3526,3535)`, and `[3535,3538)`. Every recorded owner dispatch
uses one binding-class 4 bucket. At offset 5585 there are 22 partitions of 256 tokens;
at 5633 there are 23. The report retains exact segment byte sizes, offsets, bucket
segment IDs, work counts and geometry changes. Production-sized settings are
configuration facts; they do not assert an identical live-model allocator state.

Host construction spans row binding, optional clearing and lazy graph creation.
Fenced evaluation spans the existing `eval(outputs)` and stream synchronization,
including encoding, submission and completion. Whole-step time is their sum.
Setup, input generation, warmup, geometry inspection and native-byte hashing are
excluded. Every measured output is hashed after its fence; the complete final
native BF16 K/V history is gathered and hashed outside timing. All six arms match
every output and full-history digest, including across repetitions.

## Local observations

The host is an Apple M3 Max (`Mac15,11`) with 36 GiB on macOS 26.4. One optimized
process runs all six arms in 3.92 seconds. Local compiler/model work is idle during
measurement. Load averages and environment are retained; no thermal acceptance
claim is made. No M5, provider or model operation is performed by this profiler.

Each cached arm records 600 hits and 40 rebuilds across 640 owner calls; each fresh
arm records zero hits and 640 rebuilds. The cached 40 rebuilds are the four page
crossings per owner, including the partition crossing. Key construction costs
about 0.0016–0.0021 ms per step in both arms. The table contains mean milliseconds
per synthetic ten-owner step:

| Pair | Arm | Metadata preparation | Host construction | Fenced evaluation | Whole step |
|---|---|---:|---:|---:|---:|
| 1 | cached | 0.0111 | 0.238 | 2.773 | 3.012 |
| 1 | fresh | 0.1623 | 0.426 | 2.914 | 3.340 |
| 2 | fresh | 0.1607 | 0.427 | 2.881 | 3.308 |
| 2 | cached | 0.0107 | 0.270 | 2.775 | 3.045 |
| 3 | cached | 0.0104 | 0.279 | 2.968 | 3.247 |
| 3 | fresh | 0.1624 | 0.439 | 3.558 | 3.997 |

The repeatable host preparation reduction is about 0.150–0.152 ms per step.
Host construction falls by 0.157–0.188 ms. Fenced and whole-step times vary more,
especially the final fresh arm; they include host submission and synchronization,
so they cannot be interpreted as isolated Metal kernel time. The separate
full-model comparison determines any end-to-end benefit. No timing threshold,
rollout change or full-model speedup is asserted here.

## Validation and provenance

Two selected native filters pass four functions/six expanded cases with no skips.
The new tests refuse unbounded inputs before allocation and compare every output,
full history, resolved geometry and exact hit/rebuild counts across page 32 and
partition 256 boundaries. Existing cached lazy-successor replacement and shared
prefix/tail tests also pass. There are no timing assertions.

Source1 passes native tests and an optimized build. Source2 removes a redundant
setup cast, adds the same-row binding to every synthetic step and clarifies its
timing label. Both filters pass again. Only the exact source2 optimized executable
is measured. It passes eleven bounded parser/help checks; there are no failed
build or test attempts in this milestone.

The optimized build takes 65.64 seconds. Executable SHA-256 is
`33b7483a7705dcb7283658ac6c06802f9ed50fb5a91b347ebbdffb777733229e`
(33,789,128 bytes, mode 0755). All six runtime resources retain the previously
verified bytes and modes. The declared optimized graph matches 512 native,
256 pinned dependency and 14 Jinja source references; this does not claim every
graph target links into the selected executable. The actual MLX source path is
the pinned local tree, independently of unused SwiftPM checkout resolution.

The [evidence manifest](evidence/segment-metadata-profiler-2026-09-06/manifest.json)
and [archive](evidence/segment-metadata-profiler-2026-09-06/payloads.tar.gz) retain
181 checked payloads, including both source versions, native logs, exact
source/graph proofs, preserved unmeasured build1, final build and parser logs,
raw per-step timings and output/history hashes. Binaries and model weights are
excluded. Archive SHA-256: `7db1563683378ba1c89acfa7e210208cc06138264675aa4667cb951a538359bd`.

See [the dispatch cache milestone](2026-09-06-segmented-dispatch-metadata-cache.md)
for ownership and invalidation correctness. This profiler establishes a bounded
host-preparation attribution for that change; full-model acceptance remains
separate.
