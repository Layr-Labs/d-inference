# Qwen benchmark provenance

`capture.py` writes a deterministic JSON envelope for one benchmark arm. It
captures the state needed to compare prefill artifacts without changing or
reformatting any measured result:

- root commit/tree plus every recursive submodule SHA and dirty status;
- benchmark executable and source-matched `mlx.metallib` SHA-256;
- lightweight model configuration/index hashes and a safetensor identity
  manifest;
- macOS, Xcode, Swift, Metal compiler/linker, machine, power, and thermal data;
- benchmark-relevant environment, a canonical configuration hash, top CPU
  processes, and every supplied stderr artifact path/hash.

The helper does not execute a benchmark or mutate serving code. Capture once
immediately before a cell and once immediately after it while the benchmark
posture still holds. Include `phase=before` or `phase=after` as a benchmark
setting so both documents are self-describing.

## Decision-grade invocation

```bash
PROVENANCE=research/qwen36-prefill/provenance/capture.py

python3 "$PROVENANCE" \
  --repo "$CAND_ROOT" \
  --binary "$CAND_BIN" \
  --metallib "$(dirname "$CAND_BIN")/mlx.metallib" \
  --model-path "$MODEL_PATH" \
  --model-manifest "$MODEL_MANIFEST" \
  --config "$CONFIG" \
  --benchmark-setting arm=candidate \
  --benchmark-setting phase=after \
  --benchmark-setting batch=4 \
  --benchmark-setting prompt_tokens=8192 \
  --benchmark-setting kv_backend=contiguous \
  --stderr-path "$OUT/arrival-candidate-1-b4-l8192.stderr" \
  --require-exact-model-identity \
  --output "$OUT/provenance-candidate-after.json"
```

Repeat `--config`, `--benchmark-setting`, and `--stderr-path` as needed. The
script captures all set `DARKBLOOM_*`, `MLX_*`, `MTL_*`, `METAL_*`, `OMP_*`,
`VECLIB_*`, `SWIFT_*`, `HF_*`, and `HUGGINGFACE_*` variables, plus explicit
`--env-name`/`--env-prefix` additions.

## Model identity without a 20 GB read

The script never hashes safetensor payloads. It instead accepts one of these
immutable identities:

1. a registry manifest whose aggregate and per-file identities are
   self-consistent and whose names/sizes plus lightweight metadata hashes match
   the local snapshot;
2. Hugging Face safetensor symlinks whose blob names are SHA-256 digests;
3. an immutable 40–64 hex snapshot revision (or `sha256:<digest>`) supplied via
   `--model-snapshot-id`.

A plain directory named `local` with ordinary shard files has no exact identity
unless a registry manifest or immutable ID is supplied. The JSON records that
state as incomplete, and `--require-exact-model-identity` fails closed.

## Secret handling

Only benchmark-related environment names are selected. Names associated with
tokens, passwords, credentials, private keys, database URLs, and similar
secrets are emitted as `<redacted>`. Credential-bearing URLs lose userinfo and
query strings. The process inventory uses executable names only and never
captures command arguments. Configuration files and stderr logs are hashed;
their contents are not serialized.

Run the serialization and identity regression suite with:

```bash
python3 -m unittest discover \
  -s research/qwen36-prefill/provenance \
  -p 'test_*.py'
```

The archived E3/E4 source can be restored into the MLX-Swift checkout with:

```bash
git -C libs/mlx-swift apply \
  ../../research/qwen36-prefill/patches/e3-e4-dense-reference-probe.patch
```
