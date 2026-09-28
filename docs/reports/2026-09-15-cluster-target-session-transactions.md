# Qwen target transactions through real model stages

> Last updated: 2026-09-15 · commit `605651bb9`

Fifteen GPU cases pass through two real Qwen stages and the shared Session
transaction code, with zero observed logit difference from ordinary decoding.
This private fixture uses deterministic tiny weights. It establishes target
transaction behavior; registered-checkpoint and bilateral MTP generation remain
unfinished.

## Executed scope

One deterministic eight-layer, hidden-size-64, float32 source is divided into
two four-layer stages through the existing Plan mapping and stage construction.
The source contains 109 tensors and 1,280,048 bytes; the stages own 54 and 55
tensors. Fresh ordinary and speculative requests share those model weights
while retaining separate KV and recurrent state.

| Cases | Result |
|---|---|
| Keep zero, one or two staged inputs, then decode again | All three pass; named state hashes and logits agree |
| Deliberately mismatching draft, rollback and next decode | Pass |
| Progressive client stop, continue, output limit and post-seed EOS | All four pass |
| Owner refusal before staging or after two stages | Both retire the request |
| Ordinary snapshot, decode or finish during pending verification | All three refuse and retire |
| Reject an already committed prefix; seed is EOS | Both refuse and retire |

The ordinary target selects the matching test draft. The observed seed is 7
and the draft is 1, so the post-seed EOS branch is actually exercised. No MTP
assistant supplies the proposal, and no network transports a verification
round. The fixture calls the existing native stage, transaction, reconciliation
and generation-control implementations; it does not duplicate their math.

## Resources and cleanup

The run executes on the 24 GB M4 Pro. Its parent completes in 4.186 seconds
and outer SSH in 4.498 seconds; these durations are not throughput results.
The native process exits zero with complete stdout, empty stderr, actual reap
and an absent owned process group. The canonical journal remains empty, the
process inventory is clear, and all pinned inputs remain unchanged.

Independent replay of 17 retained resource observations confirms normal
pressure, AC power and zero swap. Minimum actual free memory is
11,736,547,328 bytes. No compiler, transfer or competing remote work overlaps
the run. The original six-GiB guard remains in force. The fixture emits its
runtime-derived allocation ledger; it does not claim a continuous whole-process
peak or qualify a registered model's memory requirement.

The preflight review found an inherited supervisor cleanup hazard: a reaped
leader could still authorize a destructive group signal. A separate runner
revision serializes reaping with watchdog signalling and limits reaped leaders
to an absence observation. Seven CPU groups pass, including three actual child
process cases and two ownership/race checks. The original runner was preserved
and never deployed or launched.

## Reproduction and remaining work

Private evidence under `/Users/developer/DarkbloomDev/cluster-research/`:

- `qwen-mtp-target-session-draft-20260915`: ten-file fixture overlay and
  unchanged registered resource-authority validation.
- `qwen-mtp-target-session-build-guarded-20260915`: successful 225-second
  build and argument check, preserving 3,075 source and 8,755 dependency pins.
- `qwen-mtp-target-session-supervisor-v2-20260915`: frozen deployment,
  actual returned bytes, raw resources and `root-physical-review.json`.
- `qwen-mtp-target-session-supervisor-review-20260915`: independent source
  and ownership-correction reviews.

Native SHA-256 is
`37783e2fdbe33022dd56752b6a14f25873515c3f77d1b15f9c4c28918be76960`;
actual native stdout is
`c13c7dd48710faf31bd61b5016bb6d8a7461f21e70fc3f9430a952418bda8510`.
The fixture-only constructor requires `QWEN_TARGET_TINY_FIXTURE`; it does not
add a public model profile or change the installed Provider.

Next work is committed assistant-history finalization, repeated real proposals,
authenticated two-host commit/reconciliation, and matched MTP-off/on performance
with registered weights. The [distributed delivery goal](../design/distributed-cluster-delivery.md)
remains in progress.
