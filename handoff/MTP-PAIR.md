# MTP on the pair: `phase_split_mtp_v1`

The registered Qwen3.5 9B and Qwen3.8 27B ship the product's inline speculative (MTP) head. On the pair the
decoding rank of a phase split, which holds every layer after the hand-off, now runs that head exactly as the
single-Mac product does: the product's drafter (`Qwen35InlineMTPAssistant`) drafts, both stages verify the window
`[last token, d1 … dk]` in one captured forward, the longest prefix of drafts equal to the target's own greedy token
is kept plus the target's token at the first mismatch, both stages commit at the kept position and roll the rest
back. Nothing new crosses the cable: rank 0 hands over what it always handed over and sees the same relay batches.
No SDK change.

## On by default, and the off switch

- **Capability.** A model whose artifact ships a head lists `phase_split_mtp_v1` in its resident row (9B, 27B);
  its capability record then advertises `speculation: "decodingRankHeadExactGreedy"` (other models keep `"off"`).
- **Placement.** The planner gives the speculative phase split the same holdings and time as the plain one and
  prefers it (`ClusterPlacementPlanner.ordered`), so `darkbloom cluster plan` / setup writes `phase_split_mtp_v1`
  into the saved setup whenever both workers advertise it. `darkbloom start --local --distributed` then starts both
  workers with `--generation-mode phase_split_mtp_v1`.
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

The mode, `QwenMTPTerms` (schema, `depth` 1…4, default 4 = the product drafter's maximum, verification
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

| Family (registered row) | Head in the artifact | `phase_split_mtp_v1` | Why / what is missing |
|---|---|---|---|
| Qwen3.5 9B, Qwen3.8 27B | inline `mtp.`, one dense layer | **on** | as above |
| Qwen3.5 35B A3B, Qwen3.6 35B A3B | inline `mtp.`, one routed-expert layer (split gate/up, as the SDK's `Qwen35MTPDecoderLayer` keys it) | **on** | same head type (`Qwen35InlineMTPAssistant`), same loader and decoder; the row lists the mode |
| Prism Bonsai 2 27B | none (`mtp_num_hidden_layers` 0) | off | nothing to run |
| GPT-OSS 20B, Gemma 4 26B | none | off | pipeline-only rows (a hand-off cannot carry a sliding layer's ring) |
| Nemotron 3.5 Lightning | inline `mtp.layers.*` (attention + MoE, 0.70 GiB), SDK `NemotronH35MTPAssistant` | off | five pieces, below |
| MiMo V2.6 | three unquantised MTP layers (1.84 GiB), SDK `MiMoV26MTPAssistant` | off | no phase split is possible on this pair; a pipeline-mode head is not built, below |

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

The whole model is about 173 GB; the 128 GB Mac cannot hold every layer, so no rank can be the decoding rank of a
phase split, with or without the head (the planner never offers `phase_split_v1` for MiMo on this pair). A head in
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

First A3B figures (Qwen3.5 35B A3B, cut 20, 4,096-token prompt, 64 outputs, prefix cache off, rank 1 on the M5 Max):
the speculative pair against the staged speculative reference `divergedAtNearTie` (index 36), and against the plain
phase split's reference at the same index as the plain pair (10): the pass rule. Decode 67.6 tok/s against 69.3 for
the plain phase split: 21 rounds, 59 drafts, 42 accepted (3 tokens a round), but a five-token verify window through
the routed experts costs about 34 ms against 14.5 ms for one token, so depth 4 gains nothing on this model here.
