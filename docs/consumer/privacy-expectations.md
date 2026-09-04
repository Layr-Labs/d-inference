# Privacy expectations

> Last updated: 2026-09-03 · commit `5d400cf75`

What you can and cannot rely on when you send an inference request through Darkbloom. For consumers deciding what to send; the mechanism — which key opens which hop, wire formats, error codes, and the code that enforces each guarantee — is stated once in [`../architecture/security/encryption.md`](../architecture/security/encryption.md) and is not restated here.

In one sentence: your request is encrypted between the coordinator and the provider that runs the model, and optionally between you and the coordinator; the coordinator decrypts it in memory to route and bill it and writes no content to logs or storage, and the provider sees your prompt and the completion in plaintext.

## What you can rely on

1. The two legs between the coordinator and the provider are always encrypted with NaCl Box, whether or not you sealed your request; a provider without a registered key is never selected — [hop 2](../architecture/security/encryption.md#hop-2--coordinator--provider-mandatory), [hop 3](../architecture/security/encryption.md#hop-3--provider--coordinator-mandatory).
2. You can seal your request body to the coordinator's published key so that TLS-terminating intermediaries in front of the coordinator never see it; the response comes back sealed to your ephemeral key with `X-Eigen-Sealed: true` — [hop 1](../architecture/security/encryption.md#hop-1--consumer--coordinator-optional); wire shape in [`../reference/api-contracts.md#sealed-transport-wire-shape`](../reference/api-contracts.md#sealed-transport-wire-shape).
3. The coordinator holds your prompt, attached media and the completion in memory only for the life of the request and writes none of it to logs or the store; the only content-derived artifacts are keyed digests used for cache routing — [what the coordinator logs and retains](../architecture/security/encryption.md#what-the-coordinator-logs-and-retains).
4. Your request is dispatched only to a provider that passes every privacy gate: an X25519 key bound to an attested Secure Enclave identity, in-process inference, coordinator-verified SIP, and code identity once it is enforced — [invariants](../architecture/security/encryption.md#invariants), [routing gate](../architecture/security/attestation.md#routing-gate).
5. A provider that returns a plaintext or wrong-key response chunk is marked `untrusted` and your request fails rather than being served insecurely — [hop 3](../architecture/security/encryption.md#hop-3--provider--coordinator-mandatory).
6. The provider never sees your API key, Privy identity or balance, and never sees another consumer's prompts — [what each party can observe](../architecture/security/encryption.md#what-each-party-can-observe).
7. Provider error text is reduced to a closed vocabulary before it is logged or returned to you, and client telemetry ingest is disabled so no free-form fields reach the coordinator — [what the coordinator logs and retains](../architecture/security/encryption.md#what-the-coordinator-logs-and-retains).

## What you cannot rely on

1. "The coordinator never sees plaintext" is false. The coordinator opens your request in memory to route, bill and enforce the request contract, then re-encrypts it for exactly one provider — [what each party can observe](../architecture/security/encryption.md#what-each-party-can-observe).
2. The provider sees your prompt and the completion in plaintext: it is the decryption endpoint, because in-process inference at native speed requires it. The guarantee is about *which* process holds the key — [`../architecture/security/attestation.md`](../architecture/security/attestation.md), [`../architecture/security/identity-binding.md`](../architecture/security/identity-binding.md).
3. Sealing is optional and deployment-dependent: plaintext JSON is accepted on the same routes, and `GET /v1/encryption-key` returns `503 encryption_unavailable` when the coordinator has no sealing key, leaving the consumer → coordinator hop TLS-only — [failure modes](../architecture/security/encryption.md#failure-modes).
4. A sealed request cannot use remote `image_url` media: the coordinator refuses to fetch on behalf of a sealed body — [hop 1](../architecture/security/encryption.md#hop-1--consumer--coordinator-optional).
5. Metadata is retained: model, sampling parameters, token counts, latency, request and trace IDs, the selected provider, the remote address of your connection (access log), and your account identity (API key hash, Privy DID, balance) — [what the coordinator logs and retains](../architecture/security/encryption.md#what-the-coordinator-logs-and-retains).
6. There is no per-response signature or receipt: the `X-Provider-*` headers are the coordinator's assertion over TLS, not a provider-signed proof — [`verification.md`](./verification.md).

## Related

- [`verification.md`](./verification.md) — reading the provider trust headers and the public attestation endpoint.
- [`../architecture/security/encryption.md`](../architecture/security/encryption.md) — canonical mechanism and privacy table.
- [`../reference/api-contracts.md`](../reference/api-contracts.md) — HTTP contract for the inference routes.
