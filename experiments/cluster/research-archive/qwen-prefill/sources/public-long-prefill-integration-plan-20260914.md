# Proposed public long-prefill launcher integration

2026-09-14. Source-only plan; no new native results were read for this review.

Add two opt-in commands to `experiments/cluster/run_stage_checks.py`:
`long-prefill-ranks` and `long-prefill-solo`. Both are local execution on the
machine running the launcher. The first creates two loopback ranks; the second
creates one full-model process. Keep the existing `p2p`, `ranks`, and v3
`prefill-ranks` command contracts, caps, receipts, and historical records intact.

The initial native admission remains the registered dense Qwen 9B artifact,
`long_prefill_8k_v1`, exactly 8192 prompt IDs, chunks of 512, one output, seed 7,
native precision and `cbv2-contiguous`. Generic path arguments do **not** mean
arbitrary models, prompt lengths, physical links, or resident serving are admitted.

## Minimal command surface

Reuse `--release`, `--runtime`, `--output`, `--expected-binary-sha256`,
`--model-dir`, and `--artifact-aggregate-sha256`. Require `--tokens-file` and
`--tokens-sha256`; forward the latter as native `--long-prompt-sha256`.
Native admission remains authoritative for the registered artifact/configuration.
Expose no prompt/chunk/output/teacher overrides for these commands.

Ranks additionally requires `--stage-prefill-policy serial_v1|prompt_lookahead_one_v1`
and `--stage-logits-dtype bfloat16`, with a fresh 32-hex epoch and explicit
`loopback-test`. Solo has no transport, epoch, or stage-policy flags. Pass seed 7
explicitly for both commands even though current solo admission also checks its
native default. The parent has `--parent-timeout-seconds` in 1–330; the native
and unchanged rank supervisor have a fixed 300-second bound.

No `--host`, remote run root, account name, model path, or executable hash is
embedded in public code. Remote execution can be a later separately reviewed
addition; this first promotion can be invoked locally on the intended Mac.
An optional origin file with a mandatory paired hash may be retained as opaque
provenance. It is not a tokenizer validation or a requirement for native input.

## Reuse and small additive seams

| Existing public symbol | Reuse or bounded change |
| --- | --- |
| `stage_checks.archive` | Reuse complete source/dependency snapshot, archived runtime loading, launcher inventory and before/after verification. Include every added module in the existing flat launcher inventory. |
| `runtime.bundle.snapshot`, `runtime.artifacts.verify_model` | Reuse immutable executable/resources and full local artifact checks before/after execution. Preserve the native verified-loader pin too. |
| `stage_checks.inputs.retain` | Reuse bounded regular-file read, retained bytes and explicit SHA. Add a separate long-input helper for strict 8192 integer lexemes, including rejection of `-0`, booleans and floats. Do not route through the legacy capped request builder. |
| `runtime.configuration.loopback_addresses` | Reuse two distinct local loopback endpoints for ranks. Record that sockets are closed after reservation and bind races fail without fallback. Solo does not allocate endpoints. |
| `runtime.processes.start/stop_processes`, `rank_worker.py` | Reuse native process-group ownership, cancel files and inherited environment clearing. Build exact one- or two-rank configurations without `processes.stage` or SSH helpers. |
| `stage_checks.prefill_resources.initial_free_screen`, `resources.resource_preflight` | Reuse the initial 6 GiB actual-free and post-hash 8 GiB reclaimable/disk/FD screens. Add a new-command zero-swap gate around existing raw observations; do not weaken or silently change older command gates. |

Add small `long_inputs`, `long_configuration`, `long_rank_contract` and
`long_solo_contract` modules, plus a thin `long_cli` coordinator. Port the pure
strict outer contracts from the frozen private drafts, removing their unrelated
remote staging code. Share request/profile/environment canonicalization only
where the native schemas actually agree. Keep the loaded-solo-ready and
rank-agreement-ready contracts distinct.

Use a focused new long-command supervision helper for one or two owners. The
current public `supervision.run` is fixed to two ranks/180 seconds and overwrites
the primary error if cleanup also fails. The new helper should retain the
tested stronger private behavior: drain complete output after fast exit,
preserve primary and cleanup failures separately, cancel every admitted owner
after any failure (including partial start), and reap all started supervisors.
It must not turn the older benchmark or persistent cohort into a stage service.

The current public stream reader permits 4 MiB of arbitrary stderr. A new-command
reader must instead require empty solo stderr and exactly the source-bound
Collective loopback warning once per rank, accepting only its prefix while
running. Both commands require exactly ready plus terminal, bounded 8 MiB
stdout/line per owner, duplicate-key/nonfinite rejection, and no partial EOF.

## Input, resource and evidence contract

Stage the retained raw prompt bytes in each owner's directory and set
`input_files={}` so `rank_worker` cannot JSON-reencode them. For ranks, stage
the exact hostfile bytes separately and use `environment_files` for its path.
Apply only the admitted arithmetic environment, plus rank/hostfile controls for
ranks; archive those exact arguments and source-bound environment receipt.

Run the initial actual-free screen before source/bundle snapshots or artifact
hashing; preserve its raw `vm_stat` and time. Post-hash free memory may decrease.
Then require at least 8 GiB estimated reclaimable, disk/FD headroom, pressure
0–2, and zero reported swap at every observation. Neither memory estimate is
a whole-process guarantee. The active parent deadline covers startup through
terminal completion; hashing and bounded cleanup remain separately reported.

Use the existing `stage_checks_run` envelope with new explicit mode values and
additive identity fields, plus a separate long-contract schema marker. Preserve
local supervisor PID/reaping names; do not copy private SSH-client labels.
Save raw outputs, all stage files and their byte hashes, source/bundle/config/
manifest/input pins, resource samples, and separate primary/cleanup errors.
No claimed native PID/RSS inventory is synthesized when one was not sampled.

Public outer validation checks exact profile/source/prompt/arithmetic identity,
ready-to-final stability, rank peer agreement, successful request retirement and
model release. It does not parse or claim the full action/wire/timing/numerical
oracle. In particular, final candidate row metadata is digest-only.

Independent reference comparison stays a separate optional post-run audit with
explicit reference file and source/evidence pins. Do not use the old v3 baseline
decoder for new v4 reference evidence, fabricate a baseline, or set
`baseline_audit.performed` from outer launcher success. Promotion of the frozen
independent auditors should be a separate review after their source assumptions
are made public and local-path independent.

## First reviewable milestone

Implement the two local commands and pure/fake tests first. Cover raw prompt
preservation, exact flags/environment, policy/profile/hash drift, stale v3
records, one/two-owner fast exit, partial start, deadline, peer failure, exact
stderr, memory refusal and primary-plus-cleanup failure. Block real subprocess
and socket creation in those tests. Run the existing public runtime tests once
to preserve previous modes; saved-schema compatibility checks can follow only
after root releases the completed audited evidence. No native rerun or new
performance claim follows from this source-only promotion.
