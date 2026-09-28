# Two-Mac resident Qwen9B generation correctness

> Last updated: 2026-09-15 · commit `605651bb9`

A serial resident Qwen3.5 9B 4-bit request completed across the 24 GB and 48 GB
M4 Pro Macs and matched a separate full-model reference for all **128 selected
tokens, the complete final BF16 vocabulary row, and all 72 final-state entry
metadata/digests**. Both remote workers completed cleanup and released their
owner leases. This records one multi-token correctness check of the experimental
shared runtime; it establishes no throughput, external TTFT or serving release.

## Request and execution path

The request uses the same retained 8,192-token diagnostic input and artifact as
the [one-output physical prefill baseline](2026-09-15-cluster-rdma-prefill-baseline.md)
and [resident solo baseline](2026-09-15-cluster-resident-solo-baseline.md).
It uses B1, 512-token prefill chunks, greedy selection, 128 output tokens,
an empty stop-token set and MTP off. The 24 GB member owns layers 0–3 and the
embedding; the 48 GB member owns layers 4–31 and the final norm/output projection.
JACCL uses the selected Thunderbolt RDMA devices, with SSH owner channels for
authenticated control and bootstrap exchange.

The matched request ID is `6426b803-8b80-40ba-8944-b0f4b403a3cf`. Its artifact
aggregate is `127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b`;
the raw prompt hash is
`ee6caf0be6391e00ec41df930f0fd6351613969622cbb247b1b4bdaf69afe997`.
The separate full-model reference ran on the 48 GB Mac with the same request,
arithmetic policy and cut-4 Plan identity. It released its model and exited zero
before the distributed comparison.

The native candidate uses the shared resident facade and its benchmark-only
recording entry. `QwenResidentRuntime.execute` constructs the common agreement,
then `recordQwenLayerStageGenerationRequest` runs the existing stage sessions and
exports CPU evidence after bilateral request retirement. These symbols live in
`libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/QwenResidentRuntime.swift`
and `QwenLayerStageGenerationDriver.swift`. The private recording wrapper does
not enable diagnostic capture in the ordinary serving worker.

Sixteen prefill frames produce the first selected token; 127 decode frames
produce the remaining tokens. Both ranks report 143 completed frames and a
committed frontier of 8,319 tokens. Capacity is 8,320; the final selected output
has not been fed back as another model input.

## Numerical comparison

The CPU comparator and expected agreement were frozen before candidate sidecars
were read. The expected agreement binds the declared membership epoch, request,
registered configuration, cut-4 stage identities, both worker builds and the
arithmetic policy. Its shared storage commitment comes from the earlier verified
cut-4 load receipts and remains an opaque identity comparison.

| Compared evidence | Result |
|---|---|
| Selected output sequence | Both ranks match all 128 reference token IDs; sequence SHA-256 `892e92cbcb8da5e696ceddb2d8e9bcf57b7c4f4f16cea15d215c4d28303c8456` |
| Final vocabulary row | All 248,320 BF16 values reconstruct to exactly 496,640 matching bytes, preserving signed zero; SHA-256 `f3c4ac81749191508dd6341e69c154abd48d5497d4c20ec8d234587c2af499f8` |
| Final selection | Independent finite CPU maximum selects token 33,303 with one maximum |
| Final state coverage | Disjoint 9/63 entry partitions merge into all 72 ordered global entries; 324,108,320 logical bytes |
| Merged state fingerprint | `de3aa89e9b7c2de641676c73e2ca7cecd15f61f29371cbfc1389b7c6c8a9d126` |
| Position offsets | All eight Int32 offset hashes reconstruct from the committed frontier 8,319 |
| Token-chain identity | Both ranks report the same final chain; the chain is not independently reconstructed |

The remaining 64 state components are compared through their metadata and
digests; their underlying bytes are not exported. The reference retains compact
metadata for every selected token, but the candidate exports only the final
logit row and final frame. Per-token logit comparison and independent verification
of intermediate candidate frontiers therefore remain false. Matching the output
sequence does not substitute for those missing observations.

## Ownership, resources and timing limits

Before model execution, a separate two-Mac CPU SSH check exercised the owner
channels with a stand-in that emitted tokens `[9, 10]`. It completed with both
native-process cleanup observations and authenticated owner-lease release
acknowledgments; both remote journals were empty. That check performed no model
execution and supplied no numerical or RDMA data-transfer qualification.

The real 128-token controller then completed with `finishReason: length`, both
native cleanup observations and both authenticated lease-release acknowledgments.
Separate postflight checks found zero-byte journals and no remaining owned
processes on either member. The controller and temporary network lease exited
zero. The alias was removed with bridge membership and the management route
preserved. The returned sidecar hashes agree with the remote postflight records.

| Member | Parent samples | Minimum actual free bytes | Minimum actual free GiB |
|---|---:|---:|---:|
| Rank 0, 24 GB M4 Pro | 140 | 7,155,154,944 | 6.663757 |
| Rank 1, 48 GB M4 Pro | 143 | 12,469,649,408 | 11.613266 |

Every retained sample reports AC power, pressure level 1, zero swap and admissible
resources. Raw `vm_stat` free-page counts reproduce all reported free-byte
values. The 6 GiB actual-free floor remains unchanged. These are sampled
observations, not a continuous peak-memory proof.

The whole controller interval is **40.284513666 seconds**, including loading,
control traffic, numerical diagnostics and cleanup. It is not an engine-only
timer or a throughput benchmark, and no external streaming TTFT was measured.
No performance comparison with the earlier one-output baselines follows from
this interval. The evidence retains `physicalTransferQualified: false`; it does
not independently attest RDMA data-path counters, loaded binary/library identity
or physical hardware through the numerical checker.

## Retained evidence

Raw records remain in the private machine evidence archive. The following hashes
identify the exact inputs and results; no credentials or private host addresses
are included here. A separate CPU replay reproduced the saved comparison receipt
byte for byte and rechecked the input snapshots.

| Execution artifact | SHA-256 |
|---|---|
| Distributed recording worker | `ae0775e407e14dcd3e6162a927bcfa0112bda29bee910a3c276cbd9b33d654ef` |
| Full-reference native | `9cc39c45793131157025bfba028fcd1876e1764b109d1e15e3c39926a28757e7` |
| Full-reference stdout | `748b2d11346b3097435f83db53296c4873c3e42a261493614cbfe896883faaa3` |
| Rank 0 recording sidecar | `e8f7241a31e679adbf5ff68c008dfd913da05833eb90650bee498c67888e4b8b` |
| Rank 1 recording sidecar | `848563fff87b0709693af0d8eb338982a0ff19c1f3a74b983eb518250ff2e971` |
| Numerical comparison receipt | `3f907d1a793bf0b921c20de5b01eecfec6eca9ed086d14171f365f06a2dec444` |
| Controller stdout | `e6c59a562a24b77a0c7cd64a5b3c056e6940c1a7fd7a2bea1de2b1ecbec84415` |
| Physical execution/alias receipt | `f3e6ef3db1be35c6761fb3ae2cf5fddc6256933131c1e450cd263411c9e483b2` |
| CPU replay and resource verification | `0b5ccffaefac22751e2a89cb84f07475af087e797a77843cc980e8d28c660c75` |

The comparator passed 16 fabricated CPU tests before candidate access. Source
reviews separately covered final diagnostic capture, the full-reference loader
and the SSH controller; those reviews are not physical execution evidence.

| Prospective or source evidence | SHA-256 |
|---|---|
| Frozen comparator manifest | `98c5e7fb6dbc9bc8b249391900ce5d9f097e503b8d82eab40983cc4a656e3d9c` |
| Expected-agreement derivation manifest | `9fb65de92251ffa16459fd57ba9ac031e7b35be35cf9f8dbec8833bdecbcd2dc` |
| Final-diagnostic source review | `6060570170ec0d00b17a02ef77d207c0f08f10b74e89b2150b8ecc56a37a0521` |
| Full-reference source review | `9ceddc6a972feca9afc50649d8cff2f2272be1ad77ab5d743dac9071cab98e4e` |
| SSH controller source review | `dd11193dc503ba624b83a1ed97b5342a2fc5b5594015c42f5fac5130f3951ff3` |
| Physical CPU SSH summary | `842ac7530c54482f3a93b94ff467857981b86b37fc817040db762f60f685ef04` |

The [execution plan](../design/distributed-cluster-execution-plan.md) still needs
actual failure/recovery coverage, normal provider startup and external streaming
measurements. This single diagnostic request does not establish representative
quality or sustained service. Lookahead performance, Qwen27B, Gemma26B, active MTP
and M3 Ultra projections remain separate work; this report does not close their
acceptance criteria or claim a generic distributed-model release.
