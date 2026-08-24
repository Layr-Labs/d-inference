# 069 — exact sequential Qwen prefix boundaries

Date: 2026-08-24  
Status: implemented as an ordered patch handoff; default off

## Scope

This extends note 060's exact hybrid-state cache from repeated complete prompts
to sequential requests with an exact shared token prefix. The state contract is
unchanged:

- every storage-owning full-attention K/V row;
- every request-owned Gated DeltaNet convolution tail and FP32 SSM state;
- the scalar model position;
- frontier logits only when the boundary is also the request's full prompt.

No KV-only Qwen path is enabled. A caller must still inject
`CBv2ExactStatePrefixCache` and enable the request's cache policy explicitly.
Existing serving, quality, and cold-throughput defaults remain cache-free.

## Cold construction

An exact-cache miss gives the scheduler the cache's block size. The scheduler
clamps ordinary text prefill chunks at each whole-block boundary, without
changing multimodal, disabled-cache, hit, or non-exact-cache rows.

After each boundary forward:

1. K/V and recurrent state are detached while they are the same visible
   generation;
2. the detached roots ride the step's existing `asyncEval`;
3. finalization commits the recurrent transaction;
4. only a non-discarded row publishes the immutable boundary.

Intermediate boundaries contain no logits. The final prompt boundary also
captures exact frontier logits, including when the prompt is not block-aligned.
A one-token final prompt slice is handled even though CBv2 executes that shape
through its rectangular decode implementation.

## Lookup and resume

`ExactPrefixCacheV2` checks the complete prompt first, then block-aligned
candidate lengths in descending order. Keys remain scoped by:

```text
format epoch + model identity + policy identity + block size
+ authenticated scope + token count + exact UInt32 token prefix
```

The first layout/spec-valid entry is pinned and returned. A boundary-only entry
at the request's full length is not a legal full hit because it has no logits;
lookup continues to the next-shorter boundary. A later complete prompt can
donate an upgraded full boundary with frontier logits when the existing entry
is unpinned.

Adoption gives each request fresh attention and recurrent owners. For a partial
match at `M`, the scheduler starts at `M` and forwards `[M, P)` normally. For a
full match at `P`, and only that form, the scheduler temporarily starts at
`P - 1` and samples cached frontier logits without applying token `P - 1`
twice. MTP remains suppressed only for that one full-hit frontier assignment.

## Capacity and cancellation

Every resident boundary is charged by exact array `nbytes`, including optional
frontier logits. Longest-prefix lookup pins the selected entry; all adoption
success/failure paths release the key at the matched prefix length. LRU
eviction never removes pinned entries and resident bytes never exceed
`maxBytes`.

A cancelled/discarded in-flight boundary is not published. Boundaries finalized
before a later cancellation remain valid immutable prefixes. Cancelling,
preempting, or advancing an adopter releases only that request's fresh wrappers
and cannot mutate the cache or another adopter.

## Benchmark integration

The opt-in provider benchmark reports
`prefixCacheMatchPolicy=longest-exact-block-prefix` and the exact cache block
size. Its construction request now builds durable boundaries for the existing
25/50/75/90-percent corpus. Warm rows report the observed longest aligned
boundary, state bytes cloned, saved prefill tokens, and exact cold/warm output
parity.

With the default 256-token block:

- an 8,192-token 75% prefix matches 6,144 tokens;
- an 8,192-token 90% prefix matches 7,168 tokens (87.5%);
- every matched fraction at or above 60% executes only the distinct suffix;
- identical prompts retain the zero-forward full-prompt frontier path.

The report validator permits honest misses/capacity skips, but any reported
exact hit must be direct, replay-free, no longer than the constructed common
prefix, and either block-aligned or a complete prompt.

## Apple Silicon result

The one-iteration 8,192-token M3 Max acceptance run
(`artifacts/e37-partial-prefix-8192.json`) measured:

| Corpus arm | Matched prefix | Cold | Warm | Speedup | Full output parity |
|---|---:|---:|---:|---:|---:|
| 25% | 2,048 (25%) | 22,027 ms | 16,657 ms | 1.32x | 100% |
| 50% | 4,096 (50%) | 21,146 ms | 11,164 ms | 1.89x | 100% |
| 75% | 6,144 (75%) | 21,076 ms | 5,866 ms | 3.59x | 100% |
| 90% | 7,168 (87.5%) | 21,378 ms | 3,035 ms | 7.04x | 100% |

All sixteen distinct-suffix warm rows were direct, replay-free hits and
matched their cache-disabled token sequences exactly. The report also retains
note 068's known identical-B2 second-token batch-geometry variation: its warm
rows reproduce the B1 donor boundary, while native B2 prefill selects the
alternate second token. First-token parity remains exact in every arm; the
new partial-prefix acceptance gate is therefore scoped to the distinct-suffix
corpus rather than relabeling that pre-existing B2 behavior.

## Regression matrix

- cache longest-match, shorter fallback, full-frontier upgrade, LRU, pinning,
  identity, and exact byte accounting;
- partial B1, B2, and B4 adoption;
- distinct suffix execution (partial hits must perform a model forward);
- complete generated-token parity against cache-disabled controls;
- full-prompt cached-frontier behavior;
- adopter cancellation and subsequent reuse;
- provider report/schema and request-correlated state-byte accounting.

## Ordered patch handoff

The nested library remote is not writable by this agent identity, so the root
repository retains the fetchable submodule gitlink. Apply:

1. `060-exact-cbv2-prefix-boundary.patch` in `libs/mlx-swift-lm`;
2. `061-cbv2-simultaneous-prompt-fork.patch` in `libs/mlx-swift-lm`;
3. `065-exact-sequential-prefix-boundaries.patch` in `libs/mlx-swift-lm`;
4. `061-provider-exact-prefix-wiring.patch` at the root;
5. `062-provider-exact-prefix-benchmark.patch` at the root.

## Apple Silicon run

From the repository root after applying the ordered patches:

```bash
cd libs/mlx-swift-lm
swift test --filter CBv2ExactPrefixCacheTests
swift test --filter CBv2ExactPrefixEngineTests

cd ../../provider-swift
swift test --filter QwenPrefixReuseTests
swift test --filter EngineV2PrefixCacheUsageTests
swift build -c release --product darkbloom

.build/release/darkbloom benchmark \
  --model qwen3.6-35b-a3b-vl-mtp-mxfp8 \
  --qwen-prefix-reuse \
  --qwen-prefix-corpus Benchmarks/QwenPrefixReuse/qwen-prefix-natural-v1.json \
  --qwen-prefix-prompt-tokens 8192 \
  --qwen-prefix-decode-tokens 64 \
  --qwen-prefix-iterations 3 \
  --kv-backend contiguous \
  --qwen-prefix-output /tmp/qwen-prefix-boundary-report.json

jq -e '
  ([.scenarios[]
      | select(.kind == "common-prefix"
          and .requestedCommonPrefixFraction >= 0.75)
      | .samples[].warm.rows[]
      | (.matchedTokens / .promptTokens)]
    | min >= 0.60)
  and
  ([.scenarios[]
      | select(.kind == "common-prefix")
      | .summary.fullTokenEqualityRate]
    | min == 1)
  and
  ([.scenarios[].summary.firstTokenEqualityRate] | min == 1)
' /tmp/qwen-prefix-boundary-report.json
```

## M3 Max result — 8K, three-run medians

| Exact matched prefix | Matched tokens/row | Cold B4 | Warm B4 | Speedup |
|---:|---:|---:|---:|---:|
| 25% | 2,048 | 21019.3 ms | 16233.7 ms | 1.295× |
| 50% | 4,096 | 20977.5 | 11191.3 | 1.874× |
| 75% | 6,144 | 20971.5 | 5768.9 | **3.635×** |
| requested 90% (87.5% aligned) | 7,168 | 20971.9 | 2968.0 | **7.066×** |

Every partial-prefix row has exact first-token, full generated-token, and
finish-reason parity in all three iterations. Full-prompt B1/B2/B4 hits
remain 196×/316×/406× by makespan.

Artifact: `artifacts/e37-partial-prefix-8192-3x.json`.
