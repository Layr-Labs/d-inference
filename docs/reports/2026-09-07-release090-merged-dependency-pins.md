# 0.9.0 merged dependency pins

> Last updated: 2026-09-07 · commit `9a4992d26`

The release stack now pins the merged MLX and C bridge commits. Their source trees are identical to the dependency revisions used by the verified 0.9.0 candidate. This changes dependency provenance without changing the selected inference implementation.

## Dependency chain

| Repository | Previous revision | Merged revision | Identical source tree |
| --- | --- | --- | --- |
| MLX | `6cdd2a2548f184dcdc1561807b508adff1e73ac4` | `6005bca7a3ee99f81c043299b1f73327d3755c9c` | `df4b285773679f28847d646519a8498b8b6238cf` |
| mlx-c | `8bdeb0f3c5793c54139e86c5437b09abc9ab9b42` | `9aaf7ff4fb0c2f13b7894d1f7c556850e891559b` | `71ccf05281b04f3519a50a2da593ab3d62e09bc2` |

Swift append `80981062b21ba8ccf4fff40f715dab495b38fb07` updates only its two dependency gitlinks. Native append `381aef4b60cfa1141b872741ebab7631077b350e` updates only the Swift revision in `Package.swift`. The parent advances both package gitlinks and its separate `libs/mlx` reference to the merged core commit. Provider and native benchmark builds use the core nested under `libs/mlx-swift`; the separate top-level core reference is outside those compiled source closures.

All 947 core and 132 C bridge source-file identities from the final candidate were checked against the merged revisions. Earlier runtime and test results retain their original artifact identities. The pin update is not reported as a new model or numerical test run; final model, connected HTTP and production-key restart acceptance remain separate.

## NAX review finding

The review on Swift PR #21 identified reduced-precision sums in `load_vector` and `load_vector_safe` within the embedded NAX source. Both functions are unused definitions in that source. NAX matrix multiplication uses `QuantizedBlockLoader`, whose `dequantize` function promotes scale and bias to float before the arithmetic and casts only the final value to the destination type. Ordinary quantized vector kernels use the separately corrected `quantized()` source.

Both embedded NAX artifacts already match the canonical core header: the generated Metal header has SHA-256 `3dc0dfa3dab060ce1f75dcbb9a4c7ae4546693d74f71cafe7658c1e6743af745`, and the embedded JIT source has SHA-256 `6fb8b82747b3cc3b124533cc631fd86aa0fb1eb4b330192afcbe26344ef22b64`. Reproducing the generator's text transformation yields the same JIT bytes. The cited helpers do not establish an active NAX precision regression, so this review does not require a shader change.

Evidence: [dependency source audit](evidence/release090-merged-dependency-pins-2026-09-07/audit.json), [independent NAX call-path review](evidence/release090-merged-dependency-pins-2026-09-07/nax-review.json).

Related: [verified final build](2026-09-07-release090-final-build.md), [release acceptance](../design/release-090-acceptance.md), [Swift review thread](https://github.com/Layr-Labs/mlx-swift/pull/21#discussion_r3945153306).
