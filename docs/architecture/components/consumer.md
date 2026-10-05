# Consumer surface

> Last updated: 2026-10-03

The consumer surface is the coordinator's OpenAI- and Anthropic-compatible request pipeline: it speaks OpenAI Chat Completions, OpenAI Responses, Anthropic Messages and legacy Completions to clients and turns each request into one provider job through a single pipeline in `HandleChatCompletions` (`coordinator/api/inference/consumer.go`), with an endpoint-specific lowering step before it and a re-shaping step after it. This page is for engineers changing or debugging that pipeline: it explains what "compatible" means concretely, walks the stages, and lists the invariants and failure modes that follow. The exact routes, headers, and JSON shapes are in [`../../reference/api-contracts.md`](../../reference/api-contracts.md).

## What compatibility means here

Compatibility is a contract about *shapes*, not a promise to forward arbitrary fields untouched. The coordinator decodes each body into a generic JSON object (`parseInferencePrelude`, `coordinator/api/inference/inference_preprocess.go`), interprets a fixed set of fields, rewrites a few, rejects a few, and forwards the rest to the provider.

| Endpoint | Handler | How it reaches the chat pipeline | How the answer is shaped |
|---|---|---|---|
| `POST /v1/chat/completions` | `HandleChatCompletions` | Native | `ChatCompletionResponse` (`BuildNonStreamingResponse`) or SSE chunks |
| `POST /v1/responses` | `HandleChatCompletions` (same registration; it detects `input` instead of `messages`) | `promptcontract.LowerProviderBody` (`coordinator/internal/promptcontract/endpoint/endpoint_lower_responses.go`) rewrites the Responses body into chat messages and tool definitions | `ResponsesResponse`; streams are re-emitted as typed `response.*` events by `NewResponsesStreamEmitter` (`coordinator/api/inference/response/responses_stream.go`) |
| `POST /v1/messages` | `HandleAnthropicMessages` | `coordinator/internal/promptcontract/endpoint/endpoint_lower_messages.go` maps `system`, content blocks and `tool_use`/`tool_result` onto chat messages | `coordinator/api/inference/response/generic_endpoint_response.go` builds the Messages object; `newMessagesStreamEmitter` (`coordinator/api/inference/response/generic_endpoint_stream.go`) emits Anthropic-style events. A matched `stop_sequence` is reported only when the caller supplied it (`coordinator/api/inference/response/generic_endpoint_stop.go`) |
| `POST /v1/completions` | `HandleCompletions` | `coordinator/promptcontract/endpoint_lower.go` wraps `prompt` as a single user message | Generic response builder and `NewGenericEndpointStreamEmitter` |

**Translated on the way in.** The alias in `model` is replaced by the concrete build id in the forwarded body (`resolveRequestedModel`); a string `stop` becomes a one-element array; tool schemas are normalised to strict JSON Schema (`NormalizeToolSchemas`, `coordinator/api/inference/request/toolschema.go`); `provider` and other routing hints are removed (`StripProviderRoutingFields`, `coordinator/api/inference/request/request_introspection.go`); remote `image_url` parts are fetched and inlined (`resolveRemoteMedia`, `coordinator/internal/inference/media/media_resolve.go`); `max_tokens` is clamped to the model's ceiling (`ensureMaxTokensBound`); reasoning fields follow per-model policy (`ApplyResolvedModelReasoningPolicy`, `coordinator/api/inference/request/reasoning_request_policy.go`).

**Translated on the way out.** The response `model` is the string the client sent, alias included; provider chunks are normalised (`NormalizeSSEChunk`) and any provider `[DONE]` is stripped so the coordinator writes exactly one; the usage and finish chunks are held to the end of the stream; `metadata`, `X-Provider-*`, `X-Timing` and `X-Inference-Job-ID` are added at commit (`WriteCommittedProviderHeaders`, `coordinator/api/inference/response/response_metadata.go`; `writeTimingHeaderWithProfile`, `coordinator/api/inference/profiler_dispatch.go`).

**Rejected.** `n > 1` (400); a `tool_choice` that names a function absent from `tools`, or `required`/named choice with no tools (400, `ValidateToolConstraintPolicy`, `coordinator/api/inference/request/tool_constraints.go`); tool schemas the constraint parser cannot compile (422, `ValidateResolvedToolConstraintParser`); image content on a model without vision (400, `visionToolsFailFast`); an inference-enforced `tool_choice` (`required` or a named function) combined with images (400, `param: tool_choice`); a `model` outside the key's `allowed_models` (403 `model_not_allowed`, `keyModelAllowed`, `coordinator/api/inference/key_policy.go`); any other `/v1/*` endpoint (404 from `handleUnimplementedEndpoint`, `coordinator/api/server.go`). `x-api-key` is not a credential here; only `Authorization: Bearer` is read (`ExtractBearerToken`). `response_format` is neither rejected nor validated: it is forwarded to the provider as sent.

## The request pipeline

Stages in the order `HandleChatCompletions` runs them. Each stage either advances or ends the request with a JSON error; nothing has been written to the client until stage 13 commits.

| # | Stage | Owning symbol | Ends the request with |
|---|---|---|---|
| 1 | Middleware: drain, auth, rate limit, sealed transport | `DrainGate` (`coordinator/api/operations/drain.go`), `RequireAuth`, `RateLimitConsumer` (`coordinator/api/access/rate_limits.go`), `SealedTransport` (`coordinator/api/inference/sender_encryption.go`) | 429 (drain, key or account rate limit), 401, 400 sealed-envelope errors |
| 2 | Parse prelude: body cap [`maxInferenceBodyBytes`](../../reference/api-contracts.md#limits-and-validation), tool-schema normalisation, JSON decode, `model` required, key allow-list | `parseInferencePrelude`, `keyModelAllowed` | 400, 403 `model_not_allowed` |
| 3 | Shape checks: `messages`/`input` present, `n == 1`; strip routing fields; read metadata-details and self-route opt-ins | `StripProviderRoutingFields` (`coordinator/api/inference/request/request_introspection.go`), `ApplyMetadataDetailsRequest` (`coordinator/api/inference/request/metadata_flags.go`), `resolveSelfRoutePolicy` (`coordinator/api/inference/self_route.go`) | 400 |
| 4 | Traits and tool preflight: media requirement, tools present, Responses lowering for validation, tool-choice policy | `DetectMediaRequirement`, `RequestHasTools`, `promptcontract.LowerProviderBody`, `ValidateToolConstraintPolicy` | 400, 422 |
| 5 | Model resolve: alias → build under the request's constraints; unresolvable → unavailable | `resolveRequestedModel` → `registry.ResolveModelConstrainedWithTraits` | 503 `model_unavailable` |
| 6 | Vision/tool fail-fast and remote-media gate | `visionToolsFailFast`, `gateRemoteMediaPreDispatch` | 400, 503 `model_unavailable` |
| 7 | Bounds and deadline: clamp `max_tokens`, compute the first-content deadline, shed if the model is rejecting | `ensureMaxTokensBound`, `FirstContentDeadline`, `shedIfModelRejected` | 429 with `Retry-After` |
| 8 | Token-rate admission (input/output tokens per minute) | `applyTokenRateLimitWithAdmission` (`coordinator/api/inference/configuration.go`) | 429 with `Retry-After` |
| 9 | Reserve balance for the worst-case cost | `reserveInferenceBalance` (`coordinator/api/inference/inference_balance.go`) | 402 (`error.type` and `code` per [`billing.md`](../billing.md#payment-required-responses)) |
| 10 | Fetch remote media (billed as media, after the reservation) | `resolveRemoteMedia` | 400 |
| 11 | Capacity admission: can any eligible provider take this prompt now? | `Admission.Run` | 429, 503, 413 `payload_too_large` |
| 12 | Plan: cache-aware route plan for the prompt | `planCacheRoute` (`coordinator/api/inference/prompt_artifacts.go`); see [`../cache-aware-routing.md`](../cache-aware-routing.md) | — |
| 13 | Dispatch: select a provider from the scheduler plan, encrypt, send, wait for first content, race a speculative backup, fail over, commit | `Owner.NewDispatchSession` (`coordinator/api/inference/dispatch_session.go`) binds the attempt loop; `Primary.Run` (`coordinator/api/inference/primary_run.go`) selects the provider, `waitFirstChunk` (`coordinator/api/inference/first_wait.go`) waits, and `retryDecision` (`coordinator/api/inference/dispatch_retry.go`) controls retries. `runSpeculative`, `runRace`, `commitFirstContent` and `writeCommittedResponse` remain in `coordinator/api/inference/dispatch.go`. Scoring: [`../routing.md`](../routing.md); encryption: `e2e.GenerateSessionKeys` / `e2e.Encrypt` (`coordinator/internal/e2e/e2e.go`), model in [`../security/encryption.md`](../security/encryption.md) | 429 on capacity or first-content deadline, 502/503/504 `provider_error`, 503 `model_unavailable` (`Recorder.PreContentTerminal`, `coordinator/internal/inference/rejection/terminal.go`; exhausted branch of `dispatchState.finishDispatch`) |
| 14 | Relay: stream or assemble the provider's chunks | `handleStreamingResponseWithFirstChunkAndError`, `handleResponsesStreamingResponseWithFirstChunk` (`coordinator/internal/inference/relay/consumer_stream.go`); `handleNonStreamingResponseWithFirstChunkAndError` (`coordinator/internal/inference/relay/consumer_response.go`) | Terminal SSE `error` event (status already 200) |
| 15 | Settle: charge the account from provider-reported usage, record usage, credit the provider | `HandleCompleteAt` (`coordinator/api/inference/provider_inference.go`): `claimSettlement`, `ledger.Charge`, `store.RecordUsage`, `store.CreditProviderAccount`; rules in [`../billing.md`](../billing.md) | — |

Non-streaming raw responses and reconstructed deltas both wait for terminal usage through `awaitNonStreamUsage` in `coordinator/internal/inference/relay/consumer_response.go`. A closed completion channel refunds and returns 502; expiry refunds and returns 504; client cancellation refunds without writing a replacement response. Buffered provider errors keep their existing precedence before that wait.

Provider-side execution between stages 13 and 14 — the WebSocket `inference_request` → `inference_response_chunk` → `inference_complete` exchange (`coordinator/protocol/messages.go`) and the engine behind it — is described in [`../inference.md`](../inference.md) and [`provider.md`](provider.md). The whole journey as a sequence diagram is in [`../data-flow.md`](../data-flow.md).

## Invariants

1. **Nothing is written before first content.** Status code, headers and body are all deferred until a provider produces a content chunk (`commitFirstContent`). Failover and every pre-commit error therefore keep a real HTTP status. Corollary: a request that fails before producing content never sees a 200; only failures after first content arrive in-band.
2. **Money is reserved before dispatch and settled from usage.** `reserveInferenceBalance` holds the worst case; pre-commit failures release it; `HandleCompleteAt` charges the provider-reported tokens. A catalog miss after reservation (404 `model_not_found`) also releases it.
3. **The client's model string is preserved.** The forwarded body carries the build id; every response, chunk and usage record echoes the requested alias (`publicModel` in `resolveRequestedModel`).
4. **Exactly one `data: [DONE]`**, written by the coordinator after the held usage/finish frame; Responses streams end with `response.completed` / `response.incomplete` instead.
5. **No keepalives.** Silence on a stream means no token has been produced; the first-content deadline bounds it before commit (a miss is a 429 with `Retry-After`) and [`inferenceTimeout`](../../reference/api-contracts.md#timeouts-and-constants) between chunks after (a terminal `error` event).
6. **Providers never see the caller.** They receive an encrypted job carrying the build id and the prompt, not the API key or account.
7. **A departed client cancels the job.** Client disconnect before commit is recorded as 499 and sends `cancel` to the provider (`emitClientGone`, `sendProviderCancel`).

## Failure modes

| Symptom | Cause | Where |
|---|---|---|
| 429 `rate_limit_exceeded` + `Retry-After` | Key `rpm_limit`, account RPM, input/output tokens per minute, admission shedding, the model currently rejecting, or dispatch exhausted on capacity: every attempt was refused for capacity, no provider produced first content within the deadline (the coordinator's own pre-content timeout is reclassified from 504 to 429), or the request cannot fit any provider | `applyKeyRPMLimit`, `rateLimitWithTier`, `WriteTokenRateLimited`, `Admission.Run`, `shedIfModelRejected`; `retry.ClassifyExhaustedStatus` (`coordinator/internal/inference/retry/terminal_classification.go`); delay from `estimateRetryAfter`, capped at [`maxDistressRetryAfter`](../../reference/api-contracts.md#timeouts-and-constants) |
| 503 `model_unavailable`, **no** `Retry-After` | The alias resolves to no build, or no routable provider can serve the resolved model (including vision requests with no vision-capable provider online). Not transient from the client's point of view | `resolveRequestedModel`, `visionToolsFailFast`, `preContentTerminal` |
| 429 `rate_limit_exceeded` + the fixed drain [`Retry-After`](../../reference/api-contracts.md#timeouts-and-constants) | Coordinator draining; new inference is refused until the drain completes | `DrainGate` (`coordinator/api/operations/drain.go`), `coordinatorDrainRetryAfter` |
| 503 `service_unavailable` + `Retry-After` | No serving capacity for the model at all | `writeServiceUnavailable` |
| 503 `machine_offline` / `model_not_loaded` + `Retry-After` | Self-route: the account's machine is offline or has not loaded the model | `selfRouteUnavailable` (`coordinator/api/inference/self_route.go`) |
| 502 / 503 / 504 `provider_error` | Dispatch exhausted on a genuine provider fault: the provider's own status is passed through (a typed provider 504 — safety deadline or backpressure timeout — stays 504; an untyped 504 becomes the 429 above) | Exhausted branch of `dispatchState.finishDispatch` (`coordinator/api/inference/dispatch.go`), `failure.IsTypedTimeout504Cause` (`coordinator/internal/inference/failure/terminal_policy.go`) |
| 4xx `invalid_request_error` (`code: model_capability` or `payload_too_large`) | Every provider rejected the request deterministically with the same client error; surfaced once with the provider's status | `terminalClientError` handling in the exhausted branch |
| 504 `timeout` | Non-streaming only: `inferenceTimeout` elapsed after commit while waiting for the response or its usage | `handleNonStreamingResponseWithFirstChunkAndError` (`coordinator/internal/inference/relay/consumer_response.go`) |
| 200 then `data: {"error": …}` + `[DONE]` | Provider failed after commit; the status line was already sent | `writeChatStreamProviderError` (`coordinator/internal/inference/relay/consumer_stream.go`), `WriteChatStreamTerminalError` (`coordinator/api/inference/response/chat_metadata_stream.go`) |
| 413 `payload_too_large` | Prompt larger than any eligible provider accepts | `Admission.Run` |
| 402 | Balance or key budget exhausted; `error.type` and `code` per [`billing.md`](../billing.md#payment-required-responses) | `reserveInferenceBalance` |
| No response, 499 in logs | Client disconnected before commit | `emitClientGone` |

## Code map

| Concern | Files |
|---|---|
| Pipeline entry, health/version/balance handlers | `coordinator/api/inference/consumer.go` |
| Streaming and buffered response orchestration | `coordinator/internal/inference/relay/consumer_stream.go`, `coordinator/internal/inference/relay/consumer_response.go` |
| Chat/Responses shaping and SSE event handling | `coordinator/api/inference/response/chat_response.go`, `coordinator/api/inference/response/responses_response.go`, `coordinator/api/inference/response/chat_stream_terminal.go`, `coordinator/api/inference/response/stream_message.go`, `coordinator/api/inference/response/sse_events.go`, `coordinator/internal/inference/sse/sse_normalize.go` |
| Prelude parsing, body cap, vision fail-fast | `coordinator/api/inference/inference_preprocess.go` |
| Request traits and routing-field stripping | `coordinator/api/inference/request_introspection.go` |
| Balance reservation and capacity admission | `coordinator/api/inference/inference_balance.go`, `coordinator/api/inference/inference_admission.go` |
| Dispatch state machine, failover, speculative backup, commit | `coordinator/api/inference/dispatch.go`; `coordinator/internal/inference/rejection/terminal.go` (`Recorder.PreContentTerminal`) wired by `Owner.NewRejectionRecorder` in `coordinator/api/inference/rejection_telemetry.go`; `coordinator/internal/inference/rejection/inference_failure_class.go` |
| Endpoint lowering | `coordinator/promptcontract/endpoint_lower.go`, `coordinator/internal/promptcontract/endpoint/endpoint_lower_responses.go`, `coordinator/internal/promptcontract/endpoint/endpoint_lower_messages.go` |
| Endpoint-specific response and stream builders | `coordinator/api/inference/response/generic_endpoint_response.go`, `coordinator/internal/inference/relay/generic_endpoint_stream.go`, `coordinator/api/inference/response/generic_endpoint_stop.go`, `coordinator/api/inference/response/responses_stream.go`, `coordinator/api/inference/response/chat_metadata_stream.go`, `coordinator/api/inference/response/sse_response.go` |
| Provider metadata, timing header | `coordinator/api/inference/response/response_metadata.go`, `coordinator/api/inference/profiler_dispatch.go` |
| Tools and media | `coordinator/api/inference/request/toolschema.go`, `coordinator/api/inference/tool_constraints.go`, `coordinator/internal/inference/media/media_resolve.go` |
| Self-route policy | `coordinator/api/inference/self_route.go` |
| Sealed client transport | `coordinator/api/inference/sender_encryption.go` |
| Provider WebSocket, completion and settlement | `coordinator/api/provider/`, `coordinator/protocol/messages.go` |
| Wire types | `coordinator/api/types/types.go` |

## Related

- [`../../reference/api-contracts.md`](../../reference/api-contracts.md) — routes, headers, JSON shapes, error envelope, limits and timeouts.
- [`../data-flow.md`](../data-flow.md) — the same journey as a sequence diagram with the provider leg included.
- [`../billing.md`](../billing.md) — reservation, settlement and the payment-required responses.
- [`../../consumer/quickstart.md`](../../consumer/quickstart.md) — calling the API as a consumer.
