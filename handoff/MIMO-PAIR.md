# Registered MiMo V2.6 Flash across two Macs

> Last updated: 2026-10-09 18:05Z (branch `work/mimo`, base `e15f5b891`). Work in progress: the pair has not run.

"Mac A" is the M3 Ultra (256 GiB), "Mac B" the M5 Max (128 GiB). Raw logs,
receipts and gate records are outside the repository in the task's evidence
folder `mimo-20261009`. Nothing here was pushed.

MiMo is the one catalog model that needs the pair: 172.9 GB of weights against
a 256 GiB Mac whose single-Mac load needs about 183 GiB usable. As a two-stage
layer pipeline neither Mac holds more than about 103 GiB of it.

## Status

| Step | State | Evidence (folder `mimo-20261009`) |
|---|---|---|
| Admission, ceilings and capability from the real metadata | the eight model-free check runners pass; the runtime unit tests ran once: 127 of 128 passed, and the one failure and one startup-check failure were wrong expectations, corrected and **not re-run** | `unit/pure-3/`, `unit/build5.*` |
| Stage load and release, rank 1 on Mac B | **passed at cut 40** (26.87 GiB) after four loads the growth guard stopped; **refused at cut 28** by the committed rule when the first pair hold began (72.27 GiB needed, 61.62 free) | `stage-load/B-*` |
| Stage load and release, rank 0 on Mac A | **not attempted** | |
| Single-Mac reference | not run; the owner put it after the pair | |
| Pair across the cable | **not run** | |
| One rank ended mid-request | not run | |

`STATUS.md` in the evidence folder is the live record: every attempt, the
binaries on each Mac, what is in flight and the next command.

## How the product runs MiMo, and what the pair runs

The product serves `mimo-v2.6-flash-mopd` through the same continuous-batching
engine as the Qwen models, but through a path of its own: the provider's
`MiMoV26ServingLoad` drives the SDK's native factory and strict loader
(`MiMoV26ModelFactory`, `MiMoV26SerialLoadSession`, `MiMoV26FilesystemWeights`
in `MLXVLM`), which builds a `MiMoV26LoadedModel`. Its text target is
`MiMoV26TextModel` (`MLXLLM`: `MiMoV26TextBackbone`, `MiMoV26DecoderLayer`,
`MiMoV26Attention`, `MiMoV26MoE`), and the engine steps it through
`MiMoV26CBv2Adapter` with a native paged KV pool, the three embedded MTP heads
as a speculative assistant, an audio sidecar and a vision tower.

The pair runs the same `MiMoV26TextModel` class, one compact instance per
stage, through the class's own public forward:

- stage 0 is given token IDs and returns the residual the class captures after
  the stage's last layer (`captureLayers`), before any final norm;
- stage 1 is given that residual as input embeddings and returns logits.

That is the product's ordinary-cache text path, not the path its engine serves
through: state is the class's own `KVCacheSimple` and `RotatingKVCache`, not the
paged pool; there is no MTP, no vision, no audio. The weights, the layer
arithmetic and the kernels the class selects by default are the product's. The
adapter exposes neither a residual egress nor an ingress and needs the native
construction scope, so putting a stage on the engine's own adapter is a change
in `libs/mlx-swift-lm` and was not made. Speed and near-tie tokens against the
product engine are therefore measured, not assumed.

## Architecture facts the adapter rests on

Read from the artifact's `config.json` and shard headers, and pinned in
`MiMoRegisteredSpecification`:

- 48 pre-norm residual layers, hidden 4,096, vocabulary 152,576, `bfloat16`.
- Layer 0 has a dense MLP; layers 1 to 47 route over 256 experts, 8 per token.
- Nine layers attend over the whole history (0, 5, 11, 17, 23, 29, 35, 41,
  47; four key-value heads); the other 39 keep a window of 128 positions
  (eight key-value heads, a learned sink bias). Keys are 192 wide, values 128.
- A layer is `x + attention(norm(x))`, then `+ mlp(norm(.))`. Its attention
  state is its own and positions come from its own cache offset. So any layer
  boundary is a cut, and only the residual `[1, tokens, 4096]` in `bfloat16`
  crosses it: 8,192 bytes per token, 4 MiB for a 512-token chunk.
- Request state is keys and values only: 23,040 bytes per token over the nine
  full-attention layers plus a constant 24.4 MiB for the windows; about
  207 MiB for the whole model at 8,320 tokens. There is no recurrent state.
- The MTP heads read the output of the final norm (they would live with
  stage 1); vision and audio feed the embedding ingress (stage 0). None of the
  three is part of the pair: text, greedy, MTP off.

One numeric note. For rows of one to seven tokens the class fuses each layer's
finish with the next layer's input norm in one kernel. At the cut, stage 0
runs that kernel against a placeholder norm (its residual output does not
depend on the norm) and stage 1 computes the norm itself with the stock
operation. A unit test builds a tiny random four-layer MiMo
with the product's class and compares the whole model with its two stages at
every cut, prefill and decode, in bfloat16: it passed. There is no single-Mac
comparison on the real weights yet.

## Artifact

| Field | Value |
|---|---|
| Runtime model ID | `registered_mimo_v26_flash_mopd` |
| Catalog model ID, version | `mimo-v2.6-flash-mopd`, `2026-09-28-r1` |
| Manifest SHA-256 (the catalog's manifest record, 8,624 bytes) | `de1bd701115a9ee7e4a99ac85307b31285c63a0b0b1c22ef0c69e9b4ac10f346` |
| `config.json` SHA-256 | `35b6e3d4543b65e6fa9d6174e2260d9ac1d3ea1e5acb9955d9fe9f2b815d13d4` |
| Aggregate SHA-256 | `2334547d8acc9898ad4a74570ce44d2b12390bbac8d4bc52c092eb5ad5cfe034` |
| Files, bytes | 53 files, 172,863,462,401 bytes |
| Indexed tensors | 1,732 in 37 shards, 170,974,427,392 bytes |
| Text tensors the stages load | 1,103, 167,264,120,704 bytes (155.78 GiB); largest 1,073,741,824 |
| Not loaded | 629 tensors, 3,710,306,688 bytes: MTP heads 1.84 GiB, vision 1.36 GiB, audio 0.26 GiB |
| Text inventory SHA-256 | `284eb2366eb7aacec0aa8362f54d195312bd2d0c2f68b3f7069e8a80add6d7d5` |

Packing: the expert banks are MXFP4, group 32, `U32` packed weights with `U8`
block scales and no biases, three tensors of exactly 1 GiB per routed layer.
Attention projections, the dense MLP of layer 0, the embedding and the head
are affine 8-bit, group 64, with `bfloat16` scales and biases. Routers and
norms are `bfloat16`; the router's score correction is `float32`. A routed
layer is 3.283 GiB (3.278 for a full-attention one), layer 0 is 0.287 GiB, the
embedding and the head 0.618 GiB each.

Shards are ordered by tensor name (layers 10 to 19 come before layer 2), so a
contiguous layer range is not a contiguous range of files. The manifest also
carries `audio_tokenizer/model.safetensors` (1.87 GB), which is not part of the
indexed checkpoint.

The manifest pin is the catalog's own manifest record. The copy the provider
writes beside a downloaded artifact (`.darkbloom-manifest.json`) is a
re-encoding with another hash; a model directory for the runtime needs the
catalog record as `manifest.json`.

Where the artifact is: on Mac A, 53 copy-on-write clones of
the operator's verified copy plus `manifest.json`, in the models directory
that holds the 9B and 27B, as `mimo-v2.6-flash-mopd-2026-09-28-r1` (no extra
disk; the operator's files were never opened for writing). On Mac B the same
directory, copied over the cable by the coordinator and verified 53 of 53,
with `manifest.json` added.

## Placement

Rank 0 holds the embedding and layers `[0, cut)`; rank 1 the rest, the final
norm and the head. The row lists cuts 16, 20, 24, 28, 30, 32, 34 and 36.

| Cut | Rank 0 tensors | Rank 1 tensors | Request state at 8,320 tokens (rank 0 / rank 1) |
|---:|---:|---:|---:|
| 24 | 76.39 GiB | 79.39 GiB | 113 / 94 MiB |
| 28 | 89.52 GiB | 66.25 GiB | 116 / 91 MiB |
| 30 | 96.08 GiB | 59.69 GiB | 137 / 70 MiB |
| 32 | 102.65 GiB | 53.13 GiB | 138 / 69 MiB |
| 34 | 109.21 GiB | 46.56 GiB | 139 / 68 MiB |
| 36 | 115.77 GiB | 40.00 GiB | 160 / 47 MiB |

The row also lists cuts 38 to 44 (rank 1 down to 13.7 GiB). Which cut a pair
loads is decided by what each Mac's memory gate admits when the session
starts: each rank needs its tensors plus about 6 GiB of loading margin.

No phase split in this rank order: the rank that decodes alone would have to
hold all 155.8 GiB, which is the single-Mac case. The row therefore lists the
pipeline and its compact decode framing only. The reversed placement (rank 0
with the lower layers on the 128 GiB Mac, rank 1 on the 256 GiB Mac, which can
hold the whole text model) is the only arrangement in which a phase split could
exist for this model; cuts 16 and 20 are listed for it. It was not built.

## What changed

Branch `work/mimo` on `e15f5b891`. `wip:` marks commits whose unit tests have
not run.

| Commit | What |
|---|---|
| `9477640c2`, `c03dcc4c0`, `b2831fb3d` | cherry-picks: per-adapter protocol policy (`7d06b0a30`), the GPT-OSS adapter case (`658ba3e64`), the tensor scope `acceptsUInt8` (`0f5fd2c48`) |
| `9279bf607` | tensor scope `indexedShardsOnly` |
| `1262599d0` | `VerifiedCheckpoint(hashingConcurrency:)` |
| `b53ffd212` | host memory gate `record` and `measure` qualification modes |
| `ff69393cf` | protocol: MiMo adapter, session lifetime per adapter |
| `1b8e9a46e` | wip: the MiMo runtime, `Models/MiMo/` |
| `abf6d70f2` | `ClusterResidentModelCatalog` |
| `5f2c53c05` | wip: MiMo unit tests |
| `5699b0542` | wip: the worker runs a MiMo stage |
| `2926d6a57`, `4baffbebb` | wip: stage check with a prefill and decode probe |
| `80d7edae6` | wip: pair driver, request and tokenizer rows |
| `f214e9add` | the MiMo section of `DESIGN-resource-gate-v3.md` |
| `40193382a` | wip: two test expectations corrected |

### Shared files other workers also edit

All additive; the dense paths keep their behaviour and their refusal wording.

| File | Change |
|---|---|
| `Checkpoints/SafeTensorReader.swift` | `TensorDescriptorScope.indexedShardsOnly` beside `acceptsUInt8`; default unchanged |
| `Checkpoints/VerifiedCheckpoint.swift` | `hashingConcurrency` (default 1 is the original pass) |
| `Models/Qwen/Resources/QwenDenseStageLoadResources.swift` | the watch asks the measurement object after each decision; off by default |
| `Models/Qwen/Resources/QwenDenseStageLoadMeasurement.swift` | new: `record` and `measure` modes and their report |
| `Models/Qwen/Resident/QwenResidentRuntimeQualification.swift`, `QwenResidentRuntime+Load.swift` | the gate switch is a third qualification switch, refused without the flag and honoured with it |
| `DarkbloomClusterProtocol/ClusterRuntimeCapability.swift`, `…Validation.swift` | MiMo adapter case; `maximumLifetimeSeconds` per adapter (300 unless the adapter says otherwise) |
| `Models/Metadata/ClusterResidentModelCatalog.swift` | new: every registered resident model across adapters |
| Worker: `WorkerConfiguration`, `WorkerCapabilityCommand`, `WorkerMain`, `NativeWorkerRuntime` | ask the catalog; own whichever runtime the entry names; per-model session bound |
| Qualification: `QualificationRequest`, `PromptTokenizer`, `PairConfiguration`, `PairDriver`, `PairCheck`, `StageLoadCheck` | MiMo rows and switches (`--memory-gate`, `--stage-residency`, the stage probe) |
| Check runners: worker `CapabilityChecks/run.sh` and `CapabilityCommandCheck.swift`, `PrefillScheduleChecks/run.sh`, `StartupChecks/run.sh`, `QualificationComparatorTests.swift` | MiMo's metadata in the MLX-free source closures; MiMo cases |

## What today's runtime refused, and how the MiMo row answers

| Refusal | Answer |
|---|---|
| The closed catalog has no MiMo | Its own closed row, `MiMoRegisteredSpecification`, selected by pinned configuration bytes or by model ID, and its own protocol adapter `mimo-v26-layer-stage` |
| The tensor reader refuses `U8`, and requires the shard index to equal every `.safetensors` of the manifest | `tensorDescriptors(checkpoint:scope:)`: the default scope is unchanged; MiMo asks for `U8` and for the indexed shards only, so the audio tokenizer file is hashed with the artifact and contributes no descriptor |
| Profile admission is Qwen-shaped (model type, vocabulary 248,320, GDN geometry, cuts on whole attention intervals, fusion accounting) | `MiMoRegisteredModelProfile`, `MiMoLayerStagePlan` and `MiMoRequestStateBudget`, from MiMo's own metadata; every layer boundary is structural |
| Manifest ceiling 8 GiB; loaded-tensor ceilings 4 and 8 GiB | The row's own: the manifest total itself, and no stage above the text model |
| 300 s for load plus every request | 1,800 s for this adapter, in the protocol and in the row, with the arithmetic beside it; the dense rows keep 300 s |
| Each rank hashes the whole artifact before each load | Kept. It is the largest part of a load (62.4 s on one thread on Mac B; 12.9 to 13.6 s with six files hashed at once, which is what MiMo's row asks for). Verifying only the shards a rank reads would need the manifest check to be per file set and is not built |
| The host memory gate refused a 53 GiB stage on the 128 GiB Mac | Not changed, and it was right. A qualification-only mode keeps its record; see the next section |

## The host memory gate at this size

The committed rule was not changed. `handoff/DESIGN-resource-gate-v3.md` ends
with a section holding the five loads that tested it at this size; in short:

- The rule's reserve term is the kernel's own file-cache minimum (about a
  third of memory). Loaded past it, the kernel compresses other programs'
  memory, and the growth guard (512 MiB) stopped every such load, cleanly.
- The counted-cache term over-admitted once, right after large writes by other
  copies; the guard stopped that load too.
- The 173 GB copy itself was the obstacle on Mac B: 36.64 GiB of the artifact
  sat in the file cache under the kernel's minimum. Verification and loading
  read uncached and add none. Replacing each file by a clone of itself (a
  one-off cleanup the coordinator ordered) returned 36.40 GiB as free pages.
- Which cut a pair can load is therefore decided by what each Mac admits when
  the session starts, not by its size: the placement tool chose cut 40, 38 and
  28 on the same pair within half an hour as Mac B's memory moved.

## Standing residency

A loaded stage sets MLX's per-process wired limit to its tensors plus its
request state, capped at the product's ceiling (physical memory less the
larger of 16 GiB and a tenth, and never above the recommended working set),
and restores the previous limit before the tensors are released. It is on by
default; `DARKBLOOM_CLUSTER_MIMO_STAGE_RESIDENCY=off` is a qualification
switch. The limit applied, the ceiling and the previous limit are in the load
line and in the load agreement both ranks compare.

Measured once so far (rank 1 at cut 40 on Mac B, residency on): limit
27.02 GiB of a 107.5 GiB ceiling; the Mac's wired memory 5.48 GiB before,
33.32 GiB loaded, 5.23 GiB after the process exited; limit 0 before and
after. The reading inside the process right after release still said
30.76 GiB, so the check now waits up to five seconds and reports how long the
kernel took. Not yet measured: decode without residency, and wired memory
after SIGTERM.

## Stage loads (model level, one Mac, no collective)

| When | Rank, cut, Mac | Verify | Load | Probe (512 prefill, 64 decode) | Release |
|---|---|---|---|---|---|
| 17:44Z | 1, cut 40, Mac B | 13.6 s | 4.88 s for 26.87 GiB | prefill 2.72 s; decode median 5.19 ms a step (8 layers), first step 231 ms | 920 bytes active, 0 cached, model deallocated, nothing compressed |

The probe drives one stage alone (rank 1 from a constructed residual): it is
the stage's own cost, not a correctness check. The four earlier loads that the
guard stopped are in `STATUS.md` and in the gate design.

## The pair

Not run yet.

## Single-Mac reference

Not run. `darkbloom-cluster-stage-check mimo-reference` loads both stages in
one process on one Mac (about 162 GiB admissible) and runs the same request;
the owner put it after the pair.

## What stands between this and serving MiMo on the pair through the product

1. The pair itself has to run and be compared with a single-Mac reference.
2. The stages run the product's ordinary-cache text path. The product serves
   MiMo through its continuous-batching adapter with a paged KV pool and the
   MTP assistant; a stage on that adapter needs a residual egress and ingress
   in `libs/mlx-swift-lm`, which was not changed. The speed gap is to be
   measured, not assumed.
3. Text only: no MTP, no vision, no audio.
4. Placement has to come from each Mac's admissible memory at session start
   (the placement tool does this); a fixed cut will be refused on a busy Mac.
5. Large artifacts written through the buffer cache block the load that
   follows (gap finding in the evidence folder).
6. No coordinator or provider wiring was done here.

## Resuming

Read `STATUS.md` in the evidence folder first. Tools are in the evidence
folder's `tools/`: `build-all.sh N` (under a compile lane), `unit-tests.sh`
(under `lane.sh`), `stage-load.sh A|B RANK CUT LABEL [probe flags]`,
`stage-sigterm.sh`, `pair-run.sh REQUEST CUT LABEL`, `mac-a-slot.sh` (takes
the three Mac A lanes in order). A MiMo load on Mac A needs all three Mac A
lanes; anything on Mac B needs `lane-b.sh`.

## Not done

- The two corrected test expectations have not been re-run, and the worker
  package's XCTest build has not run.
- Rank 0 has never been loaded; no pair run; no fault run; no reference.
- Verifying only the shards a rank reads (each rank still hashes all 53 files).
- The loader pace that was tried was removed: no dependable effect.
- Phase split, and the reversed placement that could have one, were not built.
