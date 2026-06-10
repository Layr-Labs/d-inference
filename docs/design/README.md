# Design & Spec Documents

Detailed design docs, specs, and engineering findings. For the as-built system
overview see [../ARCHITECTURE.md](../ARCHITECTURE.md); for the API surface see
[../api.md](../api.md).

## Security & attestation

| Doc | Status | What it covers |
|---|---|---|
| [apns-code-attestation-design.md](apns-code-attestation-design.md) | Implemented (Phases 1–3) | Remotely-verifiable code-identity attestation via APNs: why App Attest doesn't exist on macOS, the APNs push-as-code-gated-channel insight, the encrypted-challenge protocol, and the on-box verification ledger. |
| [acme-mda-apple-root-signed.md](acme-mda-apple-root-signed.md) | Implemented | Apple-root-signed ACME `device-attest-01` (MDA) with MicroMDM + step-ca: the trust chain, the macOS keychain constraint, options evaluated, and the RDMA/multi-node residual analysis. |

## KV cache (SSD prefix cache)

Read in this order:

| Doc | Status | What it covers |
|---|---|---|
| [ssd-kv-cache-design.md](ssd-kv-cache-design.md) | Implemented (historical design) | Original design rationale: goals, threat model, file format, envelope encryption (SE-wrapped KEK/DEK), index, eviction, phased plan. |
| [ssd-kv-cache.md](ssd-kv-cache.md) | Current (as-built reference) | How the shipped cache actually works: tiers, data path, load-path verification ladder, disk budget, on-disk layout, TB-007 security model, code/test map. |
| [ssd-kv-cache-hybrid-models.md](ssd-kv-cache-hybrid-models.md) | Implemented | Exact-checkpoint whole-cache snapshots for hybrid sliding-window models (Gemma-4, gpt-oss-20b), the window-vs-prefix-length distinction, and the numeric-equivalence verification gate. |
| [kv-cache-lookup-shadowing-finding.md](kv-cache-lookup-shadowing-finding.md) | Open finding | Short in-window RAM checkpoints shadow the SSD tier on small-window hybrid models; evidence, impact, proposed fixes. |

Diagrams: [ssd-kv-cache-model-binding.png](ssd-kv-cache-model-binding.png)
(source: [ssd-kv-cache-model-binding.mmd](ssd-kv-cache-model-binding.mmd)).

## Routing modes

| Doc | Status | What it covers |
|---|---|---|
| [self-route.md](self-route.md) | Implemented | Free, relayed inference on your own Mac: opt-in surfaces, server-side ownership model, owner-filtered routing, settlement re-verification, `private_only` mode. |
| [direct-mode.md](direct-mode.md) | Implemented | Coordinator-free local/LAN inference: `--local` / `--local-endpoint`, token + discovery record, shared-engine unified mode, local-first client fallback. |
