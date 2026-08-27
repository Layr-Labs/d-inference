# Consumer

Darkbloom exposes an OpenAI-compatible HTTP API. Any client that can speak the
OpenAI chat/completions protocol can use it by changing `base_url` and `api_key`.

## Authentication

Use a Darkbloom API key in the `Authorization: Bearer <key>` header. API keys
can be created in the console UI or via admin endpoints.

## Optional sender-side encryption

For end-to-end confidentiality from the consumer client to the coordinator CVM,
a consumer may encrypt the request body with NaCl Box using the coordinator's
ephemeral X25519 key advertised at `GET /v1/encryption-key`.

Implementation: `coordinator/api/sender_encryption.go`.

## Routing hints

- `X-Darkbloom-Route: self` — route only to a provider owned by the caller's
  account (free, no fallback).
- `X-Darkbloom-Route: prefer` — prefer owned provider, fall back to paid public
  fleet.
- `X-Darkbloom-Private-Only: true` — request private-tier-only providers.

See [`provider/self-route.md`](../../provider/self-route.md).

## Response extensions

Every inference response includes Darkbloom provider headers (`X-Provider-Attested`, `X-Provider-Trust-Level`, `X-Provider-Id`, `X-Provider-Chip`, `X-Provider-Encrypted`, `X-Provider-Secure-Enclave`, `X-Timing`, …). OpenAI-compatible SDKs often hide custom headers, so `POST /v1/chat/completions` can copy the same consumer-safe fields into the JSON body when the caller sets `metadata_details: true` (or `X-Darkbloom-Metadata-Details: true`). The body object is `metadata` (`provider_attested`, `provider_trust_level`, `timing`, …). Device serials are never included.

Implementation: `coordinator/api/response_metadata.go`, attached from `handleChatCompletions` writers in `coordinator/api/consumer.go`.

## Supported operations

- Chat completions (`/v1/chat/completions`)
- Completions (`/v1/completions`)
- Messages (`/v1/messages`)
- Models (`/v1/models`)
- Transcriptions (`/v1/audio/transcriptions`)
- Images (`/v1/images/generations`)

Implementation: `coordinator/api/consumer.go`.
