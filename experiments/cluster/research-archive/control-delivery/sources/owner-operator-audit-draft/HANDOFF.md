# Supplementary selected-owner CPU audit

Prospective source/fixture work; frozen before first owner-candidate access.
Root native invocations had already begun before the freeze. This agent read
no candidate owner sidecar, ran no native/GPU/SSH/model work, and used only
fabricated CPU metadata. Root reported a first cohort whose parent archive
check failed after an included document changed; that retained failure is not
a positive fixture and does not justify relaxing this oracle.

API:

```python
validate_one(stdout_path, full_phase_path, owner_trace_path, role)
validate_solo(stdout_path, full_phase_path, owner_trace_path)
validate_ranks([stdout0, stdout1], [phase0, phase1], [owner0, owner1])
```

CLI:

```sh
python3 owner_clock_audit.py solo STDOUT PHASE OWNER
python3 owner_clock_audit.py ranks STDOUT0 PHASE0 OWNER0 STDOUT1 PHASE1 OWNER1
```

The existing frozen numerical audit and current-run executable/source/runtime
provenance audit must qualify the identical stdout and sidecar inputs. This
helper does not inspect model payloads, compare final numerical state/logits,
verify artifact bytes or reconstruct original raw prompt input. The owner
identity itself has no artifact/config/plan digest. Request correlation comes
from the full recorded history in the unchanged base stdout, which is a small
metadata dependency rather than an inherited numerical audit.

The helper hash-pins the existing four phase-auditor modules, validates their
closed base metadata and exact41/204/235 coarse event/action contracts, and
checks the same-process main-clock ordering already defined there. It also
pins the new collector/seam/hooks plus root publication/selection plumbing.
Those source pins express the expected instrumentation contract; a separate
archive/runtime verifier must bind them to the actually tested executable.

The separate owner sidecar is bounded to64KiB, requires its exact closed
schema/flags and production-clock label, full recorded-request/profile/role
identity and fixed frame7/offset3584/width512/frontier4096. It requires exactly
eight events with exact phase order, ordinals, widths and current frontiers
(the first seven3584, the last4096), bounded UInt64 nondecreasing clocks and
exact endpoints/span. Fractional/Boolean integer fields, negative zero integer
lexemes, duplicate keys, nonfinite values/exponents and deep JSON are rejected.
Existing stdout and coarse phase bounds remain16MiB and512KiB respectively.
All input and helper/source bytes are rechecked after replay.

Every owner timestamp must lie inside the unique local frame7 interval:

| Role | Start | End |
| --- | --- | --- |
| solo | prefill.begin | prefill.committed |
| rank0 | prepare.begin | prepare.committed |
| rank1 | receive.beginConsumption | receive.consumptionAndSelectionValidated |

No rank0/rank1 timestamps are aligned, subtracted, ordered or summed. Pair mode
compares only request/history/policy/epoch/agreement/input metadata across ranks.
Each local parent interval is source-bound to the correct stage's actual call.
Tied times and inclusive parent boundaries are valid; repeated or missing events
are not. The production-clock label is an assertion from pinned native source,
not a separate clock measurement by this Python replay.

The four reported disjoint intervals are graph construction, root staging,
evaluation with its existing error/deadline check, and validation/commit. Their
sum is checked against the owner's span and its parent span. The two remainders
are expressly unclassified. They must not be called observer overhead, device
execution or communication. The helper makes no operator-GPU timing, GPU
overlap, physical transfer, speedup, representative throughput, model-release
or independently proved outer-success claim. A coherently fabricated metadata
stream remains outside what CPU-only replay can disprove.

The67 synthetic tests cover all roles and policies, unaligned rank clock
origins, ties/UInt64 edge placement, schema/role/history/frame tampering,
partial/duplicate/changed-phase/frontier events, clock reversal/overflow,
parent-interval escape, changed matching coarse/native action records,
cohort swaps, malformed JSON and bounded immutable file replay. Synthetic base
model fields are intentionally opaque placeholders and would not pass the
separate numerical oracle. The native owner candidate must not be substituted
as a fixture before this helper/test freeze.
