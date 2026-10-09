# Shared historical checkpoint storage measurement

> Last updated: 2026-10-09

The production encrypted writer retained and wrote 21.43% fewer bytes for a
Gemma-shaped fixture and 34.19% fewer for a uniform-FP32 GPT-OSS-shaped fixture.
The shared writer additionally authenticated every page, increasing donation
read traffic. These are storage byte receipts, not whole-model performance or
quality results.

## Scope and provenance

Source: d-inference `cba4827a9776d08099a2b6ad706db4b5044e5aaa`, with unchanged
SDK pins `mlx-swift-lm=3fd4944c3b3ee5cb45c5cbfac8805876332d3a29`,
`mlx-swift=6923a80f624f5c91fbf456efe4e00e9698a72961`, and
`mlx=cb77239be31b1df7f5db895226af55c39fc4f093`. The source-matched metallib
SHA-256 was `fb1ba8f90b9f1cc346246b7240c3986771464bd977c67f0ef03186811f16c85c`.
The first invocation failed before writes because the rebuilt test bundle lacked
that resource; `scripts/stage-test-metallib.sh` staged it before the successful
retry. This does not qualify release packaging.

The opt-in `SSDCheckpointStorageGeometryTests.productionGeometry` uses
CPU-scoped, zero-valued native-shaped tensors. It reads only cached model
configuration JSON, derives the actual ordered attention map through the SDK,
and invokes `SSDHybridCheckpointStore.donate` and the production authenticated
read paths. No weights, attention forward pass or token generation run.
Independent files and shared pages capture the same three endpoints: 1,024,
16,384 and 32,768 tokens. MiMo is outside this experiment.

| Fixture | Configuration SHA-256 | Dtype scenario |
|---|---|---|
| `gemma-4-26b-qat-4bit` | `29910322dd085f45c8f95c6c0f1611b20f722d6f6c8394321b34817e98a972fa` | BF16 throughout, matching the cached Gemma configuration |
| `gpt-oss-20b` | `d1c1f73bf62116ed0bb37c068af80534543cd1de9b61d609fc01bf70920e842d` | Uniform FP32 storage scenario; not a fresh runtime dtype observation |

The [machine-readable receipt](fixtures/2026-10-09-shared-checkpoint-storage/geometry.json)
SHA-256 is `8efe451eb057d5672bfe24aee523afe8d8276a34a06a8c6b537306b6bd904816`.

## Measured bytes

All table sizes are MiB (1,048,576 bytes). Retained size counts each inode's
encoded file length once; it excludes filesystem allocation rounding and
metadata/journal writes. Newly written size includes DBK3 headers, metadata,
wrapped keys, ciphertext framing and authentication tags; linked payloads are
uncharged. The fixtures use uncompressed DBK3, whose serialized length is
independent of zero values. Their values cannot establish compressibility.

| Metric | Gemma independent | Gemma shared | GPT-OSS independent | GPT-OSS shared |
|---|---:|---:|---:|---:|
| Unique retained bytes | 1,580.19 | 1,241.59 | 2,370.21 | 1,559.76 |
| Newly written bytes | 1,580.19 | 1,241.59 | 2,370.21 | 1,559.76 |
| Donation authentication reads | 0.00 | 1,581.23 | 0.00 | 2,375.62 |
| Deepest complete restore reads | 840.22 | 841.15 | 1,542.25 | 1,548.07 |

The retained/write reductions are **21.4277%** and **34.1931%**, respectively.
Deepest restore transfer grows by **0.1114%** and **0.3779%** from page framing
and the reference manifest. Donation authentication reads are a material
additional cost; reduced write volume does not prove faster persistence.

Gemma's configuration has five full-attention owners (two KV heads, width 512)
and 25 sliding owners (eight KV heads, width 256, window 1,024), with no borrowed
KV layers. GPT-OSS has 24 alternating full/sliding owners (eight KV heads,
width 64, window 128). Full-attention prefix pages share across the three
snapshots from one execution. Windows at these boundaries are disjoint and
remain independently retained.

## Validation and limits

The storage test passed. Its 87.247-second fixture duration is not a model
latency or throughput measurement. Earlier independent refactor validation
passed 87 tests in 13 suites, including corruption, source replacement,
complete native import, restart, endpoint retirement and inode accounting.
`make docs-impact-check BASE=origin/master` passed; `make docs-check` retains the
base revision's unrelated frozen-report link failure in
`2026-10-03-all-model-prefix-qualification.md`.

Active KV memory, real-model output parity, end-to-end SSD restore latency and
cross-request ancestry reuse remain separate gates. The current stable-page
sharing path accepts native historical layout only. The concurrent INT4 SDK
format (`affine-paged-historical-attention-v1`) stores opaque uint8 role blobs
rather than authenticated token-page topology; this measurement does not prove
shared-prefix savings for that format. Lossless codec and measured retention
composition require their own integrated tests and receipts.

Reproduction, after the source-matched test build, from `provider-swift/`:

```bash
DARKBLOOM_RUN_STORAGE_GEOMETRY=1 \
DARKBLOOM_STORAGE_GEOMETRY_OUTPUT=/tmp/kv-shared-geometry-full.json \
swift test --skip-build --filter SSDCheckpointStorageGeometryTests
```

The probe owns an isolated temporary cache and deletes it afterward. Run it
while the machine is idle; GiB-scale CPU/SSD traffic can perturb other
measurements.
