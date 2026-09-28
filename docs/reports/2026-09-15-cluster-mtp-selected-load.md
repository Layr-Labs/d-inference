# Qwen9B final-stage MTP selected-weight loading

> Last updated: 2026-09-15 · commit `605651bb9`

A private native fixture on the 48 GB M4 Pro loads the registered Qwen3.5 9B
final stage and its additional MTP weights, then releases the model owners and
exits cleanly. This validates selected loading and bounded process ownership.
It does not execute a forward pass or establish distributed MTP generation.

## Actual scope and inputs

The fixture is `MTPSelectedLoadCheck`, binary SHA-256
`acabd7237c8f244db1fe30878f796ec6e4496b43ad82b1df1a0505aea72ea7bf`,
from the isolated selected-load build. Its three-member bundle manifest is
`bf09d61315aadb2e7688d02fe27e9c294831a68080938d782f676ef4194a75ef`.
The build source-manifest reference is
`e6b6126fc28258843e3ba7e85ccb12857e005ecde6c8e2f49d95dc6b8334e37d`.
These artifact pins, rather than the base commit alone, identify the uncommitted
private implementation. The installed Darkbloom serving binaries are unchanged.

The model artifact is
`127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b`.
The selected target is rank 1 of the existing 4/28 layer plan; the MTP assistant
owns its extra head weights and an explicit input-embedding replica. It shares
the target's final norm and output projection. Existing target residual/inert
embedding metadata is preserved.

The fixture uses serial scheduling and disables the freed-buffer cache. Rank,
device-matrix and coordinator fields are validated admission metadata only.
No collective or network socket is initialized, and no Thunderbolt alias or
interface configuration is changed. Only the 48 GB machine loads weights.

## Loading and retirement observations

| Selected component | Tensor count | Raw tensor bytes |
|---|---:|---:|
| Existing final-stage target | 809 | 3,979,190,464 |
| MTP head | 31 | 136,881,152 |
| Explicit input-embedding replica | 3 | 572,129,280 |
| Additional MTP total | 34 | 709,010,432 |

The target's complete semantic receipt matches the retained MTP-off control,
including 8,192 inert bytes. Operational aligned-read counters are checked
separately. Additional names, shapes, dtypes, counts and byte totals match the
frozen inventory. The complete new target receipt, including its own operational
counters, is hashed for association with the MTP receipt.

Active MLX bytes rise from 0 to 4,688,206,698 during loading; process peak is
4,688,206,702 bytes. After the fixture releases its target, assistant and verified
checkpoint owners, active bytes are 3,656 and cached bytes are 0. The nonzero
residual is retained rather than described as a zero-allocation result. Weak
owner checks, stream synchronization and cache clearing precede the final
success record. Native materialization checks cover the declared MLX buffer
properties, not an independently enumerated buffer-address graph.

The supervisor accepts exactly the admission and final report, observes complete
stdout/stderr EOF and exit 0, reaps the native process, and verifies its owned
process group is fenced. The same canonical device-journal inode is empty and
unlockable after exit. No cleanup or input-recheck error occurs. Native stderr
is empty. The parent takes 5.913743 seconds and the external SSH invocation
6.044121 seconds; these are procedure durations, not throughput measurements.

All 24 parent resource observations report AC power, zero swap and pressure
level 1. Minimum actual free memory is 25.900803 GiB. Native initial/loaded/released
observations separately pass their resource and clock arithmetic. The original
six-GiB resource floor is unchanged.

## Supervision and evidence

The independently reviewed portable supervisor manifest is
`04a571bd3cf60a268c3a9b3723c9901aa3498feeb409993d8e0c9480b301e441`.
All 46 installed package files are verified before execution. A model-free check
on the remote machine confirms the complete 16-module and 21-file runtime/control
closure. Nine preparation-test methods previously passed with fabricated child
processes; those results are separate from this real native loading observation.

The native deadline is the installed Swift binary's own uptime plus 300 seconds.
The parent's 315-second lifetime includes preflight and clock sampling; its
independent group watchdog uses the remaining budget at model launch. Python
absolute monotonic values are not substituted for the Swift clock. The canonical
device exclusion is held through loading and final output, and the supervisor
never clears an unresolved journal.

Raw evidence is under
`/Users/developer/DarkbloomDev/cluster-research/qwen-mtp-selected-load-physical-20260915/physical-1/`:
`execution.json`, `root-result-review.json`, and `remote/` with the job, expected
admission, native and clock process streams, resource samples, owner records and
journal observations. Retained native stdout SHA-256 is
`80401dcb3b10c8f4fba4c138924d075f8778188feb43f26062471f38cb3f10d0`.

## Remaining qualification

The fixture performs no forward computation, request-history allocation,
accepted-prefix transaction, speculative verification or generation. Tensor
values and pairwise buffer addresses are not independently compared. It makes
no provider eligibility, distributed transfer, numerical-parity or performance
claim. The work is private and does not enable an MTP option in the installed
cluster product. Those remaining steps belong to the
[distributed execution plan](../design/distributed-cluster-execution-plan.md).
