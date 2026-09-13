# Native checkpoint page adoption and shared-ledger primitives

> Last updated: 2026-09-05 · commit `456a8dcff`

Private checkpoint pages can now transfer into a native pool without copying
their KV buffers. The native checks pass 162 distinct cases; the combined
provider checks pass 118 cases. The shared process-ledger primitive also passes
its 18 tests. Live paged SSD serving and production process binding remain pending.

## Native ownership transfer

Native commit `eeece251e91e90c29c75eb1db0a83816baea76e2` advances
`326d9a27a9227e1636a7a584687193d425f0b4b0` across eleven files. A typed stage
lease identifies the owning Admission instance and its target, auxiliary and
scratch charges. Adoption transfers destination ownership into the full request
promise and physical floor in one Admission transaction. Scratch stays charged
until its own retirement.

The pool prepares rebased segment wrappers and row metadata, allocates only
missing backing, and publishes all groups under one grant-epoch check. Imported
pages remain exclusive, including a partially filled frontier. On failure,
private arrays and auxiliary state leave ownership before the floor is refunded.
Consumed frame handles cannot close the installed request. Generation markers
prevent a late release from affecting a reused request ID; layer count, geometry
and mapping are checked before indexing or mutating the pool.

These helpers still require the complete codec and engine adoption path to move
ownership through them. They do not enable sliding-window, borrowed-row, recurrent
or MTP restore by themselves.

## Process-ledger primitive

`ProcessMemoryLedger` accepts each native owner's complete charge C and exact
evaluated materialization M. Its accounting subtracts the remaining commitment
C−M from coherent allocator headroom. It does not introduce a second page-pricing
formula or infer ownership from memory deltas. Opaque generations, revisions and
policy epochs protect mutations; closing preserves live charges until explicit
retirement. Coverage withdrawal precedes backing destruction, and charge reduction
follows actual retirement.

The two provider files are a tested primitive. The actor facade, atomic load
integration, native connection and real allocation coverage are subsequent work.
The concurrency tests use a caller-owned native projection model; they are not
evidence of actual multi-model native admission.

## Validation and provenance

The accepted builds use `mlx-swift` `eafd98a7c53c145ff40faa486c5f696b7104ae92`,
nested MLX `9b3f4d1ec6bd65314e06825658334e5788ee3167` and `mlx-c`
`720953eff635e772d9f3d73e46942bc49fac04c3`.

| Accepted run | Functions / actual cases | Result |
|---|---:|---|
| Native distinct cases across fourteen filters | 128 / 162 | Pass |
| New native stage/adoption cases within that run | 11 / 14 | Pass |
| Combined provider budget, load/bridge/SSD lifecycle and ledger | 117 / 118 | Pass |
| Earlier isolated pure-ledger run | 18 / 18 | Pass |

The native run executes 136 functions / 170 cases because eight speculative-row
cases match two filters; the headline count deduplicates them. Native build time
is 128.89 seconds and combined provider build time is 87.44 seconds. No accepted
case fails or skips. Manifests verify 449 native inputs, 1,353 MLX inputs and
1,125 selected provider/native/Jinja inputs before and after execution.

The first native attempt selected an old remote MLX checkout despite the requested
local package edit. It is preserved and excluded from the accepted results. The
accepted run uses an isolated package with one explicit local-dependency manifest
overlay. Actual compiler paths prove the new local `Memory.swift` and Metal
allocator sources; primary package manifests and dependency pins remain unchanged.

## Evidence and remaining gates

The [evidence manifest](evidence/paged-checkpoint-adoption-2026-09-05/manifest.json)
indexes 124 payloads in one compressed archive, including original commands,
logs, source identities, patches, exact test identifiers and the rejected attempt.
All archive members were checked against their originals. Manifest SHA-256:
`c2f8d321c487f51477006cdf68a5f062a803b4196beefa0f190316ae808dcce5`.

This milestone establishes neither production shared-budget enforcement nor
complete paged SSD cache hits. Contiguous/recurrent/MTP ownership, native runtime
dtype guards, all five exact full-size models, usable context, B1/B2/B4 repeated
performance, HTTP/tool/vision behavior and persistent-key restart evidence remain
release gates. Backend defaults and rollout configuration are unchanged.
