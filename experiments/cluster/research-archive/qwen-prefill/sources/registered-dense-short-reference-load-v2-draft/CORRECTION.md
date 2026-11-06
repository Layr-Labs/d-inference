# V2: preserve exact registered F32 source tensors

2026-09-14. V1 remains frozen at manifest `0ee6fcc7…c4e16a`. Root's retained
38-source compile passed; the first pure fixture run then exited -5 with
`Short full-reference allocator bounds or loaded types differ`, before producing
stdout. Receipt `dadcac04…df3ad9` and all V1 source/failed outputs remain unchanged.
The author inspected that completed CPU failure and retained metadata only; no
model output, payload or native model execution was accessed or performed.

This is a new runtime-budget predicate error, not fabricated fixture dtypes.
The exact registered 9B canonical inventory contains 250 U32, 653 BF16 and 24 F32
tensors. Those F32 entries are the recurrent layers' `linear_attn.A_log`, each
shape [32] / 128 bytes, totaling 3,072 bytes. The exact 27B inventory has 498 U32,
1,349 BF16 and no F32 entries. The fixture constructs observed records directly
from those pinned canonical descriptors, then uses the actual source validator.

The actual bridge preserves `.float32` as source `F32`. The shared source
validator maps F32 to loaded `float32`; the legacy materializer requires the
sanitizer to preserve source dtype and converts only F16 to BF16. The new V1
budget incorrectly allowed only loaded uint32/bfloat16. Its F32 refusal therefore
contradicted the preserved source/materializer contract for registered 9B.

V2 changes only that runtime predicate: each loaded dtype must equal the exact
mapping for its canonical source dtype: U32→uint32, BF16→bfloat16, F32→float32.
The complete canonical inventory still must equal the exact admitted registered
profile, including every name, shape, dtype and byte count. This admits neither
arbitrary F32 source tensors nor a conversion of BF16/F32 identity. The private
gate's existing F32 descriptor mapping and the materializer require no changes.

The fixture adds one exact source-to-loaded dtype/count assertion for each model,
a rejection of coherently widened BF16→F32 metadata for each, and a 9B rejection
of narrowed F32 A_log→BF16 metadata. Expected counts become 22 accepted / 101
rejected. All previous 20/98 case bodies remain unchanged. Full role/request/Plan,
Q, allocation bounds, actual-free floor, zero swap, source/loader operation order,
weak ownership and error cleanup are unchanged. No numerical tolerance changes
or forward/model execution are introduced.

`correction.patch` shows the two deltas. `runtime.patch` is the complete final
runtime patch against the still-unmodified repository base. The 38-source list
replaces only budget/fixture paths; its other 36 sources and stdin remain pinned.
The integration map combines these two corrected files with six original files.
Root owns the V2 Swift compile and fixture replay; no V2 Swift was run by author.
