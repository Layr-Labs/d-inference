# Direct mode: a local OpenAI-compatible endpoint

> Last updated: 2026-09-03 · commit `5d400cf75`

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
   (`provider-swift/Sources/darkbloom/StartCommand.swift`, `Start.run`).

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

   `--port` defaults to `8000`, `--bind` to `127.0.0.1`. Before serving,
   `Start.runLocalServe` (`provider-swift/Sources/darkbloom/StartCommand+Modes.swift`)
   loads or creates the API token, filters the chosen models to those with an
   engine-v2 adapter (exit 1 with `No engine-v2-capable models available to
   serve.` if none remain), waits up to 5 s for the socket to bind (`Local
   server failed to bind <addr>:<port> within 5s` otherwise), writes the
   discovery file and holds a fan-control lease while running
   ([fan control](./fan-control.md)). Ctrl-C stops it and removes the
   discovery file.

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
| Directory override | `DARKBLOOM_LOCAL_DIR` replaces `~/.darkbloom` for both files | `LocalEndpoint.directory` |
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
| GET | `/props`, `/metrics` | `/metrics` adds per-slot MTP posture lines (`provider-swift/Sources/ProviderCore/Server/LocalMetricsResponder.swift`) |
| POST | `/v1/chat/completions`, `/chat/completions` | Streaming and non-streaming; inline media; **32 MiB** body cap |
| POST | `/v1/chat/completions/batch` | Same cap |
| POST | `/v1/completions`, `/completions`, `/completion` | Text; upstream 2 MiB body ceiling |
| POST | `/v1/responses`, `/responses` | Responses API, in-memory store |
| GET / POST | `/v1/responses/:response_id`, `/v1/responses/:response_id/cancel` | |
| POST | `/tokenize`, `/detokenize`, `/apply-template` | Tokenizer utilities |
| POST | `/v1/embeddings`, `/embeddings`, `/embedding` | Registered upstream; the provider configures no embedding model, so they return an OpenAI error envelope with code `embeddings_not_configured` |

The cap `localInferenceMaxUploadBytes = 32 * 1024 * 1024`
(`provider-swift/Sources/ProviderCore/Server/LocalChatUploadResponder.swift`)
matches the coordinator WebSocket frame allowance. Per-image, per-video and
per-audio limits are the same as fleet serving and are configured through the
variables in [`reference/configuration.md`](../reference/configuration.md).
`max_tokens` defaults to the scheduler's default when a request omits it.

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
| `413` on a chat request with images | Body above 32 MiB; downscale or send fewer images |
| `darkbloom local` says no server is running but a process is listening | The listener is not a Darkbloom server (foreign process on the port) or a stale `local.json` was cleaned; restart with a free port |
| Model not in `/v1/models` | Only models with an engine-v2 adapter are advertised; `darkbloom models list` |
| Endpoint unreachable from another machine | Default bind is loopback; `--bind 0.0.0.0` and open the port, then set a reverse proxy with TLS |

## Related

- [Self-route](./self-route.md) — route your *fleet* requests to your own
  provider through the coordinator instead of a local socket.
- [CLI reference](./cli-reference.md) — `start`, `local` flags and paths.
- [Beta features](./beta-features.md) — MTP and paged KV apply to local serving too.
- [`reference/configuration.md`](../reference/configuration.md) — media limits and engine variables.
