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

## MiMo and Nemotron

- **Nemotron 3.5 Lightning** (inline `mtp.layers.*`, 0.70 GiB, SDK `NemotronH35MTPAssistant`) already runs the
  phase split. What is missing for `phase_split_mtp_v1`: (1) a captured-window forward through
  `NemotronStageForward` (per-position conv and SSM capture for the Mamba blocks, attention rollback; the session's
  window refuses a `NemotronHModel` today); (2) the head is trained on the **post-norm** target hidden, so the
  consumer-stage tap must hand it the normalised rows (the Qwen head applies the target norm itself); (3) the head's
  loader against a layerless NemotronH35 target sharing stage 0's embedding and stage 1's norm and head;
  (4) `QwenMTPDecoder` generalised over `CBv2MTPRequestStatefulDrafter`; (5) the mode in its resident row.
- **MiMo V2.6** (three unquantised MTP layers, 1.84 GiB) runs only the pipeline modes on this pair: the whole model
  (about 173 GB) does not fit the 128 GB Mac, so no rank can hold every layer and a phase split, with or without the
  head, is impossible. MTP for MiMo needs the pipeline-mode per-round protocol (head and an embedding copy on the
  last rank, drafts sent back each round, both ranks committing the kept position before either runs again). Not
  built.

## Evidence

Hardware runs, figures and the comparison verdicts are in the task's evidence folder `mtp2-20261010`
(`STATUS.md`).
