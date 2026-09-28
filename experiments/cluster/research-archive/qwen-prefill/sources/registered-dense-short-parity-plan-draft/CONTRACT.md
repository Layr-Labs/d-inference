# Closed short registered parity contract

2026-09-14. Source/design only; no forward or materialization qualification.

The first implementation increment is a separately admitted full-reference load,
returning CPU evidence after model/file retirement. It adds no CLI or forward.
Later parity reuses the existing recorded full baseline and two-stage comparison
loops in one process, with the full model released before the stage pair loads.

Both exact registered 9B and 27B profiles use their default half Plans. A fresh
UUID, three bounded raw prompt IDs, one raw teacher ID and both exact byte hashes
bind the request. Geometry is prompt 3, chunk 2, output 2, teacher count 1 and
native capacity 5. Existing recorded frames commit at 2, 3 and 4; logits are
observed at 3 and 4. Teacher forcing and arithmetic do not change.

Full-reference and sequential-stage-pair storage requirements are rebuilt
separately. Their 8K state fields are never repurposed as short state estimates.
The companion short ledger derives fresh per-array state, first-use GDN fusion,
named intermediate and CPU evidence allowances for this exact recorded request.
It is metadata, not a resource permit or complete peak bound.

For each load, let R be remaining actual allocator-bounded weights, H the largest
remaining host-copy allowance, and Q the short ledger's operational forward
reserve. Actual free must meet max(6 GiB, R + 2H + Q + 4 GiB); the unchanged current
allocator limit must cover current active/cache + R + H + Q + 2 GiB. Absolute swap
must be zero and existing pressure/freshness/counter checks must pass. Reclaimable
bytes remain diagnostic. Device maximum-buffer limits apply to each named array.
Unknown native scratch, objects and serialization are not proven bounded by Q.

Only a private owner sampling live resources can authorize actual descriptor
reads. It verifies the full checkpoint once, never bypasses legacy payload caps,
poisons failed progress and returns no model or tensor. The selected-stage
load-only entry remains unchanged. Future forward execution needs a reviewed
private continuation with fresh state and the same cleanup/error ordering.

Later numerical qualification must compare the complete same-source CPU baseline
and candidate: exact Plan and native storage identities, all 3 state frontiers,
2 full logit rows and complete 72/144 state-key coverage. No tolerance widening,
throughput, provider, long-8K, multi-device or hardware-fit claim follows from
this contract. Root owns any compiler/native/SSH execution.
