# Attention operator replay

This standalone diagnostic consumes one confirmed [attention packet v1](../attention_packet/FORMAT.md). It constructs no model, serving engine, SSD cache, key hierarchy or network client. It does not evaluate release gates or establish model parity.

The Python driver validates the complete packet before creating a fresh output directory, preserves all six native FP16/BF16/FP32 buffers and writes a bounded, hashed transfer. The Swift CLI checks transfer and raw lengths/hashes/packing before constructing an MLX array. Both enforce a 32 MiB input limit and a conservative 256 MiB allocation plan. That plan bounds these arrays and pools; it does not bound process RSS or the framework allocator cache.

Three arms run sequentially in separate processes:

- `nativeSDPA`: actual `MLXFast.scaledDotProductAttention`, with original Q and the production conversion of stored K/V to Q dtype.
- `pagedFixed`: the actual fixed-pool `PagedLayerCache.updateAndAttend` decode branch.
- `pagedSegmented`: the actual segmented-pool branch, with 256 usable pages per maximum segment so histories longer than 4,096 tokens cross a segment boundary.

Each paged arm seeds only T−1 tokens through the existing bulk writer and its fence. The selected incoming token then goes through the real fused decode write. After evaluation, ordinary gathers return complete chronological K/V for exact byte comparison. The paged branch is observed through the existing metadata hook; its synthetic observer remains unconfirmed and is never exported as model-forward evidence. Native SDPA identifies the API actually invoked, not an instrumented internal MLX kernel variant. Partition geometry is explicitly derived by the pinned pure dispatch sizer.

Use the pinned NumPy requirement in `../attention_packet/requirements.txt` in a dedicated virtual environment. From `scripts/benchmarks`, staging alone is:

```sh
python -m attention_replay --packet /owned/capture/packet.json --output /owned/new-replay --prepare-only
```

Execution additionally requires an explicitly reviewed built binary and SHA-256:

```sh
python -m attention_replay --packet /owned/capture/packet.json --output /owned/new-replay --binary /reviewed/attention-replay --binary-sha256 SHA256
```

Build the independent Swift package with `ATTENTION_REPLAY_SOURCE_ROOT` pointing to reviewed source containing `libs/mlx-swift` and `libs/mlx-swift-lm`. Build preparation must pin the existing dependency graph and Metal resources; an executable hash alone does not attest external resources. This driver performs no automatic build, download or signing.

The collector reports per-head/global L∞, RMSE, relative L2 and nonfinite counts against independent CPU FP32 softmax(QKᵀ × scale)V with GQA grouping. Original Q is primary. FP32 Q with narrower KV gets a separately labeled narrowed-Q counterfactual. Storage mismatch, nonfinite output or failure to reproduce the originally captured backend output makes interpretation inconclusive. Raw results remain available; failed/timed-out arms stop the sequence and retain logs/argv.

Replay does not reconstruct original physical slabs or graph strides, prove that original model history was stored correctly, or show that different backends produced identical Q/K/V. Those require the separate history mirror and model/captured-output investigations.

CPU tests plant head swaps, dropped-tail readbacks, transpose/shape mistakes, malformed/truncated bytes, wrong hashes/dispatch, symlink escapes, aliased page receipts and execution failures. Collector fixtures are not native execution. Swift tests invoke all three genuine operators across native dtypes, supported head dimensions and page/partition/segment boundaries. They keep the existing numeric oracle (`native relativeL2 ≤ 1e−2`, `paged ≤ max(3 × native, 1e−2)`) separate from exact storage and fixed/segmented output checks. These synthetic tests are not model-token gates.
