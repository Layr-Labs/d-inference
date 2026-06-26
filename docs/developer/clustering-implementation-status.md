# Clustering — Implementation Status

> Tracks what is actually built in-tree against the
> [clustering design](../architecture/clustering.md),
> [handshake design](../architecture/cluster-node-handshake.md), and
> [spike plan](clustering-spike-plan.md). **Status: early scaffold + verified
> auth/crypto layer.** Not wired into the provider loop or coordinator yet.

## What is implemented and verified

All new code lives in `provider-swift/Sources/ProviderCore/Cluster/`. The whole
`ProviderCore` target and every executable (`darkbloom`, ...) build clean with
it; the auth/crypto/partition logic is verified by 27 assertions (the swift-
testing suite `Tests/ProviderCoreTests/ClusterCryptoTests.swift`, plus a
standalone harness used where this box lacks XCTest — see "Testing notes").

| File | What it does | Status |
|------|--------------|--------|
| `ClusterRoster.swift` | Coordinator-signed member roster (nodeId, SE key, X25519 key, trust level, issued/expires). Deterministic sorted-key JSON (matches `AttestationBuilder`/Go). Signature + expiry + membership verification; `min(member trust)`. | ✅ built + tested |
| `ClusterLinkCrypto.swift` | Directional HKDF session keys; per-token ChaCha20-Poly1305 seal/open with monotonic counter nonce + structured AAD (cluster/request/layerRange/seq); in-order opening channel. | ✅ built + tested |
| `ClusterHandshake.swift` | 3-message SIGMA mutual auth over `AttestationSigner` + ephemeral `X25519KeyAgreementKeyPair`, verified against the roster; derives the shared master secret + directional session keys. | ✅ built + tested |
| `LayerPartition.swift` | Memory-weighted, largest-remainder layer→node split (exo's `allocate_layers_proportionally` in Swift), min 1 layer/node, contiguous intervals. | ✅ built + tested |
| `MLXDistributed.swift` | Swift binding over the `mlx-c` distributed C API (`init`/`is_available`/`rank`/`size`/`send`/`recv_like`/`all_gather`). The wrapper mlx-swift doesn't ship. | ✅ built (compiles against real `mlx-c`); ⏳ runtime unverified |
| `InferenceEngine.swift` | The protocol seam; `BatchScheduler` conforms unchanged (single-node default). | ✅ built |
| `ActivationCodec.swift` | Serialize a hidden-state `MLXArray` ↔ bytes (dtype+shape header) so it can be sealed and shipped; reject unsupported dtypes. | ✅ built + tested |
| `PipelineTransport.swift` | Transport seam (send/recv sealed frames) + in-process `LoopbackMailbox`/`LoopbackPipelineTransport` so the full chain runs on one machine. | ✅ built + tested |
| `PipelineStage.swift` | One rank's half of a forward step: recv+open → run owned layers → seal+send (exo's PipelineFirst/Last in Swift, with encryption woven in). | ✅ built + **verified** |
| `PipelineDecoder.swift` | Multi-token decode driver over `PipelineStage`; model hooks (embed/runLayers/sampleToken) injected. | 🟡 built; decode loop drives one step, full loop on hardware |
| `DistributedInferenceEngine.swift` | Engine wiring LayerPartition + MLXDistributed + encrypted link into `InferenceEngine`. | 🟡 scaffold; submit() drives PipelineStage, model-load slice + sampling are on-hardware |

### Forward pass — verified end-to-end on ONE machine

`PipelineForwardPassTests.swift` proves the **headline correctness property**:
running a model split across 2 ranks (over the loopback transport, with real
MLX tensors) produces a result **identical to running every layer on one rank**.
The full chain is exercised: `embed → rank-0 layers → ActivationCodec.encode →
ClusterLinkCrypto seal → transport → open → decode → rank-1 layers → logits`,
plus a tampered-frame-rejected test. This is the on-one-machine half of Spike A;
the remaining half is the same `PipelineStage` driven over the real MLX ring
across two TB-linked Macs (and loading only each rank's layer slice).

Notable build facts (de-risks Spike A): the `mlx-c` C API **does** expose the
distributed collectives, `Cmlx` is a public product of `mlx-swift`, and
`MLXArray.ctx` is publicly readable — so `MLXDistributed.swift` binds them from
Swift directly, no MLX C++ changes. `ProviderCore` now depends on `Cmlx`
(`Package.swift`).

## What the verified tests cover

- **Roster:** valid verify; reject expired / wrong-coordinator-key / tampered-body; weakest-member trust.
- **Handshake:** happy path derives matching directional keys (A.send == B.recv); reject forged responder sig; reject peer-not-in-roster; reject impersonated initiator at confirm (forged Msg3).
- **Link cipher:** 8 KB activation seal/open round-trip; monotonic multi-frame stream; reject AAD tamper (request-id swap); reject out-of-order frame; reject wrong-direction key.
- **Layer split:** 48 layers across 32GB+24GB → contiguous, sums exactly, bigger node gets more; even split; tiny-node min-1; reject more-nodes-than-layers / empty.

### Provider-loop `--cluster` wiring (config + selection, tested)

The provider can now be told it is part of a cluster, with full validation:

- `[cluster]` config section (`ClusterSettings`/`ClusterMemberSettings` in
  `Config/ProviderConfig.swift`): `enabled`, `cluster_id`, `node_id`,
  `[[cluster.members]]` (node_id + ring-ordered address), `backend`
  (`ring`/`jaccl`). Round-trips through config I/O.
- `darkbloom start --cluster` flag forces `enabled = true` given a `[cluster]`
  section, so a user can opt in without editing TOML.
- `ClusterPlan.resolve` (`Cluster/ClusterPlan.swift`): resolves this node's
  rank from its `node_id`, computes ring neighbors (prev/next), validates
  (self-in-members, ≥2 members, no duplicate ids, known backend), and emits the
  MLX ring environment (`MLX_HOSTLIST`/`MLX_RANK`/`MLX_WORLD_SIZE`, exo-style)
  plus a `layerPlan(...)` convenience over `LayerPartition`.
- `StartCommand.run()` resolves + prints the plan up-front (fail-fast on
  mis-config) and is the decision point that selects the distributed engine.

Tested by `ClusterPlanTests.swift` (17 assertions: rank/neighbor resolution,
ring env, layer-plan forwarding, every mis-config error path, config round-trip).

Example `~/.config/darkbloom/provider.toml`:

```toml
[cluster]
enabled = true
cluster_id = "home-studio"
node_id = "mac-32"            # this machine; must appear in members
backend = "ring"             # ring (TCP/Thunderbolt-IP) | jaccl (RDMA/TB5)

[[cluster.members]]          # ring order; rank = position
node_id = "mac-32"
address = "10.0.0.1"         # Thunderbolt-bridge IP preferred

[[cluster.members]]
node_id = "mac-24"
address = "10.0.0.2"
```

### Full decode path — wired and verified on ONE machine

The five pieces that connect the verified primitives to a running model across
machines are now code-complete and integrate through the real engine:

| Piece | Module | State |
|-------|--------|-------|
| #1 Sharded model seam | `PipelineModelShard` | ✅ seam + extension; the concrete impl (slice `LlamaModelInner.layers`) is the mlx-swift-lm-fork piece |
| #2 `DistributedInferenceEngine.submit` | `DistributedInferenceEngine`, `PipelineRunner` | ✅ tokenize → embed → ring pipeline → sample → detokenize → stream; **verified** |
| #3 Handshake transport | `HandshakeTransport`, `NWHandshakeChannel` | ✅ wire envelope + runner; in-memory + `NWConnection` (TCP) channels |
| #4 Provider-loop wiring | `StartCommand`, `ClusterBringup` | ✅ `--cluster` resolves plan, materializes ring env, runs neighbor handshakes; engine swap gated to hardware |
| #5 MLX ring env | `MLXRingEnvironment` | ✅ writes the `MLX_HOSTFILE` JSON (`[["ip:port"],…]`) + `MLX_RANK`, verified against MLX C++ ring.cpp |

`DistributedEngineTests` runs a full **2-rank decode end to end on one machine**:
the bring-up handshake over the in-memory channel, then a request through both
engines over the loopback runtime — the tail streams the expected greedy tokens
(verified: `["t3 ","t4 ","t5 "]`). The token-broadcast, per-hop AEAD binding
(`hop-<rank>`), and EOS/length handling are all exercised.

## What is NOT done — HARDWARE-ONLY remainder

Everything writable without the two Macs is done. What remains genuinely needs
the hardware (or is out of scope for the PoC):

1. ~~**Concrete `PipelineModelShard` for an architecture**~~ — **DONE for Llama.**
   The `mlx-swift-lm` fork (`crypt0fairy/mlx-swift-lm`, branch
   `feat/pipeline-shard`) adds `LlamaPipelineShard` (owns only layers[start..end]
   + embed on head + norm/lm_head on tail) and `LlamaPipelineShardLoader` (reads
   only this rank's safetensors keys, remaps layer indices, quantizes 4-bit).
   `LlamaShardAdapter` (ProviderCore) conforms it to `PipelineModelShard`. The
   d-inference submodule now points at the fork. Remaining for this item: run it
   on hardware (load + partial forward of real Llama-3.3-70B-4bit weights).
2. **Real `MLXDistributed` ring** — `init`/`send`/`recv_like` compile against the
   `mlx-c` API but are unrun across two machines. The loopback transport proves
   the orchestration; the ring swaps in behind the same `PipelineTransport` /
   `ClusterRuntime` seams.
3. **Thunderbolt-Bridge network setup** — `MLXRingEnvironment` writes the hostfile
   MLX wants; bringing up the TB-bridge IPs between the Macs is host config.
4. **Real Secure Enclave + socket handshake on hardware** — the handshake runs
   against `AttestationSigner` (SE in prod, software key in tests) over
   `NWHandshakeChannel` (TCP); exercising it with real SE keys between the two
   Macs is the on-hardware check.
5. **Coordinator side** (separate workstream) — cluster roster issuance, member
   registration, aggregate-capacity routing (`registry`/`protocol`/`attestation`
   unchanged). Not needed for a provider-only PoC.

## Testing notes

`swift test` cannot run in this environment: a pre-existing target
(`ProviderCoreFoundationTests`) does `import XCTest`, and the local toolchain is
Command Line Tools (no XCTest), which fails the whole test graph. The cluster
suites use swift-testing (`import Testing`) and run under a full Xcode toolchain
in CI. For local verification here, the same assertions were run via throwaway
standalone SwiftPM packages that vendor the cluster sources (MLX forced to CPU
with a fetched metallib where the engine/forward-pass is exercised):

- crypto / roster / handshake / partition: 27/27
- encrypted pipeline forward pass == monolithic: 8/8
- `--cluster` plan resolution: 17/17
- bring-up handshake + ring hostfile: 9/9
- full 2-rank `DistributedInferenceEngine` decode: 2/2 (streams `t3 t4 t5`)
