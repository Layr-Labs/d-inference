# Resident paged prefix cache milestone

> Last updated: 2026-09-05 · commit `788ce9f06`

This record banks the tested resident-page cache integration and SSD tier
selection fix. It establishes cache ownership and deadline correctness in
focused tests; it does not establish a real-model latency improvement or
enable recurrent Qwen prefix reuse.

## Source and scope

Provider commit `788ce9f067f90128af1b71424023574b9d5d21c5` pins
`libs/mlx-swift-lm` to `713d2cf4bfb244ac1c8eef7e6a5e8c6fc99091f0`.
The changes adapt [provider PR #686](https://github.com/Layr-Labs/d-inference/pull/686)
and [MLX-LM PR #116](https://github.com/Layr-Labs/mlx-swift-lm/pull/116)
to the current engine without replacing its newer deadline handling.

- Complete resident pages can be shared using generation-stamped handles and
  reference counts. The prefix index does not reserve free pages against the
  allocator, and a recycled generation cannot satisfy an old cache handle.
  See `PagedKVPool` in
  `libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/Paged/PagedKVPool.swift`
  and the focused `Paged/PrefixBlocks/` module beside it.
- Publication uses confirmed causal ranges. A chained next step cannot
  publish unconfirmed tokens from the previous step; cancellation and page
  reuse are exercised by the cache/leak tests.
- Actual memory adoption remains distinct from SSD adoption and durable
  cache evidence. See `EngineV2RequestUsageSignal` in
  `provider-swift/Sources/ProviderCore/Inference/EngineV2Bridge+PrefixCache.swift`
  and `PrefixCacheEvidenceSequencer` in the same directory.
- A short resident match cannot hide a longer useful SSD match. The bridge
  compares conservative saved-token estimates before deciding whether to
  stage SSD data. `SSDPrefixCache.estimatedPrefillTokensSaved` reads only
  in-memory metadata; its shared planner applies existing replay, size and
  benefit bounds. Actual staging still authenticates bytes and revalidates
  availability. See
  `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDPrefixCache+StagePlan.swift`
  (`planStaging`) and `Inference/EngineV2Bridge.swift`.

Radix indexing and paged versus contiguous KV storage are separate choices.
This milestone adds resident page sharing to eligible paged slots; it does
not change the default backend or implement the later hybrid radix bank.

## Validation

Tests ran against a frozen source snapshot before these commits were made.
The final SSD overlay, including its empty-index fast return, was included.

| Check | Result | Evidence |
|---|---|---|
| Provider cache, bridge, backend gate and receipt tests | 242 tests, 32 suites; passed in 4.494 s | [Provider test results](evidence/paged-prefix-2026-09-05/provider-tests.log) |
| LM resident prefix, leak and paged pool tests | 27 tests, 3 suites; passed in 1.629 s | [Cache test results](evidence/paged-prefix-2026-09-05/lm-cache-tests.log) |
| First-token work projection and engine deadline tests | 28 XCTest tests; zero failures in 3.811 s | [Deadline test results](evidence/paged-prefix-2026-09-05/lm-deadline-tests.log) |
| Whitespace/error checks | Both repositories passed `git diff --check` | Checked before source commits |

The external LM test harness excluded unrelated package-access resolution
tests and colocated the matching native `mlx.metallib` with its executable.
The first attempt lacked that resource; the successful reruns above executed
the assertions. Deadline filters used the actual test class names
`CBv2FirstTokenWorkProjectionTests` and `CBv2FirstTokenDeadlineEngineTests`.

The [evidence manifest](evidence/paged-prefix-2026-09-05/manifest.json) records
source commits, native library hash and log hashes. Saved logs contain the
complete test-result segments; compiler/build diagnostics are omitted.

## Remaining measurement

Real-model paged reuse, recurrent-state radix reuse, cold capture overhead,
warm TTFT, decode throughput and MTP compatibility require separate results.
These test timings are validation durations, not serving latency savings.
