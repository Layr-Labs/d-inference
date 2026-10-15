# Portable Nemotron qualification fixtures

These are isolated SDK and provider **fixture harnesses**, not shipping provider
manifests or proof that the full checkpoint runs. Setup creates source symlinks
and copies manifests into a new directory. It does not build, download, resolve
packages, load weights, start a provider or alter source checkouts.

## Create the harnesses

Use the matching reviewed d-inference, mlx-swift-lm and mlx-swift revisions from
the handoff/PR stack. Initialize gitlinks separately if needed. Python 3.9+ is
required for setup; Apple Silicon, macOS 14+ and Swift 6.3+ with the matching
Xcode/Metal toolchain are required for native qualification.

From the d-inference checkout:

```sh
python3 scripts/nemotron-qualification/setup.py --output /tmp/nemotron-fixtures
```

The defaults use this checkout and `libs/mlx-swift-lm`, `libs/mlx-swift`. Override
all three for separate checkouts:

```sh
python3 scripts/nemotron-qualification/setup.py \
  --checkout /path/to/d-inference --sdk /path/to/mlx-swift-lm \
  --mlx /path/to/mlx-swift --output /tmp/nemotron-fixtures
```

The output must not already exist and must be outside the source checkouts.
Its parent must exist. Interrupted setup leaves its partial directory for
inspection; choose a new output path when retrying. Source links are live: freeze
and record checkout revisions before testing; concurrent source edits invalidate
reproduction. The provider's SDK wrapper replaces the remote mlx-swift dependency
with `../mlx-swift`, matching the fixture-tested local dependency layout. The
original SDK manifest is untouched. Both harnesses receive the captured
`Package.resolved` locks; use `--force-resolved-versions` with Swift build/test
commands to refuse dependency version drift. Templates are snapshots, not automatically
regenerated from future upstream manifests.

CPU-only manifest checks (no dependency resolution or native model execution):

```sh
swift package --package-path /tmp/nemotron-fixtures/sdk dump-package
swift package --package-path /tmp/nemotron-fixtures/provider dump-package
swift package --package-path /tmp/nemotron-fixtures/provider/packages/mlx-swift-lm dump-package
```

Before native tests, follow [build](../../docs/developer/build.md) and
[test](../../docs/developer/test.md): acquire exclusive GPU access, use isolated
state, build/stage the source-matched metallib and resource bundles, and preserve
fault/watchdog handling. The harness templates include the selected fixture
sources; they do not build the complete shipping provider graph. After those
prerequisites, the test commands are:

```sh
swift test --package-path /tmp/nemotron-fixtures/sdk --force-resolved-versions -j 1
swift test --package-path /tmp/nemotron-fixtures/provider --force-resolved-versions -j 1
```

These commands may resolve/download public Swift dependencies and execute GPU
work; setup does neither. No production credentials, routing or live accounts
belong in these runs. Synthetic tests cannot establish full-weight quality,
throughput, memory sufficiency, MTP acceptance or production readiness.

## Offline official checkpoint verification

The unchanged manifest describes all 88 shards of
`nvidia/NVIDIA-Nemotron-3.5-Super-VL-120B-A12B-NVFP4`, revision
`7d4bc747b6bdc2cff64c58d65da0d08dd9caa25c`. It includes MTP in shard 88.
No weights, full model index or config are included here. Obtain the exact
snapshot separately under its license. Use a directory with regular shard files;
the payload verifier rejects symlink shards, including ordinary symlink-based
Hub cache snapshots. Do not duplicate a large snapshot without checking space.

```sh
python3 scripts/nemotron-qualification/verify_nemotron_bundle.py \
  --index /path/to/snapshot/model.safetensors.index.json \
  --manifest scripts/nemotron-qualification/weight-manifest.json

# Optional: streams and hashes every shard; potentially long, read-only I/O.
python3 scripts/nemotron-qualification/verify_nemotron_bundle.py \
  --index /path/to/snapshot/model.safetensors.index.json \
  --manifest scripts/nemotron-qualification/weight-manifest.json \
  --weights /path/to/snapshot

NEMOTRON_INDEX=/path/to/snapshot/model.safetensors.index.json \
  python3 -B -m unittest discover -s scripts/nemotron-qualification -p test_bundle.py
```

Without `NEMOTRON_INDEX`, the three index-dependent tests skip; the two synthetic
payload safety tests still run. Verification pins the index and shard manifest,
checks all 88 shard names and 4,120 MTP entries, and optionally validates payload
sizes/SHA256. It does not inspect every config/tokenizer/license asset or qualify
inference. It performs no publication or network operations.

## Admission and reservation calibration

Full-checkpoint runtime calibration is required before enabling serving or
raising capacity. This measures memory budgets; it must not alter NVIDIA's
quantization calibration scales. Record exact source/model revisions, hardware,
OS, memory pressure, backend policy and image/context/concurrency geometry.

Measure load residency plus maximum staging and backend scratch; then measure
image decode/normalization/tower/projector, prompt prefill, attention/recurrent
state, decode and MTP draft/verify/rollback peaks. Include allocator slack,
simultaneously live arrays, graph resources and conservative OS headroom. Compare
observed physical/MLX peaks with the actual pending LOAD, media, activation and
KV reservations. A header shape estimate is not a measured activation floor.

Exercise refusal before allocation, near-limit admission, admitted concurrent
requests, cancellation during each phase, native completion failure, drain and
restart. Assert no early refund while GPU work/owners survive, no double refund,
no leaked charge after successful retirement, and no admission beyond the
calibrated total. Retain charges on uncertain native completion. Preserve the
conservative unmeasured vision reserve until reproducible worst-case evidence
supports a reviewed replacement; coordinate capacity units/semantics with the
platform owner. Do not change safety floors merely to make a model load.

Report reservation versus observed peak per phase and geometry, explicit margin
and limits, concurrency, cold/warm TTFT, prefill/decode throughput, and MTP
acceptance/useful-token speedup. Include repeat runs and failure receipts. No
full-model calibration or throughput result is supplied by these fixtures.
