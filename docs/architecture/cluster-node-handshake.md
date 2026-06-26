# Cluster Node-to-Node Handshake — Design Proposal

> **Status: PROPOSAL / not implemented.** Companion to
> [`clustering.md`](clustering.md). It specifies how two cluster member Macs
> mutually authenticate and establish an encrypted channel for the inter-node
> activation link, **reusing Darkbloom's existing crypto and attestation
> primitives** rather than inventing new ones. This is the detailed design behind
> Spike B in the [spike plan](../developer/clustering-spike-plan.md).

## 1. Why a handshake is needed at all

In pipeline parallelism the boundary data crossing between Macs is the
hidden-state **activation tensor** (KV cache stays local — see `clustering.md` §2).
Activations are approximately invertible to prompt text, so they are as sensitive
as the prompt. The cluster operator owns *every* Mac and the Thunderbolt cable
between them. Darkbloom's existing per-node defenses (Hardened Runtime,
`PT_DENY_ATTACH`, SIP/Secure Boot, key-in-process-memory) already stop the
operator from reading a *single* node's memory. They do **not** cover a **physical
tap on the inter-node bus** — which is strictly easier than the de-soldering
attack Darkbloom already declares its residual threat. So the link must be
**encrypted between two mutually-attested hardened processes**, with key material
that never leaves either process.

## 2. Grounding: primitives that already exist (verified)

The handshake composes existing, audited code — nothing cryptographically new:

| Primitive | File | Role in handshake |
|-----------|------|-------------------|
| **SE P-256 signing**, private key never leaves Enclave, fresh per process | `Security/SecureEnclaveIdentity.swift` (`sign`, static `verify(signature:for:publicKey:)`) | Proves a peer controls an attested hardware identity. |
| **X25519 + ChaCha20-Poly1305 sealed messages** with explicit `senderPublicKey`, HKDF-SHA256 key derivation, and **AAD support** | `Crypto/X25519ChaChaPoly.swift` | Session key agreement + framing. AAD binds the transcript. |
| **NaCl box** (X25519/XSalsa20-Poly1305), ephemeral keypair gen | `Crypto/NodeKeyPair.swift` (`generate`, `encrypt`/`decrypt`) | Ephemeral DH keys for forward secrecy; data-plane sealing. |
| **Signed attestation blob** binding an X25519 key to the SE identity, deterministic sorted-key JSON reproduced in Go | `Security/AttestationBuilder.swift`; `coordinator/attestation/attestation.go` | The exact "this encryption key belongs to this attested identity" pattern we reuse pairwise. |
| **The binding is already enforced** coordinator-side: `result.EncryptionPublicKey == regMsg.PublicKey` | `coordinator/api/provider.go:2207-2229` | Precedent: SE-signed attestation vouches for an X25519 key. |

**The single most important precedent:** Darkbloom *already* proves "this ephemeral
X25519 key is controlled by this attested Secure-Enclave identity" — the SE signs an
attestation blob whose `encryptionPublicKey` field is the X25519 key, and the
coordinator rejects a mismatch. The node-to-node handshake is **the same trick
applied pairwise** instead of node↔coordinator.

## 3. The finding that unblocks the transport: RDMA is already trust-compatible

A naïve reading says clustering needs Thunderbolt/RDMA, but the attestation blob
reports `rdmaDisabled` and the 5-minute challenge re-checks it — implying
RDMA-enabled would fail trust. **It does not.** The coordinator's challenge handler
(`coordinator/api/provider.go:1155-1171`) explicitly accepts RDMA-enabled nodes:

> *"Reporting remains mandatory so routing and trust policy can distinguish
> single-node providers from RDMA-aware cluster runtimes. RDMA enablement is not
> itself a challenge failure: Apple Silicon Thunderbolt RDMA is IOMMU-scoped to
> registered buffers, so the security boundary is the signed runtime's
> buffer-registration discipline, not a hypervisor flag."*

So the trust policy was **already designed with RDMA-aware cluster runtimes in
mind.** The handshake's job is the layer above that the comment defers to: the
"signed runtime's buffer-registration discipline" — i.e. *encrypt the activation
before it enters a registered RDMA buffer, decrypt after DMA on the peer.*

## 4. Trust topology: coordinator-anchored roster + peer-to-peer session

Full MDA certificate-chain verification (Apple Enterprise Root CA + MicroMDM
cross-check) is heavy and centralized; replicating it on every Mac would weaken
and bloat the model. So the trust anchor stays the coordinator, and only the cheap
per-session step is peer-to-peer:

1. **Each member attests to the coordinator** (members register, or the head relays
   each member's `SignedAttestation`). The coordinator runs its existing full
   `Verify` + MDA chain + challenge loop and assigns each a trust level.
2. **Coordinator computes `cluster trust = min(member trust)`** and, if every member
   clears the floor, issues a **signed cluster roster**:
   ```
   ClusterRoster {
     clusterId
     members: [{ nodeId, sePublicKey (P-256), x25519PublicKey, trustLevel }]
     issuedAt, expiresAt
   }                          // signed by the coordinator key
   ```
3. **Members run pairwise handshakes** (below), using the roster to know which peer
   SE keys are authorized. The coordinator is **not** in the per-message path.
4. **Revocation rides the existing challenge loop.** If any member fails its
   5-minute challenge (SIP flipped, disconnect, posture change), the coordinator
   drops it and pushes a new roster; the head tears the cluster instance down —
   a cluster with a tainted member must not serve. Roster `expiresAt` forces
   periodic re-issue so a stale roster can't outlive trust.

## 5. The pairwise handshake (3 messages, mutual-auth ECDH)

For each ring neighbor pair, the lower-`nodeId` node is **initiator (A)**, the
other is **responder (B)**. Each generates a **fresh ephemeral X25519 keypair**
for this session (`NodeKeyPair.generate()`) — forward secrecy; the long-term SE
key only *signs*, it never does ECDH (SE P-256 is signing-only).

```
transcript1 = clusterId ‖ A.nodeId ‖ eA.pub ‖ nonceA ‖ B.nodeId ‖ eB.pub ‖ nonceB

A → B   Msg1  { clusterId, A.nodeId, eA.pub, nonceA }
B → A   Msg2  { B.nodeId, eB.pub, nonceB, sigB }     sigB = SE_B.sign(transcript1)
A → B   Msg3  { sigA }                               sigA = SE_A.sign(transcript1 ‖ sigB)
```

Each side verifies, before deriving any key:
- peer's `sePublicKey` ∈ roster, roster signed by coordinator and not expired;
- peer's signature valid under that roster SE key → proves the peer **controls the
  attested SE identity *and* chose this ephemeral key** (the §2 binding, pairwise);
- `nonce` is fresh (anti-replay).

**Session key** (derived once, then cached — never per token):
```
K = HKDF-SHA256( ikm  = X25519(eA, eB),
                 salt = nonceA ‖ nonceB,
                 info = "darkbloom-cluster-link-v1" ‖ clusterId ‖ sort(A.nodeId,B.nodeId) )
```
`info` channel-binds `K` to this cluster and this identity pair, so a recorded
handshake can't be re-pointed at a different peer. Two directional sub-keys
`K_A→B`, `K_B→A` are split from `K` so each direction has an independent nonce
counter.

This is a standard SIGMA-style "sign the transcript" mutual-auth pattern, built
entirely from `SecureEnclaveIdentity.sign`, `NodeKeyPair`, and
`X25519ChaChaPoly`'s HKDF — no new crypto.

## 6. Data plane: per-token sealing

After the handshake, each directed activation send is sealed with **ChaCha20-Poly1305
under the cached `K_dir` and a monotonic 96-bit counter nonce** — *not* a fresh
ECDH per message (that would cost a key agreement per token; see Spike B perf gate):

```
seal:  ct = ChaChaPoly.seal(activationBytes, key: K_dir, nonce: counter++,
                            authenticating: clusterId ‖ requestId ‖ layerRange ‖ seq)
open:  pt = ChaChaPoly.open(ct,               key: K_dir, nonce,
                            authenticating: <same AAD>)
```
- **AAD** carries `requestId`, the `layerRange`, and a sequence number, so a sealed
  activation can't be replayed into a different request, layer boundary, or order.
- **Nonce discipline:** counter is strictly monotonic per direction; never reuse
  `(K_dir, nonce)`. Re-handshake (new ephemeral keys) on process restart or roster
  re-issue; 2⁹⁶ never wraps in practice.
- **Payload is tiny:** ≈ `hidden_size × dtype_bytes` ≈ 8 KB/token, so the AEAD tax
  is microseconds — the quantitative claim Spike B must confirm (< ~5% decode-TPS hit).
- **RDMA path:** seal into the registered buffer, DMA the ciphertext, open after
  receive. This is exactly the "buffer-registration discipline" the coordinator's
  RDMA policy (§3) defers to. Ring/TCP first; RDMA zero-copy-vs-encrypt trade-off is
  a later optimization.

## 7. What does NOT change

- **The request-decryption boundary is identical to today.** The coordinator seals
  the request to the **head node's** attested X25519 key (the existing per-request
  NaCl Box path, `ProviderLoop` decrypt). The head is the single prompt-decryption
  endpoint, exactly as a lone provider is now. Only *activations* — never the prompt
  plaintext — cross to other nodes, and those are sealed per §6.
- **Consumer-facing verification.** `GET /v1/providers/attestation` and the
  `X-Provider-*` headers expand to expose the **whole roster**, so a consumer can
  confirm every node that touched their data is attested; surfaced trust = min.

## 8. Threat model summary

| Adversary capability | Defense |
|----------------------|---------|
| Tap the Thunderbolt cable / inter-node bus | Activations are AEAD-sealed under a key only in two hardened processes' memory. |
| Run a modified node to MITM the link | A MITM is an unattested binary → fails roster membership + transcript signature (APNs code-identity + binary hash already gate this). |
| Replay a recorded handshake or activation | Handshake nonces; per-direction counter nonce + `requestId`/`seq` AAD. |
| Compromise a key later to decrypt past traffic | Ephemeral-per-session X25519 → forward secrecy. |
| Smuggle an untrusted Mac into the cluster | `cluster trust = min(member)`; coordinator roster + 5-min challenge revocation. |
| Read a node's in-memory activation/key directly | Pre-existing per-node defenses (HR, `PT_DENY_ATTACH`, SIP/Secure Boot). |
| De-solder and probe memory chips | Out of scope — same residual threat Darkbloom already accepts (and PCC accepts). |

## 9. Open questions for the spike

1. **Member registration shape** — do members each open a WebSocket to the
   coordinator, or does the head relay member attestations? (Protocol-symmetry cost
   differs; affects `coordinator/protocol/messages.go` ↔ `Protocol/Messages.swift`.)
2. **Re-handshake cost on roster churn** — how disruptive is tearing down + rebuilding
   the MLX distributed group when one member is revoked mid-request?
3. **RDMA encrypt-in-buffer overhead** — does sealing-into-registered-buffer erase
   enough of RDMA's zero-copy win to prefer the ring/TCP path at cluster sizes we care about?
4. **Key lifetime vs. challenge interval** — should a failed 5-min challenge force
   immediate session-key revocation, or is roster-expiry granularity acceptable?
