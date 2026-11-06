# Additive registered dense-Qwen model admission

Source/retained-metadata proposal, 2026-09-14. No Swift implementation, model payload
read, compilation or native execution. Existing 9B qualification remains separate.

Use one admitted **model identity + execution geometry + storage capability**
through the existing dense-Qwen long runners. Keep the legacy entry points and
`LocalCorrectnessStorage` constants unchanged. Do not copy the 9B inference loop
or let arbitrary configuration values mint larger limits.

## First implementation boundary

Add a Foundation-only `QwenRegisteredDenseModelProfile` with closed, private
construction for the exact retained 9B and 27B configuration/artifact identities.
Its fields are model/profile ID, exact configuration and manifest pins, dense
family and namespace, geometry, vocabulary, expected canonical/source counts and
bytes, largest stored tensor, conversion policy, and supported execution scopes.
The initial 27B scope should explicitly select 32/32; structural cuts alone are
not execution admission. The existing 9B scope retains its current legal cuts and
nil meaning 16/16.

Separate the existing token profile (`8192/512/1`, BF16, one batch, no teacher)
from the model profile. A shared `QwenAdmittedDenseLongPrefill` combines the two
with raw prompt pins, recorded request, exact Plan, early arithmetic receipt,
and an admitted resource ledger. Model defaults must never be selected from
layer count or file size alone. Preserve original configuration bytes, including
27B's `output_gate_type: "swish"`; metadata accepts that spelling, while the
provider decoder still ignores the key and the existing operator remains fixed.

Return a non-publicly-initializable `QwenAdmittedCheckpointStorage` from that
admission. It binds profile, artifact/configuration, exact canonical inventory
expectations, selected Plan and both stage identities, permitted full/stage role,
and checked byte limits. Pass it explicitly to new loader overloads. Existing
loader APIs delegate to their unchanged legacy caps. Lower layers receive only
the already-admitted capability; an arbitrary `Int` or decoded receipt must not
authorize a bigger checkpoint. Revalidate actual descriptor counts/shapes/dtypes,
triplets, one-part dense tensors, ownership and byte sums before materialization.

## Exact source seams

| Seam | Minimal responsibility |
| --- | --- |
| `QwenRegistered9BLongPrefillAdmission`, `QwenLongPrefillReferenceAdmission`, `QwenLongPrefillStageCut` | Keep 9B wrappers; move reusable validation into a core accepting the closed model profile. Derive Plan dimensions and selected-cut binding from that admitted profile. Preserve old defaults and receipt bytes. |
| `VerifiedQwenLayerStageBaseline` → `loadVerifiedQwenDiagnostic`/`DiagnosticQwenStorage`; `prepareVerifiedQwenLayerSource` → `PreparedQwenCheckpoint` → `VerifiedCheckpoint` | Thread the same capability before verified manifest IO and the full descriptor scan. These are the actual 8-GiB payload, 6-GiB source and 512-MiB tensor refusals. Preserve pinned descriptors, full aggregate verification, source-change checks and conversion rules. |
| `PreparedQwenLayerStage` / `loadVerifiedQwenLayerStage` | Check both actual inventories against the capability before the first payload read; enforce per-stage and combined allocation commitments in the new scope. Preserve compact ownership checks before forward. The old 4/8-GiB rank/combined constants belong to `LocalCorrectnessStorage`'s partitioned path; current whole-layer loading does not call that validator, so do not claim it already provides those guards. |
| `QwenLongPrefillReferenceCapture`, `QwenLayerStageProfiledComputeAdmission` | Replace only the new core's 32/927/legacy-cap assertions with exact capability expectations; keep actual receipt/layout/arithmetic/Plan comparisons. |
| `QwenLongPrefillReferenceRequest`, `SoloRequest`, `ReferenceEvidence`, `PairAdmission`, `PairResult` | Replace new-scope 72-component/319,946,784-byte checks with independently derived exact state metadata. `PairAdmission` also hardcodes agreement `hiddenSize: 4096`; take the admitted 5120 width. Preserve complete keys, dtypes, shapes and native digests. Merely fixing ComputeAdmission is insufficient. |
| Result identity | The current reference kind/domain explicitly says `registered9b`; never emit it for 27B. Use an additive model-profile-qualified evidence namespace/domain and capability fingerprint while leaving legacy serialization unchanged. Source/Plan/storage hashes already flow through v4; bind the new capability through the new evidence/storage commitment and local validation without weakening existing wire fields. |

`CBv2RequestGeometry`, the owned-state core, full-width StageSession and profiled
state component derivation already use actual model/local layer geometry. The
8K schedule, v4 packet limits, finite argmax, owner/phase timing, source ownership,
retirement and error checks can stay. Both registered models have vocabulary
248,320, so the existing BF16 final-row size still applies. This is a source
compatibility observation, not numerical qualification or a provider capability.

## Retained 27B facts and named-buffer ledger

The bounded replay helper reads only three previously pinned JSON files; its
output records all pins, all legal-cut name/byte maps, and detailed state shapes.
It does not inspect the new download or verify any weight payload.

| Item | Exact retained/derived value |
| --- | ---: |
| Manifest total, including non-text files | 16,320,415,757 B |
| Canonical text descriptors / bytes | 1,847 / 15,132,802,048 B |
| Raw header entries / excluded vision and MTP | 2,211 / 333 + 31 |
| Largest packed embedding/head tensor | 635,699,200 B |
| 32/32 active tensors | 923 / 924 |
| 32/32 active bytes | 7,566,395,904 / 7,566,406,144 B |
| 32/32 inert BF16 bytes | 20,480 / 10,240 B |
| Layers / full attention / recurrent | 64 / 16 / 48 |
| Native BF16 `[1,512,5120]` boundary | 5,242,880 B; below unchanged 16-MiB wire cap |
| Final native state | 144 components / 690,815,040 B |
| Existing conservative full named-state formula | 1,599,082,560 B |
| The same formula evaluated per 32-layer rank | 826,806,304 B each |
| All first-use GDN fusion triplets / largest one | 2,278,195,200 / 47,462,400 B |

The text descriptors are BF16/U32, with no stored Float16 tensors; enabling the
conversion policy does not prove an actual conversion occurred. Do not copy the
9B `A_log` source-dtype expectation into this inventory. SSM state remains F32.

Keep the ledger's terms separate, per process and execution mode:

- **Weights:** actual selected allocation footprints plus inert buffers. Logical
  sums above precede backend rounding. A one-process pair holds both stages after
  the full baseline retires; separate ranks hold only their selected stage.
- **Load transient:** at least one `Data` host tensor alongside the MLX-owned
  copy (`TensorDescriptor.read`), plus conversion source/destination where
  applicable, bounded verifier/header/metadata buffers and allocator effects.
  The MLX destination is already part of resident weights; avoid double counting.
- **First-use fusion:** `Qwen35.prepareFusedInputProjection` evaluates concatenated
  qkv/z/b/a triplets, then installs original module names as views of the fused
  allocation. Budget replacement overlap/cache separately. The all-banks sum is
  a conservative named replacement allowance, not persistent duplicate weights;
  compact uniqueness and pre-forward parameter layout do not describe later
  fused views. Do not alter this math or add synchronization for budgeting.
- **State and boundary:** keep the existing checked formula and its explicit
  F32 overestimate/three recurrent generations/host snapshot/two boundaries.
  Per-rank host-copy allowances must be counted per process, not borrowed from
  a single full-model formula. Final-state logical bytes are a different quantity.
- **Unmeasured terms:** constructor graphs, command/backend/SDPA/GDN workspaces,
  allocator caches and rounding, finite/argmax and CPU evidence, framework
  baseline and OS reserve. These require a separately pinned resource policy
  and runtime gates; unknown headroom must not silently become zero.

There is a concrete attention-workspace reason to retain that last category:
`CBv2AttentionV1.attendQueryBlocks` creates four query128 blocks for chunk512;
the pinned Metal SDPA dispatch selects composed attention for head dimension256
and query length128. The logical score shape near the final frontier can reach
`[1,24,128,8192]` (25,165,824 elements). Its actual dtype, intermediate/output
liveness, command scheduling and allocator reuse determine resident workspace;
neither this shape nor the four-block count is a process peak bound. Keep the
same-chunk reference and early query128/BF16/TF32 environment contract unchanged.

For orientation, adding logical full weights + one largest host tensor + the
all-banks replacement allowance + full named-state formula gives
19,645,779,008 B. Each 32-layer rank's analogous sum including inert storage is
10,168,019,488 B. These are **partial named-buffer ledgers**, not peak forecasts
or execution ceilings. No 24/48/256-GiB device is admitted by these sums.
A capability may declare a named-state ceiling separately (the new 27B formula
already exceeds the old 768-MiB 9B ceiling), but total process admission must also
budget the unresolved terms and use the external pressure/swap/deadline fence.
Do not change the provider's measured serving-reserve policy with this formula.

## Small prospective fixture sequence

1. Reuse `Tests/LayerStageCandidates` and `QwenStageOutputGateMetadataCheck` for
   public synthetic positive/refusal semantics. Root's retained metadata emitter
   can call actual Plan/Candidates with the pinned 64-layer config and all 1,847
   names; expect 15 structural cuts, complete disjoint ownership, and unknown
   compute costs. The older private 9B candidate fixture hardcodes 927 and must
   not be presented as a generic 27B test.
2. Extend the pure budget/admission fixture with the exact geometry and independent
   term vector from `metadata.json`. Reject wrong config/aggregate/profile/cut,
   stale 927/32 counts, bool/fractional/overflow bytes, changed dtype/triplet/name,
   mismatched capability/Plan and role, a forged ceiling, and unresolved total
   reserve. Prove all legacy8/6/4/8-GiB and512-MiB refusals remain unchanged.
3. After download, root verifies the full manifest/aggregate, replays actual
   headers against retained identities, then compares actual sanitized canonical
   descriptors and constructed shapes with the exact 1,847-name/15,132,802,048-B
   ledger. Retained `language_model.` classification alone does not prove this.
4. Only then qualify one guarded fresh full 8K/512 baseline, followed by the
   same-plan pair/ranks under newly frozen numerical and resource oracles. Never
   relabel a 9B reference. M3 numerical/backend compatibility, provider
   `apple_m5`/`mlx_nax` policy and performance remain separate unresolved gates.
