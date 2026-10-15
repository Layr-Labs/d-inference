# Whole-layer candidate enumeration: bounded metadata draft

Date: 2026-09-14. Source-only; no repository change, compiler, model construction,
native execution, SSH, payload reads or timing-input reads.

The existing planner already supports arbitrary legal two-stage cuts. The missing
piece is enumeration and a convenient ownership view, not a new partitioning rule.
`QwenLayerStageCandidates.swift` adds that small layer while keeping the existing
planner authoritative. Every compute-cost field is `unknown`; ascending cut order
is deterministic enumeration order, with no preference or performance ranking.

## Existing contract and gap

`QwenLayerStagePlan.init` requires `[0..<cut, cut..<layers]`, each range containing
at least `interval` layers, and both starts divisible by the interval. It does not
require the final layer count to be divisible by the interval. Thus 10 layers with
interval 4 admits 4+6; blindly halving would produce the invalid 5+5 split.

The same initializer owns wrapper namespace selection, preservation of full widths,
per-path quantization remapping, inactive embedding/head/norm responsibilities and
MTP deactivation. Its `parameters` method owns canonical-name coverage, exclusions
and injective global-to-local parameter mapping. The new helper reuses both for
every cut. It neither sanitizes raw Hugging Face names nor rewrites configuration
keys. If any constructor or name check throws, the enumeration call throws; it
does not return an apparently complete subset with failures hidden.

No existing candidate enumeration was found in the harness source. Current short
comparison admission selects halves. Registered long-reference admission selects
16+16; `QwenLayerStageProfiledComputeAdmission` additionally requires that split,
16 local layers and 927 canonical tensors. Its final-state validator requires 36
components per stage. These execution gates are intentionally unchanged.

## Draft API

```swift
QwenLayerStageCandidates.structuralCuts(
    layerCount: Int, fullAttentionInterval: Int
) throws -> [Int]

QwenLayerStageCandidates.enumerate(
    configuration: Data, canonicalSourceNames: [String], activeMTP: Bool = false
) throws -> [QwenLayerStageCandidates.Candidate]
```

The first API reports bounded integer positions only. It may return an empty set
and never constitutes configuration admission. The second rejects an empty set,
then returns the existing validated plan and two ownership records for each cut.
Each ownership record contains that stage's canonical parameter mappings, existing
global/local layer descriptors and named state components. Recurrent layers own
`conv` and `ssm`; full-attention layers own `kv.keys`, `kv.values` and
`kv.position_offsets`. Explicit excluded source names remain visible separately.
Embedding ownership stays on stage 0; final norm/head ownership stays on stage 1.

The helper accepts canonical names, not a purported verified-byte receipt. It makes
no shape, dtype, quantization-triplet, payload, allocation, state-capacity or runtime
proof. A subsequent metadata-only attachment could join supplied descriptor records
by exact canonical name and conserve declared bytes across owners. Actual source
verification and constructed-stage layout checks remain the existing loader's job.
State byte estimates additionally need request geometry and actual dtype policy;
component ownership alone supplies neither. The current budget helper requires a
divisible total layer count, so it must not be silently reused to narrow this API's
valid 10-layer structural case.

## Retained metadata examples

The 9B configuration has 32 layers and interval 4: cuts 4, 8, 12, 16, 20, 24 and 28.
The table below is an independent Python regrouping of the previously frozen 927
header-derived canonical descriptors. It is not output from executing the new Swift
helper. Every row conserves 5,038,041,600 declared source bytes and 72 named state
components. Inert placeholder bytes, request tensors and workspaces are excluded.

| Cut | Tensor counts, stage 0 / 1 | Declared source bytes, stage 0 / 1 | State components, stage 0 / 1 |
| ---: | ---: | ---: | ---: |
| 4 | 118 / 809 | 1,058,851,136 / 3,979,190,464 | 9 / 63 |
| 8 | 233 / 694 | 1,545,572,992 / 3,492,468,608 | 18 / 54 |
| 12 | 348 / 579 | 2,032,294,848 / 3,005,746,752 | 27 / 45 |
| 16 | 463 / 464 | 2,519,016,704 / 2,519,024,896 | 36 / 36 |
| 20 | 578 / 349 | 3,005,738,560 / 2,032,303,040 | 45 / 27 |
| 24 | 693 / 234 | 3,492,460,416 / 1,545,581,184 | 54 / 18 |
| 28 | 808 / 119 | 3,979,182,272 / 1,058,859,328 | 63 / 9 |

The retained 27B configuration has 64 layers and interval 4, yielding 15 structural
positions: 4 through 60 in increments of 4. Its actual `text_config` also contains
`output_gate_type: "swish"`, which is absent from the planner's closed known-key
set. Full configuration enumeration therefore remains refused by the existing
source contract. This refusal was established by reading the exact configuration
and validator, not by executing Swift. The property is never removed to obtain an
admitted plan. Determining its intended operator semantics and implementing a
qualified adapter is separate work. Neither structural positions nor this draft
establish 27B runtime capability; existing registered-9B pins and loader budgets
still apply, and the retained inventory does not establish a complete 27B payload.

`metadata-preview.json` binds the exact retained configurations, inventory,
header-derived descriptor record and relevant current source bytes. It contains
the table and separate Python metadata hashes. Those hashes use a declared Python
JSON encoding and are not native plan, storage-commitment or payload hashes. No
fresh safetensor header or payload was read for this preview.

## Validation and next boundary

The new Swift fixture takes the retained 9B configuration and its 927 canonical
names as caller-owned inputs. It covers all seven cuts, conserved/disjoint name
ownership, local/global interval phase and components, explicit unknown costs,
the 10-layer 4+6 case, exclusions and propagation of selected existing failures.
It does not repeat the planner's full metadata/quantization test matrix. Root owns
compilation and any future fixture execution; this draft's Swift has not run.

`source_check.py` ran 16 source invariants and rejected 14 deliberately changed
source variants. It also regenerated the descriptor table using only pinned CPU
metadata and checked input hashes before/after. These checks do not establish
Swift syntax, compiled behavior, loadability or numerical parity. The independent
peer source review found no concrete blocker and did not execute the fixture.

A future candidate selector can first attach verified descriptor/resource facts,
then use measurements whose artifact, implementation, hardware, chunk/frontier,
dtype, schedule and cache state are explicit. Whole 16-layer stage timings cannot
be divided into per-layer costs: embedding/head responsibilities differ, attention
and recurrent layers differ, and native dispatch/workspace behavior can change.
Until such evidence exists, the helper must not rank candidates. Executing a new
cut requires separate admission and complete loader/state/numerical qualification;
this draft does not relax the tested 16+16 path or any memory cap.

## Handoff

Only `QwenLayerStageCandidates.swift` is proposed production metadata code. The
fixture and Python source checker remain out of tree unless root elects to move
them. No Options, CLI, native loop, trace schema or wire format changes are needed
to review this API. Root can compile the core with the existing pure planner,
metadata, bounded-integer and SHA helpers, then call the fixture with retained
configuration bytes and `fullCanonicalTensors.map(sourceName)` from the saved 9B
descriptor record. Such compilation/execution is still pending.
