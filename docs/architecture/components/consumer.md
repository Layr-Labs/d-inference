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

Successful, provider-committed inference responses include Darkbloom provider
headers (`X-Provider-Attested`, `X-Provider-Trust-Level`, `X-Provider-Id`,
`X-Provider-Chip`, `X-Provider-Encrypted`, `X-Provider-Secure-Enclave`,
`X-Timing`, …). Validation, capacity, and other pre-commit failures do not have
a selected provider and therefore do not carry these headers
([`dispatch.go:3371-3379`](../../../coordinator/api/dispatch.go#L3371-L3379)).

OpenAI-compatible SDKs often hide custom headers, so
`POST /v1/chat/completions` can copy the committed fields into the JSON body
when the caller sets `metadata_details: true` (or
`X-Darkbloom-Metadata-Details: true`). The coordinator consumes the flag before
provider encryption
([`response_metadata.go:51-99`](../../../coordinator/api/response_metadata.go#L51-L99)),
builds `metadata` with region/country-only `location`
([`response_metadata.go:208-239`](../../../coordinator/api/response_metadata.go#L208-L239)),
and reserves that top-level key against provider-supplied values before
attaching its snapshot
([`chat_metadata_stream.go:13-50`](../../../coordinator/api/chat_metadata_stream.go#L13-L50),
[`response_metadata.go:241-267`](../../../coordinator/api/response_metadata.go#L241-L267)).
Device serials, city, coordinates, lookup source, and raw IPs are never
included. `location` is body-only, not a header. Successful streams attach
metadata to the terminal chunk; failed committed streams emit it immediately
before the terminal in-band error
([`consumer.go:2185-2216`](../../../coordinator/api/consumer.go#L2185-L2216),
[`chat_metadata_stream.go:63-87`](../../../coordinator/api/chat_metadata_stream.go#L63-L87)).

## Supported operations

- Chat completions (`/v1/chat/completions`)
- Completions (`/v1/completions`)
- Messages (`/v1/messages`)
- Models (`/v1/models`)
- Transcriptions (`/v1/audio/transcriptions`)
- Images (`/v1/images/generations`)

Implementation: `coordinator/api/consumer.go`.
