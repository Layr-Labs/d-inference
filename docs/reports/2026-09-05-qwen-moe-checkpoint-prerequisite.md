# Qwen MoE complete-checkpoint prerequisite

> Last updated: 2026-09-05 · commit `6e90514f5`

The complete-checkpoint codec now accepts Qwen MoE targets with supported native
activation dtypes. Focused native and provider tests pass. This is a prerequisite
for the 0.9.0 paged-attention work; it does not establish real 35B-model correctness,
paged execution, production-key restart reuse, or a latency improvement.

## Change and evidence

Native commit `b5d6c92` removes the dense-only topology restriction from
`Qwen35TextConfiguration.cbv2Capabilities` and
`Qwen35TextModel.cbv2CompleteCheckpointKVDTypes`. Routed and shared experts are
token-local; the model retains the same attention and recurrent checkpoint state.
Existing dtype, geometry, position, token-history and runtime-identity checks
remain. The default execution backend is still contiguous.

The new tiny-model fixture uses four routed experts, top-two selection, a shared
expert, two full-attention layers and two recurrent layers. It exercises FP32,
BF16 and FP16 activations with a packed affine embedding. A byte-only archive is
restored into a newly created model and engine, then compared against cold raw
token IDs for repeats, shorter suffixes and a changed branch. Tests also check
foreign-tenant misses, disabled caching, position/media rejection and released
reservations. Existing MTP history and codec tests now cover dense and MoE
configurations. This fixture does not simulate a new OS process.

The provider tests exercise actual dense/MoE slot extraction with caching enabled
and disabled, and verify the required pre/post-load weight hashes. They preserve
the default SSD store without an opt-in resident tensor bank.

| Validation | Result |
|---|---|
| Native focused suites | 38 passed: 23 XCTest and 15 Swift Testing, none skipped |
| Provider focused suites | 35 Swift Testing cases across three suites passed |
| Initial new MoE fixture | Failed with a Metal trap: unsupported 16-wide recurrent heads |
| Corrected fixture | Test-only recurrent head dimension changed to 64; both new XCTest cases passed |

The original failure log is retained. No production change was needed for that
fixture correction. Full-size Qwen3.6/Qwen3.5 validation and the five-model paged
matrix remain separate gates.

## Reproduction record

The [evidence manifest](evidence/qwen-moe-prerequisite-2026-09-05/manifest.json)
contains sizes and hashes for 11 compressed build/test logs, exact commands,
the five native paths, two provider test paths, and a 1,059-file source snapshot.
Its SHA-256 is
`a1aad3f71f2e9f18d61752000270bd969a19079a81e53097c082311b006611b7`.
Stored and decompressed artifact hashes were independently checked before commit.

Earlier real-model SSD measurements apply only to their recorded dense Qwen
source and artifact: [SSD prefix model check](2026-09-05-ssd-prefix-cache-model-check.md).
