# How to request and verify an inference receipt

> Last updated: 2026-09-24 · commit `b6f9574ed`

This how-to documents the opt-in request contract, public lookup, and independent verification of request, provider-request, and assistant-text commitments. A receipt records a trusted-network event; it does not prove that the answer is correct or acceptable for your task.

## Prerequisites

- A Darkbloom API key with a stable public key ID. The receipt's `caller_ref` is this public ID, never the API-key secret.
- A cryptographically secure random source for a fresh 32-byte verifier nonce for each request.
- A raw HTTP client or a server-side SDK transport that can set request headers and read response headers. Cross-origin browser clients can use receipt headers on inference requests and read receipt ID/hash response headers; see [CORS behavior](../reference/api-contracts.md#headers).

## Steps

### 1. Keep the request within the current support boundary

Only non-streaming plain-text `/v1/chat/completions` is supported. Tools, media, Responses (`/v1/responses`), Anthropic (`/v1/messages`) and legacy completions (`/v1/completions`) are not supported. Each message must have a non-empty string `content` and a `system`, `developer`, `user`, or `assistant` role. Omit `stream` or set it to `false`. The exact validation and errors are in the [receipt contract](../reference/api-contracts.md#inference-receipts).

### 2. Save the exact JSON body and generate a nonce

Keep the body file unchanged until verification: `request_bytes_sha256` commits to its exact plaintext bytes, including whitespace and string escaping. If you use sealed transport, save the JSON plaintext before sealing; the receipt hashes that plaintext body.

```json
{
  "model": "<model id from GET /v1/models>",
  "messages": [
    {"role": "user", "content": "What is 2 + 2?"}
  ],
  "stream": false,
  "max_tokens": 32
}
```

Save it as `request.json`, then generate the canonical unpadded base64url form of 32 random bytes:

```bash
export DARKBLOOM_API_KEY="sk-db-..."
export RECEIPT_NONCE="$(python3 -c 'import base64,secrets; print(base64.urlsafe_b64encode(secrets.token_bytes(32)).rstrip(b"=").decode())')"
```

This encoding is 43 characters, uses the URL-safe alphabet, and has no `=` padding. Never reuse a nonce; the coordinator enforces single use.

### 3. Submit the opt-in request and retain its response headers

```bash
curl --dump-header response.headers --output response.json \
  https://api.darkbloom.dev/v1/chat/completions \
  -H "Authorization: Bearer $DARKBLOOM_API_KEY" \
  -H "Content-Type: application/json" \
  -H "X-Darkbloom-Receipt: required" \
  -H "X-Darkbloom-Receipt-Nonce: $RECEIPT_NONCE" \
  --data-binary @request.json
```

On a completed success, retain `X-Darkbloom-Receipt-Job-ID` and `X-Darkbloom-Receipt-Hash` from `response.headers` and the normal Chat Completions response in `response.json`. The job ID header is set when the committed request starts its response; the receipt-hash header is set after the signed envelope is durably recorded. An inference whose receipt cannot be recorded fails closed with HTTP 502 `receipt_unavailable`.

### 4. Retrieve the public record

Use either identifier from the response headers. These lookups do not require an API key and accept no query parameters; any query string has no effect.

```bash
curl "https://api.darkbloom.dev/v1/inference-receipts/jobs/$JOB_ID"
curl "https://api.darkbloom.dev/v1/inference-receipts/hashes/$RECEIPT_HASH"
```

The job lookup can return `202` with `state: "pending"`, `200` with a completed receipt, or `200` with `state: "failed"` or `"interrupted"` and no receipt. Pending jobs older than 24 hours are marked `interrupted` by hourly coordinator maintenance. The hash lookup returns completed, unexpired receipts only. Missing or expired lookups return `404` `not_found`. Lookup JSON contains hashes and metadata, not the request prompt or assistant text. The record is no longer publicly retrievable after its 90-day lookup expiry and is removed from storage by the same hourly maintenance loop.

### 5. Verify the receipt and compare the commitments

Treat the issuer as configuration, not as an arbitrary URL supplied by an untrusted receipt. The verifier should be configured with the expected coordinator issuer, require that it equals `payload.issuer`, and fetch that issuer's key set:

```bash
curl "https://api.darkbloom.dev/v1/inference-receipts/keys"
```

The key-set response contains `issuer` and `keys`, each with `key_id`, `algorithm: "Ed25519"`, and a standard-base64 Ed25519 `public_key`. Require its issuer to match the configured issuer and receipt payload, select the key whose ID equals the envelope's `key_id`, and verify the envelope signature and receipt hash. The API issuer is derived from configured `EIGENINFERENCE_BASE_URL`; it defaults to `https://api.darkbloom.dev` when unset or invalid (`inferenceReceiptIssuer`, `coordinator/api/inference_receipts.go`).

Then recompute and compare the commitments in `receipt.payload`:

| Payload field | Compare against |
|---|---|
| `request_sha256` | SHA-256 of the canonical JSON encoding of the original plaintext request body |
| `request_bytes_sha256` | SHA-256 of the exact original plaintext body bytes, such as `request.json` |
| `provider_request_sha256` | SHA-256 of the provider request-body bytes carried into dispatch; only the digest is published |
| `output_sha256` | SHA-256 of the exact UTF-8 bytes of `choices[0].message.content` in the completed assistant response |

For `request_sha256`, reconstruct version-1 canonical JSON exactly as the coordinator does (`CanonicalJSON`, `coordinator/receipts/canonical.go`): accept exactly one top-level JSON object; reject duplicate decoded object keys at every depth; parse numbers with `UseNumber` so their lexemes survive; remove insignificant whitespace and normalize string escapes by decoding and re-encoding; and marshal compact JSON with sorted map keys and Go `encoding/json`'s default string escaping. The raw body limit is 16 MiB and nested arrays/objects are limited to depth 256, counting the root object. Hash the resulting canonical bytes with SHA-256 and encode the digest as lowercase hexadecimal. Do not parse numbers through floating point or substitute a generic JSON canonicalizer.

The signed payload also identifies `job_id`, the submitted `nonce`, `caller_ref`, requested and resolved model, the winning attempt, `status`, `finish_reason`, completion time, and lookup expiry. Receipt-hash and Ed25519 signing byte rules are defined in the [receipt API reference](../reference/api-contracts.md#inference-receipts).

## Verify

- The envelope `receipt_hash` and Ed25519 signature validate against a public key fetched from the configured issuer, and that issuer matches the verifier's expected issuer.
- `nonce`, `caller_ref`, job ID, and model fields match the request and your API key's public ID.
- The four SHA-256 commitments match the canonical request, exact plaintext request bytes, provider-body digest when available, and exact assistant-text bytes.
- `status` is `completed`; `finish_reason` is `stop` or `length`. The hash fields alone do not make the answer semantically correct.

## Troubleshooting

| Result | Cause | Fix |
|---|---|---|
| 400 `invalid_request_error` | Missing/mismatched opt-in headers, a non-canonical nonce, unsupported endpoint/body, or request JSON that cannot be canonicalized | Send both headers, generate a new 32-byte nonce, and use the supported request shape |
| 503 `receipt_unavailable` | Disabled/invalid signing configuration, storage unavailability, or nonce reuse | Check coordinator receipt-key configuration and storage health; use a fresh nonce for each retry |
| 502 `receipt_unavailable` | Inference completed, but response extraction, signing, or receipt persistence failed | The response is deliberately withheld as a successful receipt-backed result; submit a new request with a fresh nonce if retrying |
| 202 `pending` remains visible | The job has not reached a terminal receipt state | Poll the job path; coordinator maintenance marks pending records older than 24 hours as `interrupted` |
| 404 `not_found` | Job/hash is unknown or its lookup window expired | Check the saved response header values and the 90-day lookup window |

## Related

- Exact request/response shapes, routes, errors, and receipt signing bytes: [`../reference/api-contracts.md#inference-receipts`](../reference/api-contracts.md#inference-receipts).
- Receipt lifecycle and coordinator implementation: [`../architecture/inference-receipts.md`](../architecture/inference-receipts.md).
- Ordinary inference setup: [`quickstart.md`](quickstart.md).
- Provider attestation checks: [`verification.md`](verification.md).
