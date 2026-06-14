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

Responses include:

- `provider_attested` (bool)
- `provider_trust_level` (string, e.g. `hardware`)
- `X-Timing` header decomposing per-request latency.

## Supported operations

- Chat completions (`/v1/chat/completions`)
- Completions (`/v1/completions`)
- Messages (`/v1/messages`)
- Models (`/v1/models`)
- Transcriptions (`/v1/audio/transcriptions`)
- Images (`/v1/images/generations`)

Implementation: `coordinator/api/consumer.go`.
