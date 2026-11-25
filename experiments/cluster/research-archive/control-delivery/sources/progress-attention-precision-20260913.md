# Cluster goal progress — explicit numerical policy

This goal turn made implementation progress and yielded evidence that changes
the next action. The full goal remains active. Wider output arithmetic is not
a general MoE stability fix; no quality or throughput milestone was closed.

## Current implementation

- `AttentionOutputPrecision.swift`: native or Float32 attention/GDN output
  projection arithmetic, keeping Float32 through a full-TP reduction and casting
  once afterward. Stored packed weights/metadata stay unchanged. Baseline and
  FFN-only execution use the same policy on their replicated attention outputs.
  Native remains default; FFN/router/input-projection arithmetic is unchanged.
- `QwenPartitionPlan` adapter identity is now v2 and binds numerical policy.
  Native reports are schema5 and require `attentionOutputPrecision`; Python
  workload `attention_output_precision` is defaulted, forwarded and strictly
  validated for every rank. Other experiments retain their existing scope.
- Router traces are format2 with precision identity. Replay accepts format1 only
  as native, and verifies current-policy equality. Both compatibility and
  mismatched-policy rejection are exercised.
- Six isolated projection cases independently unpack W4 nibbles and compare
  BF16-rounded inputs/metadata against CPU Double dot products. Actual full TP
  uses the same wrapper with real local multiprocess all-sums.

## Results and artifacts

Final binary: `1168951b3d7cb36f0dcc7f28c9f1cad4ee4cede80818889d2b6d3da0cbb7e3cb`.
Runtime bundle manifest: `372eca9e9fc74cbdf39863e8746fcff9c90960c086ba0dde5e93c4b3d4c0ce1c`.

- `runs/attention-output-operators-20260913`: whole native operator suite passes;
  six new projection cases improve isolated post-cast error. No transport claim
  is attached to the manual CPU-oracle projection comparisons.
- `runs/attention-output-precision-20260913`: 18 ordinary same-policy paired
  executions, all verified and marked ineligible for hardware qualification.
  Includes source archive/manifest and dependency revisions bound in receipt.
  Same-policy BF16 MoE maximum row RMS (native -> wide): seed7 .245065 -> .286389;
  seed31 .196589 -> .191331; seed103 .018270 -> .157567. Seed7 wide and seed31
  native each match 7/8 baseline argmax tokens. The dense 27B head fixture improves
  slightly .012477 -> .011616. These are small random models, not real weights.
  All-F32 MoE remains within strict synthetic bounds (~7e-7 RMS).
- `runs/attention-output-routing-20260913`: wide solo/full traces exactly match
  uninstrumented logits; peer complete events/logits are identical. Format2 and
  legacy-native replay baseline controls are exact; cross-policy replays reject.
  Analyzer finds 12 set changes and 11 order changes. At row 5 after teacher 64,
  layer 2's small input difference (~.006435 RMS) changes an expert at a BF16
  probability tie. Layer 3 input RMS grows to ~.190392, final output RMS reaches
  ~.286389 and argmax changes from 473 to 480. This is another routing discontinuity, not a collective-rank
  mismatch or proof of one universal upstream cause.
- 96 repository Python tests pass. Docs check passes 280 files. No submodule
  changes. Builds and supervised GPU runs are finished.
- Repo record: `experiments/cluster/inference/ATTENTION_PRECISION.md`.

## Next work toward the actual product

Do not continue treating wider attention outputs as the MoE fix or weaken a
broad logit tolerance. Retain explicit numerical identity and the failures for
future real-checkpoint qualification. The primary dense 27B performance goal
remains separate from these synthetic MoE sensitivity cases.

The next major implementation step should make the experimental execution
usable by a serving engine: persistent rank workers, serialized request IDs and
epochs, deterministic per-request collective agreement, fresh committed cache
ownership, and bounded cohort cancellation/retirement. The current native
benchmark reloads once per process and repeats a fixed workload; it has no
general request loop or production sampling/streaming contract. A persistent
worker protocol is concrete progress toward the CBv2Engine integration seam.

`provider-cluster-integration-audit.md` maps the actual provider seams. Choose
distributed construction before `loadModelContainer`; use `any CBv2Engine`
behind `EngineV2Bridge`, preserve minted engine request IDs and OneShotRelease,
account memory on every process/host, and bind plan/numerical identity before
prefix-state reuse. No provider changes have been made. Exact CBv2 state and
cancellation contracts cannot be inferred from the ordinary model experiment.

Final read-only health check: the 48 GB peer remains offline. The 24 GB peer
answers SSH, but its Thunderbolt en1 link reports inactive. No network mutation,
provider start or sustained real-model benchmark was performed. If the 48 GB peer
returns, inspect uptime, panic records and network state first. Actual RDMA and
the two-M3-Ultra 800/1000 TPS qualification remain
unmeasured. No commit, push, deployment or catalog mutation occurred.
