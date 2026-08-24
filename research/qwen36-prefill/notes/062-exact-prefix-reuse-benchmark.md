# 062 — exact Qwen prefix-reuse benchmark

Status: **implemented; no real-model numbers claimed in this note**

Exact warm-prefix reuse is a separate product path from the cold 8K objective.
The existing quality corpus intentionally disables prefix caching and remains
unchanged. This note records the dedicated serving benchmark added to measure
reuse without folding construction work into a warm-only claim or dropping the
compulsory miss.

## Measurement contract

One loaded Qwen checkpoint and one
`EngineV2Factory.makeProductionBuild` instance serve the complete run. <!-- pragma: allowlist secret --> The
engine is configured for four concurrent requests and receives one
request-correlated `PrefixCacheV2` observation wrapper. No phase constructs a
replacement engine.

Each scenario iteration uses a unique cache salt and executes:

1. **cold baseline** — the target B1/B2/B4 batch with
   `prefixCacheEnabled=false`;
2. **cache construction** — one cache-enabled donor request against an empty
   scenario scope, followed by an explicit wait for the asynchronous donation;
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
overlap is never used as a proxy for token overlap. Prefix-cache matches remain
whole-block values in the report; the requested common prefix and the observed
matched/saved token counts are separate fields.

## Evidence emitted

Every row records:

- cache outcome, matched tokens, actual prefill tokens saved, replay strategy,
  replay tokens, and boundary splits from `CBv2Usage`;
- exact logical `nbytes` of lookup state correlated by request receipt ID and
  handed to backend adoption after any tail-replay slice, reported as
  `stateBytesCloned` only for a terminal hit;
- submit-to-first-token and submit-to-terminal latency;
- first token ID/checksum, full raw token IDs/checksum, and finish reason.

Every batch records makespan, first-token makespan, hit/miss accounting, total
saved tokens, and total state bytes cloned. Cold and warm rows are paired by row
index for first-token, full-token, and finish-reason equality. Scenario
summaries use medians for makespan/construction time and aggregate all cache
outcomes without filtering failed attempts.

The cache-construction section separately records request latency,
submit-to-cache-ready time, terminal-to-cache-ready time, and cache bytes after
publication. A callback is not enough to claim readiness:
`donationObserved=true` only when `PrefixCacheV2` retained a positive-byte
entry.

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

## Interpretation boundary

Qwen's current recurrent adapter advertises `supportsPrefixReuse=false` until
attention K/V and all request-owned recurrent state can be restored together.
The serving factory therefore strips the supplied KV-only cache today, and a
run on that adapter should honestly report
`capabilityUnsupportedReason=model_request_state_unsupported` plus disabled
rows—not a fabricated warm hit. The harness is ready to measure B1/B2/B4 and
partial-prefix behavior when the exact-state capability is proven, but this
change does not weaken that fail-closed production gate. <!-- pragma: allowlist secret -->

No Apple-Silicon real-model run is attached here. Unit coverage fixes the
scenario topology, token-boundary construction, request cache controls,
request-correlated state-byte accounting, construction-inclusive miss rate,
report round trip/validation, committed corpus, schemas, and CLI isolation.
