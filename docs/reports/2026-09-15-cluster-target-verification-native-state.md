# MTP target verification native-state checks

> Last updated: 2026-09-15 · commit `605651bb9`

Seven GPU checks passed on the 24 GB M4 Pro using the actual target-verification,
recurrent-state, KV-cache and cache-bank implementations. The inputs are synthetic
arrays; this result verifies local state transactions, not model generation,
bilateral MTP acceptance or a speed improvement.

## Cases and observations

The private `TargetVerificationCheck` executable calls the staged
`TargetVerificationNativeCheck` through its testing SPI. It uses actual
`CBv2TargetVerification` operations and the existing production state classes.
It does not reproduce their commit or rollback logic in a stand-in.

| Case | Checked behavior |
|---|---|
| Keep zero provisional inputs | Restore the original recurrent and KV frontier |
| Keep one provisional input | Retain the seed and remove the rejected suffix |
| Keep both provisional inputs | Commit both pending generations |
| Progressive commit, then stop | Preserve the committed seed and discard the pending draft |
| Progressive commit, then continue | Commit the already evaluated draft without reevaluation |
| Failure during forward construction | Retire request roots after an open-binding failure |
| Failure after native evaluation | Retire request roots after validation refuses the result |

The synthetic recurrent values progress from 10 to 11 to 13. Before commit,
confirmed state remains 10 while the second provisional step reads the first
step's pending state. Reconciliation checks the retained KV values, host and
device offsets, and immediate cache rebind. A subsequent ordinary step checks
that it reads the reconciled state. Progressive decisions are fabricated locally;
no peer agreement or client token publication is exercised.

The native process exits zero with the exact seven-case result, complete output
and no stderr. The supervisor observes the owned process group absent, unchanged
inputs and the same empty canonical device journal after exit. A separate SSH
collection again observes no native/owner process and an empty journal. This
standalone fixture acquires device exclusion; it does not run an owner protocol
or produce authenticated peer-release acknowledgments.

## Resources and evidence

All seven resource samples pass AC power, zero reported swap, normal pressure
and the six-GiB actual-free-memory floor. Raw free-page arithmetic reproduces the
reported values; minimum observed actual free memory is 13,058,097,152 bytes.
The enclosing remote supervisor takes 1.614606958 seconds. That interval includes
verification and cleanup and is not model throughput or TTFT.

| Artifact | SHA-256 |
|---|---|
| Native executable | `2291d742aea5b66f459fd3b86af8ed89015a027049029884b902348ec6369840` |
| Native source snapshot | `1962591fdc66bda64459988a92af51f9b6b33ca6570385b68a3104f277a2942c` |
| Supervisor package | `c83cd25899a18d60ead3902a7cd952c3f2da006b67960619f287a47707ba8f07` |
| Actual 224-byte native stdout | `1ece2f8fbef7e7eb4ff71acce7fdc8c5bc790d950ba81bd39eb9520599838021` |

Twelve returned files match their remote hashes. Raw native output, supervisor
records, resource samples and independent collection observations are retained in
`/Users/developer/DarkbloomDev/cluster-research/qwen-mtp-target-verification-physical-20260915/`.
The preceding native build and eleven Foundation contract groups passed; those
checks remain separate from this actual GPU execution.

The [delivery plan](../design/distributed-cluster-delivery.md) still requires
transactions through the real model sessions, actual target-logit verification,
bilateral commit and rollback, client/EOS stopping, and matched MTP off/on
measurements. The earlier [registered unaccepted-proposal result](2026-09-15-cluster-registered-mtp-owner-release.md)
is complementary evidence and does not close those requirements.
