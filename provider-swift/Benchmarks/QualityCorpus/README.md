# Qwen quality corpus benchmark

This benchmark is a correctness/quality artifact for fixed-weight, prefill-only
experiments. It is not a serving mode. It loads one Qwen checkpoint once,
constructs one engine through `EngineV2Factory.makeProductionBuild`, applies the <!-- pragma: allowlist secret -->
checkpoint's ordinary chat template, and executes corpus cases sequentially.

Every case uses greedy decoding and a fixed-length window of at least 32 tokens.
Stop tokens and prefix caching are disabled so baseline and candidate reports
contain equal-sized cold-prefill continuations. The report includes raw token
IDs, FNV-1a checksums, authoritative streamed text, prompt-token counts, and
submit-to-first-token timing.

Files:

- `qwen-quality-v1.json`: original CC0 corpus.
- `qwen-quality-corpus.schema.json`: input JSON Schema.
- `qwen-quality-report.schema.json`: output JSON Schema.

Example on an Apple Silicon Mac, from `provider-swift`:

```bash
swift build -c release

env -u DARKBLOOM_QWEN35_PREFILL_MOE_TOP_K \
    -u DARKBLOOM_QWEN35_PREFILL_MOE_FULL_LAYERS \
    .build/release/darkbloom benchmark \
      --model ORG/QWEN_MODEL \
      --quality-corpus Benchmarks/QualityCorpus/qwen-quality-v1.json \
      --quality-run-label baseline \
      --quality-max-tokens 64 \
      --kv-backend contiguous \
      --quality-output /tmp/qwen-quality-baseline.json

DARKBLOOM_QWEN35_PREFILL_MOE_TOP_K=4 \
DARKBLOOM_QWEN35_PREFILL_MOE_FULL_LAYERS=39 \
    .build/release/darkbloom benchmark \
      --model ORG/QWEN_MODEL \
      --quality-corpus Benchmarks/QualityCorpus/qwen-quality-v1.json \
      --quality-run-label top4-layer39 \
      --quality-max-tokens 64 \
      --quality-baseline-report /tmp/qwen-quality-baseline.json \
      --kv-backend contiguous \
      --quality-output /tmp/qwen-quality-top4-layer39.json
```

The candidate command exits successfully when tokens differ: disagreement is
the measurement. It exits nonzero when reports are not comparable (different
model artifact hash, corpus hash, generation policy, case order, prompt
tokenization, or resolved KV backend).
