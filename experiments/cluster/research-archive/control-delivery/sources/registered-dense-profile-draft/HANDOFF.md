# Pure registered dense-Qwen profile boundary

Source-only draft, 2026-09-14. No Swift compiler, native inference, GPU, SSH or
checkpoint payload work was performed by this author. Existing repository
sources, loader caps, 9B receipts and runtime behavior are unchanged.

`QwenRegisteredDenseModelProfile.admit(configuration:manifest:expectedArtifactAggregateSHA256:canonicalTensors:)`
admits only the exact two closed source identities. It retains the original raw
configuration and manifest bytes and validates the complete canonical name,
shape, source dtype and logical byte identity against separately derived pins.
This validates retained metadata, not the actual artifact or resident model.
The exact descriptor signature is UTF-8, sorted by name, joined with LF and no
terminal LF: `name|SOURCE_DTYPE|comma-separated-shape|decimal-byteCount`.
Inputs reject delimiter characters before hashing. Descriptor order is irrelevant.
The existing dense Plan validates name coverage and semantic metadata too.

`profile.makePlanningPlan(stageCut:)` preserves all seven existing9B cuts and the
default16/16 Plan. The first27B planning scope is32/32; a structurally valid24/40
Plan is deliberately refused by requirement derivation. This does not change
generic candidate enumeration, and neither scope authorizes execution.

`QwenDenseStorageRequirement.derive(profile:plan:role:)` binds actual rebuilt
Plan/stage/construction identities and per-role full/sequential-pair/stage0/stage1
storage and state metadata. Source/tensor/inert/fusion/host/state terms remain
separate. No source-level cost ranking, allocation footprint or memory peak is
inferred. The first-use fusion allowance is all selected original qkv/z/b/a
triplets; current native code replaces original module names with fused views.
It does not mean persistent duplicate weights or post-forward compact uniqueness.

`QwenDenseResourcePlanningInput` requires a caller-supplied lowercase policy hash,
the exact requirement fingerprint, four positive reserve categories and an
explicit total ceiling. It does not authenticate that hash or establish that any
reserve is measured or sufficient. `QwenDenseResourcePlan.calculate` uses checked
arithmetic and reports whether the numbers fit that ceiling; all provenance,
current-OS/resource and execution flags stay false even on the positive path.
There is no default-zero unknown workspace and no API to mint a loader permit.
Future loader overloads must additionally bind verified actual payload/descriptors,
role/Plan identities and independently performed device/OS/runtime admission.

The six core files are Foundation/CryptoKit-only and use existing pure
Plan/Metadata/Candidates plus checked geometry/budget helpers. Types and registered
specifications have closed constructors where they represent validated values;
the caller-supplied tensor/resource input DTOs remain explicitly untrusted.
No existing `LocalCorrectnessStorage` symbol is imported or modified by the core.
The old9B admission is used only by the fixture as a compatibility control.

`retained-inputs.json` is a CPU fixture containing base64 raw configuration and
manifest bytes plus2,774 tensor descriptors. `retained-input-pins.json` identifies
the old9B expected inventory and archived raw metadata, and the three previously
pinned27B JSON files. The27B payload completion reported later by root is not
used to mint this profile or claimed as this agent's verification. The exact
canonical pins and all checked dimensions are retained-data expectations; source
sanitization/payload/header verification remains a later distinct operation.

The fixture checks unchanged9B budget and Plan identity, raw-byte retention,
all roles/cuts, independently pinned27B state and storage numbers, descriptor
permutation, wrong config/manifest/artifact/geometry/name/shape/dtype, missing and
duplicate names, scope/cross-model Plan substitution, invalid tensor dimensions,
invalid/no-zero resource inputs, cross-role identity and checked overflows.
One-byte reserve examples deliberately prove only arithmetic/non-permission.
The fixture has not been Swift-compiled or executed by this author.

Root can compile `ProfileCheckMain.swift`, the six core files and
`QwenRegisteredDenseProfileCheck.swift` with the actual pure dependency files
listed in `source-pins.json`; supply the existing small ProbeError/sha256 support
used by the public Candidate harness. The old registered9B admission and
`QwenLongPrefillStageCut` are fixture dependencies. No MLX import or inference
target build is necessary. Then run the standalone executable with
`retained-inputs.json` on stdin. This is a root-owned future check, not a result.

The preceding design is separately frozen in `../qwen27-model-profile-draft` at
manifest `0f84ad60d2d9ff6cb29acf710494b8c2a1fdfe6e5da40521d077126732181288`.
Its44 source pins and detailed workspace limitations remain applicable. New
generic/model-qualified execution evidence will need a new identity namespace;
the existing `registered9b` reference kind must never label27B results.
