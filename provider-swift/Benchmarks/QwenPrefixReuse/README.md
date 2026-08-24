# Qwen exact-prefix reuse benchmark

This is an opt-in serving benchmark, separate from the cache-free Qwen quality
corpus. It loads one checkpoint once and constructs exactly one engine through
`EngineV2Factory.makeProductionBuild`. <!-- pragma: allowlist secret --> Every scenario and phase runs through
that engine.

For each iteration the harness evicts the in-memory reference cache, then runs:

1. a cache-disabled cold batch;
2. one cache-enabled construction request against the empty scenario scope;
3. a cache-enabled warm batch.

The report keeps the construction request and its compulsory miss separate from
the warm makespan, while also publishing a construction-inclusive hit/miss
denominator. Unsupported, policy-skipped, capacity-skipped, and adoption-failed
outcomes remain in the JSON; they are never rewritten as hits.

Scenarios:

- identical prompts at B=1, B=2, and B=4;
- B=4 prompts with exactly 25%, 50%, 75%, or 90% common token prefixes and
  distinct suffixes.

The prose corpus is human-reviewable, but overlap is constructed after
checkpoint tokenization. This avoids treating character overlap as token
overlap. Greedy, fixed-length cold and warm outputs are compared by first token
and full raw token sequence.

Files:

- `qwen-prefix-natural-v1.json`: original CC0 synthetic prose.
- `qwen-prefix-corpus.schema.json`: input JSON Schema.
- `qwen-prefix-report.schema.json`: output JSON Schema.

Example on an Apple Silicon Mac, from `provider-swift`:

```bash
swift build -c release

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

A successful command means the measurement completed and validated, not that
every warm request hit. Read `capabilitySupported`, row-level `cacheOutcome`,
and `cacheAccountingIncludingConstruction` before interpreting speedups.
