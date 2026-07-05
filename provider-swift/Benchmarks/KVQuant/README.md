# KV Quant Gate

This benchmark gate is scoped to the two current target models:

- `mlx-community/gpt-oss-20b-MXFP4-Q8`
- `mlx-community/gemma-4-26b-a4b-it-qat-4bit`

Do not use unrelated local models as release evidence. Smaller or unrelated models may be useful for compiler smoke tests, but they are not acceptance baselines for this workstream.

## Baseline Smoke

Use `candidate=fp16-kv` to exercise the fp16 reference path without candidate KV quantization:

```bash
cd provider-swift

swift run kv-quant-gate \
  --model-id mlx-community/gpt-oss-20b-MXFP4-Q8 \
  --model-dir /absolute/path/to/gpt-oss-20b-MXFP4-Q8 \
  --reference fp16-kv \
  --candidate fp16-kv \
  --suites perf,memory,output \
  --contexts 4096 \
  --decode-tokens 128 \
  --iterations 1 \
  --allow-missing-data \
  --out ../artifacts/kvquant/gpt-oss-20b-fp16-baseline.json
```

```bash
cd provider-swift

swift run kv-quant-gate \
  --model-id mlx-community/gemma-4-26b-a4b-it-qat-4bit \
  --model-dir /absolute/path/to/gemma-4-26b-a4b-it-qat-4bit \
  --reference fp16-kv \
  --candidate fp16-kv \
  --suites perf,memory,output \
  --contexts 4096 \
  --decode-tokens 128 \
  --iterations 1 \
  --allow-missing-data \
  --out ../artifacts/kvquant/gemma-4-26b-qat-fp16-baseline.json
```

If `--model-dir` is omitted, the gate attempts to resolve `--model-id` from the HuggingFace cache. Passing `--model-dir` is preferred for release runs because it pins the exact snapshot under test.

## Candidate Modes

Current production-candidate labels:

- `full-v-affine4:g64:start1024` — first safe candidate once live KV injection is wired.
- `full-v-turbo4:start1024` — target TurboQuant+ compact candidate.
- `full-kv-turbo4:start1024` and `turbo4v2:start1024` — M5-only experimental candidates after V-only modes pass.

Until live candidate injection is implemented, candidate modes intentionally report as skipped rather than emitting fake metrics.

## Target Policy

GPT-OSS-20B:

- Keep K fp16 by default.
- Compress full-layer V only.
- Preserve attention sinks with a sink-aware attention path.
- Leave 128-token sliding-window caches fp16.

Gemma 4 26B QAT 4-bit:

- Keep K fp16 by default.
- Compress full/global-layer V only.
- Leave sliding-window caches fp16.
- Disable or guard MTP until quantized KV capture is validated.

## Comparison

Threshold comparison is scaffolded with:

```bash
python3 scripts/kvquant/compare.py \
  -t provider-swift/Benchmarks/KVQuant/thresholds/release.json \
  provider-swift/../artifacts/kvquant/gpt-oss-20b-fp16-baseline.json
```

Missing metrics are skipped by default during development. Use `--strict-missing` for release validation once all suites are implemented.
