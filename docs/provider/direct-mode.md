# Direct mode: a local OpenAI-compatible endpoint

> Last updated: 2026-10-21

Run the provider's inference engine as an OpenAI-compatible HTTP server on your
own Mac, either standalone (`darkbloom start --local`, no coordinator, no
earnings) or alongside fleet serving (`darkbloom start --local-endpoint`). For
operators who want their own tools to call the models they already host.
Requests never leave the machine and are never billed.

## Prerequisites

- Provider installed ([installation](./installation.md)); no account or
  `darkbloom login` is needed for `--local`.
- At least one model downloaded with an engine-v2 adapter (gpt-oss, gemma-4
  families); `darkbloom models list`.
- Port `8000` free, or choose another with `--port`.

## Steps

1. Pick a mode. The two flags are mutually exclusive; `darkbloom start`
   rejects the combination with exit 1
   (`provider-swift/Sources/darkbloom/Start/StartCommand.swift`, `Start.run`).

   | Mode | Command | Coordinator | Models come from | Earns |
   |---|---|---|---|---|
   | Standalone | `darkbloom start --local` | not contacted | `StandaloneServer`'s own slot cache (`provider-swift/Sources/ProviderCore/Server/StandaloneServer.swift`) | no |
   | Unified | `darkbloom start --local-endpoint` | connected as usual | the live `ProviderLoop` slots — weights load once and local + fleet requests share one continuous-batching engine and KV budget (`provider-swift/Sources/ProviderCore/ProviderLoop+LocalEndpoint.swift`) | yes, for fleet traffic |

2. Start standalone. This runs in the current terminal (no LaunchAgent) and
   installs no service:

   ```bash
   darkbloom start --local --model <model-id>          # or --all, or the picker
   darkbloom start --local --port 8080 --bind 0.0.0.0  # other port / all interfaces
   ```

   `--port` defaults to `8000` (`defaultLocalPort`; a dev build uses its own
   port, see [Dev build identity](../operations/provider-release.md#dev-build-identity)),
   `--bind` to `127.0.0.1`. Before serving,
   `Start.runLocalStandalone` (`provider-swift/Sources/darkbloom/Start/StartCommand+Modes.swift`)
   loads or creates the API token, filters the chosen models to those with an
   engine-v2 adapter (exit 1 with `No engine-v2-capable models available to
   serve.` if none remain), and preloads the selected models before listening
   when `[backend] startup_preload` is enabled (the default). The explicit
   `preload_models` list takes precedence; slot and memory limits can skip a
   model, which still loads on request. Standalone preload does not run the
   coordinator-serving one-token startup self-test. Each preloaded model does run
   the excluded [shape warmup](../architecture/inference.md#model-startup-calibration)
   before the listener opens: a short shader-cache probe, plus the shape cells
   after a new install or a macOS or MLX kernel update. The 5-second sweep tick
   warms a deferred, lazily loaded or MTP-upgraded engine once the server is
   idle; a request that arrives first preempts it and may still compile Metal
   kernels. `DARKBLOOM_TTFT_SHAPE_WARMUP=0` disables the warmup. Ctrl-C during preload cancels startup
   without opening the listener. It then waits for the socket to bind (`waitUntilBound`,
   bounded by the local bind wait in [runtime constants](./cli-reference.md#runtime-constants);
   `Local server failed to bind <addr>:<port> within 5s` otherwise), writes the
   discovery file and holds a fan-control lease while running
   ([fan control](./fan-control.md)). Ctrl-C stops it and removes the
   discovery file. Closing the terminal window does the same
   ([stop signals](./cli-reference.md#graceful-stop-and-restart)), unless the
   command was started with hangups ignored (for example under `nohup`), in
   which case it keeps serving.

3. Or start unified. This goes through the normal LaunchAgent path, so the
   flags are recorded in the plist and survive reboots:

   ```bash
   darkbloom start --local-endpoint --port 8000
   ```

   The provider daemon starts the local server in a child task once it is
   running. If the port is busy the daemon logs `Local OpenAI endpoint did NOT
   bind on <host>:<port> (port already in use?)` and keeps serving the fleet;
   restart with a free `--port`. The discovery file is written only after the
   provider's own socket is bound, never on a probe another process could
   answer (`ProviderLoop.onLocalEndpointBound`). In unified mode a local
   request first loads the model if needed and then holds a reservation until
   its stream ends, so the coordinator's advertised capacity reflects local
   load too.

4. Get the endpoint and key:

   ```bash
   darkbloom local          # Base URL, API key, model list, curl example
   darkbloom local --json   # the raw ~/.darkbloom/local.json record
   ```

   `Local` (`provider-swift/Sources/darkbloom/LocalCommand.swift`) reads the
   discovery file through `LocalEndpoint.readLiveInfo`, which checks the
   recorded `pid` is alive so a crashed server is never advertised; with no
   live server it exits 1 (`{}` under `--json`).

5. Call it with any OpenAI client:

   ```bash
   export OPENAI_BASE_URL=$(darkbloom local --json | jq -r .base_url)
   export OPENAI_API_KEY=$(darkbloom local --json | jq -r .api_key)
   curl -s "$OPENAI_BASE_URL/chat/completions" \
     -H "Authorization: Bearer $OPENAI_API_KEY" -H "Content-Type: application/json" \
     -d '{"model":"<model-id>","messages":[{"role":"user","content":"hi"}]}'
   ```

## Authentication and files

| Item | Value | Source |
|---|---|---|
| API key | `~/.darkbloom/local_token`, mode `0600`; `dk-local-` + base64url of 32 random bytes; created once, reused across restarts | `provider-swift/Sources/ProviderCore/Server/LocalEndpoint.swift` (`loadOrCreateToken`, `tokenPrefix`) |
| Discovery record | `~/.darkbloom/local.json`, mode `0600`: `base_url`, `api_key`, `host`, `port`, `pid`, `version`, `updated_at`; removed on graceful shutdown | `LocalEndpoint.Info`, `writeInfo`, `removeInfo` |
| Directory | `~/.darkbloom`; a dev build (`darkbloom-dev`) uses `~/.darkbloom-dev`. `DARKBLOOM_LOCAL_DIR` replaces it for both files | `LocalEndpoint.directory`, `BuildEnvironment.installDirectory` |
| `--bind 0.0.0.0` | Advertised `base_url` uses `127.0.0.1`; other hosts use the machine's address | `LocalEndpoint.Info.init` |
| `--no-auth` | No token check; `api_key` is empty in the discovery record | `LocalInferenceHTTPConfig.authToken == nil` |

`LocalAuthResponder` (`provider-swift/Sources/ProviderCore/Server/LocalAuthResponder.swift`)
is the outermost layer: `OPTIONS` preflights, `GET /health`, `GET /v1/health`
and `GET /` pass without a token; everything else needs
`Authorization: Bearer <token>`, compared in constant time; failures return
`401` with an OpenAI-style error envelope and `Access-Control-Allow-Origin: *`
so browser clients can read it. There is no rate limiting and no TLS: keep the
default loopback bind, or put a reverse proxy in front before exposing it.

## Routes

The responder stack is auth → CORS → `/metrics` → chat-upload interception →
the upstream `MLXLMServer` router
(`provider-swift/Sources/ProviderCore/Server/LocalInferenceHTTP.swift`,
`makeLocalInferenceApplication`). Routes are registered in
`libs/mlx-swift-lm/Libraries/MLXLMServer/HTTP/MLXServerApplication.swift`
(`buildRouter`):

| Method | Path | Notes |
|---|---|---|
| GET | `/health`, `/v1/health` | Unauthenticated |
| GET | `/models`, `/v1/models` | Advertised catalog, not just resident models |
| GET | `/props`, `/metrics` | `/metrics` adds per-slot MTP and serving-posture lines (`provider-swift/Sources/ProviderCore/Server/LocalMetricsResponder.swift`); see [SSD cache observations](../reference/ssd-kv-cache.md#verification) for `prefix_cache_status` |
| POST | `/v1/chat/completions`, `/chat/completions` | Streaming and non-streaming; inline media; body capped at `localInferenceMaxUploadBytes` |
| POST | `/v1/chat/completions/batch` | Same cap |
| POST | `/v1/completions`, `/completions`, `/completion` | Text; upstream 2 MiB body ceiling |
| POST | `/v1/responses`, `/responses` | Responses API; provider continuation history and SDK response-object storage, with distinct retention below |
| GET / POST | `/v1/responses/:response_id`, `/v1/responses/:response_id/cancel` | |
| POST | `/tokenize`, `/detokenize`, `/apply-template` | Tokenizer utilities |
| POST | `/v1/embeddings`, `/embeddings`, `/embedding` | Registered upstream; the provider configures no embedding model, so they return an OpenAI error envelope with code `embeddings_not_configured` |

The cap `localInferenceMaxUploadBytes`
(`provider-swift/Sources/ProviderCore/Server/LocalChatUploadResponder.swift`;
value in [runtime constants](./cli-reference.md#runtime-constants))
matches the coordinator WebSocket frame allowance. Per-image, per-video and
per-audio limits are the same as fleet serving and are configured through the
variables in [`reference/configuration.md`](../reference/configuration.md).
`max_tokens` defaults to the scheduler's default when a request omits it.

For Chat/Completions streaming, inspect every SSE event for `error`, even after
HTTP 200. A late generation failure ends with a sanitized error chunk and
`finish_reason: "error"`, without a success `[DONE]`; the HTTP transfer closes
normally. Pre-header errors retain their HTTP status, and client cancellation
still cancels generation. Responses uses `response.failed` for late failures.
The provider chat-upload interceptor selects the SDK service's HTTP framing
policy (`LocalChatUploadResponder.respond` and `MLXOpenAIService.streamChatCompletionFrames`).
A failed required tool call is still a failure; no argument repair or fabricated
call is performed.

## Responses continuation and retention

Send a stored response's string `id` as `previous_response_id` on the next
Responses POST. Send only the new input; the provider prepends the stored input
and assistant output. Supply the new request's instructions and tool settings
again: previous top-level instructions and settings are not inherited. Keep
your own history if a conversation must survive eviction or an application
restart (`provider-swift/Sources/ProviderCore/Server/LocalResponseConversation.swift`,
`prepare`, `conversation`).

| Behavior | Local contract | Source |
|---|---|---|
| Input limit | Responses POST bodies use `min(maxUploadBytes, 2 * 1024 * 1024)`; the larger Chat upload cap does not apply. Reconstructed history still passes ordinary token/context admission. | `provider-swift/Sources/ProviderCore/Server/LocalChatUploadResponder.swift` (`respond`) |
| Continuation ID | Omitted or JSON `null` starts without prior history. Non-null non-string values, empty/unknown IDs and evicted IDs return JSON HTTP `400`, code `previous_response_not_found`, before model acquisition or SSE setup. | `LocalResponseConversation.prepare`; `LocalChatUploadResponder.respond` |
| Saved history | Input plus one assistant turn containing answer, reasoning and tool calls; tool-result `call_id` is preserved. A streamed completed/incomplete response is recorded before its terminal frame is forwarded; a failed frame is not recorded. | `LocalResponseConversation.conversation`, `finalResponse`; `provider-swift/Sources/ProviderCore/Server/LocalResponseConversationStore.swift` (`record`, `recording`) |
| Continuation lifetime | One history store per local application. Defaults are `maxResponses = 256` and `maxBytes = 64 * 1024 * 1024`, measured as retained serialized histories including inline media. Reads refresh recency; oldest entries are evicted, and a history larger than the byte cap is not saved. This is not a total process-memory bound. | `LocalResponseConversationStore.init`, `conversation`, `save`; `provider-swift/Sources/ProviderCore/Server/LocalInferenceHTTP.swift` (`makeLocalInferenceApplication`) |
| Retrieval lifetime | GET reads a separate application-shared SDK object store. It has no matching count/byte eviction or TTL; objects remain in memory for that store's lifetime. A successful GET does not imply the ID is still available for continuation, and GET does not refresh history recency. Neither store is persistent. | `libs/mlx-swift-lm/Libraries/MLXLMServer/Runtime/InMemoryResponseStore.swift` (`save`, `get`); `makeLocalInferenceApplication` |
| Storage opt-out | `store: false` suppresses both new saves. It can still read an available previous history; it does not delete an older response. | `LocalChatUploadResponder.respond`; `libs/mlx-swift-lm/Libraries/MLXLMServer/Runtime/MLXOpenAIService.swift` (`createResponse`, `streamResponseFrames`) |

If continuation returns `previous_response_not_found`, resend the conversation
you retained as explicit input without the expired ID. GET may still retrieve
the old response object. See [reasoning state](../architecture/inference.md#collected-and-streaming-reasoning-state)
for parser selection and incomplete thinking, and the
[regression recipe](../developer/test.md#local-responses-and-reasoning-regressions)
for isolated helper/router checks.

## Verify

```bash
darkbloom local
curl -s http://127.0.0.1:8000/health
curl -s http://127.0.0.1:8000/v1/models -H "Authorization: Bearer $(cat ~/.darkbloom/local_token)"
```

`darkbloom status` shows the local endpoint in unified mode; in standalone mode
the process prints its listening address and the daemon-state file is not used.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `--local and --local-endpoint are mutually exclusive` | Use one flag |
| `401 Unauthorized` | Send `Authorization: Bearer $(cat ~/.darkbloom/local_token)`; the token in `local.json` is authoritative |
| `413` on a chat request with images | Body above `localInferenceMaxUploadBytes`; downscale or send fewer images |
| `darkbloom local` says no server is running but a process is listening | The listener is not a Darkbloom server (foreign process on the port) or a stale `local.json` was cleaned; restart with a free port |
| Model not in `/v1/models` | Only models with an engine-v2 adapter are advertised; `darkbloom models list` |
| Endpoint unreachable from another machine | Default bind is loopback; `--bind 0.0.0.0` and open the port, then set a reverse proxy with TLS |

## Nemotron Super

In unified mode, chat completions for `nvidia-nemotron-3.5-super` load the
managed slot through the ordinary local acquisition and run on its owner
(`provider-swift/Sources/ProviderCore/Server/NemotronSuperLocalEndpointEngine.swift`):
the controls in the table below apply, prefix reuse uses one partition per
local endpoint (an image turn reuses only checkpoints of the same images at the
same positions), and inline images are served as described below, target-only on
the default speculating owner. Other routes for that id
(`/v1/completions`, `/v1/responses`) are refused; the generic engine never
serves Super. Standalone mode (`darkbloom start --local`) does not list it.

### Experimental Nemotron Super owner fixtures

The optional `NemotronSuperLocalImageHTTP` owner hook in
`provider-swift/Sources/ProviderCore/Server/NemotronSuperLocalImageHTTP.swift`
uses the existing local authentication, body limits, JSON/SSE framing and
request-cancellation scope. Its default is absent; only the qualification
runner installs it as a hook, and it does not advertise a new model. When installed it serves
every chat request for the Super model ID: text on the owner's text binding with
its own tokenizer, and bounded inline images on the owner's image binding:
`data:image/png;base64,` or `data:image/jpeg;base64,` URIs whose content, not the
label, selects PNG or JPEG (see the
[image format reference](../reference/nemotron-super-image-formats.md)), or one
`data:video/mp4;base64,` or `data:video/quicktime;base64,` video as the only
media of the request ([managed slot](../architecture/inference.md#managed-nemotron-super-slot)).
Image prompts carry the reference `<img>`, one `<image>` per visual feature,
`</img>` span for each image; a video carries one per tubelet behind its
frame-timestamp label.

| Request control | Hook behavior |
|---|---|
| `enable_thinking` absent or `true` | Template default; `reasoning_content` streams until `</think>` |
| `enable_thinking: false` | All output is `content`, including literal markers |
| `chat_template_kwargs.force_nonempty_content` | Unterminated reasoning becomes `content`: moved in a complete response; a stream sends it as reasoning, then repeats it as `content` at the end |
| `tools`, `tool_choice` (text) | `<tool_call>` frames become validated `tool_calls`; violations return 422, or end a stream with an error event |
| `response_format` `json_object`/`json_schema` (text) | Content is withheld and validated; invalid JSON returns 422, or ends a stream with an error event |
| Contradictory controls, `logprobs`, `logit_bias`, `min_p`, `n > 1` | 400 before generation |
| A request beyond the owner's concurrency while others are in flight (text or image) | 429 once the service has decoded the request, before its prompt is planned or rendered and before any response starts; the owner serves one request unless `DARKBLOOM_NEMOTRON_SUPER_MAX_CONCURRENT` raises it, and one image at a time |
| Image input while speculation is installed | Served target-only: no speculation for that request, while text keeps speculating |
| Image whose media reservation does not fit the shared budget | 503 before decoding; nothing stays reserved |
| A media request body over 8 MiB, or visual tokens or an image prompt beyond the context | 400 before decoding; nothing stays reserved |
| A second video, a video with images, another container, a codec other than H.264 or HEVC, an undecodable movie, frames of more than 8,847,360 pixels (`4096 * 2160`, in any shape), more decoded pixels than `NemotronSuperVideoDecode.maximumDecodedPixels` or an extreme aspect ratio | 400 before any frame decodes |

Image and video requests still refuse `tools` and `response_format`; formats outside the
image format reference are refused. The host calls the hook's `drain()` before the
owner's `closeAfterDrain()`. This is not full image support or full-checkpoint
serving qualification.

The [portable component harness](../../scripts/nemotron-qualification/README.md)
exercises this hook on isolated loopback endpoints. Admission/reservation
calibration and full-checkpoint throughput remain separate gates. Cancellation
must retain media/KV and response ownership until native terminal retirement.

## Related

- [Self-route](./self-route.md) — route your *fleet* requests to your own
  provider through the coordinator instead of a local socket.
- [CLI reference](./cli-reference.md) — `start`, `local` flags and paths.
- [Beta features](./beta-features.md) — MTP and paged KV apply to local serving too.
- [`reference/configuration.md`](../reference/configuration.md) — media limits and engine variables.

## Graceful drain

After local admission closes for shutdown, a new POST receives HTTP `503`
with a structured capacity response (`invalid_request_error`) from `LocalDisconnectResponder`.
CORS headers remain present. Health checks and preflight requests still work,
and already admitted responses retain their existing owner. Retry a rejected
request after the provider is serving again.
