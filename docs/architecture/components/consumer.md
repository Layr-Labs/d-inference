# Consumer surface

> Last updated: 2026-09-14 · commit `5f2c53f32`

The consumer surface is the coordinator's OpenAI- and Anthropic-compatible request pipeline. `coordinator/inference/ingress/controller.go` (`Controller`) owns request preparation and admission: `ChatCompletions` serves Chat Completions and Responses, while `Completions` and `Messages` share `handleGenericInference`. These entry points use the same live routing, billing and quota services before handing off to dispatch. The API binding in `coordinator/api/inference_ingress.go` (`inferenceIngress`) constructs one controller and supplies the current store, registry, resolver, limiters, profiler and shared dispatch/settlement services. Readiness, authentication, RPM limits and sender-sealed transport remain in the route middleware; provider completion still reconciles against the same token limiter handles. This page explains the compatibility contract, stages and failure modes. The exact routes, headers and JSON shapes are in [`../../reference/api-contracts.md`](../../reference/api-contracts.md).

## What compatibility means here

Compatibility is a contract about *shapes*, not a promise to forward arbitrary fields untouched. The coordinator decodes each body into a generic JSON object (`parseInferencePrelude`, `coordinator/inference/ingress/prelude.go`), interprets a fixed set of fields, rewrites a few, rejects a few, and forwards the rest to the provider.

| Endpoint | Handler | Input lowering | How the answer is shaped |
|---|---|---|---|
| `POST /v1/chat/completions` | `Controller.ChatCompletions` | Native | `ChatCompletionResponse` (`buildNonStreamingResponse`) or SSE chunks |
| `POST /v1/responses` | `Controller.ChatCompletions` (same registration; it detects `input` instead of `messages`) | `promptcontract.LowerProviderBody` (`coordinator/promptcontract/endpoint_lower.go`) and `lowerResponses` (`coordinator/promptcontract/endpoint_lower_responses.go`) rewrites the Responses body into chat messages and tool definitions | `ResponsesResponse`; streams are re-emitted as typed `response.*` events by `NewResponsesSink` (`coordinator/inference/response/responses_stream.go`) |
| `POST /v1/messages` | `Controller.Messages` | `coordinator/promptcontract/endpoint_lower_messages.go` maps `system`, content blocks and `tool_use`/`tool_result` onto chat messages | `coordinator/inference/response/generic_endpoint_response.go` builds the Messages object; `newMessagesStreamEmitter` (`coordinator/inference/response/messages_stream.go`) emits Anthropic-style events. A matched `stop_sequence` is reported only when the caller supplied it (`coordinator/inference/response/generic_endpoint_stop.go`) |
| `POST /v1/completions` | `Controller.Completions` | `coordinator/promptcontract/endpoint_lower.go` wraps `prompt` as a single user message | Generic response builder and `NewEndpointSink` |

**Translated on the way in.** The alias in `model` is replaced by the concrete build id in the forwarded body (`resolveRequestedModel`); a string `stop` becomes a one-element array; tool schemas are normalised to strict JSON Schema (`toolpolicy.NormalizeParsed`, `coordinator/inference/toolpolicy/normalize.go`); `provider` and other routing hints are removed (`stripProviderRoutingFields`, `coordinator/inference/ingress/request_shape.go`); remote `image_url` parts are fetched and inlined (`resolveRemoteMedia`, `coordinator/inference/ingress/media_resolve.go`); a missing output bound is filled from the model registry or fallback while explicit positive bounds are preserved (`ensureMaxTokensBound`, `coordinator/inference/ingress/output_bound.go`); reasoning fields follow per-model policy (`applyResolvedModelReasoningPolicy`, `coordinator/inference/ingress/reasoning.go`).

**Translated on the way out.** The response `model` is the string the client sent, alias included; provider chunks are normalised (`normalizeSSEChunk`) and any provider `[DONE]` is stripped so a successful chat stream ends with exactly one; the usage and finish chunks are held to the end of the stream; `metadata`, `X-Provider-*`, `X-Timing` and `X-Inference-Job-ID` are added at commit (`WriteCommittedProviderHeaders`, `coordinator/inference/response/provider_snapshot.go`; `writeTimingHeaderWithProfile`, `coordinator/inference/dispatch/profile.go`).

**Rejected.** `n > 1` (400); a `tool_choice` that names a function absent from `tools`, or `required`/named choice with no tools (400, `toolpolicy.ValidateParsed` / `toolpolicy.ValidateBytes`, `coordinator/inference/toolpolicy/validate.go`); tool schemas the constraint parser cannot compile (422, `validateResolvedToolConstraintParser`); image content on a model without vision (400, `visionToolsFailFast`); an inference-enforced `tool_choice` (`required` or a named function) combined with images (400, `param: tool_choice`); a `model` outside the key's `allowed_models` (403 `model_not_allowed`, `accounts.KeyModelAllowed`, `coordinator/api/accounts/key_policy.go`); any other `/v1/*` endpoint (404 from `handleUnimplementedEndpoint`, `coordinator/api/routes.go`). `x-api-key` is not a credential here; only `Authorization: Bearer` is read (`extractBearerToken`). `response_format` is neither rejected nor validated: it is forwarded to the provider as sent.

## The request pipeline

Stages in the order `Controller.ChatCompletions` runs them. Each stage either advances or ends the request with a JSON error. Successful responses commit at stage 13.

| # | Stage | Owning symbol | Ends the request with |
|---|---|---|---|
| 1 | Middleware: drain, auth, rate limit, sealed transport | `Controller.Gate` (`coordinator/api/readiness/gate.go`), `requireAuth` (`coordinator/api/authentication.go`), `rateLimitConsumer` (`coordinator/api/request_rate_limits.go`), `sealedTransport` (`coordinator/api/sender_encryption.go`) | 429 (drain, key or account rate limit), 401, 400 sealed-envelope errors |
| 2 | Parse prelude: body cap [`maxInferenceBodyBytes`](../../reference/api-contracts.md#limits-and-validation), tool-schema normalisation, JSON decode, `model` required, key allow-list | `parseInferencePrelude`, `accounts.KeyModelAllowed` | 400, 403 `model_not_allowed`, 413 `invalid_request_error` |
| 3 | Shape checks: `messages`/`input` present, `n == 1`; strip routing fields; read metadata-details and self-route opt-ins | `stripProviderRoutingFields` (`coordinator/inference/ingress/request_shape.go`), `ApplyMetadataDetailsRequest` (`coordinator/inference/response/metadata_optin.go`), `ResolveSelfRoutePolicy` (`coordinator/inference/ingress/self_route.go`) | 400 |
| 4 | Traits and tool preflight: media requirement, tools present, Responses lowering for validation, tool-choice policy | `detectMediaRequirement`, `requestHasTools`, `promptcontract.LowerProviderBody`, `toolpolicy.ValidateParsed` / `toolpolicy.ValidateBytes` | 400, 422 |
| 5 | Model resolve: alias → build under the request's constraints; unresolvable → unavailable | `resolveRequestedModel` → `registry.ResolveModelConstrainedWithTraits` | 503 `model_unavailable` |
| 6 | Vision/tool fail-fast and remote-media gate | `visionToolsFailFast`, `gateRemoteMediaPreDispatch` | 400, 503 `model_unavailable` |
| 7 | Bounds and deadline: fill an omitted output bound, preserve explicit positive bounds, compute the first-content deadline, shed if the model is rejecting | `ensureMaxTokensBound`, `FirstContentDeadline`, `shedIfModelRejected` | 429 with `Retry-After` |
| 8 | Token-rate admission (input/output tokens per minute) | `applyTokenRateLimitWithAdmission` (`coordinator/inference/ingress/tokens.go`) | 429 with `Retry-After` |
| 9 | Reserve balance for the worst-case cost | `reserveInferenceBalance` (`coordinator/inference/ingress/balance.go`) | 402 (`error.type` and `code` per [`billing.md`](../billing.md#payment-required-responses)) |
| 10 | Fetch remote media (billed as media, after the reservation) | `resolveRemoteMedia` | 400 |
| 11 | Capacity admission: can any eligible provider take this prompt now? | `runInferenceAdmission` | 429, 503, 413 `payload_too_large` |
| 12 | Plan: cache-aware route plan for the prompt | `planCacheRoute` (`coordinator/inference/ingress/cache_plan.go`); see [`../cache-aware-routing.md`](../cache-aware-routing.md) | — |
| 13 | Dispatch: select a provider from the scheduler plan, encrypt, send, wait for first content, race a speculative backup, fail over, commit | `Controller.Run` (`coordinator/inference/dispatch/request.go`) enters `execution.run` (`coordinator/inference/dispatch/run.go`); [dispatch ownership and code map](../routing.md#dispatch-controller) describe the queue, hedge and failover operations. Payload encryption uses `e2e.GenerateSessionKeys` / `e2e.Encrypt` (`coordinator/internal/e2e/e2e.go`); see the [encryption model](../security/encryption.md) | 429 on capacity or first-content deadline, 502/503/504 `provider_error`, 503 `model_unavailable` (`preContentTerminal`, `coordinator/inference/dispatch/terminal_write.go`; exhausted branch of `execution.run`) |
| 14 | Relay: stream or assemble the provider's chunks | `Writer.Stream` (`coordinator/inference/response/stream.go`) and `Writer.handleEndpointStreamingResponse` (`coordinator/inference/response/endpoint_stream.go`); `Writer.NonStream` (`coordinator/inference/response/nonstream.go`) | Terminal SSE `error` event (status already 200) |
| 15 | Settle: charge the account from provider-reported usage, record usage, credit the provider | `Service.CompleteAt` (`coordinator/inference/providerframe/complete.go`) claims the terminal and calls `Service.Complete` (`coordinator/inference/settlement/completion.go`) before signaling consumer channels; rules in [`../billing.md`](../billing.md) | — |

Non-streaming raw responses and reconstructed deltas both wait for terminal usage through `awaitNonStreamUsage` in `coordinator/inference/response/nonstream.go`. A closed completion channel refunds and returns 502; expiry refunds and returns 504; client cancellation refunds without writing a replacement response. Buffered provider errors keep their existing precedence before that wait.

Provider-side execution between stages 13 and 14 — the WebSocket `inference_request` → `inference_response_chunk` → `inference_complete` exchange (`coordinator/protocol/inference.go`) and the engine behind it — is described in [`../inference.md`](../inference.md) and [`provider.md`](provider.md). The whole journey as a sequence diagram is in [`../data-flow.md`](../data-flow.md).

### Streaming ownership

`relayProviderStream` (`coordinator/inference/response/provider_stream.go`)
arbitrates chunks, provider errors, idle expiry and client cancellation for
all four SSE endpoints. It drains only already-queued chunks and flushes each
batch before reporting a close or provider error. The endpoint caller retains
idle-timer resets, settlement, route outcomes and terminal encoding. Chat keeps
its held usage/finish frames and metadata in `Writer.Stream`
(`coordinator/inference/response/stream.go`). Responses, Messages and legacy
Completions share `Writer.handleEndpointStreamingResponse`
(`coordinator/inference/response/endpoint_stream.go`); their sinks retain the
existing wire formatting and accepted-write observers.

`streamCompletionPolicy` and `Writer.finishEndpointStream` in
`coordinator/inference/response/endpoint_stream.go` preserve different completion
contracts. Messages and Completions require an explicit `CompleteCh` value;
client cancellation interrupts their two-second usage wait. Responses can finish
without completion usage when no outstanding reservation is refunded, and its
usage wait does not observe client cancellation. A trailing provider error takes
precedence over either policy. The shared lifecycle invokes the same reservation,
feedback and outcome services bound by `responseWriter`
(`coordinator/api/response_writer.go`).

## Invariants

1. **Successful responses wait for first content.** Success status, headers and body are deferred until a provider produces a content chunk (`commitFirstContent`). Failover and every pre-commit error therefore keep a real HTTP status. Corollary: a request that fails before producing content never sees a 200; only failures after first content arrive in-band.
2. **Money is reserved before dispatch and settled from usage.** `reserveInferenceBalance` holds the worst case; pre-commit failures release it; `providerframe.Service.CompleteAt` settles the provider-reported tokens. A catalog miss after reservation (404 `model_not_found`) also releases it.
3. **The client's model string is preserved.** The forwarded body carries the build id; every response, chunk and usage record echoes the requested alias (`publicModel` in `resolveRequestedModel`).
4. **Successful chat streams have exactly one `data: [DONE]`**, written after the held usage/finish frame. Successful Responses streams end with `response.completed` / `response.incomplete`; Messages ends with `message_stop`. Error termination keeps its endpoint-specific form and does not synthesize a chat success marker.
5. **No keepalives.** Silence on a stream means no token has been produced; the first-content deadline bounds it before commit (a miss is a 429 with `Retry-After`) and [`inferenceTimeout`](../../reference/api-contracts.md#timeouts-and-constants) between chunks after (a terminal `error` event).
6. **Providers never see the caller.** They receive an encrypted job carrying the build id and the prompt, not the API key or account.
7. **A departed client cancels the job.** Client disconnect before commit is recorded as 499 and sends `cancel` to the provider (`emitClientGone`, `attempt.Service.SendCancel`).

## Failure modes

| Symptom | Cause | Where |
|---|---|---|
| 429 `rate_limit_exceeded` + `Retry-After` | Key `rpm_limit`, account RPM, input/output tokens per minute, admission shedding, the model currently rejecting, or dispatch exhausted on capacity: every attempt was refused for capacity, no provider produced first content within the deadline (the coordinator's own pre-content timeout is reclassified from 504 to 429), or the request cannot fit any provider | `applyKeyRPMLimit`, `rateLimitWithTier`, `WriteTokenRateLimited`, `runInferenceAdmission`, `shedIfModelRejected`; `classifyExhaustedStatus` (`coordinator/inference/dispatch/failure.go`); delay from `EstimateRetryAfter`, capped at [`maxDistressRetryAfter`](../../reference/api-contracts.md#timeouts-and-constants) |
| 503 `model_unavailable`, **no** `Retry-After` | The alias resolves to no build, or no routable provider can serve the resolved model (including vision requests with no vision-capable provider online). Not transient from the client's point of view | `resolveRequestedModel`, `visionToolsFailFast`, `preContentTerminal` |
| 429 `rate_limit_exceeded` + the fixed drain [`Retry-After`](../../reference/api-contracts.md#timeouts-and-constants) | Coordinator draining; new inference is refused until the drain completes | `Controller.Gate` (`coordinator/api/readiness/gate.go`), `coordinatorDrainRetryAfter` |
| 503 `service_unavailable` + `Retry-After` | No serving capacity for the model at all | `writeServiceUnavailable` |
| 503 `machine_offline` / `model_not_loaded` + `Retry-After` | Self-route: the account's machine is offline or has not loaded the model | `selfRouteUnavailable` (`coordinator/inference/ingress/self_route.go`) |
| 502 / 503 / 504 `provider_error` | Dispatch exhausted on a genuine provider fault: the provider's own status is passed through (a typed provider 504 — safety deadline or backpressure timeout — stays 504; an untyped 504 becomes the 429 above) | Exhausted branch of `execution.run` (`coordinator/inference/dispatch/run.go`), `attempt.IsTypedTimeout504Cause` (`coordinator/inference/attempt/terminal_cause.go`) |
| 4xx `invalid_request_error` (`code: model_capability` or `payload_too_large`) | Every provider rejected the request deterministically with the same client error; surfaced once with the provider's status | `terminalClientError` handling in the exhausted branch |
| 504 `timeout` | Non-streaming only: `inferenceTimeout` elapsed after commit while waiting for the response or its usage | `Writer.NonStream` (`coordinator/inference/response/nonstream.go`) |
| 200 then terminal `data: {"error": …}`, without `[DONE]` (chat) | Provider failed after commit; the status line was already sent | `writeChatStreamProviderError` (`coordinator/inference/response/stream.go`), `Writer.ChatError` (`coordinator/inference/response/chat_metadata_stream.go`) |
| 413 `payload_too_large` | Prompt larger than any eligible provider accepts | `runInferenceAdmission` |
| 402 | Balance or key budget exhausted; `error.type` and `code` per [`billing.md`](../billing.md#payment-required-responses) | `reserveInferenceBalance` |
| No response, 499 in logs | Client disconnected before commit | `emitClientGone` |

## Code map

| Concern | Files |
|---|---|
| Consumer request owner and live bindings | `coordinator/inference/ingress/controller.go` (`Controller`, `Dependencies`, `New`); `coordinator/api/inference_ingress.go` (`inferenceIngress`, `ingressObserver`) |
| Endpoint entry points | `coordinator/inference/ingress/chat.go` (`Controller.ChatCompletions`), `coordinator/inference/ingress/endpoints.go` (`Controller.Completions`, `Controller.Messages`), `coordinator/inference/ingress/generic.go` (`handleGenericInference`) |
| Health, version and account usage endpoints | `coordinator/api/health.go` (`handleHealth`), `coordinator/api/version.go` (`handleVersion`), `coordinator/api/account_usage.go` (`handleBalance`, `handleUsage`), `coordinator/api/provider_earnings.go` (`handleProviderEarnings`) |
| Shared lifecycle services and write-evidence binding | `coordinator/api/response_writer.go` (`responseWriter`); owner contract in `coordinator/inference/response/writer.go` (`Dependencies`) |
| Streaming and buffered response orchestration | `coordinator/inference/response/stream.go` (`Writer.Stream`), `coordinator/inference/response/endpoint_stream.go` (`Writer.handleEndpointStreamingResponse`, `Writer.finishEndpointStream`), `coordinator/inference/response/nonstream.go` (`Writer.NonStream`) |
| Provider channel arbitration and bounded coalescing | `coordinator/inference/response/provider_stream.go` (`relayProviderStream`), `coordinator/inference/response/stream_coalesce.go` (`drainQueuedChunks`, `MaxBatchChunks`, `MaxBatchBytes`) |
| Chat/Responses shaping and SSE event handling | `coordinator/inference/response/chat_response.go`, `coordinator/inference/response/responses_response.go`, `coordinator/inference/response/chat_stream_terminal.go`, `coordinator/inference/response/stream_message.go`, `coordinator/inference/response/sse_events.go`, `coordinator/inference/response/sse_normalize.go` |
| Prelude parsing, body cap, vision fail-fast | `coordinator/inference/ingress/prelude.go` (`parseInferencePrelude`), `coordinator/inference/ingress/body.go` (`maxInferenceBodyBytes`), `coordinator/inference/ingress/capability.go` (`visionToolsFailFast`) |
| Request traits and routing-field stripping | `coordinator/inference/ingress/request_shape.go` (`introspectRequest`, `stripProviderRoutingFields`) |
| Token quotas, output bounds and deadlines | `coordinator/inference/ingress/tokens.go` (`applyTokenRateLimitWithAdmission`, `ReconcileOutputAdmission`), `coordinator/inference/ingress/output_bound.go` (`ensureMaxTokensBound`), `coordinator/inference/ingress/deadline.go` (`FirstContentDeadline`) |
| Cache planning and candidate-body memo | `coordinator/inference/ingress/cache_plan.go` (`planCacheRoute`), `coordinator/inference/ingress/candidate_memo.go` (`providerBodyMemo`) |
| Balance reservation and capacity admission | `coordinator/inference/ingress/balance.go` (`reserveInferenceBalance`, `topUpReservationForInlinedMedia`), `coordinator/inference/ingress/admission.go` (`runInferenceAdmission`) |
| Dispatch controller and API bindings | `coordinator/inference/dispatch/request.go` (`Controller.Run`), `coordinator/inference/dispatch/run.go` (`execution.run`); `coordinator/api/inference_dispatch.go` (`initializeInferenceDispatch`) |
| Attempt cancellation, rejection policy and provider feedback | `coordinator/inference/attempt/` (`Service`, `Tracker`); `coordinator/api/inference_attempt.go` binds shared services |
| Endpoint lowering | `coordinator/promptcontract/endpoint_lower.go`, `coordinator/promptcontract/endpoint_lower_responses.go`, `coordinator/promptcontract/endpoint_lower_messages.go` |
| Endpoint-specific response and stream builders | `coordinator/inference/response/generic_endpoint_response.go`, `coordinator/inference/response/generic_stream.go`, `coordinator/inference/response/generic_endpoint_stop.go`, `coordinator/inference/response/responses_stream.go`, `coordinator/inference/response/chat_metadata_stream.go`, `coordinator/inference/response/sse_response.go` |
| Provider metadata, timing header | `coordinator/inference/response/provider_snapshot.go`, `coordinator/inference/dispatch/profile.go` |
| Tools and media | `coordinator/inference/toolpolicy/`, `coordinator/inference/ingress/tools.go`, `coordinator/inference/ingress/media_resolve.go` |
| Self-route policy | `coordinator/inference/ingress/self_route.go` |
| Sealed client transport | `coordinator/api/sender_encryption.go` |
| Provider WebSocket, completion and settlement | `coordinator/api/provider.go` (`handleProviderWS`); `coordinator/inference/providerframe/complete.go` (`Service.CompleteAt`); `coordinator/protocol/inference.go` |
| Wire types | `coordinator/api/types/types.go` |

## Related

- [`../../reference/api-contracts.md`](../../reference/api-contracts.md) — routes, headers, JSON shapes, error envelope, limits and timeouts.
- [`../data-flow.md`](../data-flow.md) — the same journey as a sequence diagram with the provider leg included.
- [`../billing.md`](../billing.md) — reservation, settlement and the payment-required responses.
- [`../../consumer/quickstart.md`](../../consumer/quickstart.md) — calling the API as a consumer.
