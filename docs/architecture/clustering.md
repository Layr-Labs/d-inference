# Multi-Device Clustering — Design Proposal

> **Status: PROPOSAL / not implemented.** This document describes a possible
> future capability: serving a single model that is too large for any one Mac by
> stitching it across a cluster of co-located Apple Silicon machines, inspired by
> [exo](https://github.com/exo-explore/exo). Nothing here is built. It exists to
> capture the design, the privacy analysis, and the integration map so the
> feasibility spikes (see [the spike plan](../developer/clustering-spike-plan.md))
> have a concrete target.

## 1. Problem

Darkbloom's hard ceiling today: **a model only runs if its weights fit in one
Mac's unified memory.** There is no model sharding — the coordinator routes each
request to a Mac large enough to hold the model
(`ModelLoadAdmission.canLoad`, `provider-swift/Sources/ProviderCore/Inference/ModelLoadAdmission.swift:62-89`).
The landing page's "MoE up to 239B params" is therefore only honest for the
rare 512 GB Mac Studio. Aggregating RAM across machines would make frontier-scale
models real on commodity hardware.

## 2. What exo does (verified against source, `master` branch)

exo's `master` is a ground-up rewrite (Rust Zenoh discovery/control + Python
master/worker + Swift menubar). The relevant mechanisms:

| Mechanism | Where | Note |
|-----------|-------|------|
| **Placement** = filter-and-rank over topology cycles | `src/exo/master/placement.py:106` | Memory is the **only** hard constraint (`filter_cycles_by_memory`, `placement_utils.py:21`). No real latency/bandwidth optimizer (`TODO: profile actual speeds`). |
| **Layer split** = memory-weighted largest-remainder | `placement_utils.py:47` | Layers allocated ∝ `ram_available / total_ram`, min 1/node. |
| **Pipeline parallelism** | `worker/engines/mlx/auto_parallel.py:132/158` | Each node owns a contiguous layer interval. Boundary data crossing the wire is **only the hidden-state activation tensor** via a ring `mx.distributed.send`/`recv_like`. **KV cache stays local to each rank.** Final token broadcast with `all_gather`. |
| **Tensor parallelism** | `auto_parallel.py:456+` | Splits each layer; per-layer `all_sum`/`all_gather` collectives. Chatty — needs RDMA. Collectives live in MLX C++. |
| **Transport** | `worker/engines/mlx/utils_mlx.py:90-143` | MLX-distributed `ring` (TCP, Thunderbolt-IP prioritized) or `jaccl` (RDMA over Thunderbolt 5). Configured purely via host-list JSON + env vars (`MLX_HOSTFILE`, `MLX_RANK`, `MLX_IBV_DEVICES`, `MLX_JACCL_COORDINATOR`). |
| **Discovery** | `rust/networking/src/discovery.rs:18` | Custom IPv6 UDP multicast + Zenoh control plane. |
| **Trust** | — | **None.** Zenoh = plain TCP no TLS/auth; ring/jaccl tensor traffic plaintext; `TRUST_REMOTE_CODE` set. Assumes one owner, physically TB-cabled, trusted LAN. |

**Two facts dominate the rest of this design:**

1. **Pipeline mode ships only the activation tensor** (~`hidden_size × 2` bytes
   per token, ≈8 KB), not the KV cache. That is a small, well-defined payload we
   can encrypt cheaply.
2. **exo's stitching logic is Python-bound** (written against MLX's *Python* API +
   mlx-lm Python model classes). The transport *config* is language-agnostic JSON +
   env vars, and the collectives themselves live in **MLX C++** — which is exposed
   through the **`mlx-c` C API** (`mlx_distributed_send/recv_like/all_gather/all_sum`,
   `distributed_group.h`). `mlx-swift` does **not** wrap them yet.

## 3. The three gating questions

### ① Privacy — the gate

exo assumes a *trusted* co-located cluster; Darkbloom assumes *operator-blind*.
**Physical co-location is NOT sufficient for Darkbloom**, because in a cluster the
operator owns *every* Mac and could tap the inter-node link. Hidden-state
activations are approximately invertible to prompt text, so plaintext activation
transfer breaks the brand promise outright.

**This is securable precisely because pipeline mode ships only the activation
tensor.** Wrap the ring `send`/`recv` in pairwise **NaCl Box** channels keyed by
each node's **Secure Enclave** X25519 key, established after mutual attestation,
sealed/opened *inside the hardened process*. The operator with root still cannot
read: the key never leaves the SE and Hardened Runtime blocks memory inspection —
the same guarantee Darkbloom already makes per-node, extended to the link.
Per-token NaCl sealing of an 8 KB tensor is microseconds. **Tensor parallelism is
much harder to secure** (collectives buried in MLX C++), so the secure design is
**pipeline-only**.

### ② Engine

Darkbloom is Swift `mlx-swift-lm`, in-process; exo's stitching is Python. You
**cannot** import exo.

- **Path (a): embed exo's Python worker as a subprocess.** Rejected — reintroduces
  the IPC surface Darkbloom deliberately engineered out (`README` "no subprocess,
  no local server, no IPC to tap"), and exo's transport is plaintext, failing ①.
- **Path (b): reimplement pipeline parallelism in Swift** against `mlx-swift`,
  reusing exo's *design* (memory-weighted layer split, ring send/recv, host-list +
  env config) but not its code. More work, but the **only** path that preserves
  the privacy guarantee — and since we own the send/recv wrapper, it is exactly
  where the attested encryption from ① is injected. **The two requirements point
  to the same architecture.**

  **Feasibility (verified):** the primitives Path (b) needs already exist in MLX
  C++ and in the `mlx-c` C API (`mlx_distributed_send`, `recv_like`, `all_gather`,
  `all_sum`, `mlx_distributed_init`, `mlx_distributed_group`). They are simply
  **unwrapped in `mlx-swift`**. So Spike A is *"write a Swift binding over an
  existing C API"*, **not** *"modify MLX C++"* — a materially smaller and safer
  scope.

### ③ Topology

exo's good numbers need TB5 RDMA full-mesh. Darkbloom providers are WAN Macs on
outbound WebSockets; per-token pipeline hops over WAN would tank TPS. Therefore
clustering is a **new provider tier**, not arbitrary fleet stitching.

## 4. Proposed architecture: the "cluster provider" tier

A single operator's **co-located, Thunderbolt-cabled, individually-attested** Mac
cluster registers as **one logical large-capacity provider**. The coordinator sees
one endpoint advertising aggregate RAM; existing routing/billing/capacity logic
largely carries over. Internally the cluster runs **Swift-native pipeline
parallelism with attested NaCl-encrypted activation links.**

```
        Consumer (OpenAI/Anthropic SDK)
                  │  TLS (+ optional NaCl Box)
                  ▼
   Coordinator (Go, Confidential VM)
     · sees ONE provider = the cluster
     · seals request to the cluster HEAD node's attested X25519 key
                  │  WebSocket (outbound from head node)
                  ▼
   ┌─────────────── Cluster (one operator, TB-cabled) ───────────────┐
   │  HEAD node (rank 0)          rank 1            rank 2            │
   │  · decrypts request          · layers L1       · layers L2..    │
   │  · layers L0                 ·                  ·                │
   │      │ activation tensor      │                 │               │
   │      └─── NaCl Box (SE-keyed) ┴── NaCl Box ──────┘  (ring)       │
   │  Every node: Secure Enclave attested, Hardened Runtime,         │
   │  PT_DENY_ATTACH. Inter-node link encrypted to attested keys.    │
   └──────────────────────────────────────────────────────────────────┘
```

Trust rule: **cluster trust = min(member trust)** — one un-attested member taints
the whole cluster, and it is not admitted for private traffic.

## 5. Integration map (verified file:line touchpoints)

The codebase already has the right seams. Each row is single-machine today; the
"change" column is the cluster extension.

| Area | Current (file:line) | Single-machine assumption | Change |
|------|---------------------|---------------------------|--------|
| **Load gate** | `ModelLoadAdmission.swift:42-89` (`freeForLoadGb`, `canLoad`) | `totalBytes`/free memory are local | Aggregate across members; gate on cluster-sum free memory. |
| **KV budget** | `Inference/GlobalKVCacheBudget.swift` | `ProcessInfo.physicalMemory` local | Per-node budgets stay local (KV is local in pipeline mode) — no change to the math, only to where it is reported. |
| **Capacity report** | `BackendCapacity`/slots, `Protocol/Types.swift` | 1 slot ≈ 1 machine | N member slots aggregated into one logical `BackendCapacity`. |
| **Engine binding** | `BatchScheduler` owns one `BatchedEngine` (single field); `InferenceFoundation/LocalMLXModelFoundation.swift` | Hardcoded in-process MLX | Introduce an `InferenceEngine` protocol; add a `DistributedInferenceEngine` conformer. `BatchedEngine` already satisfies it with a thin wrapper. |
| **Protocol** | `provider-swift/.../Protocol/Messages.swift` ↔ `coordinator/protocol/messages.go` | One register / one heartbeat / one Hardware | Add cluster bootstrap + per-member heartbeat messages. **Must stay mirrored** (repo's #1 sync rule). |
| **Routing** | `coordinator/registry/registry.go` (`Provider` 1:1 with a socket, `freeMemoryAdmits`, `snapshotProviderLocked`); `scheduler.go` | Provider == one machine | Cluster abstraction: aggregate capacity for admission, pick a member internally, fail over within the cluster. |
| **Attestation** | `provider-swift/.../Security/AttestationBuilder.swift`, `SecureEnclaveIdentity.swift`; `coordinator/attestation/`; `GET /v1/providers/attestation` | One SE key per provider | Per-member chain; verify each independently; cluster trust = min(member). |
| **E2E decryption** | `ProviderLoop.swift` decrypt path, `ProviderLoop+InboundDecode.swift`, `Crypto/X25519ChaChaPoly.swift`, `Crypto/NodeKeyPair.swift` | Plaintext stays in one process | Head node decrypts request; activation tensors crossing nodes are re-sealed to each member's attested SE key (new pairwise channel). |

## 6. Scope guardrails

- **Pipeline parallelism only** at first. Tensor parallelism is a later,
  separately-justified step (harder to secure, needs RDMA).
- **Co-located clusters only.** No WAN stitching. Enforced by an explicit
  cluster trust-model field, not by hope.
- **Surgical, seam-based changes.** Reuse existing routing/billing/capacity; add a
  cluster layer, do not rewrite the provider model.

## 7. Next step

Two independent de-risking spikes — see
[`docs/developer/clustering-spike-plan.md`](../developer/clustering-spike-plan.md).
Coordinator/protocol work begins only if both pass.
