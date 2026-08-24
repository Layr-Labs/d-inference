# 083 — Cross-layer artifact projection batching handoff

Date: 2026-08-24  
Status: **implemented as an ordered patch; default off; M3 performance and
semantic quality pending**

## Contract

E51 runs layers 0–3 at full depth. Its 320 historical B1×512 rows then pass
unchanged through skipped layers 4–39 while only their persistent artifacts are
constructed. Patch 079 exploits that independence without changing the suffix
river:

- a lazy immutable bank stacks all 30 GDN `qkv`/`a`/`b` and all 10 attention
  `k`/`v` quantized projection families;
- each eligible skipped-layer run normalizes the unchanged history by layer and
  issues one matrix-level gathered QMM per family, with one sorted RHS layer ID
  selecting each complete `[B * history, hidden]` matrix;
- recurrence, K normalization, RoPE, K/V commitment, and full-depth suffix
  traversal remain layer-local and sequential;
- the original `QuantizedLinear` modules remain the only named parameters.
  The bank never replaces or mutates source weights.

The feature is strictly opt-in:

```bash
export DARKBLOOM_QWEN35_PREFILL_ARTIFACT_ONLY=1
export DARKBLOOM_QWEN35_PREFILL_FRONTIER_TOKENS=192
export DARKBLOOM_QWEN35_PREFILL_MOE_TOP_K=4
export DARKBLOOM_QWEN35_PREFILL_ARTIFACT_PROJECTION_BATCH=1
```

`DARKBLOOM_QWEN35_PREFILL_ARTIFACT_PROJECTION_BATCH_MIB` optionally selects a
16–512 MiB transient ceiling; malformed values disable projection batching.
Unsupported/nonuniform quantization, additive projection biases, a persistent
stack above 320 MiB, unavailable commit-only K/V caches, and batches too small
to cross a layer family all retain the established sequential E51 path.
Decode, MTP, vision embedding prefill, and an unset feature flag are unchanged.

## Arithmetic and memory

For history dtype width `w`, the conservative retained-array estimate is:

```text
B * H * w * (
  Lgdn * (hidden + qkv + 2 * aux)
  + Lattn * (hidden + 2 * kv)
)
```

E51 B1×512 has `H=320`, `hidden=2048`, 27 skipped GDN layers with
`qkv=8192`, `aux=32`, and 9 skipped attention layers with `kv=512`.
At two bytes per value this is:

```text
195,747,840 bytes = 186.679688 MiB
```

The default 192 MiB ceiling admits that rectangle as one batch. The same
rectangle is 373.359375 MiB at B2 and 746.718750 MiB at B4, so preparation
selects a consecutive budget-safe prefix and resumes with another layer chunk.
No individual family output can exceed the configured aggregate ceiling.

For the full 30/10-layer 4-bit affine group-64 bank, packed weights plus bf16
scales and quantization biases are:

```text
packed weights:       264,110,080 bytes
scales + q-biases:     33,013,760 bytes
total:                297,123,840 bytes = 283.359375 MiB
```

The 320 MiB persistent ceiling rejects larger geometries or precisions before
the lazy stacks are evaluated.

## Correctness coverage

The patch adds regressions for:

- default-off policy and strict malformed-budget fallback;
- strict ascending layer IDs before the sorted gathered-QMM route;
- the E51 B1/B2/B4 arithmetic and an actual two-layer budget cut;
- gathered versus per-layer quantized projections at `rtol=1e-4`,
  `atol=1e-5`;
- B1/B2/B4 gathered history versus the incumbent full-rectangle projection
  slices, covering the incumbent history/suffix QMM split;
- source parameter object identity and exact bytes before and after bank use;
- B1/B2/B4 artifact-only and suffix-frontier equivalence;
- exact K/V cache offsets and row offsets;
- recurrent conv/SSM equivalence, commit, rollback, cancelled-row removal, and
  surviving-row isolation.

The Linux host parses every changed Swift file, type-checks the policy, and
type-checks the projection bank against the built MLX/MLXNN modules. The full
focused package test cannot run on this host because MLX's pre-existing
CPU-only `MLXFast` target references Metal-only symbols. The parent M3 run owns
the focused tests, real gathered-QMM execution, and the E51 quality gate.

## M3 decision gate

An explicit Metal-only `Qwen35ArtifactProjectionBatchPerfTests` probe compares
per-layer QMM, aligned batched QMM, matrix-level gathered QMM, and a row-gather
QMV control at the target dimensions. It defaults to two-layer chunks and
historical `M` in `{320, 512, 2048, 8192}`, validates values, rotates route
order, and reports 15-sample medians. It runs only when
`DARKBLOOM_QWEN35_ARTIFACT_BATCH_BENCH=1`.

The locked E51 suffix192 + top-k4 B1×512 result is 2,213.1 tok/s. The requested
additional 1.3× gate is therefore at least **2,877.0 tok/s** under the same
model, prompt, power, and measurement protocol. Keep patch 079 only if:

1. the focused B1/B2/B4 regressions pass on Metal;
2. B1×512 reaches at least 2,877.0 tok/s versus E51;
3. the fixed E51 blind quality corpus still passes; and
4. peak memory, cancellation, and uptime remain clean.

## Ordered patch

Apply `079-cbv2-cross-layer-artifact-projection-batching.patch` after patch
078's final nested commit `e5ba752`.

- patch SHA-256:
  `788799ddacc0d51894f5aa36f597e68811ae198fd9850e6d795fb306b1b15bc3`;
- nested commits:
  `2f67b8bcebaba60ad2625bbd4387b326c889363a`,
  `785c1c21217bd3c2e296b8de4ee6d503d08f22f2`,
  `77d3a05a0eca714014e922d542bf1b528d1352bc`,
  `fc32dae08048a0ee51f89742eaaa000572c51490`,
  `971667684e5e9a9d9605a48e0af4cd836057040b`,
  `8cdbbdb52823ee4158463212445e23a78ce12d99`,
  `0063990684c4ccb559e1fc6cbbb70e1429143d1a`,
  `4e73236580544a342a6e0385d5f06331ed6a5266`;
- final tree: `b3fdf3ccdd0cec69c35881c2f4c0f32603ee0202`, verified by clean
  patch replay.
