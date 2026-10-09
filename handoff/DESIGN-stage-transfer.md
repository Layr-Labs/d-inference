# Design: a follower receives its stage over the link (B11)

> Last updated: 2026-10-09

Status: **plan only, nothing implemented.** Written from a read of the code on
2026-10-09 (`cac79ceaf`). Every timing below is an estimate until the stream
probe and the pair runs (slices 8 and 9) have been done. The decisions in
section 10 are the owner's; the defaults taken for the first slices are the
recommendations stated there.


Paths use `$SRC` for the repository root, `$RT` = `$SRC/libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime`, `$PR` = `$SRC/libs/darkbloom-cluster/Sources/DarkbloomClusterProtocol`, `$WK` = `$SRC/libs/darkbloom-cluster-worker`, `$PV` = `$SRC/provider-swift/Sources`.

**Recommendation.** Build this as a second payload source for the existing verified stage loader, not as a new loader. The receiving rank derives every name, shape, dtype, byte count and message size from pinned metadata. It receives its stage in typed pieces of at most 8 MiB over the existing `Collective.sendCompleted` / `receiveCompleted` calls, with no change to the 16 MiB cap or to `Collective.swift`. It checks each assembled tensor against a new pinned per-tensor SHA-256 inventory before the stage model leaves the loader. The sending rank reads byte ranges from its already-verified file descriptors one piece at a time and never materialises the peer's stage. One new pinned identity per registered model is unavoidable, because the finest content identity pinned today is per file. Keep the first version memory-only, and bind the choice into the load agreement so its bytes are unchanged when both ranks load locally. My estimate is a follower stage in about 1.0–1.9 s once the leader has finished its own 2.1–2.4 s verification, so pair-ready moves from 6.3–7.3 s to roughly 7–9 s. Slices 1, 2 and 5 touch none of the files the 27B and phase-split work are editing and can start tonight.

## 1. What the follower needs, and what can verify it

**Tensors.** Stage 0 is `language_model.model.embed_tokens.{weight,scales,biases}` plus layers `[0, cut)`. Stage 1 is layers `[cut, 32)` plus `language_model.model.norm.weight` and `language_model.lm_head.{weight,scales,biases}` (`QwenLayerStagePlan`, `$RT/Models/Qwen/Metadata/QwenLayerStagePlan.swift`). A linear-attention layer has 30 tensors (122,913,216 bytes); every fourth layer is full attention with 25 (117,982,208 bytes). Placeholders (`installQwenStageInertParameters`) are built locally and never sent.

**Bytes per cut**, computed in planning from `$SRC/libs/darkbloom-cluster/Tests/StageMetadataChecks/Inputs/qwen-retained-inputs.json` with that ownership rule. Both columns sum to the pinned `sourceBytes: 5_038_041_600` and `tensorCount: 927`.

| Cut | Stage 0 (rank 0) | Stage 1 (rank 1) |
|---|---|---|
| 4 | 1,058,851,136 B, 118 tensors | 3,979,190,464 B (3.706 GiB), 809 tensors |
| 8 | 1,545,572,992 B, 233 | 3,492,468,608 B, 694 |
| 12 | 2,032,294,848 B, 348 | 3,005,746,752 B, 579 |
| 16 | 2,519,016,704 B, 463 | 2,519,024,896 B, 464 |

The largest tensor in either stage is 508,559,360 bytes (`embed_tokens.weight` or `lm_head.weight`, U32 `[248320, 512]`).

**Dtypes and quantized layout.**
- Whole model: 250 U32 tensors (4,476,370,944 B), 653 BF16 (561,667,584 B), 24 F32 (3,072 B, the `A_log` vectors).
- Storage is affine 4-bit with group size 64: a `[out, in]` projection is stored as U32 `[out, in/8]` plus BF16 scales and biases `[out, in/64]`. For example `mlp.down_proj` is U32 `[4096, 1536]` with BF16 `[4096, 192]`.
- No tensor is stored as F16, so `qwenStageLoadedDType` converts nothing: wire bytes, file bytes and resident bytes are identical. The design still hashes source-dtype bytes and converts afterwards, as `materializeVerifiedQwenLayerStage` does.

**What is pinned today** (`QwenDenseRegisteredSpecification.all`, `$RT/Models/Qwen/Metadata/QwenDenseRegisteredSpecification.swift`):
- `configurationSHA256`, `manifestSHA256` (which fixes a SHA-256 and size for each of the 12 files) and `artifactSHA256`.
- `inventorySHA256`, a fingerprint of `name|sourceDType|shape|byteCount` lines (`QwenDenseCanonicalTensor.identity`). It contains no content digest.
- The derived values `sourceTensorManifestSHA256`, `sourceParameterLayoutSHA256` and `storageCommitmentSHA256` hash names, files, offsets, shapes and counts. Content enters only through `verifiedAggregateSHA256`.

So the pinned identities are per file, not per tensor. Per-tensor content hashes were not found in the specification, the manifest, or the four research refs.

**Smallest addition: a pinned content inventory.**
- **Record.** The existing model-independent `LayerStageSourceTensor` (`$RT/Models/Metadata/LayerStageTensorMetadata.swift`: name, dtype, shape, byteCount, file, absolute offset) plus `contentSHA256` over `file[offset ..< offset+byteCount]`. File and offset must be in the pinned record because `sourceTensorManifestSHA256` hashes them. With them, a diskless rank derives the same `storageCommitmentSHA256` as a local load.
- **Pin.** One new optional field, `contentInventorySHA256`, on `QwenDenseRegisteredSpecification`, nil for a model nobody has inventoried. It must not be folded into `profile.fingerprint` or any existing fingerprint.
- **Who computes it.** A new mode of `darkbloom-cluster-stage-check`, run on a Mac whose artifact has passed `VerifiedCheckpoint`. It can reuse `tensorDescriptors(checkpoint:)`.
- **Where the document lives.** I recommend a generated Swift literal per model in the runtime (about 150 KB for 927 tensors), so nobody sends it and the already-compared worker build hash covers it. The alternative is delivering it in-band and checking it against the same pin.
- **How it is itself verified.**
  - Its hash equals the pin at every load.
  - Dropping the content field must reproduce the already-pinned `inventorySHA256` (`4a543a46…fb51`).
  - Its file and offset fields must reproduce the cut-4 commitment `e2e41be21c40…` recorded in the ledger.
  - A real-artifact test recomputes it, as does an independent Python script.

**Fallback with no new pin.** Stream both weight shards whole (5,950,221,072 B) and check the manifest's file hashes. It works for any model, but sends 2–3.4 GB the follower discards and is bounded by one SHA-256 stream over the 5.35 GB shard (about 1.8 s).

## 2. Transfer protocol

**Where it runs.** Inside `QwenResidentRuntime.load` (`$RT/Models/Qwen/Resident/QwenResidentRuntime+Load.swift`), after the `residentLoadIntent` exchange and before `residentLoaded`, in place of the receiver's disk read. A separate pre-step is not possible: the bytes must land in the worker's own MLX allocations, and a closed JACCL group cannot be reused.

**Roles.** Sender is the rank whose source is `local_artifact_v1`; receiver is `peer_transfer_v1`. Both ranks choosing `peer_transfer_v1` is refused at admission. The sender already holds the peer's ordered inventory: every rank runs `inspectOtherQwenLayerStage` today. The sender serves the peer before materialising its own stage.

**Framing.** There is no sender-declared metadata.
- Both ranks compute the same `QwenStageTransferPlan` from the delivered stages' `inventory.active` order and two agreed constants.
- A tensor at or under the piece limit is one message with its real shape and dtype.
- A larger tensor is split along axis 0 into the fewest equal row-aligned pieces under the limit, then joined with `concatenated(pieces, axis: 0)`.
- Phase-split has rank 1 hold both stages, so the plan must take a list of delivered stages (5,038,041,600 B in that case), not "the follower's stage".

**Piece size against the cap.**
- `CollectivePointToPointShape.hardByteLimit = 16 * 1024 * 1024` bounds the allocation one receive makes before any byte is validated. Its comment reads "Local admission, never inferred from an unchecked remote header". No other written rationale was found.
- The cap is policy, not transport: JACCL frames everything at `FRAME_SIZE * (1 << 7)` = 512 KiB, and the transport check moved 1 GiB in one call.
- I propose 8 MiB pieces. That equals `CheckpointAlignedReadPlan.maximumScratchRequestBytes`, so the sender needs one aligned read per piece. It also leaves room for the 40-byte record framing under `ClusterRecordLimits.hardMaximumPlaintextBytes` if the transfer is encrypted later.
- Cut 4 stage 1 is about 1,100 pieces at 8 MiB (1,071 by bytes, plus one more per `mlp.down_proj.weight` from row alignment), or 925 at 16 MiB.
- Throughput through `sendCompleted` at these sizes is not in the ledger; slice 8 measures it and picks the size.

**Flow control.** A window is the longest run of pieces totalling at most 64 MiB and 64 pieces. Each window is:
1. sender to receiver: `windowOpen(i)` or `senderAbort`;
2. the pieces, back to back;
3. receiver to sender: `windowReceived(i)` or `receiverAbort`.

After the last window the receiver sends `stageVerified` or `stageRefused` and the sender sends `senderComplete`. Each control value is a 64-element Int32 digest, as in `QwenLayerStageGenerationAcknowledgement.values`, bound to the load agreement (and so the epoch), the phase, the window index and the cumulative bytes. The receiver compares it with a locally computed value and never parses it. If the link does not tolerate back-to-back sends (gap B2), the window shrinks to one piece.

**Rank agreement additions.** Append fields to the load-intent agreement only when a rank is not local, following `QwenResidentPrefillSelection.loadAgreementFields`: both ranks' sources, the delivered stages, `contentInventorySHA256`, the piece and window limits, and the budget. `residentLoaded` is unchanged.

**Worker JSONL additions.**
- An optional `stage` object on `ClusterWorkerReady` (source, tensor count, bytes, inventory hash; or bytes served), omitted when both ranks are local so existing fixtures stay byte-identical.
- `supportedStageSources` on `ClusterRuntimeCapability`, omitted when local-only.
- One optional worker argument, `--stage-sources`.
- No new commands and no progress events: `WorkerMain` builds the runtime before `WorkerCoordinator` exists, so nothing can be published before `ready`.

**Bilateral deadline.** The agreement carries a duration, since the two uptime clocks differ. I propose 5 s plus 1 ms per MB. Each rank starts it when the `transferOpen` exchange completes and enforces it with `QwenResidentControl.check(deadline:)` before every call. The transfer refuses to begin unless start + budget + `JACCL_PROGRESS_TIMEOUT_MS` + 2 s falls before the startup and lifetime deadlines. That keeps every failure on the path that releases memory, not the abrupt exit 123 or 124.

**When the other side stalls or dies.**
- A failure noticed between calls (bad digest, budget, read error) is sent as an abort at the next window boundary, so the peer stops within about 64 MiB.
- A peer that dies inside a native call costs the survivor the full progress limit (60 s installed, 120 s default). The survivor then throws, joins its hash jobs, drops everything, clears the cache and exits 1 without being signalled.
- No cancel exists in the transport (gap B1).

## 3. Memory

**Sender.** At any moment the sender holds about 24 MiB beyond its normal load: one 8 MiB host buffer, one 8 MiB MLX array and the aligned-read scratch, regardless of stage size.

It could send from mmap'd bytes, but I advise against it:
- The pinned MLX's no-copy constructor goes through `MetalAllocator::make_buffer` (`$SRC/libs/mlx/mlx/backend/metal/allocator.cpp`), which wraps page-aligned regions and adds them to the GPU residency set and active memory. That is exactly the "loaded into GPU memory" outcome to avoid, and tensor offsets are not page-aligned anyway.
- A mapping turns read errors into SIGBUS.
- A mapping grows page cache that the leader's own load gate does not count as free.

The loader already avoids mapping ("never a mapping of the verified file"). Use `VerifiedCheckpoint.File.read(into:offset:)`.

**Receiver.**
- A tensor at or under the piece limit is received straight into its final typed allocation.
- A larger tensor is joined once, so the transient is twice that tensor (at most 1.02 GB, early in the order when little else is resident).
- There is never a second copy of the stage and no host `Data` staging.
- Admission reuses `QwenResidentLoadGate`, which already budgets two copies of the largest tensor, with the window in place of the read scratch.
- Removing the join copy means receiving a whole tensor in one call, which needs a separately admitted limit above the cap. I would leave that for later.

**Release on failure.** The stage model is never returned until every digest has passed. On refusal the receiver joins the hash jobs (they hold array references), drops pieces and model, and takes the existing failed-load path: synchronize both streams, `Memory.clearCache()`, `guard retired == nil`, exit. That path checks model retirement but not active bytes; the single-Mac test adds the check.

## 4. Verification cost and time to ready

**Measured inputs.**
- Link: 8.7 GiB/s (9.34 GB/s) A to B and 6.4 GiB/s B to A, for 1 GiB raw transfers (ledger).
- SHA-256: 2.94 GB/s on one thread, 7.95 GB/s over 4 threads and 21.5 GB/s over 8. I measured this during planning on Mac A with OpenSSL via Python, in memory. CryptoKit and Mac B were not measured.
- Local stage load: 2.9–3.6 s on A and 2.2–2.7 s on B (ledger). A breakdown of that figure was not found.

**Arithmetic for cut 4, stage 1 (3.979 GB).**
- Wire: 3.979 / 9.34 = 0.43 s at peak. I assume 0.6–1.0 s once the sender's SSD read and piece overhead are included.
- Hashing: serially 3.979 / 2.94 = 1.35 s. Because the inventory is per tensor, hashing runs on 6–8 threads while receiving, each job reading the final array in place through `asData(access: .noCopyIfContiguous)`. It keeps pace with the link, and the tail is the largest tensor: 0.509 / 2.94 = 0.17 s.
- Join: about 0.3 s for roughly 3.2 GB of multi-piece tensors.
- Model construction and install: 0.3–0.7 s, inferred from the local load.

That gives a follower stage in about 1.0–1.9 s from transfer start, against 2.2–2.7 s for a local load on B. The local load is dominated by hashing all 12 files serially (6.114 / 2.94 = 2.08 s).

**The catch.** The leader must verify its own checkpoint first (about 2.1–2.4 s), so the follower is ready roughly 3.4–4.3 s after both start. Pair-ready moves from 6.3–7.3 s to about 7–9 s. All of this is estimate until slices 8 and 9 run.

## 5. Durability

I recommend memory-only for the first version:
- A stage is not an artifact. Files are pinned whole, so a persisted stage could never pass `VerifiedCheckpoint`; persisting means moving all 12 files.
- Persisting belongs to the provider, not the rank worker. It needs `ModelDownloader`'s staging, `ensureAvailableCapacity`, `ModelArtifactWriteLease` and exclusive promotion, which is what the research rsync draft did.
- Two disk routes already work: the CDN, and a copy over the cable followed by a rehash.
- Re-sending is cheaper than a local load, including at each 300 s session rotation.

The follower keeps only the 9 non-weight manifest files (26,846,742 bytes), all verifiable with existing pins.

## 6. Failure and security cases

| Case | Outcome |
|---|---|
| Wrong bytes | That tensor's digest differs; abort at the next boundary or `stageRefused`; nothing leaves the loader; both ranks exit 1 |
| Truncated tensor | Sizes are local: a short send stalls until the progress limit, a padded one fails its digest |
| Extra tensors | The receiver never posts a receive for them. Read from source, not exercised: JACCL has no message boundaries, so a mismatched send surfaces as a transport fault or a wrong control value |
| Different quantization layout | A different config stops at admission or load intent, before any byte; same config with different bytes fails digests |
| Older artifact revision, or replay | Bytes are checked against the current pins; control values bind the membership epoch, so old ones do not match |
| Follower lies about verifying | Undetectable, and not new: `residentLoaded` is computable from metadata alone, and rank 1 already selects tokens |

After a transfer the leader may assume only that it disclosed those bytes. It must not hang any new authority on the follower's claim (decision D1).

**What plaintext means here.** Integrity does not depend on the transport, because verification is end to end against pins. Confidentiality is absent: 2.5–4 GB of weights cross the cable in the clear to whoever answered JACCL's unauthenticated bootstrap (gap A6). That is acceptable only for a publicly distributed artifact, so each model needs an explicit flag allowing transfer.

Encrypting later is not a drop-in: `ClusterRecordType` has no payload type, and `hardMaximumCumulativePlaintextBytesPerDirection = 4_294_967_296` is below the full 9B (4.69 GiB) and every 27B stage. The research cost figure (5 MiB record: 4.50 ms encrypted, 2.02 ms raw, on different hardware) suggests roughly double the wire time.

## 7. Product surface

- **Setup.** Each Mac decides about itself from local evidence and saves it explicitly, as a new per-peer `stageSource` in `ClusterConfiguration` (`$PV/ProviderCore/Config/ClusterConfiguration.swift`). Omission means local. A complete artifact (all manifest files at exact sizes) proposes local; a metadata-only directory proposes receive.
- **Consent.** Choosing receive asks for confirmation, stating the size and that the bytes are unencrypted.
- **No silent switching.** A setup saved as local with weights missing refuses at start; it does not fall back to receiving.
- **Agreement.** Both saved setups name both ranks' sources; a mismatch fails at the load-intent exchange.
- **Installed plan.** `DistributedInstalledPlan.nativeArguments` adds `--stage-sources` only when non-default and advertised, through a small selection type modelled on `DistributedInstalledPrefillSelection`. The follower's `--model-dir` points at the metadata directory.
- **`cluster doctor`.** A new `stageSource` check reports that the worker advertises the source, the model has an inventory pin, and the metadata files verify. It says plainly that no weights were transferred or verified.
- **`cluster status`.** Each member shows its source and, from the `ready` event, the tensors and bytes verified.

## 8. Test plan

**Unit (no model, no GPU).**
- Inventory codec and its refusals.
- Plan arithmetic, with goldens from the fixture.
- Sender and receiver state machines on tiny safetensors fixtures (as in `TensorVerificationTests`): flipped bit, swapped same-shape tensors, short or extra message, wrong or replayed control value, abort from either side.
- Codecs: legacy bytes unchanged when the new fields are absent.
- The deadline rule.

This level supports framing, ordering, refusal logic and wire compatibility. It cannot support real bytes, memory, transport or speed.

**Single Mac (real artifact, real MLX, no collective).**
1. The generated inventory equals its pin, both projections hold, and the Python recomputation agrees.
2. The refactor leaves all eight stage-check receipts unchanged.
3. A new stage-check mode drives the receiver from the sender core in-process, pull-based on one thread. Pass means: the same commitment; a new digest over every resident parameter equal to the local load's; peak within final plus twice the largest tensor plus a window; and after release a few KB active, zero cached, model deallocated.
4. Injected corruption refuses and returns to baseline.

This level supports byte-exact equality with a local load, peak and release, and hash cost on that chip. It cannot support RDMA, link flow control, throughput, or two-process failure timing. No in-process two-rank transport exists on this branch (gap B7); the phase-split worktree has an uncommitted loopback one, `CollectiveLocalSocket`, which this level should adopt once it lands.

**Two Macs (physical; blocked until Mac B's port has an address).**
1. A model-free `--mode stream` in `darkbloom-cluster-collective-check` replays the exact cut-4 schedule with patterned bytes, both directions, at 8 and 16 MiB, with windows of 1, 8 and 64 and receiver delays injected. It measures GiB/s and settles B2.
2. The pair driver runs with a metadata-only follower at cuts 4 and 16, short and 8,192-token prompts. Pass means:
   - both ranks exit 0 and no worker is left;
   - the commitment matches the local-load value;
   - tokens compare `exact` against the local-load pair run of the same request (the pair is exact run to run today);
   - IP counters on the link move at most 0.01% of the payload, with the RDMA libraries loaded;
   - time to ready and wired memory before and after are recorded.
3. Faults: one corrupted bit; each rank ended mid-transfer; budget expiry. Every survivor must end by itself and memory must return, and the next clean run must be exact.

This level supports RDMA carriage, real timing, cross-chip token equality and failure behaviour. It cannot support link security, coordinator-paired serving (C10), the 27B, or other chips and OS frame classes (B5).

## 9. Slices

| # | Commit | Files | Needs |
|---|---|---|---|
| 1 | Content inventory type, codec, refusals | new `$RT/Models/Metadata/LayerStageTensorContentInventory.swift`; new test | One Mac, no model. Start here |
| 2 | Generator, 9B document, pin | `$RT/Models/Qwen/Metadata/QwenDenseRegisteredSpecification.swift`; new generated file beside it; `$WK/Sources/StageLoadCheck/StageLoadCheck.swift`; Python cross-check under `$SRC/scripts` | One Mac with the artifact |
| 3 | Loader seam, behaviour-preserving: split metadata from payload source | `$RT/Models/Qwen/Loading/{PreparedQwenCheckpoint,PreparedQwenLayerSource,PreparedQwenLayerStage,VerifiedQwenLayerStageLoading,QwenResidentLoading,QwenDenseObservedSourceBridge,QwenResidentSource}.swift` | One Mac with the artifact |
| 4 | Source metadata from the pinned inventory, no files | new `$RT/Models/Qwen/Loading/QwenResidentPinnedSource.swift` | One Mac with the artifact |
| 5 | Plan, control values, sender and receiver cores (no MLX, no transport) | new `$RT/Models/Qwen/Transfer/*.swift`; new test | One Mac, no model |
| 6 | Native intake, in-process adapter, stage-check mode, parameter digest | new `Transfer/QwenStageTransferIntake.swift`; `$RT/Models/Qwen/Resident/QwenResidentStageLoadCheck.swift`; `QwenResidentLoading.swift` | One Mac with the artifact |
| 7 | Collective adapter, load integration, agreement, worker flag, ready and capability fields | `QwenResidentRuntime+Load.swift`, `QwenResidentAdmission.swift`, `QwenLongPrefillReadinessMaterial.swift`; `$PR/ClusterWorker{Messages,Codec,Session,Validation}.swift`, `$PR/ClusterRuntimeCapability*.swift`; `$WK/Sources/DarkbloomClusterWorker/Startup/WorkerConfiguration.swift` | One Mac for checks |
| 8 | Model-free stream probe | `$WK/Sources/CollectiveCheck/CollectiveCheck.swift` | **Two Macs** |
| 9 | Pair driver support and qualification runs | `$WK/Sources/DarkbloomClusterQualification/{PairConfiguration,PairDriver,QualificationReports}.swift`, `$WK/Sources/PairCheck/PairCheck.swift`, the fake worker | **Two Macs** |
| 10 | Fault runs | qualification flags only | **Two Macs** |
| 11 | Product: saved setup, installed plan, doctor, status | `$PV/ProviderCore/Config/ClusterConfiguration.swift`, `$PV/ProviderCore/Inference/Distributed/Installed/*`, `.../Diagnostics/ClusterDiagnostics.swift` | Checks on one Mac; end to end on **two** |
| 12 | Docs and ledger rows | `$WK/README.md`, `$SRC/docs/reference/cluster-control-protocol.md`, `$SRC/handoff/*` | — |

Slice 3 is the risky one: it touches the loader every load uses. Its oracle is byte-identical stage-check receipts before and after.

**Conflicts with the two changes in flight** (uncommitted, read in their worktrees today):
- **27B.** It edits `QwenResidentAdmission.swift`, `QwenResidentSource.swift`, `QwenResidentStageLoadCheck.swift`, `WorkerConfiguration.swift` and the capability files, and adds `QwenResidentModelDefinition` and `QwenResidentResourceCeilings`. Transfer eligibility and ceilings belong in those per-model rows. The global `QwenDenseLegacySourceBounds.maximumHostTensorBytes` (512 MiB) is below the 27B's largest tensor (635,699,200 B), so it must not be reused. Slices 2, 6 and 7 rebase on the 27B work.
- **Phase split.** It rewrites the same region of `QwenResidentRuntime+Load.swift`, edits `Collective.swift`, and adds a second `loadQwenResidentStage` call on rank 1 for the producer stage. Slice 7 goes after it and uses its agreement-extension pattern. Staying on the unchanged send and receive calls avoids any conflict in `Collective.swift`. Its `QwenPhaseSplitHandoffIntake` is the same join-then-verify shape but trusts the sender's digests, so I would not merge the two now.

## 10. Risks and open decisions for the owner

1. **Registration format.** Accept one new pinned hash per model plus a generated inventory, or take the whole-file fallback (no new pin; slower and larger).
2. **Inventory delivery.** Embedded in the runtime (my recommendation) or sent in-band against the same pin. Longer term it belongs beside `manifest.json` in the catalog.
3. **Weights on a plaintext, unauthenticated link.** Acceptable for the public 9B artifact? Should transfer be an explicit per-model permission?
4. **Persistence.** Confirm memory-only; if disk is wanted, it is a provider artifact-fetch feature with its own disk admission and ownership.
5. **Cap.** Keep pieces under 16 MiB (recommended), or admit a separate whole-tensor receive class later to remove the join copy.
6. **Back-to-back sends on the link (B2).** Unproven. One 1 GiB send from B took an unexplained 2.8 s. If the probe fails, the window drops to one piece and wire time rises.
7. **Dead peer mid-transfer.** The survivor holds up to a partial stage for the full progress limit. A rank ended abruptly while holding a partial model has never been tried; the deadline rule exists to avoid it.
8. **Receipt wording.** A diskless rank reports the registered aggregate in `verifiedAggregateSHA256` without having verified it. Add a provenance field outside the commitment so the receipt does not overstate.
9. **Timing.** All timing here is estimate until slices 8 and 9. Hash rate on Mac B, CryptoKit's rate, piece-size throughput and the fixed load cost are unmeasured.
10. **Sequencing.** Two changes in flight touch the same files; landing order should be 27B, then phase split, then slice 7.

### Critical Files for Implementation
- `$SRC/libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/Models/Qwen/Loading/VerifiedQwenLayerStageLoading.swift`
- `$SRC/libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/Models/Qwen/Loading/QwenResidentLoading.swift`
- `$SRC/libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/Models/Qwen/Resident/QwenResidentRuntime+Load.swift`
- `$SRC/libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/Models/Qwen/Metadata/QwenDenseRegisteredSpecification.swift`
- `$SRC/libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/Transport/CollectivePointToPointShape.swift`
