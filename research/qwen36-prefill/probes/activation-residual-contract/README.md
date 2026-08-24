# Cohort activation contraction probe

This probe screens a fixed-weight cold-prefill mechanism before any serving
integration. It factorizes the **runtime activation cohort**
`X[M,K] ~= Q[M,r] B[r,K]`, not a checkpoint matrix:

```text
native:     Y = X W
candidate:  Y~ = Q (B W)
repair S:   Y~[S] += (X[S] - Q[S]B) W
```

`W` is unchanged. Repair rows are selected from errors on a deterministic
sentinel subset of output columns. The full output is used only to score this
offline probe; it is not used to select rows. At a 100% repair rate the
algorithm returns to the original projection (subject to floating association),
while a useful prefill point must stay inside the charged repair budget.

This differs from the exact-weight rank audit in `notes/047`: that audit proved
the dequantized checkpoint matrices cannot be replaced by sufficiently cheap
exact static factors. This experiment asks whether a real prompt cohort occupies
a small *runtime activation* subspace and uses the original weight for both
basis and residual projections.

## Local deterministic smoke probe

Requires Python 3 and NumPy:

```bash
cd research/qwen36-prefill/probes/activation-residual-contract
python3 probe.py \
  --synthetic \
  --rank 16 \
  --sentinels 16 \
  --repair-fraction 0 \
  --output /tmp/activation-contract-synthetic.json
python3 -m unittest -v test_*.py
```

The synthetic arm validates the implementation and arithmetic only. It is not
evidence that Qwen activations are low rank.

## Captured projection

`patches/078-e50-runtime-capture.patch` is a temporary, default-off seam against
the pinned `mlx-swift-lm` commit `ab73a82`. It intercepts only the CBv2 input to
`model.layers.12.linear_attn.out_proj`, and only when
`DARKBLOOM_QWEN35_E50_CAPTURE_DIR` is set. It exports each wide prefill stripe
as float32 `[M,K]`, the packed immutable weight/scales/biases, and the exact
runtime-dtype dequantized weight as float32 `[K,N]`. The float32 conversion is
lossless for the runtime BF16 values.

Apply it only in a disposable model-library checkout:

```bash
git -C libs/mlx-swift-lm apply --check \
  research/qwen36-prefill/patches/078-e50-runtime-capture.patch
git -C libs/mlx-swift-lm apply \
  research/qwen36-prefill/patches/078-e50-runtime-capture.patch
export DARKBLOOM_QWEN35_E50_CAPTURE_DIR=/absolute/path/e50-layer12-gdn-out
export DARKBLOOM_QWEN35_E50_CAPTURE_LAYER=12
export DARKBLOOM_QWEN35_E50_CAPTURE_MIN_TOKENS=512
darkbloom benchmark \
  --config /path/config.toml \
  --model qwen3.6-35b-a3b-vl-mtp-mxfp8 \
  --scheduler-prefill \
  --prefill-lengths 8192 \
  --prefill-iterations 1 \
  --kv-backend contiguous
```

The M3 research checkout used for the measured run had already replayed the
exact-cache patches, so its pre-capture `Qwen35.swift` SHA-256 was
`6a2c5cceffaca05d4a5f857a1326b795feda645c5c2b1897d522e7538b26a4e2`.
`patches/078-e50-runtime-capture-m3-6a2c.patch` is the same helper plus a
zero-context seam pinned to that exact source. Reproduce that overlay with
`git apply --unidiff-zero`; first verify the source hash above. The ordinary
patch remains the canonical overlay for the pinned `ab73a82` submodule.

The scheduler performs an uncaptured 128-token warm-up. A nominal 8,192-token
request has 8,191 measured prefill rows, normally emitted as three 2,048-row
stripes plus one 2,047-row stripe. Validate and assemble those stripes:

```bash
python3 assemble_capture.py \
  --capture-directory /absolute/path/e50-layer12-gdn-out \
  --output /absolute/path/e50-layer12-gdn-out/activation-8k.npy \
  --manifest /absolute/path/e50-layer12-gdn-out/capture-manifest.json \
  --expected-rows 8191 \
  --expected-input-width 4096 \
  --expected-output-width 2048 \
  --provenance root-commit,submodule-commit,patch-sha256
```

Run the preregistered `r=64,h=16,p=12%` cell directly:

```bash
python3 probe.py \
  --activations /absolute/path/e50-layer12-gdn-out/activation-8k.npy \
  --weights /absolute/path/e50-layer12-gdn-out/weight-dequantized-k-by-n.npy \
  --rank 64 \
  --sentinels 16 \
  --repair-fraction 0.12 \
  --power-iterations 0 \
  --output /absolute/path/e50-layer12-gdn-out/r64-p12.json
```

Or run the frozen local neighborhood (`r=32,48,64,80,96`;
`p=8,10,12,15%`; `h=16`) and archive every cell:

```bash
python3 sweep.py \
  --activations /absolute/path/e50-layer12-gdn-out/activation-8k.npy \
  --weights /absolute/path/e50-layer12-gdn-out/weight-dequantized-k-by-n.npy \
  --output-directory /absolute/path/e50-layer12-gdn-out/sweep
```

`capture-manifest.json` hashes every raw capture, immutable quantization tensor,
dequantized weight, and assembled activation. The sweep skips redundant
per-cell rehashing and points back to that manifest. A standalone `probe.py`
run hashes both inputs by default.

The reported MAC fraction charges:

- randomized range projection and basis coefficients;
- every configured power iteration and a conservative QR equivalent;
- basis rows through the unchanged weight;
- dense output reconstruction;
- exact sentinel columns;
- repaired-input reconstruction and exact residual weight products.

The `wall` object separates NumPy/CPU candidate operations from the full-output
oracle projection and scoring. `inclusive_candidate_seconds` includes range
construction, QR/basis coefficients, basis-through-weight, sentinel projection
and scoring, repair selection, output reconstruction, and residual repair. This
is an inclusive offline implementation measurement, not an MLX/Metal M2 result.

The `uniform_model_composition` field applies that one projection fraction to
all top-k4 linears only as a roof diagnostic.
`preregistered_model_schedule` separately emits the complete machine-readable
shape ledger from note 078, including all-expert basis cost and strict routers.
A real decision still requires captured per-family numerics and measured M3
wall time. The full experiment and continuation gate are in
`notes/078-activation-subspace-residual-prefill.md`.
