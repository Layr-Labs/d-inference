# Inference Receipts

Darkbloom's trust stack proves privacy end to end: NaCl Box per hop, Secure
Enclave attestation, MDM, Hardened Runtime. Receipts close the one gap that
stack leaves open. Before receipts, nothing proved that a provider actually
ran the claimed model on the submitted request and returned its real output.
The response attestation signed `sha256(requestId:completionTokens:responseBody)`,
which binds neither the model weights, nor the request content, nor any
sampling parameter. A provider serving one model at another model's price
produced perfectly valid attestations.

A receipt is a canonical record of one inference. Its receipt hash is the
SHA-256 of its canonical JSON bytes, and the provider's Secure Enclave signs
that hash. Receipts carry digests only, never prompt or response plaintext,
so they are public by construction.

## The record

```json
{"completion_tokens":42,
 "model_id":"mlx-community/gemma-4-26b",
 "model_weight_hash":"<aggregate SHA-256 of the served weights>",
 "prompt_tokens":17,
 "request_id":"<coordinator request id>",
 "request_sha256":"<SHA-256 of the exact decrypted request body bytes>",
 "response_sha256":"<SHA-256 of the full response text, UTF-8>",
 "v":2}
```

Shown wrapped; the canonical form is a single line, keys in alphabetical
order, minimal escaping, no HTML or slash escaping. The Go encoder is
`coordinator/receipt/receipt.go`, the Swift twin is
`provider-swift/Sources/ProviderCore/Security/InferenceReceipt.swift`, and
`fixtures/receipts/receipt_vectors.json`, generated independently of both,
pins them byte for byte.

Two decisions keep the record small:

- **The request digest binds every sampling parameter.** Temperature, seed,
  max_tokens, messages, and tools all live inside the request bytes, so one
  digest binds them all. No float canonicalization, no parameter list to
  keep in sync.
- **The wire contract is the existing contract.** `se_signature` has always
  meant "Secure Enclave signature over `response_hash`". For a v2 provider,
  `response_hash` is the receipt hash and the new optional `receipt` field
  carries the record. Older providers omit the field and keep today's
  behavior; older consumers see the same fields they always saw.

## Who verifies what

| Binding | Verifier | How |
|---|---|---|
| Receipt bytes to hash | anyone | SHA-256 of the `receipt` field equals `response_hash` |
| Hash to provider | anyone | `se_signature` verifies against the provider's attested P-256 key (served by `GET /v1/receipts/{hash}`) |
| Request bytes to digest | whoever sealed the request | the coordinator checks automatically at completion; sealed sender consumers recompute over their own plaintext |
| Weights to hash | coordinator and provider | the receipt's `model_weight_hash` must equal the hash the provider registered, which registration already cross checks against the model catalog |
| Response text to digest | consumer | recompute SHA-256 over the assembled response text |

The coordinator runs its checks at `inference_complete`
(`coordinator/api/receipts.go`), records the verdict, and serves it publicly:

```
GET /v1/receipts/{hash}
→ { "address", "receipt", "se_signature", "se_public_key",
    "checks": { "address_match", "request_digest_match", …,
                "signature_valid", "signature_checked" },
    "created_at" }
```

Every check has a paired `*_checked` field. A check runs only when the
coordinator had the input to check against; for example, sealed sender mode
hides the plaintext body, so `request_digest_checked` is false and the
consumer holds that binding instead. A failed binding never fails the
request. It is logged, counted (`receipts.check_failed`), and visible on the
record.

## The forgery result (tested)

A malicious provider can mint a well formed receipt over a lie and sign it.
Internal consistency is not the defense; cross checking is:

- `TestIntegration_ReceiptGenuine`: an honest provider passes every
  check, and a third party verifies the signature using only public endpoint
  data.
- `TestIntegration_ReceiptLyingProviderIsFlagged`: a correctly signed,
  canonically encoded receipt claiming a different request digest and weight
  hash keeps `address_match` and `signature_valid` true (that is the attack)
  while `request_digest_match` and `model_weight_hash_match` refute it.
- `coordinator/receipt/receipt_test.go`: canonical form strictness (exactly
  one byte string per receipt), golden vectors, and the tamper matrix. The
  Swift twins live in `Tests/ProviderCoreTests/InferenceReceiptTests.swift`.

## Replay audits (future work)

Because `darkbloom start --local` runs the identical engine on any Apple
Silicon Mac, anyone holding a transcript can escalate from digest checks to
replay: rerun the request bytes named by `request_sha256` against the
weights named by `model_weight_hash` and compare output. Two facts must be
measured on real hardware before replay verdicts are trusted:

1. **The determinism envelope.** Production decode runs inside a continuous
   batch; a replay runs alone. Whether greedy decode replays byte identical
   on the same machine, and across machines and chip generations, is an open
   measurement. The sampler RNG is keyed on (seed, requestID, step), so a
   replay must reuse the receipt's `request_id`.
2. **The comparator.** If byte identity holds, replay verdicts are boolean.
   If not, the verdict becomes a divergence token index with a tolerance.
   The receipt commitment is unchanged either way.

Canary audits compound this: any party may submit seeded requests as
ordinary paid traffic and check the receipts that come back against local
replays. A provider cannot distinguish auditors from customers, so cheating
on a fraction f of traffic against a canary rate e survives R requests with
probability (1 − ef)^R. A signed receipt, the transcript, and a refuting
replay together form a self contained fraud proof, which is the natural
input to cryptoeconomic enforcement if the project ever wants it. All of
this is future work; this document only records that the receipt layer was
designed to make it possible.

## Privacy

The public record contains hashes, a signature, and the provider's
attestation public key, which is already the provider's pseudonymous
identity. Only holders of the plaintext can bind a receipt to content. The
receipt cache is in memory and bounded (`receiptCacheCap`); the receipt
itself travels inline to the consumer, so the endpoint is a convenience,
not a custody layer.
