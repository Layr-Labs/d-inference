# Standalone attention operator replay

> Last updated: 2026-09-06 · commit `ae3835969`

The standalone replay tool passes eight Swift functions covering 29 expanded
cases, plus 35 CPU functions. It invokes actual native SDPA and both paged decode
layouts on identical synthetic inputs, including a genuine incoming-token write
and exact full-history readback. No real captured-model packet was replayed in
this milestone; model parity failures remain unresolved.

## Implementation and scope

Two additive Benchmarking SPI files expose native-byte inputs/results through
`CBv2AttentionReplay.validate` and `run`. The standalone executable links
MLX/MLXLMCommon and creates no model, provider, SSD store or key hierarchy. Python
applies the complete packet-v1 validator before staging; Swift repeats dtype,
shape, packing, length/hash and allocation checks before constructing MLX arrays.
Inputs are limited to 32 MiB. A conservative 256 MiB allocation plan bounds these
arrays and pools, not process RSS.

Each paged arm seeds T−1 tokens through the existing writer/fence, then calls the
actual fixed or segmented `PagedLayerCache.updateAndAttend`. Ordinary gathers
read full chronological K/V after evaluation; bytes are retained before pool
release. Paged dispatch is observed at its call site. The synthetic observer
stays unconfirmed and is not exported as model-forward evidence. Native SDPA
identifies the API invoked, not an instrumented internal MLX variant. Partition
geometry is labeled as derived from the pinned dispatch sizer.

The original-Q CPU FP32 GQA reference remains primary; a narrowed-Q counterfactual
is separate. No numerical/model-token gate pass flag is emitted. Captured output
reproduction, original physical layout, model-history fidelity and cross-backend
Q/K/V identity remain distinct proof requirements.

## Validation

| Executed coverage | Cases | Result |
|---|---:|---|
| FP16/BF16/FP32 × D64/128/256/512, T257 | 12 | All three genuine operators pass |
| BF16 D256 at T15/16/17/255/256/257/4095/4096/4097/5585 | 10 | Real tail write and page/partition/segment boundaries pass |
| Original FP32 Q with FP16 or BF16 KV | 2 | Original-Q and outward dtype checks pass |
| Host transfer, file, option and malformed-input guards | 5 | Pass without model/key operations |

Every operator case keeps the existing numeric oracle: native relative L2
`≤ 1e-2`; paged relative L2 `≤ max(3 × native, 1e-2)`. Full readback bytes and
fixed/segmented output bytes are separately exact. No limit was relaxed.

The first Swift build passed without source correction, followed by all eight
functions/29 cases without skips. Thirteen replay CPU functions and 22 existing
packet functions pass. Planted CPU faults cover head maps, dropped tails,
transpose/shape mistakes, truncated bytes, wrong hashes/dispatch, path escapes,
aliased page receipts and failed execution. Those collector fixtures are not
native execution. Independent host review found an unbounded log hash read;
source2 uses streaming reads and preserves the process receipt before fallible
hashing, with a dedicated regression.

The tested native base was `dcf39f6` plus the two SPI files; parent source was
`1be058a6b`. Native integration commit `7d32d43977a5774f223b6892ecfbbaa844047600`
adds those byte-identical files directly onto `b01e1af`. The 12 parent source files
also match reviewed source2 byte-for-byte. This rebase is not relabeled as another
test execution.

The [manifest](evidence/attention-operator-replay-2026-09-06/manifest.json) and
[archive](evidence/attention-operator-replay-2026-09-06/payloads.tar.gz) retain 74
verified source/review/build/test payloads. Manifest SHA-256 is
`4e2a8cd447ad74a5ca78b7d66f84b3514b176b5cade65c8a4e168a12cc4d82e1`;
archive SHA-256 is `f5162e98a862a3b2935fe86238006da93faf23449812af7be81c08fc7690e3e7`.
The [build](../developer/build.md#standalone-attention-operator-replay) and
[execution](../developer/test.md#attention-operator-replay) instructions describe
the next optimized same-host replay. This milestone establishes no model-token
parity, SSD latency improvement or release promotion.
