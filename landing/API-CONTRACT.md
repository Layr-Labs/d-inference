# Public API description

> Last updated: 2026-10-12

Landing serves [`/openapi.json`](https://darkbloom.ai/openapi.json) from
[`public/openapi.json`](public/openapi.json). This is a reviewed documentation
artifact for the Coordinator at `https://api.darkbloom.dev`, not an API proxy.
The authoritative API implementation and reference belong to
[Layr-Labs/darkbloom-platform](https://github.com/Layr-Labs/darkbloom-platform).

## Coverage and provenance

The reviewed source revision is
[`baca977134a63678ab12979038d3618901d852ee`](https://github.com/Layr-Labs/darkbloom-platform/tree/baca977134a63678ab12979038d3618901d852ee).
The artifact carries this revision and the reviewed source paths in
`x-source-repository`, `x-source-revision` and `x-reviewed-source-files`.

| Operation | Scope |
| --- | --- |
| `GET /v1/models` | Authenticated Consumer catalog, optional `include_builds=1`, capacity metadata and individual-token pricing |
| `GET /v1/models/{id}` | Authenticated exact-id lookup, including slash-bearing model identifiers |
| `GET /v1/pricing` | Public platform model and fallback rates, in micro-USD and formatted USD per one million tokens |
| `POST /v1/chat/completions` | Ordinary text messages, common sampling/output controls, JSON response and SSE framing |

Source mapping at that immutable revision:

- [Route bindings](https://github.com/Layr-Labs/darkbloom-platform/blob/baca977134a63678ab12979038d3618901d852ee/coordinator/api/routes.go) establish HTTP methods and authentication boundaries.
- [Response types](https://github.com/Layr-Labs/darkbloom-platform/blob/baca977134a63678ab12979038d3618901d852ee/coordinator/api/types/types.go) define model, pricing and nonstreaming chat fields.
- [Model handlers](https://github.com/Layr-Labs/darkbloom-platform/blob/baca977134a63678ab12979038d3618901d852ee/coordinator/api/catalog/models_endpoints.go) define aliases, hidden builds and slash-bearing exact ids.
- [Pricing handler](https://github.com/Layr-Labs/darkbloom-platform/blob/baca977134a63678ab12979038d3618901d852ee/coordinator/api/billing/pricing.go) and [price conversion](https://github.com/Layr-Labs/darkbloom-platform/blob/baca977134a63678ab12979038d3618901d852ee/coordinator/api/modelprice/price.go) define public rates and their distinct units.
- [Chat handler](https://github.com/Layr-Labs/darkbloom-platform/blob/baca977134a63678ab12979038d3618901d852ee/coordinator/api/inference/consumer.go), [output-budget validation](https://github.com/Layr-Labs/darkbloom-platform/blob/baca977134a63678ab12979038d3618901d852ee/coordinator/api/inference/request/output_budget_validation.go), [budget alias precedence](https://github.com/Layr-Labs/darkbloom-platform/blob/baca977134a63678ab12979038d3618901d852ee/coordinator/internal/inference/providerwire/output_bound.go), [JSON error envelope](https://github.com/Layr-Labs/darkbloom-platform/blob/baca977134a63678ab12979038d3618901d852ee/coordinator/api/httpx/json.go), [SSE headers](https://github.com/Layr-Labs/darkbloom-platform/blob/baca977134a63678ab12979038d3618901d852ee/coordinator/api/inference/response/sse_response.go) and [stream lifecycle](https://github.com/Layr-Labs/darkbloom-platform/blob/baca977134a63678ab12979038d3618901d852ee/coordinator/internal/inference/relay/consumer_stream.go) establish request and terminal behavior.

The [full platform API reference](https://github.com/Layr-Labs/darkbloom-platform/blob/baca977134a63678ab12979038d3618901d852ee/docs/reference/api-contracts.md)
covers additional operations and advanced features. Responses, legacy
Completions, Anthropic Messages, multimodal requests, tools, sealed transport,
advanced routing, key management and Provider management are outside this
OpenAPI subset. Omission does not imply an unsupported platform capability.
The text request schema intentionally allows additional properties; it is
not a complete reconstruction of the Coordinator's request validator.

## Security and stream handling

Consumers create an API key through the Console and send
`Authorization: Bearer <DARKBLOOM_API_KEY>` directly to the Coordinator.
Authentication also accepts a valid Privy JWT. Provider device tokens are not
Consumer API keys. Model discovery and inference retain authentication, key
restrictions, billing and rate limits. Only the pricing operation in this
subset is public. No credentials, live model availability guarantees or fixed
prices are embedded in the document.

A streaming request does not commit HTTP 200 until first content. Failures
before that point use their real error status and the JSON error envelope.
After commit, failures use a terminal SSE `data: {"error": {...}}` event and
omit `[DONE]`. A successful Chat stream ends with exactly one `[DONE]` event.
Clients must inspect both the HTTP response and terminal stream events; a
200 response by itself does not establish successful completion. SSE is
described as text, not as a JSON response body. No keepalive is promised;
callers own request deadlines and cancellation.

## Updating and checking

1. Have the platform API owner review the affected operation against a new
   immutable platform revision. Compare route bindings, authorization,
   validation, response types, error paths and stream terminal behavior.
2. Update the artifact and this provenance together. Keep the coverage
   explicit and retain both pricing units. Do not infer a schema only from
   public documentation or change Coordinator behavior from Landing.
3. From `landing/`, run `npm ci`, `npm run build`, `npm run lint` and `npm test`.
   The built-site HTTP tests retrieve the public artifact and validate it
   with the pinned OpenAPI validator, then check the reviewed security,
   operations, types, pricing units and stream contract. They do not send
   credentials or paid inference requests to production.
4. After a separately authorized deployment, verify the public URL and
   discovery links. A source revision or passing local test does not prove
   the artifact has been deployed or remains synchronized with production.
