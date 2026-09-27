# Reusing segmented decode dispatch metadata

> Last updated: 2026-09-06 · commit `191291d96`

Full-attention paged decode now reuses its last immutable dispatch plan and device
metadata within unchanged page coverage. Native regressions pass in 69 functions
and 108 expanded cases. This milestone establishes metadata and execution
correctness; repeated real-model speed measurements remain pending.

## Source and lifetime

Native commit `a317dde5d678e96cd85327d86cc49a99ca86805c` changes six files from
`7d32d43977a5774f223b6892ecfbbaa844047600`: four production paths and two test
files. `PagedLayerCache` owns one `PagedSegmentDispatchCache`; repeated ordered
membership keeps it, while changed or empty membership releases it.
`PagedSegmentPreparedDispatch` holds host records and immutable device records
and value offsets. It holds no segment storage, row, query, output or write fence.

The key uses canonical row-table serial/version and order, page/partition
coverage, writer page, partition size, page size, group geometry and exact layout
ranges. Growing token length and write slot remain in fresh sequence metadata.
Current segment storage, parameters and group write fence are bound for every
dispatch. Direct callers without canonical row identity and windowed/nonzero-start
ranges use fresh preparation. Identical retired/recreated segment ranges preserve
address metadata, while new row serials prevent page-ID reuse from aliasing an
old request. In-flight graphs retain their own immutable metadata through the
existing evaluation fence.

No Metal source, FP32 attention arithmetic, partition policy, sampling, cache
routing or prefix-cache configuration changes. Optional native profiler/test
statistics count hits, rebuilds and bypasses and separate key-lookup time from
metadata preparation; normal decode reads no clock.

## Validation

Nine filters pass with zero failures or skips. The ten new functions cover eleven
cases: exact fresh-versus-cached host/device records at every page/partition edge,
more than 17 segment bindings, the Qwen geometry at 5,585 tokens, mixed-length row
order, partition/writer changes, rollback, Swift array copy-on-write, identityless
and window fallback, topology growth, row reuse, and weak storage retirement.
The growing-row test records 255 hits and 18 rebuilds over 273 positions.

BF16/FP32 lazy successors preserve output and complete KV bytes while old metadata
is replaced before evaluation. Aligned shared-prefix adoption gets an independent
tail without changing the donor. Actual direct and chained engine controls match
full emitted-token trajectories and forward geometry against clearing metadata
before every normal forward; shutdown releases bound metadata. Existing segment,
native-dtype failure/recovery, backend/speculative, prefix-sharing, ordinary packet
and Qwen paged regressions pass. Shared partial-frontier KV copy-on-write remains
unsupported by the existing backend.

The first compile stopped on one fixture passing an integer to `MLXArray.full`.
Source2 changes only that argument to `MLXArray(Float(2))`; production bytes stay
identical. Fresh validation2 builds in 74.01 seconds and runs all nine filters.
The original final-evidence counter initially omitted adjacent suites selected by
Swift Testing's filename filter; the corrected counter binds their exact declared
identifiers to the raw six-function dtype and 34-function backend logs. No source
or test execution changes were needed for that evidence correction.

Validation binds 914 canonical native inputs, 915 compile inputs, 1,356 dependency
inputs and 27 Jinja files. The declared graph matches 509 native, 256 dependency
and 14 Jinja source references. This does not claim every graph target links into
the selected test product. Actual MLX compilation uses the pinned local tree.

## Evidence and remaining work

The [manifest](evidence/segmented-dispatch-metadata-cache-2026-09-06/manifest.json)
and [archive](evidence/segmented-dispatch-metadata-cache-2026-09-06/payloads.tar.gz)
retain 114 checked payloads (5,086,466 raw bytes), including both
source freezes, the failed first compile, the exact fixture correction, all
passing raw logs, source/graph proofs and root source review. Binaries, model
weights and runtime resources are excluded.

Manifest SHA-256: `ef41be3db9ffe2e0114c61af8ea7af51dcc60d79071539ea5b7167cb217e001c`.
Archive SHA-256: `a253f58f3e0c47ae44b4a45fe2973c17af259c15d3524c62ce345612f8d98352`.

The optimized probe and repeated old/new paged Qwen measurements are separate.
The closest existing probe has identical provider/harness sources; its native
source differs by two additive standalone replay SPI files as well as this cache
change. That difference must remain explicit in measurement provenance.
[Benchmark validation](../developer/test.md#prefix-cache-benchmark-validation)
continues to require exact inputs and output evidence. No latency win or release
promotion is claimed here.
