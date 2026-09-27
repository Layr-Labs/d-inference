# Inference receipts

> Last updated: 2026-09-27 · commit `d3e3c3a62`

Inference receipts define a coordinator-signed record binding a supported chat job to request and output commitments. This explanation covers the coded lifecycle, persistence, verification, key rotation, and failure behavior; consumer request and verification steps are in the [consumer procedure](../consumer/inference-receipts.md).

## Context

A consumer normally receives a completion but has no compact, publicly retrievable coordinator record that ties the submitted request, the dispatched request body, and the completed assistant text to one coordinator job. A receipt adds that record without publishing prompt or output plaintext. It proves that the trusted Darkbloom network recorded the committed event and signed its metadata and hashes; it does not prove that the answer is correct or acceptable for the consumer's task (`Payload`, `coordinator/receipts/receipts.go`).

Receipt requests currently cover only non-streaming plain-text `/v1/chat/completions` without tools or media. The opt-in validator is in `newInferenceReceiptRequest` (`coordinator/api/inference_receipts.go`); exact consumer rules and the current exclusions are in the [how-to](../consumer/inference-receipts.md#1-keep-the-request-within-the-current-support-boundary).

## Mechanism

```mermaid
sequenceDiagram
    participant C as Consumer
    participant A as Coordinator API
    participant D as Dispatch / winner attempt
    participant S as Receipt store
    participant K as Public key lookup
    C->>A: POST chat completion + required and nonce headers
    A->>A: Validate shape, nonce, stable API-key ID; compute request digests
    A->>S: Create pending job (job ID, nonce, expiry)
    A->>D: Dispatch with digests and provider-body hash on each attempt
    D-->>A: Committed winner and non-streaming response
    A->>A: Hash assistant text; sign winner payload
    A->>S: Atomically transition pending → completed with envelope
    A-->>C: Completion + receipt job/hash headers
    C->>S: GET by job ID or receipt hash
    S-->>C: Public state and, when completed, signed hashes/metadata only
    C->>K: GET /v1/inference-receipts/keys at configured issuer
    K-->>C: Issuer and active + retained Ed25519 public keys
    C->>C: Reconstruct request commitments and verify digest/signature
```

### Request and attempt binding

The consumer opts in with `X-Darkbloom-Receipt: required` and `X-Darkbloom-Receipt-Nonce`. The nonce is a canonical unpadded base64url encoding of 32 random bytes; the API persists it with the pending job and the store enforces uniqueness across retained rows (`newInferenceReceiptRequest`, `createPendingInferenceReceipt`, `coordinator/api/inference_receipts.go`; `validInferenceReceiptNonce`, `coordinator/store/inference_receipts.go`). A stable API key public ID becomes `caller_ref`; requests without one are rejected (`keyIDFromContext`, `coordinator/api/server.go`).

The coordinator keeps hashes and identifiers—not prompt or output plaintext—in `InferenceReceiptContext` as dispatch retries proceed (`coordinator/registry/inference_receipt.go`). The context is attached to each pending attempt; finalization uses the `PendingRequest` that won and committed its response, so `winning_attempt_id` identifies that attempt (`dispatchWithReserver`, `coordinator/api/consumer.go`; `writeCommittedResponse`, `coordinator/api/dispatch.go`). Request canonicalization and the four hash definitions are detailed in the [consumer procedure](../consumer/inference-receipts.md#5-verify-the-receipt-and-compare-the-commitments).

### Signing and public lookup

The version-1 payload contains issuer, job ID, winning attempt ID, nonce, caller reference, request/provider/output hashes, requested and resolved models, `status: "completed"`, finish reason, completion timestamp, and lookup expiry (`Payload`, `coordinator/receipts/receipts.go`). `Signer.Sign` marshals the fixed-order payload, hashes the versioned `darkbloom:inference-receipt:v1\0` domain plus payload bytes, and signs a domain-separated preimage with Ed25519 (`Signer.Sign`, `payloadDigest`, `signaturePreimage`).

`GET /v1/inference-receipts/jobs/{job_id}` returns the job state; when completed, it includes the verified envelope. `GET /v1/inference-receipts/hashes/{receipt_hash}` finds completed, unexpired receipts. Both routes are public and return hashes/metadata only. `GET /v1/inference-receipts/keys` returns the issuer and configured Ed25519 public-key ring (`routes`, `coordinator/api/server.go`; `handleInferenceReceiptByJobID`, `handleInferenceReceiptByHash`, `handleInferenceReceiptKeys`, `coordinator/api/inference_receipts.go`).

## Invariants

1. **Receipt-enabled inference reserves before dispatch.** The pending row persists the validated nonce before `d.run()`; if durable reservation fails, the request fails closed and no inference is dispatched (`createPendingInferenceReceipt`, `coordinator/api/inference_receipts.go`; `handleChatCompletions`, `coordinator/api/consumer.go`).
2. **The coded completion path binds only the winning committed attempt.** When pending reservation succeeds, the response writer finalizes the exact committed `PendingRequest`; storage atomically changes `pending` to `completed`, and terminal records cannot be overwritten (`finalizeInferenceReceipt`, `coordinator/api/inference_receipts.go`; `CompleteInferenceReceipt`, `coordinator/store/postgres_inference_receipts.go`).
3. **A completed envelope contains commitments and metadata, not conversation text.** Registry receipt context carries digests and identifiers only; the stored envelope is the signed payload (`InferenceReceiptContext`, `coordinator/registry/inference_receipt.go`; `InferenceReceiptRecord`, `coordinator/store/inference_receipts.go`).
4. **Receipt creation fails closed.** If a completed response cannot be extracted, signed, or durably completed, the handler returns 502 `receipt_unavailable` rather than a receipt-backed success (`plainTextReceiptOutput`, `finalizeInferenceReceipt`, `writeInferenceReceiptFailure`, `coordinator/api/inference_receipts.go`).
5. **The store makes a nonce single-use while its row is retained.** Both backends enforce nonce uniqueness and completed receipt hashes cannot be duplicated (`CreateInferenceReceipt`, `coordinator/store/memory_inference_receipts.go`; unique indexes in `inferenceReceiptTableDDL`, `coordinator/store/postgres_inference_receipts.go`).
6. **Public lookup is bounded by the payload's 90-day expiry.** The API hides missing or expired job/hash records and emits `Cache-Control: private, no-store` for returned lookup records (`defaultInferenceReceiptExpiry`, `handleInferenceReceiptByJobID`, `handleInferenceReceiptByHash`, `writeInferenceReceiptLookup`, `coordinator/api/inference_receipts.go`).
7. **A verifier trusts only its configured issuer and a matching key ID.** The coordinator validates stored signatures before serving completed envelopes; its key endpoint publishes active and configured historical verification keys (`configureInferenceReceipts`, `writeInferenceReceiptLookup`, `handleInferenceReceiptKeys`, `coordinator/api/inference_receipts.go`; `Verify`, `coordinator/receipts/receipts.go`).

## Persistence and key rotation

`inference_receipts` is installed by the idempotent Postgres startup migration. It stores a unique job ID, nonce, optional unique receipt hash, lifecycle state, opaque envelope, timestamps, and expiry; pending/failed/interrupted records contain no receipt envelope (`inferenceReceiptTableDDL`, `coordinator/store/postgres_inference_receipts.go`). `PostgresStore` makes rows durable across coordinator restarts. `MemoryStore` implements the same interface for local/test configurations but loses records on process exit (`MemoryStore`, `PostgresStore`, `coordinator/store/memory_inference_receipts.go`, `coordinator/store/postgres_inference_receipts.go`; [storage backends](storage.md#two-implementations-and-when-each-runs)).

At startup, `EIGENINFERENCE_INFERENCE_RECEIPT_SIGNING_KEY_ID` and `EIGENINFERENCE_INFERENCE_RECEIPT_SIGNING_KEY` select the active signer. `EIGENINFERENCE_INFERENCE_RECEIPT_PUBLIC_KEYS` is a JSON map of retained key IDs to standard-base64 Ed25519 public keys; the active public key is added to the published ring. During rotation, configure each still-needed historical public key alongside the new active signer. Keep a historical key published while a receipt signed by it may still be queried: the coordinator returns 503 for a completed record if its key ID is absent from the configured ring. Feature enablement and key encodings are defined in [`configuration.md`](../reference/configuration.md#inference-receipt-signing).

Lookup expiry is 90 days from receipt request creation. The lookup handlers reject expired rows even if the row remains in storage. An hourly coordinator maintenance loop marks pending rows older than 24 hours as interrupted and prunes expired rows in bounded batches (`StartInferenceReceiptMaintenance`, `coordinator/api/inference_receipt_maintenance.go`; started by `coordinator/cmd/coordinator/main.go`).

## Lifecycle and failure modes

| State | Meaning and transition | Public job lookup |
|---|---|---|
| `pending` | Row reserved before dispatch. It remains pending while the job runs. A request-scope return marks it failed; maintenance marks it interrupted if it is still pending after 24 hours. | HTTP 202 with `job_id` and `state` |
| `completed` | One valid plain-text assistant choice and supported finish reason were extracted, signed, and atomically stored from the winner attempt. | HTTP 200 with the signed receipt envelope |
| `failed` | Dispatch/request path failed, receipt extraction/signing failed, or completion persistence failed. Terminal state is immutable. | HTTP 200 with `job_id` and `state`, no receipt |
| `interrupted` | Terminal state assigned by hourly maintenance to a pending receipt older than 24 hours. | HTTP 200 with `job_id` and `state`, no receipt |

| Symptom | Cause | Code behavior |
|---|---|---|
| HTTP 400 `invalid_request_error` | Headers, nonce, message content, endpoint, or requested mode violates validation | Request is rejected before a receipt record is reserved (`newInferenceReceiptRequest`) |
| HTTP 503 `receipt_unavailable` | Feature disabled/invalid signing config, storage unavailable, or a job/hash record cannot be safely verified | No signed success is returned (`configureInferenceReceipts`, lookup handlers) |
| HTTP 502 `receipt_unavailable` | Inference completed but receipt extraction, signing, or persistence failed | Normal successful inference body is withheld (`writeInferenceReceiptFailure`) |
| Job remains `pending` after abrupt coordinator termination | Process exited before its request defer could mark failure; the row has not yet reached the 24-hour stale threshold | Hourly maintenance changes it to `interrupted` after the stale threshold |
| Old completed receipt lookup returns 503 after rotation | The receipt's `key_id` is not in the current configured verification ring | Restore the matching public key in `EIGENINFERENCE_INFERENCE_RECEIPT_PUBLIC_KEYS` |

## Code map

| Concern | Location |
|---|---|
| Routes and lookup/signing configuration | `coordinator/api/server.go` (`routes`, `NewServer`); `coordinator/api/server_config.go` (`ReadServerConfig`) |
| Request validation, hashing, envelope finalization, lookup responses | `coordinator/api/inference_receipts.go` (`newInferenceReceiptRequest`, `finalizeInferenceReceipt`, `writeInferenceReceiptLookup`) |
| Winner-attempt attachment | `coordinator/api/consumer.go` (`handleChatCompletions`, `dispatchWithReserver`); `coordinator/api/dispatch.go` (`writeCommittedResponse`) |
| Canonical request encoding and Ed25519 envelope | `coordinator/receipts/canonical.go` (`CanonicalJSON`); `coordinator/receipts/receipts.go` (`Signer.Sign`, `Verify`) |
| Registry digest context | `coordinator/registry/inference_receipt.go` (`InferenceReceiptContext`) |
| Store contract and backends | `coordinator/store/interface_domains.go` (`InferenceReceiptStore`); `coordinator/store/postgres_inference_receipts.go` (`inferenceReceiptTableDDL`); `coordinator/store/memory_inference_receipts.go` |
| Stale recovery and expiry maintenance | `coordinator/api/inference_receipt_maintenance.go` (`StartInferenceReceiptMaintenance`); `coordinator/cmd/coordinator/main.go` |

## Related

- [Consumer how-to](../consumer/inference-receipts.md) — opt in and independently check the envelope.
- [HTTP API contracts](../reference/api-contracts.md#inference-receipts) — exact routes, fields, headers, and errors.
- [Configuration reference](../reference/configuration.md#inference-receipt-signing) — signing and retained-key settings.
- [Storage](storage.md) — coordinator store backends and schema lifecycle.
