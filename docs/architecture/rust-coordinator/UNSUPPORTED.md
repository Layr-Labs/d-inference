# Unsupported route matrix (Rust pilot)

The Rust pilot **never proxies** to Go. Excluded production surfaces return
`501` with `code=unsupported_route`.

| Surface | Status in pilot |
| --- | --- |
| `POST /v1/chat/completions` | Supported (warm plane) |
| `POST /v1/responses` | Supported (alias) |
| `GET /v1/models` | Supported |
| `GET /v1/encryption-key` | Supported (real X25519) |
| `GET /health`, `/readyz` | Supported |
| `GET /ws/provider` | Supported (register/heartbeat/prepare/start) |
| `GET /v1/admin/quiescence` | Supported (pilot inventory) |
| `POST /v1/admin/deposits` | Supported (pilot Stripe-inbox apply; not production webhook) |
| `POST /v1/admin/terminal-ingest` | Supported (replay ACK / late record; never double-settles) |
| `POST /v1/admin/force-settle` | Supported (ops clear start_authorized hold) |
| `POST /v1/admin/recover-undispatched` | Supported (release reserved-not-started) |
| Stripe deposit/withdraw/Connect (prod webhooks) | Unsupported (use pilot admin deposits for inbox tests) |
| Privy / API-key CRUD | Unsupported (pilot keys via env) |
| Device auth / enroll / MDM | Unsupported |
| Vision / tools / Anthropic messages | Unsupported |
| Completions (legacy `/v1/completions`) | Explicit 501 |
| Anthropic `/v1/messages` | Explicit 501 |
| Releases / installer / catalog admin | Unsupported |
| Invites / referrals / rewards / stats | Unsupported |
| Telemetry ingest / admin writes | Unsupported |

When adding a route to the pilot, remove it from this table and add fixtures.
