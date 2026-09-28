# Distributed cluster calibration and RDMA confidentiality

> Last updated: 2026-09-15 · commit `605651bb9`

Status: **Proposed** — 2026-09-15 — user confirmed trusted members running Darkbloom, both verified and routable; peer-owner blindness is out of scope. Automatic placement, authenticated RDMA and joint member admission remain undelivered.

This addendum extends the [cluster delivery goal](distributed-cluster-delivery.md): select partitions from measurements on the actual pair and protect the RDMA data plane. It supersedes the direct-trusted-fabric-only release scope in [distributed peer ownership](distributed-peer-owner.md), while preserving RDMA as the 27B development transport. The existing [privacy model](../architecture/security/encryption.md) remains the authority for current product guarantees.

## Placement decision

Memory is a feasibility constraint; measured execution time is the optimization objective. A RAM ratio is not a compute ratio. The planner must compare eligible solo, layer-pipeline, tensor, expert and hybrid candidates, prioritizing external request-send-to-first-content latency and reporting decode and total latency separately. Unsupported or numerically unqualified candidates cannot win selection.

Calibration records the exact model/artifact/quantization, GPU and OS/runtime identity, actual free memory, pressure, thermal/power conditions, and verified link capabilities. Measure operator or stage costs at the relevant prefill chunk and decode batch sizes, sustainable memory bandwidth, RDMA latency/bandwidth, synchronization, and authenticated encryption plus staging costs. Store cache lifetime and invalidation rules for these profiles; changed artifacts, kernels, link or hardware require renewed calibration.

Check resident weights, attention/recurrent state, measured activation allowance, loader peak and temporary buffers, transport/crypto buffers, and the existing native admission policy on each rank. Simulate the actual dependency schedule with measured costs, including overlap and pipeline fill/drain. Then validate the best feasible candidates with matched end-to-end trials before selecting a default. Report uncertainty and fallback to a qualified solo path when clustering provides no benefit and the model fits.

The [9B comparison](../reports/2026-09-15-cluster-resident-solo-comparison.md) demonstrates why prefill and decode need separate decisions. Its result is a measured manually selected plan, not proof that an automatic planner or encrypted path is complete. The external [HTTP observation](../reports/2026-09-15-cluster-balanced-prefill-http.md) is a separate TTFT measurement.

## MoE candidates

For Gemma, compare whole-expert placement, expert intermediate-width tensor partitioning, and hybrids with layer placement. Preserve shared feed-forward work, attention, router normalization, tied weights and mixed quantization. Whole experts must be assigned by measured routed work and memory constraints, not only by expert count. Include skew, per-expert token batching, transport volume and synchronization in the cost model. Replicating frequently used experts is a candidate when its memory and consistency costs are justified by measurement.

The shared Gemma metadata implementation starts at `Gemma4TextMetadata`, `Gemma4TensorInventory` and `Gemma4LayerStagePlan` in `libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/`. Metadata coverage and a compiled stage adapter do not establish distributed expert execution, numerical qualification or throughput. Existing kernel eligibility must survive any selected partition shape.

## RDMA confidentiality requirement

Use authenticated encryption for inference-bearing RDMA records, including activations, token decisions and acknowledgments. Encrypt before submission to the RDMA transport and authenticate before accepting a received record into model state. Keep RDMA as the underlying transport. SSH authentication and encryption of the owner/bootstrap channel do not encrypt these payloads.

Use a supported cryptographic library and reviewed session-key establishment bound to the authenticated peer identities and fresh membership epoch. Require independent directional keys or nonce domains, unique nonces, replay rejection, bounded framing and authenticated request/plan/rank/sequence bindings. Corrupt, stale, wrong-peer and truncated records must fail before consumption. Production distributed mode must not silently downgrade to plaintext. Benchmark encryption, copies, temporary memory and synchronization with the same TTFT boundary as inference; existing plaintext measurements cannot be relabeled as encrypted results.

The minimum committed scope is confidentiality and integrity in transit. A participating Mac still computes on plaintext in its own memory; hiding a request from that Mac's owner is a separate, unresolved threat-model requirement. Packet sizes and timing also remain observable unless a separately measured padding policy addresses them. Do not describe sharding or authenticated encryption alone as blind computation.

The security implementation must update the canonical privacy/threat-model and verification documentation before release. This record changes requirements and makes no as-built encryption claim.

## Compatibility and acceptance

Discover capabilities on both members instead of promising RDMA on every Mac. Apple's [RDMA requirements](https://developer.apple.com/documentation/technotes/tn3205-low-latency-communication-with-rdma-over-thunderbolt) require supported Apple silicon hardware with Thunderbolt 5 and macOS 26.2 or newer. A separate non-RDMA fallback needs its own performance and security qualification.

Acceptance includes heterogeneous-pair calibration, representative prefill/decode and MTP comparisons, memory refusal without unsafe fallback, authenticated-encryption tamper/replay/rekey tests, and recovery without session or nonce reuse. Retain the request-send TTFT target of 10 seconds plus one millisecond per input token; do not extend it during peer startup or session rotation.
