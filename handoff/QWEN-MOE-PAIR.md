# The two Qwen mixture-of-experts models as distributed models

> Last updated: 2026-10-09 18:02Z (branch `work/qwen-moe`, base `4433b35e5`)

"Mac A" is the M3 Ultra (256 GB), "Mac B" the M5 Max (128 GB). Raw logs,
reports and the scripts that produced them are outside the repository in the
task's evidence folder `qwen-moe-20261009`; its `STATUS.md` is the live record
of what has run and is kept current step by step. Nothing here was pushed.

This is runtime support and qualification. Neither model is served by a pair:
the provider refuses both by construction (see "Provider and coordinator").

## Status

| Step | Qwen3.5 35B A3B | Qwen3.6 35B A3B (text only, MTP off) |
|---|---|---|
| Artifact verified against its catalog manifest | **Done** on both Macs (14 of 14) | **Done** on both Macs (13 of 13) |
| Registration: catalog row, pins, admission, ceilings, capability, worker arguments | **Done**, unit level, from the artifact's real `config.json` and manifest | **Done**, same |
| A. Stage load and release at the cut that runs (12) | **Passed** on both Macs, both ranks | **Passed** on both Macs, both ranks |
| B. Staged reference on one Mac, twice, identical | **Passed** on Mac A (`exact`) | **Passed** on Mac A (`exact`) |
| C. Two workers on one Mac over the local test socket, equal to B | **Passed** on Mac A, pipeline (`exact`, ranks agree) | **Passed** on Mac A, pipeline (`exact`, ranks agree) |
| D. Across the cable in every mode | **Ran**: all three modes completed, ranks agree, the modes agree with each other `exact`. **Against B: `divergedAtNearTie`** (an exact tie in the oracle at output index 10, broken the other way on the pair); a pass under the owner's mixed-chip rule of 2026-10-09 | **Passed**: all three modes completed, ranks agree, modes agree `exact`; against B `tokensEqualLogitsDiffer` (64 of 64 tokens equal) |
| D. One rank ended with SIGTERM mid-decode | **Passed**: the other rank exited by itself, nothing left on either Mac | **Passed**, the same way |
| Other cuts, longer prompts, each Mac alone, Mac B's reference, product comparison | Not run | Not run |

A local-socket pass is not a hardware pass; D is one. Everything above is one
request (4,096 prompt tokens, 64 outputs) at one cut. `STATUS.md` in the
evidence folder has the file behind each cell and supersedes this table.

## Artifacts

| Field | Qwen3.5 35B A3B | Qwen3.6 35B A3B |
|---|---|---|
| Runtime model ID | `registered_qwen35_35b_a3b` | `registered_qwen36_35b_a3b` |
| Profile ID | `registered_qwen35_35b_a3b_greedy_generation_v1` | `registered_qwen36_35b_a3b_greedy_generation_v1` |
| Catalog model ID, version | `qwen3.5-35b-a3b`, `2026-08-25-r1` | `qwen3.6-35b-a3b-vl-mtp-mxfp8`, `2026-08-11-r1` |
| Manifest SHA-256 | `db0a8dd2902473c4b6dcd4eab9511212b52fe7bf9cb8e043aebfc47a900d21ff` | `54ba4df3022077a69974cfd4de91196622c865b45ae361e1051c1cda405bc7cc` |
| `config.json` SHA-256 | `58a2b700bbe36066bc3e8bac65341a7f886c8dbe4db510553150004cfb0294f7` | `b852ada32203b112e217e5cb48afeadaf16594c0f5d3f5f7a380897e5e8732c2` |
| Aggregate SHA-256 | `95811153b3bb2ed78bf44b3248b07b52fce637706107de8b0fddf21796ade01c` | `d932e96b00404b0575fff47e2dac8ed113056b3f22d0040c3c8d3f9ef25b09ed` |
| Files, bytes | 14 files, 20,893,747,852 | 13 files, 21,308,856,601 |
| Text tensors loaded | 1,637 canonical (1,757 stored), 19,498,262,656 bytes | 1,637 canonical (1,757 stored), 19,508,787,456 bytes |
| Not loaded | `mtp.safetensors` (46 tensors), vision tower (333) | MTP head inside the shards (30 tensors, 10 of them unsigned-byte MXFP8), vision tower (333) |
| Weights | affine 4-bit, group 64; recurrent decay float32 | affine 4-bit with 8-bit routers declared per module (80 entries); recurrent decay bfloat16 |

The full hashes are in `QwenDenseRegisteredSpecification.swift`. The manifest
pin of both is the catalog endpoint's manifest bytes. The 9B and 27B pin a
`manifest.json` object of the model CDN; which convention stands is for the
integrator to settle.

Geometry of both: 40 layers, hidden 2,048, 16 query heads, 2 key/value heads,
head width 256, full attention every fourth layer (30 recurrent, 10
attention), 256 experts of width 512 with 8 used per token beside one shared
expert of width 512, vocabulary 248,320.

## Feasibility

No change was needed outside the two cluster packages.

- The product's model class already builds the routed-expert layer; a stage is
  that class with fewer layers. The experts are token-local and hold no
  request state, so a layer that carries them splits between stages exactly as
  a dense layer does: the state a mode moves, its framing and the hand-off of
  the phase split are unchanged.
- The expert-tile route is selected by one environment variable
  (`MLX_GATHER_QMM_EXPERT_SLICES=trust`, the product's serving value) and
  kernels the worker's Metal library already contains. The guarded JACCL
  commit the 26.2 worker is built against differs from the recorded nested
  MLX pin in JACCL files only.
- What had to change is admission: the dense runtime refused the wrapper model
  type, the routed-expert keys, the fused bank and the fourth arithmetic
  variable by name.

## What changed

| Commit | Change |
|---|---|
| `7d06b0a30` | Protocol: a second adapter, `qwen35-routed-expert-layer-stage`, with its own model and profile pairs and its own arithmetic policy ID. A capability must name the policy of its adapter |
| `0c66af481` | Layer-stage metadata admits a routed-expert configuration: bounded sizes, the pinned router policy, the wrapper namespace, the fused module inventory, adapter labels in the stage and plan identity |
| `f2afdbaa3` | Loading: the artifact stores the routed bank's gate and up projections as two tensors and the decoder holds one fused tensor. A canonical tensor may have a second stored part; the largest host read is per part |
| `f3433e28b` | The arithmetic contract `qwen_cbv2_query128_bf16_tf32_expert_tiles_v1`: the dense contract plus `MLX_GATHER_QMM_EXPERT_SLICES=trust`, with `MLX_QWEN_DIRECT_EXPERT_REDUCTION` required absent |
| `5351ff491` | Qwen3.5 35B A3B registered: catalog row with pinned hashes, ceilings, definition (cuts 4 to 36 in fours, all three generation modes), capability metadata from the row's adapter and policy; metadata fixtures and an admission suite |
| `81d0ecda5` | Qualification tools take the model's extra arithmetic variable from its row; prompt tool pin; usage texts read cuts from the catalog; one test holds all five closed model lists to each other |
| `4bd43edae` | Fix found by the first real load: the observed stored-tensor count is compared with the canonical tensors counted by their stored parts (1,757, not 1,637) |
| `8f455866d` | A routed-expert load requires the native expert-tile route before it reads a tensor; the reference tool arms the backend's route counters and reports them |
| `c4fcd265f` | Cherry-pick of `0f5fd2c48` (`work/gptoss`): a tensor header scope that can describe unsigned-byte tensors; the dense default refuses them as before |
| `ba7b820e8` | Qwen3.6 35B A3B registered. Its row sets `unownedUInt8Tensors`, the only caller of the wider header scope; a stage still loads none of those tensors |
| `5cfdaed4e` | Qwen3.6 35B A3B in the qualification request models and the prompt tool pins |

The first four commits are the base other family branches were built on.

The 9B and the 27B are unchanged: their admission suites, plan and profile
fingerprints, the 9B capability golden file (`registered-qwen35-9b.capability.json`,
byte for byte) and the dense arithmetic receipt pass as before; the routed
adapter's suite asserts the dense receipt equals the one computed the old way.

### Shared files touched

Every edit to a file that existed is additive or a one-line substitution:

| File | Edit |
|---|---|
| `DarkbloomClusterProtocol/ClusterRuntimeCapability.swift` | new adapter case; `registeredProfiles` and `arithmeticPolicyID` per adapter; `registering(runtimeModelID:)` |
| `DarkbloomClusterProtocol/ClusterRuntimeCapabilityValidation.swift` | one line: the capability's policy must be its adapter's |
| `Checkpoints/SafeTensorReader.swift` | the cherry-picked scope (`TensorDescriptorScope`, `acceptsUInt8`) |
| `Models/Qwen/Metadata/QwenDenseProfileTypes.swift` | two model cases |
| `Models/Qwen/Metadata/QwenDenseRegisteredSpecification.swift` | fields `kvHeads` (default 4), `routedExperts` (default nil), `unownedUInt8Tensors` (default false), `rootModelType`; two rows |
| `Models/Qwen/Metadata/QwenRegisteredDenseModelProfile.swift` | root type from the row; routed geometry compared with the row |
| `Models/Qwen/Metadata/QwenLayerStageMetadata.swift`, `QwenLayerStagePlan.swift` | hooks into `QwenRoutedExpertStageMetadata`; dense path unchanged when the root type is `qwen3_5` |
| `Models/Qwen/Metadata/QwenRegisteredContentInventory.swift` | switch cases |
| `Models/Qwen/Resources/QwenResidentResourceCeilings.swift` | one case for both models |
| `Models/Qwen/Resident/QwenResidentModelDefinition.swift` | two cases; `adapter` and `arithmetic` on the row |
| `Models/Qwen/Resident/QwenResidentAdmission.swift` | one line: the row's arithmetic contract admits the environment |
| `Models/Qwen/Resident/QwenResidentCapabilityMetadata.swift` | adapter and policy from the row; `registeredModels`, `registeredCutsUsage`, manifest pin and required environment per model |
| `Models/Qwen/Prefill/QwenLongPrefillArithmeticEnvironment.swift` | an overload of `admit` that takes extra required and absent names |
| `Models/Qwen/Loading/QwenLayerStageInventoryTypes.swift` | `secondPart` on a source tensor (default nil) |
| `Models/Qwen/Loading/PreparedQwenLayerSource.swift`, `QwenDenseObservedSource.swift`, `VerifiedQwenLayerStageLoading.swift` | second stored part; feed-forward type through the routed helper |
| `Models/Qwen/Loading/PreparedQwenCheckpoint.swift`, `QwenResidentSource.swift` | the header scope passed from the row |
| `Models/Qwen/Loading/QwenResidentLoading.swift` | one line: the route requirement |
| `Models/Qwen/Generation/QwenLayerStageSession.swift`, `State/CBv2RequestGeometry.swift` | feed-forward kind through the routed helper |
| worker `QualificationRequest.swift`, `PairConfiguration.swift`, `SoloDriver.swift`, `PromptTokenizer.swift`, `StageLoadCheck.swift`, `ReferenceCheck.swift`, `PairCheck.swift`, `Package.swift` | request rows with an extra arithmetic variable; the drivers start ranks with the request's environment; usage from the catalog; test target dependencies |
| check runners (`CheckpointChecks`, `StageTransferChecks`, `PrefillScheduleChecks`, `StageMetadataChecks`, worker `CapabilityChecks`) | the new source files in their closure lists |

Family code is in new files: `QwenRoutedExpertStageMetadata.swift`,
`QwenRoutedExpertStageModel.swift`, `QwenResidentArithmeticPolicy.swift`,
`QwenRoutedExpertRouteObservation.swift`.

## Memory per stage

Stage 0 at cut `c` holds the embedding and `c` layers; stage 1 the rest, the
norm and the head. Loaded tensor bytes, from the registered inventory:

| | Qwen3.5 35B A3B | Qwen3.6 35B A3B |
|---|---:|---:|
| Embedding, norm and head | 286,064,640 | 286,064,640 |
| Recurrent layer | 474,072,640 | 474,335,744 |
| Attention layer | 470,395,008 | 470,658,176 |
| Four layers (one interval) | 1,892,612,928 | 1,893,665,408 |

Stage 0 at cut 12 is about 5.55 GiB and stage 1 about 12.6 GiB. Named request
state at the largest request is 558,344,232 bytes (ceiling 563,806,248), a
third of the 27B's, because there are two key/value heads.

## Results

Build r3 (commit `5cfdaed4e`, worker `0cc4c0e71427…`, the same bytes on both
Macs), cut 12, 2026-10-09 17:52Z to 18:00Z. The evidence folder's `STATUS.md`
names the file behind each line.

**Stage loads.** Rank 0 holds 12 layers (5.554 GiB), rank 1 holds 28 (12.605
GiB). Load: 16.1 s and 21.5 s on Mac A, 10.8 s and 14.9 s on Mac B, including
the hash of the whole artifact. A few kB active after release, allocator
cache 0, equal storage commitments on both Macs. For the Qwen3.6 model on
Mac B: 5.557 and 12.612 GiB, 8.1 s and 9.3 s; that load reads its shards
through the unsigned-byte header scope.

**One Mac.** Mac A's staged reference of the request, twice: `exact`. Both
stages in one process hold 18.16 GiB (peak 19.27 GiB). Two workers over the
local test socket, pipeline: `exact` against the reference, ranks agree. So
the layer split of a routed-expert model is exact on one chip.

**The pair** (rank 0 on Mac A, rank 1 on Mac B, `one_chunk_lookahead_v1`).
All three generation modes completed, the ranks agree on the tokens in each,
and the modes agree with each other bit for bit (tokens, final row, all 90
state digests).

Against Mac A's own reference the verdict is `divergedAtNearTie` in every
mode, identically: the first ten output tokens are equal; at index 10 the
reference chose token 9117 and the pair 17415, and in the reference those two
have the same logit (28.875, margin 0.0). Final-row logits differ by at most
0.5. The pair's stage 1 runs on the other chip, and the 27B programme accepts
exactly this verdict across chips, but "tokens equal the oracle" was the bar
here and it was not met. Mac B's own reference of this request (2026-10-09 23:26Z) settles it: Mac B alone also
chooses 17415 at index 10 (Mac A against Mac B: `divergedAtNearTie`, 0.0 ulp), and the
pair then equals Mac B alone up to index 36, where a 1-ulp near tie splits them. The tie
is broken by the chip, not by the pair. Under the owner's rule this is a pass.

| Mode | First token | Prefill | Decode |
|---|---:|---:|---:|
| Pipeline | 0.921 s | 4,446 tok/s | 67.7 tok/s |
| Compact pipeline | 0.919 s | 4,455 tok/s | 72.2 tok/s |
| Phase split | 0.937 s | 4,371 tok/s | 86.0 tok/s |

4,096 prompt tokens, 64 outputs, four requests per mode with the last three
quoted. The compile lanes were not held, so other workers' compiles ran
beside these requests: indicative, not a benchmark. The phase split's
hand-off is 44,482,572 bytes in 24 segments and takes 23 to 25 ms. No
single-Mac run on the same driver clock exists yet, so no speed-up is
claimed.

**Fault.** With the 8,192-token request decoding in the pipeline, rank 1 on
Mac B was ended with SIGTERM 0.3 s after the first token (24 of 128 tokens
committed). Rank 0 exited by itself with status 1; the driver sent no signal;
no worker process was left on either Mac.

**Qwen3.6 35B A3B** (same build, cut 12, 2026-10-09 23:10Z to 23:16Z, the first run of this model across the cable). Stage loads on Mac A: 5.557 GiB in 15.8 s and 12.612 GiB in 21.1 s. Mac A's reference twice: `exact` (18.17 GiB, peak 19.28 GiB). Local test socket, pipeline: `exact`. On the pair all three modes completed, ranks agree, the modes agree `exact`, and against Mac A's reference the verdict is `tokensEqualLogitsDiffer` (all 64 tokens equal; final-row difference at most 1.5, mean 0.135; reference margin 3.625). Indicative figures, compile lanes not held, mean of the last three of four requests: pipeline 0.905 s first token, 4,524 tok/s prefill, 69.7 tok/s decode; compact 0.905 s, 4,524, 71.3; phase split 0.930 s, 4,405, 85.8. Fault with the 8,192-token request: rank 1 on Mac B ended with SIGTERM 0.3 s after the first token (27 tokens committed); rank 0 exited by itself with status 1, nothing was left on either Mac, wired memory unchanged within 26 MB on both.

The owner's rule for mixed-chip numerics (2026-10-09): a run passes when its tokens equal the reference (`exact` or `tokensEqualLogitsDiffer`) or first differ at a near tie (`divergedAtNearTie`, 4-ulp rule); `diverged` and `incomparable` fail. By that rule both models pass D at cut 12.

For the Qwen3.6 model Mac B's own reference differs from Mac A's at a 1-ulp near tie at index 39 (`divergedAtNearTie`); the pair equals Mac A's reference for all 64 tokens. With 5,120 prompt tokens the pair against Mac A's reference is `divergedAtNearTie` at index 27 (1.0 ulp), a pass under the owner's rule.

**Pair against each Mac alone, Qwen3.6 35B A3B** (one hold, 2026-10-10 00:19Z to 00:25Z; `lane.sh` and `lane-b.sh`, compile lanes not held; 64 outputs, mean of requests 2 to 4 of four, driver clock; single Mac = `pair-check solo`, serial schedule; pair = lookahead):

| Prompt | Run | First token | Prefill | Decode |
|---|---|---:|---:|---:|
| 4,096 | Mac A alone (M3 Ultra) | 2.217 s | 1,847 tok/s | 56.6 tok/s |
| 4,096 | Mac B alone (M5 Max) | 1.213 s | 3,377 tok/s | 85.8 tok/s |
| 4,096 | Pair, pipeline | 0.909 s | 4,507 tok/s | 63.6 tok/s |
| 4,096 | Pair, compact pipeline | 0.910 s | 4,505 tok/s | 65.8 tok/s |
| 4,096 | Pair, phase split | 0.927 s | 4,420 tok/s | 82.8 tok/s |
| 5,120 | Mac A alone | 2.810 s | 1,822 tok/s | 57.2 tok/s |
| 5,120 | Mac B alone | 1.537 s | 3,332 tok/s | 87.9 tok/s |
| 5,120 | Pair, pipeline | 1.127 s | 4,544 tok/s | 65.7 tok/s |
| 5,120 | Pair, compact pipeline | 1.134 s | 4,514 tok/s | 69.1 tok/s |
| 5,120 | Pair, phase split | 1.165 s | 4,395 tok/s | 77.6 tok/s |

The adapter profile caps prompts at 8,192 tokens; 10k, 20k and 30k wait for the coordinator to raise it (not changed here).

**Refusals and failures.** The first real load (an earlier build, cut 20,
Mac B) was refused before any tensor was read, by the count comparison fixed
in `4bd43edae`. The host memory gate has refused or stopped no load.

## Provider and coordinator: what stands in the way

No catalog or chip gate was relaxed. To serve either model on a pair, at
least this must change (paths under `provider-swift/Sources/ProviderCore`,
lines at this branch's head):

| Where | What |
|---|---|
| `Inference/Distributed/Installed/DistributedInstalledPlan.swift:25` | An installed plan requires the dense arithmetic policy ID by literal; a routed-expert capability is refused |
| `Inference/Distributed/Installed/DistributedInstalledPlan.swift:68` | The worker environment sets the three dense variables only; a routed-expert rank would be refused by its own admission without `MLX_GATHER_QMM_EXPERT_SLICES=trust` |
| `Inference/Distributed/Installed/DistributedInstalledPairServingTable.swift:110` | The pair-serving table has rows for the 9B and the 27B; every other model is refused with `noRow`. A row needs measured time budgets from a quiet pair, and a decision on the near-tie verdict above |
| `Server/Distributed/DistributedLocalServer+HTTP.swift:71` | The distributed server has no vision gate; the Qwen3.6 artifact's catalog entry is a vision model, and only its text path exists in the runtime |
| Catalog and coordinator | The Qwen3.6 catalog ID promises vision and an MTP head. A pair would serve text with MTP off: that needs its own catalog statement, not a renamed model. Coordinator code is in another repository and was not touched |
| Manifest pin | See "Artifacts": catalog-endpoint manifest bytes against CDN `manifest.json` |

## Resuming

The evidence folder's `STATUS.md` has the exact next command at every point.
In short: `tools/run/batch-abcd.sh MODEL CUT` runs A, B and C on Mac A and
then D across the cable under the lanes; `tools/pair-measure-moe.sh` is the
full two-Mac programme (cut sweep, modes, recorded runs, fault set) in the
form of the phase-split one.

## Not done

- Everything marked "Not run" in the status table, first of all Mac B's
  staged reference and the Qwen3.6 model's B, C and D.
- `swift test` of the two packages at the final commit (the check runners
  that need no model pass; the suites that touch Metal need the GPU lane).
- The changes on this branch have not been independently reviewed.
