# Clustering Feasibility — Spike Plan

> **Status: PROPOSAL.** Two throwaway prototypes that de-risk the
> [clustering design](../architecture/clustering.md) **before** any
> coordinator/protocol work. They are independent and run in parallel. Spike code
> is disposable — it proves a number, it does not ship. Coordinator-side work
> begins only if **both** spikes pass their gate.

## Why two spikes

The design rests on two unproven claims:

- **A — Engine:** Swift-native pipeline parallelism over `mlx-swift` is possible
  and fast enough across 2 TB-linked Macs *without modifying MLX C++*.
- **B — Privacy (the gate):** the inter-node activation link can be encrypted to
  per-node Secure-Enclave keys with negligible overhead.

If A fails, the whole approach is Python-subprocess-only (which fails the privacy
model — see design §3②). If B fails, clustering contradicts Darkbloom's reason to
exist. Neither depends on the other, so run them concurrently.

---

## Spike A — Swift pipeline parallelism

**Goal:** Run one model split across **2 TB-connected Macs** from Swift, and
measure tokens/sec and time-to-first-token vs. the same model on a single Mac.

**Verified starting point (do not re-investigate):**
- MLX **C++ core** has distributed (`ring/`, `jaccl/`, `send`, `recv_like`,
  `all_gather`, `all_sum`) and the **`mlx-c` C API wraps it**
  (`mlx/c/distributed.h`, `distributed_group.h`:
  `mlx_distributed_init`, `mlx_distributed_send`, `mlx_distributed_recv_like`,
  `mlx_distributed_all_gather`, `mlx_distributed_all_sum`, `mlx_distributed_group`).
- **`mlx-swift` does NOT wrap these.** `Source/MLX` has no `Distributed.swift`.
- ⇒ This spike is **"write a thin Swift binding over an existing C API"**, not
  "modify MLX C++."

**Steps (sequenced):**

1. **Bind the C API.** Add a `Distributed` Swift target in a *fork/branch* of
   `libs/mlx-swift` exposing `init(backend:)`, `send`, `recvLike`, `allGather`,
   `allSum`, and a `Group` handle over `mlx-c`'s `distributed.h`. Smallest surface
   that covers the pipeline path. *Gate 1: a 2-process ring on one Mac can
   `send`/`recvLike` an `MLXArray` round-trip correctly.*

2. **Ring transport across 2 Macs.** Reproduce exo's config approach: write a host
   list, set `MLX_HOSTFILE`/`MLX_RANK`, `init(backend: .ring)`. Prioritize the
   Thunderbolt-bridge IP. *Gate 2: `allSum` of a known vector across 2 Macs returns
   the correct sum.*

3. **Pipeline-wrap one model.** Pick a model that does **not** fit comfortably on
   the smaller Mac alone (forces the split to matter). Reimplement exo's
   `PipelineFirstLayer`/`PipelineLastLayer` pattern in Swift on top of
   `mlx-swift-lm`'s model: rank owns a contiguous layer interval; `recvLike` the
   activation before its first layer, `send` after its last; `allGather` the final
   token. Layer split = memory-weighted (exo's `allocate_layers_proportionally`).
   Keep KV cache local per rank.

4. **Measure.** Single-Mac baseline vs. 2-Mac pipeline: TTFT, decode TPS, and
   correctness (identical greedy output, temperature 0) for a fixed prompt set.

**Pass gate:**
- ✅ Correct, identical greedy output across the split.
- ✅ A model that does **not** fit on one of the Macs runs on the pair.
- ✅ Decode TPS is interactive (target ≥ ~10 tok/s over Thunderbolt for the test
  model; record the actual number regardless).

**Risks / watch-items:**
- `mlx-c` API drift vs. the pinned MLX in `libs/mlx-swift`'s `Cmlx` submodule —
  check the submodule's MLX commit exposes the distributed symbols.
- Thunderbolt-IP bridge setup (exo does this in a shell/Swift helper; replicate
  minimally — no RDMA needed for the ring/TCP backend).
- mlx-swift-lm model classes may not expose per-layer hooks cleanly; may need a
  local patch to iterate layers. Acceptable for a spike.

**Deliverable:** a markdown result note with the TPS/TTFT table and a
go/no-go on Path (b).

---

## Spike B — Attested encrypted activation link

**Goal:** Prove that sealing each activation tensor to a peer's
**Secure-Enclave-bound** X25519 key, on the `send`/`recv` path, costs negligible
throughput — so the privacy gate (design §3①) is met.

**Verified starting point:**
- Darkbloom already has the crypto + SE primitives:
  `provider-swift/.../Crypto/X25519ChaChaPoly.swift`,
  `Crypto/NodeKeyPair.swift`, `Security/SecureEnclaveIdentity.swift`,
  `Security/PersistentEnclaveKey+ECIES.swift`, and the per-request NaCl Box path in
  `ProviderLoop.swift`. The pattern (seal/open inside the hardened process,
  key in SE) is the same one to extend to the link.
- Activation payload per token ≈ `hidden_size × dtype_bytes` (≈ 8 KB for a
  4096-hidden fp16 model) — small.

**Steps:**

1. **Pairwise channel handshake.** Two nodes mutually exchange + verify each
   other's existing **attestation blob** (reuse `AttestationBuilder`), then
   establish a NaCl Box channel keyed by their SE X25519 keys. *Gate: node A
   refuses to send to node B if B's attestation fails.*

2. **Wrap the boundary.** In the Spike-A send/recv path (or a standalone
   microbenchmark mirroring it), `seal()` the activation tensor bytes before
   `send`, `open()` after `recv`. Seal/open must execute **inside the hardened
   process**; the symmetric/ephemeral key never leaves it.

3. **Measure overhead.** Throughput and per-token latency: plaintext link vs.
   sealed link, across the activation sizes for the Spike-A test model. Sweep a
   couple of `hidden_size` values to confirm it scales with payload, not with a
   fixed tax.

4. **Adversarial check.** Confirm a passive tap on the inter-node link (the
   operator's threat) sees only ciphertext — capture the wire bytes and verify no
   plaintext activation is recoverable.

**Pass gate:**
- ✅ Sealing overhead is negligible (target < ~5% decode-TPS hit; record actual).
- ✅ Tapped link bytes are ciphertext only.
- ✅ Channel refuses unattested peers.

**Risks / watch-items:**
- SE signing/ECDH per-handshake is fine (once per channel), but ensure per-token
  work uses a cached symmetric key, not a fresh SE operation — SE ops are slow.
- Verify the seal/open stays inside Hardened Runtime memory protections (don't
  spill plaintext to a buffer a debugger could read — though `PT_DENY_ATTACH`
  already covers the live process).

**Deliverable:** a result note with the overhead table, the wire-capture
evidence, and a go/no-go on the privacy gate.

---

## Decision

| Spike A | Spike B | Outcome |
|---------|---------|---------|
| Pass | Pass | Proceed to coordinator/protocol work per design §5. |
| Pass | Fail | Stop — clustering would break the operator-blind guarantee. Revisit only with a different privacy mechanism. |
| Fail | — | Stop — no secure engine path; Python subprocess is rejected. |

Record both result notes under `docs/developer/` and link them here when done.
