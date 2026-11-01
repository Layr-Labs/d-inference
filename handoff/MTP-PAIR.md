# MTP on the pair: `phase_split_mtp_v1`

The registered Qwen3.5 9B and Qwen3.8 27B ship the product's inline speculative (MTP) head. On the pair the
decoding rank of a phase split, which holds every layer after the hand-off, now runs that head exactly as the
single-Mac product does: the product's drafter (`Qwen35InlineMTPAssistant`) drafts, both stages verify the window
`[last token, d1 … dk]` in one captured forward, the longest prefix of drafts equal to the target's own greedy token
is kept plus the target's token at the first mismatch, both stages commit at the kept position and roll the rest
back. Nothing new crosses the cable: rank 0 hands over what it always handed over and sees the same relay batches.
No SDK change.

## On by default, and the off switch

- **Capability.** A model whose artifact ships a head lists `phase_split_mtp_v1` in its resident row (9B, 27B, both 35B A3B rows);
  its capability record then advertises `speculation: "decodingRankHeadExactGreedy"` (other models keep `"off"`).
- **Placement (MTP credit).** The layout of a row that lists `phase_split_mtp_v1` carries
  `speculativeDecodeFactor` (the smallest speed-up the pair measured with the head over the same phase split
  without it: 9B 1.44, 27B 1.56, both 35B A3B rows 1.44) and `speculativeHead` (the `mtp.` tensors, charged to the
  decoding rank's memory). `ClusterSpeculativeCredit` decides per decoding Mac: a measured rate with the head wins;
  otherwise a GPU of the Apple M5 generation or later prefers the head and is credited the factor, and an older GPU
  (the M3 Ultra) decodes plain. `ClusterPlacementPlanner.ordered` ranks by time, then head preference, then
  headroom. So on a fresh install (no speed records: memory-only cuts) `darkbloom cluster plan` and the setup wizard
  save `phase_split_mtp_v1` with the M5 decoding for the 9B (cut 16), the 27B (32) and both A3B rows (20) on the
  M3 Ultra + M5 Ultra pair (product command run 2026-10-12, `T/evidence/universal-20261010/m5ultra/cluster-plan/`;
  golden plans `Tests/PlacementChecks/Golden/pairs/m3ultra-m5ultra/`, printed byte-equal on both Macs).
  `darkbloom start --local --distributed` then starts both workers with `--generation-mode phase_split_mtp_v1`.
  A placement with the M3 Ultra decoding (the wizard run on the M5 Ultra makes it rank 0) gets no head.
- **Status.** The installed session reports `mtpEnabled` and `mtpOffReason` (`none`,
  `setupSelectsPhaseSplitWithoutHead`, `generationModeRunsNoHead`, `runtimeCapabilityDisablesSpeculation`);
  `darkbloom cluster status` prints `MTP: on …` or the reason. The status codec checks the pair against the saved
  mode and the advertised modes.
- **Off switch (diagnostic).** Name `"generationMode": "phase_split_v1"` in the setup input and run
  `darkbloom cluster configure` again. It is the saved setup and not `DARKBLOOM_CBV2_MTP` because each Mac's owner
  reads only its own saved setup (no environment crosses the owner launch) and the two ranks must be told the same
  mode; a rank told something else stops at the load agreement.
- The pipeline modes run no head (a verify window would cross the cut once per round; not built).

## What both ranks agree to

The mode, `QwenMTPTerms` (schema, `depth` 1…4, default the row's own `QwenMTPTerms.standard(for:)`: 3 on the
35B A3B rows, measured fastest there, and 4 = the product drafter's maximum on the dense rows; verification
`captured_window_exact_greedy`) and the digest of the head's files from the verified manifest are bound into the
load agreement before either stage is read; the request agreement carries `mtpEnabled` and the terms. The depth is
fixed for a session (`--mtp-depth` on the worker, the pair driver and the reference), so a run is repeatable; the
product varies its depth with timing.

The head is a third object on the decoding rank, loaded after both stages: a layerless target whose embedding is
stage 0's module and whose final norm and output head are stage 1's (shared arrays, no copy), plus the 31 `mtp.`
tensors (27B: 238,934,237 file bytes, 238,931,348 active bytes added). Stage receipts and storage commitments do not
change. **Gap:** the SDK loader reads the head by path after the artifact was verified; the runtime re-hashes the
three files it read afterwards and requires the manifest digests. A verified read of the head is a follow-up.

## Tools

- `darkbloom-cluster-reference … --handoff in-process --mtp-depth N`: the staged single-process oracle.
- `darkbloom-cluster-pair-check run … --mode phase-split-mtp [--mtp-depth N]`.
- Worker: `--generation-mode phase_split_mtp_v1 [--mtp-depth N]`. Rank 1 logs `darkbloom-speculative-head-v1` at
  load and `mtp_*` fields (rounds, drafted, accepted per position, time in build/evaluate/settle) on its
  `darkbloom-phase-split-v1` line.

## Which families run the head

| Family (registered row) | Head in the artifact | `phase_split_mtp_v1` | Default depth (`QwenMTPTerms.standard(for:)`) | Why / what is missing |
|---|---|---|---|---|
| Qwen3.5 9B, Qwen3.8 27B | inline `mtp.`, one dense layer | **on** | 4 (the product drafter's maximum) | as above |
| Qwen3.5 35B A3B, Qwen3.6 35B A3B | inline `mtp.`, one routed-expert layer (split gate/up, as the SDK's `Qwen35MTPDecoderLayer` keys it) | **on** | 3 (measured fastest, table below) | same head type (`Qwen35InlineMTPAssistant`), same loader and decoder; the row lists the mode; Qwen3.6 keeps the head in a 5.26 GB shard shared with the trunk, which the re-hash after load reads again (bound 8 GiB) |
| Prism Bonsai 2 27B | none (`mtp_num_hidden_layers` 0) | off | none (no head) | nothing to run |
| GPT-OSS 20B, Gemma 4 26B | none | off | none (no head) | pipeline-only rows (a hand-off cannot carry a sliding layer's ring) |
| Nemotron 3.5 Lightning | inline `mtp.layers.*` (attention + MoE, 0.70 GiB), SDK `NemotronH35MTPAssistant` | off | none until built (the row lists no MTP mode, so `standard` is never read for it) | five pieces, below |
| MiMo V2.6 | three unquantised MTP layers (1.84 GiB), SDK `MiMoV26MTPAssistant` | off | none (not a Qwen resident row) | no phase split is possible on this pair; a pipeline-mode head is not built, below |

### Nemotron 3.5 Lightning: what `phase_split_mtp_v1` needs

The phase split itself runs (the decoding rank holds both `NemotronH35Model` stages). Missing, in order:

1. **SDK: captured stage entries.** The stages run through the public seam `NemotronHModel.cbv2StageResidual` /
   `cbv2StageLogits` (`libs/mlx-swift-lm/Libraries/MLXLLM/Models/NemotronH.swift`, "Layer-stage seam"). Both call
   the internal `cbv2Hidden(_:caches:recurrentState:captureMTP:inputEmbedding:appliesFinalNorm:)` without
   `captureMTP`; a verify window needs the per-position Mamba conv/SSM capture (`captureMTP: true`, as
   `NemotronH35Model.cbv2ForwardWithHiddenCaptured` in `NemotronH35MTPCapture.swift` does for the whole model).
   This is an SDK change (the pinned `libs/mlx-swift-lm`), which the Qwen work avoided.
2. **Runtime window.** `QwenLayerStageSession.openWindow` refuses `NemotronHModel` (the guard
   `!(stage.model is NemotronHModel)`); it needs a captured branch in `NemotronStageForward`
   (`Models/Nemotron/NemotronRequestGeometry.swift`) and the attention rollback the Qwen path already has.
3. **Post-norm hidden.** The Nemotron head is trained on the target's hidden **after** `norm_f`; the consumer-stage
   tap (`QwenLayerStageHiddenTap`) hands the Qwen head the pre-norm rows (the Qwen head applies the norm itself).
4. **Head loader.** `NemotronH35MTPAssistant.load(from:target:)` takes a `NemotronH35Model`; it needs a layerless
   target sharing stage 0's embedding and stage 1's `norm_f` and `lm_head` (as `QwenMTPHead` builds a layerless
   `Qwen35TextModel`), plus the manifest re-hash of the head's files.
5. **Decoder and row.** `QwenMTPDecoder` is written against `Qwen35InlineMTPAssistant`; it needs to take any
   `CBv2MTPRequestStatefulDrafter` (the SDK protocol both assistants conform to), then the mode goes into the
   Nemotron resident row (`QwenResidentModelDefinition`) and its capability then advertises the speculation.

### MiMo V2.6: why not, and what a pipeline head would need

The artifact is 172.9 GB (155.8 GiB loaded by the stages; one Mac alone needs 161.8 GiB admissible). The decoding
rank of a phase split holds every layer, so only the M3 Ultra could be it, and only while its applications leave
161.8 GiB admissible (157.1 GiB at 18:59Z and 134.7 GiB at 13:39Z on 2026-10-11): that is the single-Mac case the pair
exists to avoid, so the MiMo row lists only `pipeline_v1` and `pipeline_compact_decode_v1`
(`MiMoRegisteredSpecification.supportedGenerationModes`) and the planner never offers a phase split for it. The
hand-off would also have to carry the 39 sliding-window rings, which it cannot (as for GPT-OSS and Gemma 4). A head in
the pipeline modes needs a per-round protocol that does not exist: the head (1.84 GiB) and a copy of the
embedding on the last rank; each round the last rank drafts `k` tokens, sends them back across the cable, both ranks
run the verify window `[last, d1..dk]` through their stages (one cable crossing each way per round instead of per
token), the last rank picks the kept prefix, and both ranks commit the kept position and roll back the rest before
either runs again. MiMo's state is attention KV only, but 39 of its 48 layers are sliding-window (128) rings, so the
rollback must restore the ring rows a rejected draft overwrote. The comparator,
the relay batches and the request agreement would need the round as a new frame kind. Not built; with pipeline
decode on this pair at the cable's per-token latency, the gain would have to be measured before it is worth it.

## Evidence

Hardware runs, figures and the comparison verdicts are in the task's evidence folder `mtp2-20261010`
(`STATUS.md`); the A3B rows' runs are in `universal-20261010` (`STATUS.md`, `hw/a35`, `hw/a36`).

A3B figures (cut 20, 4,096-token prompt, 64 outputs, prefix cache off, rank 1 on the M5 Max, decode tok/s; every
speculative run passes against the plain phase split's staged reference: tokens equal, or a first difference at a
near tie):

| Row | Plain phase split | depth 2 | depth 3 | depth 4 | Verify window per round, depth 3 / depth 4 |
|---|---|---|---|---|---|
| Qwen3.5 35B A3B | 69.3 | 104.8 (26 rounds, 36/47 accepted) | **114.0** (21, 41/53) | 67.6 (21, 42/59) | 16.5 / 33.9 ms |
| Qwen3.6 35B A3B | 73.3 | 100.9 (25, 39/47) | **105.8** (19, 42/48) | 47.6 (18, 44/56) | 20.6 / 61.9 ms |

A window of five rows through the routed experts costs two to three times a window of four, which more than eats
the extra accepted draft; depth 3 is therefore the A3B rows' default (`QwenMTPTerms.standard(for:)`). With no depth
declared (the product's way), both rows then ran depth 3 on the pair: 114.4 tok/s (Qwen3.5, `divergedAtNearTie` at
10, as the plain pair) and 121.3 tok/s (Qwen3.6, tokens equal). Why five rows
cost so much more than four in the routed-expert matmul is an MLX kernel question for the optimisation phase.

At the planner's speed-informed plan (cut 12: rank 1 holds every layer but the first twelve and decodes alone with the
head; same request, depth 3, prefix cache off) the A3B rows ran 125.5 and 137.2 tok/s with serial prefill, each passing
against a Mac A staged phase-split reference at cut 12 (first difference at a near tie), and 131.6-141.6 and
142.5-157.9 tok/s with prefill `one_chunk_lookahead_v1` (timed, three requests in one session; first token 0.93-1.04 s
against 1.20-1.29 s for the M5 Max alone). These are M3 Ultra + M5 Max figures; the M5 Max has since been replaced.
