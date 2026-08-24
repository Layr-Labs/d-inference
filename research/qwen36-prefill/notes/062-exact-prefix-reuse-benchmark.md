# 062 — exact Qwen prefix-reuse benchmark

Status: **implemented as an ordered patch handoff; no real-model numbers claimed**

Exact warm-prefix reuse is a separate product path from the cold 8K objective.
The existing quality corpus intentionally disables prefix caching and remains
unchanged. This note records the dedicated serving benchmark added to measure
reuse without folding construction work into a warm-only claim or dropping the
compulsory miss.

## Measurement contract

One loaded Qwen checkpoint and one
`EngineV2Factory.makeProductionBuild` instance serve the complete run. <!-- pragma: allowlist secret --> The
engine is configured for four concurrent requests and receives one
request-correlated `ExactPrefixCacheV2` observation wrapper. The benchmark
carves one fifth of the unified request-state grant for one resident exact
boundary and gives the remaining four fifths to the four live rows; cache RAM
is never added on top of the serving grant. No phase constructs a replacement
engine.

Each scenario iteration uses a unique cache salt and executes:

1. **cold baseline** — the target B1/B2/B4 batch with
   `prefixCacheEnabled=false`;
2. **cache construction** — one cache-enabled donor request against an empty
   scenario scope, followed by publication confirmation;
3. **warm measurement** — the target cache-enabled batch.

The construction request has its own latency and cache-ready timing. Its
`miss` remains in `cacheAccountingIncludingConstruction`; the report also
publishes warm-only accounting so both product views are available. Disabled,
policy-skipped, capacity-skipped, adoption-failed, and miss outcomes are emitted
as observed. Command success does not relabel any of them as a hit.

## Workloads

The required matrix is fixed in the report validator:

| Scenario | Batch | Prompt relationship |
|---|---:|---|
| `identical-b1` | 1 | exact identical warm prompt |
| `identical-b2` | 2 | concurrent identical prompts |
| `identical-b4` | 4 | concurrent identical prompts |
| `common-prefix-25` | 4 | exact 25% token prefix, four distinct suffixes |
| `common-prefix-50` | 4 | exact 50% token prefix, four distinct suffixes |
| `common-prefix-75` | 4 | exact 75% token prefix, four distinct suffixes |
| `common-prefix-90` | 4 | exact 90% token prefix, four distinct suffixes |

`Benchmarks/QwenPrefixReuse/qwen-prefix-natural-v1.json` is original CC0
synthetic prose. The harness tokenizes it with the loaded checkpoint and joins
the shared and divergent pieces at token boundaries. It verifies the donor and
every common-prefix row diverge at exactly the requested token, so character
overlap is never used as a proxy for token overlap. Exact-state cache hits match
the complete prompt; the requested common prefix and the observed matched/saved
token counts remain separate fields.

The implemented exact-state cache is deliberately full-prompt-only. The
identical B1/B2/B4 rows can hit. The 25/50/75/90-percent rows have distinct full
token streams and therefore remain measured misses until arbitrary-boundary
recurrent snapshots exist. Keeping those arms is part of the honesty contract:
a full-prompt result cannot be presented as general common-prefix reuse.

## Evidence emitted

Every row records:

- cache outcome, matched tokens, actual prefill tokens saved, replay strategy,
  replay tokens, and boundary splits from `CBv2Usage`;
- exact logical `nbytes` of the atomic attention K/V + recurrent conv/SSM +
  frontier-logit snapshot correlated by request receipt ID and handed to
  backend adoption, reported as `stateBytesCloned` only for a terminal hit;
- submit-to-first-token and submit-to-terminal latency;
- first token ID/checksum, full raw token IDs/checksum, and finish reason.

Every batch records makespan, first-token makespan, hit/miss accounting, total
saved tokens, and total state bytes cloned. Cold and warm rows are paired by row
index for first-token, full-token, and finish-reason equality. Scenario
summaries use medians for makespan/construction time and aggregate all cache
outcomes without filtering failed attempts.

The cache-construction section separately records request latency,
submit-to-cache-ready time, cache-ready-minus-terminal time (normally negative
because exact donation publishes before first-token emission), and cache bytes
after publication. A callback is not enough to claim readiness:
`donationObserved=true` only when the exact cache's accepted-donation counter
advances for that request.

## CLI

From `provider-swift`:

```bash
.build/release/darkbloom benchmark \
  --model ORG/QWEN_MODEL \
  --qwen-prefix-reuse \
  --qwen-prefix-corpus Benchmarks/QwenPrefixReuse/qwen-prefix-natural-v1.json \
  --qwen-prefix-prompt-tokens 8192 \
  --qwen-prefix-decode-tokens 64 \
  --qwen-prefix-iterations 3 \
  --kv-backend contiguous \
  --qwen-prefix-output /tmp/qwen-prefix-report.json
```

The mode is opt-in, mutually exclusive with the existing sweep, scheduler
prefill, arrival, parity, and quality modes, and requires an explicit model.
All pre-existing benchmark defaults remain cache-free.

## Patch handoff

The exact-state API lives in `Layr-Labs/mlx-swift-lm`, where the agent identity
cannot push (`403`). Committing the local submodule gitlink would therefore
leave fresh clones pointing at an object they cannot fetch. The buildable root
commit keeps the existing fetchable gitlink and preserves the exact integration
as ordered patches:

1. apply `060-exact-cbv2-prefix-boundary.patch` inside
   `libs/mlx-swift-lm`;
2. apply `061-provider-exact-prefix-wiring.patch` at the repository root;
3. apply `062-provider-exact-prefix-benchmark.patch` at the repository root.

The third patch upgrades the committed CLI/report/corpus benchmark from its
fail-closed KV-only compatibility form to the exact-state cache described in
this note. It includes the exact-cache report schema and focused regression
tests. The local validation tree applies this sequence; the root branch does
not record an unreachable submodule object.

## Interpretation boundary

Qwen keeps historical `supportsPrefixReuse=false`; a KV-only cache remains
invalid. The additive `supportsExactStatePrefixReuse` capability is admitted
only when the caller injects `CBv2ExactStatePrefixCache`, so ordinary serving
and every pre-existing benchmark stay default-off. Without the ordered exact
state patches from note 060, the factory strips the cache and the report keeps
disabled/miss outcomes rather than fabricating a warm hit. This benchmark
change does not weaken that fail-closed production gate. <!-- pragma: allowlist secret -->

No Apple-Silicon real-model run is attached here. Unit coverage fixes the
scenario topology, token-boundary construction, request cache controls,
request-correlated state-byte accounting, construction-inclusive miss rate,
full-prompt-hit versus partial-prefix-miss validation, report round trip,
committed corpus, schemas, and CLI isolation.
