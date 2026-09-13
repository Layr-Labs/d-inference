# Corrected Gemma QAT backend parity; verifier equality remains open

> Last updated: 2026-09-06 · commit `38b674d53`

The corrected runtime produces identical complete Gemma QAT4 outputs across
contiguous and paged attention in ordinary, automatic speculative and
serial-target modes. All seven cells pass execution-integrity checks. Automatic
verification still differs from ordinary decoding on both backends, so the
complete comparison exits 2 and verifier correctness remains unproven.

## Exact scope

These are cache-off B1 controls on the M5 Max with 128 GiB RAM, the exact Gemma
QAT4 model aggregate
`2468a0cb3049a871f42052f4d9f9380bf12a0792f64c7a29f768559fc7d28785`,
the retained September 6 input and 5,418-token main prompts. The six main cells
cover both backends and all three modes. A seventh cell captures the bounded
Q/K/V projection for token IDs 529 and 62203. Each comparison checks seven
complete trajectories; these reuse the fixture prompt and are not seven
independent quality prompts.

The source is parent `53f3c3d0c0d0a09f4d89fe4346aa72ebdecbe4e6`, native
`de30ef9892cbd247b219cfde891f180ffbf5f47a`, MLX Swift
`c06149b4f7defa1b958c1e175f6c9a12c86c8a4f` and core
`fab0f39f69140393b454c32d6f4bf7a9b32f9dcc`. Both executables come from canonical
SwiftPM builds with the corrected embedded shader source and matching
metallib. The later recurrent teacher-scoring fix is outside this runtime.

The same seven explicit serving settings, model/assistant hashes, production
KV grant, request date, host/config identity and lifecycle predicates remain
bound throughout. Staging preserves declared file modes. No dev environment
or shared coordinator is involved.

## Results

| Comparison | Complete-trajectory result |
| --- | --- |
| Contiguous versus paged, ordinary | All seven exact |
| Contiguous versus paged, automatic | All seven exact |
| Contiguous versus paged, serial-target | All seven exact |
| Serial-target versus ordinary, either backend | All seven exact |
| Automatic versus ordinary, either backend | All seven differ first at index 30 |
| Projection versus paged automatic control | All seven exact |

All main completions contain 61 tokens and finish with `stop`. At zero-based
index 30, corrected ordinary decoding selects token 795 and automatic selects
735. The old-to-corrected contiguous ordinary result changes from 735 to 795;
automatic changes from 795 to 735. The correction changes both modes, while
the remaining disagreement is not specific to paging.

The corrected actual projection has Q/K/V mismatch counts of 1/0/0, down from
2,509/1,251/1,449. All six captured Q/K/V tensors match the corrected M3 operator
replay byte for byte. The remaining Q element differs by one BF16 step,
`7.62939453125e-6`. This confirms the corrected arithmetic in the staged runtime;
kernel names were not instrumented. It does not establish that this one element
causes the remaining output difference. Same-state logits and score gaps are
still needed to distinguish numerical variation from another verification or
state defect.

## Evidence and remaining gates

All owned processes retire, postflight identities match and no unexpected
provider process remains. Root re-verifies 160 frozen result files, all seven
cell receipts and the complete comparison. The
[manifest](evidence/gemma-qmv-controls-2026-09-06/manifest.json) and
[archive](evidence/gemma-qmv-controls-2026-09-06/payloads.tar.gz) retain 162 payloads,
including the original result freeze and independent review. Old failures stay
separate and unchanged.

No new latency or throughput gain is claimed. SSD-hit parity, B2/B4, long
contexts, memory pressure, the remaining model artifacts and final release
defaults require their own validation. These controls close the observed
Gemma QAT4 B1 backend mismatch; they do not certify the full release.
