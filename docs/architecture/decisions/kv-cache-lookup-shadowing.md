# KV-cache lookup shadowing on small-window hybrid models

**Status:** Accepted / Deferred

## Context

The checkpoint-tier prefix cache (`PrefixCacheManager`) looks up prefixes in two tiers: an in-memory LRU (`PrefixCacheRAM`) and encrypted SSD files. The current implementation checks RAM first, iterating checkpoints from longest to shortest, and only consults SSD if **no** checkpoint hits in RAM.

For hybrid sliding-window models with a small window (e.g. GPT-OSS-20B, window = 128), the in-window checkpoints are tiny (~0.7 MB at 64 tokens, ~1.4 MB at 128 tokens). Dozens of them fit in RAM and are rarely LRU-evicted. Larger checkpoints (e.g. 2048 tokens, ~12 MB) are evicted from RAM, promoted to SSD, and would save far more prefill — but the lookup returns the still-resident tiny checkpoint before it ever reaches the SSD tier. The SSD tier is **shadowed**.

Evidence on GPT-OSS-20B (M5, round-robin over 60 prefixes, `MAX_GB=0.1` / `DISK_GB=0.05`):

```
prefix cache stats: lookups=239 hits=223 (ram=223 ssd=0) misses=16 hitRate=93.3%
                    stores=8 ssdFlushes=15 diskEvictions=11 ssdReadErrors=0 ...
```

`ssdFlushes=15` shows large checkpoints were written and evicted, yet `ssd=0` shows no lookup ever reached SSD.

## Decision

Accept the current RAM-first behavior and defer a fix.

- The behavior is **correct**: a 128-token restore is valid and the suffix is correctly re-prefilled.
- The only impact is **performance**: the cache under-utilizes SSD for small-window hybrids once the long checkpoint leaves RAM.
- The preferred future fix is to prefer the longest checkpoint across **both** tiers (load from SSD when the longest available checkpoint is only on disk). This makes hit value match hit count but adds a decrypt read to the hot path, so it needs a cost/benefit validation before implementation.
- Alternative mitigations (skip tiny checkpoints for long prompts, size-aware RAM eviction) are recorded but not chosen.

Until fixed, hit-rate metrics are misleading for small-window models: a 93% hit rate can mean almost all hits are tiny prefixes. Use tokens-saved or TTFT to assess real benefit.

```text
lookup(tokens):
  checkpoints = longest-to-shortest crossed boundaries
  for cp in checkpoints.reversed():       # longest first
    if ram.peek(cp): return RAM hit       # ← tiny checkpoints hide here
  return selectSSDCandidate(...)          # never reached in the observed case
```

## Consequences

| Positive | Negative |
|---|---|
| No code change; no risk of regression. | GPT-OSS-20B and similar small-window hybrids see reduced TTFT benefit after the long checkpoint is RAM-evicted. |
| Gemma-4 (window 1024) is unaffected; its smallest checkpoint is already large, so its SSD tier is exercised heavily and remains the representative SSD stress test. | Hit-rate metrics overstate cache value for affected models. |

## Relevant code paths

| Concern | Code path |
|---|---|
| RAM-first lookup algorithm | `provider-swift/Sources/ProviderCore/KVCache/PrefixCacheManager.swift:448-500` (`lookup`, `lookupCandidate`) |
| SSD candidate selection | `provider-swift/Sources/ProviderCore/KVCache/PrefixCacheManager.swift:594-613` (`selectSSDCandidate`) |
| Small-window boundary derivation | `provider-swift/Sources/ProviderCore/KVCache/PrefixDigest.swift:44-56` (`checkpoints(forSlidingWindow:)`) |
| Original finding + evidence | Merged from the deleted `kv-cache-lookup-shadowing-finding.md` (observed on GPT-OSS-20B, M5, 2026-06-07) |

## Open question

What is the TTFT break-even for loading a large SSD checkpoint versus re-prefilling the tail on a 20B-class model? A microbenchmark is needed before implementing the cross-tier longest-prefix preference.
