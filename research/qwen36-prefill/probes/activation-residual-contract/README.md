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
python3 -m unittest -v test_probe.py
```

The synthetic arm validates the implementation and arithmetic only. It is not
evidence that Qwen activations are low rank.

## Captured projection

Export one prefill activation as a floating `.npy` matrix in `[M,K]` order and
the corresponding **dequantized checkpoint values** as `[K,N]`. Record the
checkpoint hash, layer, projection path, batch, prompt length, chunk geometry,
and export dtype alongside the files. Then run:

```bash
python3 probe.py \
  --activations /path/layer-12-post-attn.npy \
  --weights /path/layer-12-gdn-out-weight-k-by-n.npy \
  --rank 64 \
  --sentinels 16 \
  --repair-fraction 0.12 \
  --power-iterations 0 \
  --output /path/layer-12-gdn-out-r64-p12.json
```

Input files are SHA-256 hashed by default. `--skip-input-hashes` is for
iteration only and is not acceptable for an archived result.

The reported MAC fraction charges:

- randomized range projection and basis coefficients;
- every configured power iteration and a conservative QR equivalent;
- basis rows through the unchanged weight;
- dense output reconstruction;
- exact sentinel columns;
- repaired-input reconstruction and exact residual weight products.

The `uniform_model_composition` field applies that one projection fraction to
all top-k4 linears only as a roof diagnostic.
`preregistered_model_schedule` separately emits the complete machine-readable
shape ledger from note 078, including all-expert basis cost and strict routers.
A real decision still requires captured per-family numerics and measured M3
wall time. The full experiment and continuation gate are in
`notes/078-activation-subspace-residual-prefill.md`.
