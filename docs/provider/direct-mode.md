# The local API: an OpenAI-compatible server on your Mac

> Last updated: 2026-11-08

Your Mac's models as an OpenAI-compatible HTTP server for your own tools,
served two ways: **Only me** (`darkbloom start --local`: no coordinator, no
earnings) or **Both, me first** (`darkbloom start --me-first`: beside the
Darkbloom network, which pauses while you use it; `--no-me-first` keeps the two
sharing the Mac). For anyone whose own tools should call the models this Mac
hosts. A request this Mac serves never leaves it and is never billed. With an
account key saved, one it can't take can go on to your other Macs, free, and
with `my-macs-first` to the Darkbloom network, billed
([the local router](#when-this-mac-cant-take-a-request-the-local-router)). In a terminal,
`darkbloom start` asks once which you want ([Use your Mac yourself,
first](./local-first.md)); `darkbloom --opencode` also sets OpenCode up
([Use it from OpenCode or Hermes](./local-first.md#use-it-from-opencode-or-hermes)).

Chat completions accept `stop` as a string or string array and pass explicit
`min_p` to the engine. JSON and SSE responses include requested captured
logprobs and reasoning-token usage when available, using the same HTTP wiring
as a pair's local API. Capture still depends on the selected native
runtime: an unsupported cluster mode returns `logprob_capture_unsupported`
before reservation. Shared API tests do not establish native feature support.
See [inference and logprob admission](../architecture/inference.md).

## Prerequisites

- Provider installed ([installation](./installation.md)); no account or
  `darkbloom login` is needed for **Only me**.
- A model with an engine-v2 adapter (gpt-oss, gemma-4 families);
  `darkbloom models list`. For either choice, `darkbloom start`'s model list
  also downloads the ones you pick; without a model it can serve, the start
  ends with ``No model to serve yet. See them: `darkbloom models catalog`. Get
  one: `darkbloom models download <id>`, then `darkbloom start`.``
- A free port: this Mac's one local API port, `[local] port`. The first start
  that serves a local API, whichever way it starts, keeps the port this Mac's
  local API already uses (`8000` on a Mac updated from 0.10.10), or on a Mac
  with none chooses the first free port from 8001, and saves it; every later
  start uses it. `--port` picks another and
  saves it.

## Steps

1. Pick how this Mac serves. `--local` and `--me-first` (or `--local-endpoint`)
   are mutually exclusive; `darkbloom start` refuses the combination
   (`provider-swift/Sources/darkbloom/Start/StartCommand.swift`, `Start.validate`,
   `Start.run`).

   | Choice | Command | Coordinator | Models come from | Earns |
   |---|---|---|---|---|
   | Only me | `darkbloom start --local` | not contacted | `StandaloneServer`'s own slot cache (`provider-swift/Sources/ProviderCore/Server/StandaloneServer.swift`) | no |
   | Both, me first | `darkbloom start --me-first` (older flag: `--local-endpoint`) | connected as usual | the live `ProviderLoop` slots — weights load once and local + fleet requests share one continuous-batching engine and KV budget (`provider-swift/Sources/ProviderCore/ProviderLoop+LocalEndpoint.swift`) | yes, for fleet traffic while you are not using the Mac (step 3) |

2. Start **Only me**. It asks for your models (the list downloads the ones you
   pick) and the memory setting, as the other choices do, then serves in the
   background: the provider LaunchAgent runs `darkbloom start --foreground
   --local --port <n> --bind <address> --model <id>…` (`Start.launchOnlyMeService`,
   `provider-swift/Sources/darkbloom/Start/StartCommand+OnlyMe.swift`), which
   starts at login, has the crash-recovery watchdog, updates itself (a check 5
   minutes after it starts, then every 30 minutes; `StandaloneServer+AutoUpdate`)
   and unloads models idle past the memory setting
   (`StandaloneServer+IdleUnload`). The provider that served before is drained
   first; when it served Darkbloom, the start says
   ``Darkbloom network serving stops: this Mac serves only you from now on
   (`darkbloom start --me-first` serves Darkbloom and you).`` Without a
   terminal nothing is asked: the models you last chose that are still on this
   Mac, else every one it can serve. `--here` serves in the current terminal
   instead (no LaunchAgent), until Ctrl-C:

   ```bash
   darkbloom start --local                              # the model list, then the memory question
   darkbloom start --local --model <model-id>           # only this one (repeatable)
   darkbloom start --local --port 8080 --bind 0.0.0.0   # another port / every interface
   darkbloom start --local --here                       # in this terminal, for this session
   ```

   The port is this Mac's one local API port (`LocalAPIPort`,
   `provider-swift/Sources/ProviderCore/Config/LocalAPIPort.swift`):
   `[local] port`, else the port this Mac's local API already uses (its running
   API's, else its installed service's: `8000` on a Mac updated from 0.10.10),
   else the first free port from 8001 (from the build's `defaultLocalPort`,
   never `8000`; a dev build starts from its own, see
   [Dev build identity](../operations/provider-release.md#dev-build-identity)),
   saved the first time; a `--port` you name is saved too. `--bind` defaults to
   `127.0.0.1`. Before serving,
   `Start.runLocalStandalone` (`provider-swift/Sources/darkbloom/Start/StartCommand+Modes.swift`)
   loads or creates the API token, filters the chosen models to those with an
   engine-v2 adapter (exit 1 with ``No model to serve yet. See them: `darkbloom
   models catalog`. …`` if none remain), and preloads the selected models before listening
   when `[backend] startup_preload` is enabled (the default). When a load is
   short of headroom the server first releases retained paged KV segments and
   drops the MLX buffer cache once, then evicts the least recently used idle
   slot (`StandaloneServer.ensureMemoryHeadroomForLoad`). Resident models share
   the KV budget as [KV slot grants](../architecture/hardware-support.md#kv-slot-grants)
   describes; a load that would leave any model below its minimum grant fails
   with HTTP 503 (`StandaloneServer.resliceKeepsSlotsServiceable`). The explicit
   `preload_models` list takes precedence; slot and memory limits can skip a
   model, which still loads on request. A local GLM qualification load reads its
   weights for its own per-file SHA-256 verification and the tensor reads only;
   that verification is the artifact hash, with no separate weight-hash passes
   (`GLM5NextManagedLoad.verifiedArtifactSHA256`). Only me's preload does not run the
   coordinator-serving one-token startup self-test. Each preloaded model does run
   the excluded [shape warmup](../architecture/inference.md#model-startup-calibration)
   before the listener opens: a short shader-cache probe, plus the shape cells
   after a new install or a macOS or MLX kernel update. The 5-second sweep tick
   warms a deferred, lazily loaded or MTP-upgraded engine once the server is
   idle; a request that arrives first preempts it and may still compile Metal
   kernels. `DARKBLOOM_TTFT_SHAPE_WARMUP=0` disables the warmup. Ctrl-C during preload cancels startup
   without opening the listener. It then waits for the socket to bind (`waitUntilBound`,
   bounded by the local bind wait in [runtime constants](./cli-reference.md#runtime-constants);
   otherwise it stops with ``This Mac's local API couldn't listen on
   127.0.0.1:8001: another program may use port 8001. Free it, or run
   `darkbloom start --port 8002`.``, naming the next free port), writes the
   discovery file and holds a fan-control lease while running
   ([fan control](./fan-control.md)). `darkbloom stop` stops it and removes
   the discovery file. With `--here`, Ctrl-C does the same, and so does closing
   the terminal window ([stop signals](./cli-reference.md#graceful-stop-and-restart)),
   unless the command was started with hangups ignored (for example under
   `nohup`), in which case it keeps serving. `--here` stops the background
   service while it runs and says so (``Darkbloom network serving stops while
   this runs; it starts again with `darkbloom start`.``); when it ends it says
   that nothing serves now and how to serve again.

3. Or start **Both, me first**. This goes through the normal LaunchAgent path,
   so the flags are recorded in the plist and survive reboots:

   ```bash
   darkbloom start --me-first
   ```

   The provider daemon starts the local server in a child task once it is
   running, on the same port as Only me. If the port is busy the daemon logs
   `Local OpenAI endpoint did NOT bind on <host>:<port> (port already in use?)`
   and keeps serving the fleet, and its state records why
   (`DaemonState.localAPIFailure`, cleared once the API listens or stops), so
   `darkbloom status` and `darkbloom local` say ``the local API isn't up: port
   8001 is in use (`darkbloom start --port 8002`)`` instead of "network only".
   The discovery file is written only after the
   provider's own socket is bound, never on a probe another process could
   answer (`ProviderLoop.onLocalEndpointBound`). With Both, me first a local
   request first loads the model if needed and then holds a reservation until
   its stream ends, so the coordinator's advertised capacity reflects local
   load too.

   That reservation is your use of the Mac: by default ("me first") the
   provider stops taking Darkbloom requests from the moment one of your
   requests holds a model, and takes them again once none of your requests
   has run for `[local] me_first_idle_minutes` (2 minutes by default).
   Darkbloom requests already running finish. Model lists, health checks,
   `/metrics`, the tokenizer utilities and requests refused before they hold
   a model do not count. This is on for every Mac that serves Both, me first,
   including the desktop app's "Alongside the network". To share the Mac
   between your requests and Darkbloom's, as before, start once with
   `--no-me-first`, which saves `me_first = false` under `[local]` in
   `provider.toml`; `--me-first` turns it back on
   ([configuration](../reference/configuration.md#local-first-use-local),
   [owner pause](../architecture/owner-pause.md)).

4. Get the address and key:

   ```bash
   darkbloom local          # address, key, how this Mac serves, a curl example
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
| Key file for tools | A tool that reads the key from a file instead of keeping a copy (OpenCode's `{file:}`, Hermes' `key_cmd`) uses the file holding exactly the key of the server on that port: `local_token`, or `cluster_local_token` for a pair's API. Both files hold only the key and are replaced atomically, never partly written. A start without `--opencode` / `--hermes` says in one line when a tool set up for Darkbloom reads another file than `local_token` (or points at another address), and changes nothing. See the [config writers](../architecture/tool-integrations.md) | `LocalEndpoint.keyFile(forPort:)`, `LocalEndpoint.tokenPath()`, `provider-swift/Sources/ProviderCore/Service/AtomicFile.swift` (`AtomicFile.write`) |
| `--bind 0.0.0.0` | Advertised `base_url` uses `127.0.0.1`; other hosts use the machine's address, and `darkbloom local` prints its Bonjour URL on a `network:` line. [`darkbloom cluster local`](./two-mac-cluster.md#serving-locally-only) binds the cluster's API this way by default | `LocalEndpoint.Info.init`, `Local.networkURL` |
| `--no-auth` | No token check; `api_key` is empty in the discovery record. The [local router](#when-this-mac-cant-take-a-request-the-local-router) then passes nothing on and never uses the account key | `LocalInferenceHTTPConfig.authToken == nil`; `LocalRouterConfig.localKeyRequired` |

`LocalAuthResponder` (`provider-swift/Sources/ProviderCore/Server/LocalAuthResponder.swift`)
is the outermost layer: `OPTIONS` preflights, `GET /health`, `GET /v1/health`
and `GET /` pass without a token; everything else needs
`Authorization: Bearer <token>`, compared in constant time; failures return
`401` with an OpenAI-style error envelope and `Access-Control-Allow-Origin: *`
so browser clients can read it. There is no rate limiting and no TLS: keep the
default loopback bind, or put a reverse proxy in front before exposing it.

## When this Mac can't take a request: the local router

The local API routes your requests the way the iPhone app does: this Mac first,
then your other Macs, then the Darkbloom network only if you chose so. The
`[local] route` setting ([configuration](../reference/configuration.md#local-first-use-local))
and a saved account API key decide where a request goes when this Mac can't
take it (`LocalRouter`, `provider-swift/Sources/ProviderCore/Server/LocalRouter*.swift`):

| `[local] route` | When this Mac can't take the request |
|---|---|
| `this-mac` (the default without an account key) | This Mac's own answer; nothing leaves the Mac |
| `my-macs` (the default once a key is saved) | Passed to the coordinator with `X-Darkbloom-Route: self`: only your Macs answer, free |
| `my-macs-first` | Passed to the coordinator with `X-Darkbloom-Route: prefer`: your Macs first (free), then the network, billed to your balance. The coordinator picks among the Macs that can take the request now, so a busy Mac of yours doesn't hold it while another Mac, yours or the network's, can take it. `prefer` reserves the price up front even when one of your Macs answers: on any `402` (no balance, or the key's spend cap), the request is sent once more with `self` (your Macs only, free, never spending) |

**Requests from other machines never use the paid network; they can use this
Mac and your other Macs.** A local API that listens beyond loopback (a pair's
Both, me first or Only me API on `0.0.0.0`, or any `--bind`) can be reached by
anyone there with its key, and a request this Mac can't take would go on with
this Mac's account key. So the router decides per connection, from its TCP
peer and never from a header (`LocalHTTPClient`): a peer that isn't loopback
(`127.0.0.0/8`, `::1`, or an IPv4 loopback peer seen as `::ffff:127.x.y.z`)
gets `my-macs-first` as `my-macs` (`self` only, never `prefer`), and its
`/v1/models` lists no network model. Programs on this Mac keep the route as
saved. A connection's peer is read once, when it opens, and nothing is added to
this Mac's own path.

The route is read when the local API starts (a change needs a restart). The
key is read once, by the first request that needs it, and kept in memory:
`darkbloom route key` tells a running local API when it saves or removes the
key (a Darwin notification, `<keychain prefix>.route-key-changed`), and the
next request reads it again, with no restart.

- **Save the key:** `darkbloom route key` (hidden input, or `--stdin`), from
  the Darkbloom console. It is checked once with `GET /v1/models` and
  `X-Darkbloom-Route: self`, then kept in this Mac's Keychain. It is never
  printed, logged, or written to `provider.toml`, `local.json` or a tool's
  config, and a running local API uses it from its next request: no restart.
  `darkbloom route key --remove` keeps every request on this Mac again.
- **Reading the key never asks.** The local API reads the key without a
  Keychain dialog, so a request never waits on one. When the Keychain won't
  hand the key over without asking (a locked keychain, or a new local build
  the item doesn't trust yet), the local API says so once in its log and keeps
  requests on this Mac; a failed read isn't kept, so the next request tries
  again. Run `darkbloom route key` again to let a new build read it. Signed
  builds read the data-protection Keychain, which never asks. Unsigned and
  ad-hoc builds keep the key in the login keychain, and only that read turns
  off the process-wide `SecKeychainSetUserInteractionAllowed` switch, for its
  moment.
- **Without a local key (`--no-auth`) nothing is passed on.** Anything that
  reaches the port is then a client, a web page included, so the router
  serves this Mac only, never reads the account key and never dials the
  coordinator, whatever the route. The start banner, `darkbloom local` and
  `darkbloom route key` say so.
- **What passes a request on:** only this Mac's own `404` (it doesn't serve
  the model), `429` (its queue is full) or `503` (draining, an add-on hold, a
  refused load, no capacity), before any byte reached the client. A client
  error (`400`, `413`, `422`), a wrong local key (`401`), a cancel, an engine
  failure and anything after the first streamed byte stay this Mac's answer.
  The routed paths are chat completions, completions and responses; every
  other route is this Mac's only. A `404` for a public alias of a build this
  Mac serves (the name the coordinator lists it under) is first answered by
  this Mac, under the build's own id.
- **What is sent:** the request body as the client wrote it, with the account
  key and the route header. The client's own `Authorization` and
  `X-Darkbloom-Route` are never forwarded, so a tool can't choose a billed
  route. A streamed answer is passed through chunk by chunk as it arrives.
- **A client that leaves stops the request at the coordinator too,** so the
  network doesn't go on generating, billed, and your other Mac doesn't stay
  busy. A reset connection stops it at once, even while nothing flows (a
  long prompt). A normal close reads as a half-close, which the local API
  allows, as for this Mac's own streams, so it stops the request when the
  next chunk can't be delivered: mid-stream within a chunk or two, during a
  long prompt at its first token.
- **What comes back:** the coordinator's answer with its status, body and
  `Retry-After` as sent, plus `X-Darkbloom-Served-By: darkbloom` and
  `X-Darkbloom-Route-Used: self|prefer`. This Mac's own answers carry
  `X-Darkbloom-Served-By: this-mac`. These answers are this Mac's own words:
  - a `402` from `prefer` that `self` couldn't turn into an answer keeps its
    status, type, code and `Retry-After`. Its message starts with
    `No balance for the network fallback:` when Darkbloom's `error.type` is
    `insufficient_funds`, and with `Network fallback refused:` for any other
    reason (the key's spend cap, a promotion's limit), followed by
    Darkbloom's own message;
  - a refused account key is `502` `account_key_refused` (not the client's
    `401`);
  - an unreachable coordinator is `502` `darkbloom_unreachable`;
  - an error body that can't be read is `502` `darkbloom_error_unreadable`;
  - a body over the local API's limit is `413`, before anything else.
- **Never back to this Mac:** the coordinator can't leave one Mac out of a
  `self` request, and a `self` request to a Mac that can't take work waits
  120 s for `429 machine_busy`. So on a Mac that also serves Darkbloom
  (Both, me first, or a pair through Darkbloom), when this Mac serves the
  requested model (or a build of the alias it names), the router first asks
  the coordinator's `self` view of that one model (`GET /v1/models/<id>`). With
  no other Mac of yours serving it, `my-macs` answers this Mac's status with
  code `this_mac_only`, and `my-macs-first` answers `prefer`'s `402` without
  the `self` retry. Only me (`--local`, `cluster local`) never takes coordinator
  work, so it never asks, and neither does a pair's API without a cluster approval
  (`start --local --distributed`): even when its leader registers with the
  coordinator, it is a control-only member that hosts no pair slot, and the
  `self` view doesn't count it.
- **Timeouts:** 10 s to put a request on the wire, then up to 5 minutes
  without a byte, with no limit on a stream's length. With `my-macs`, a `self`
  request for a model only busy Macs of yours serve queues at the coordinator
  for up to 120 s before `429 machine_busy`. `my-macs-first` doesn't wait on a
  busy Mac of yours while another Mac, yours or the network's, can take the
  request now. When none can, the coordinator queues the `prefer` request too,
  for up to 120 s before `429 machine_busy`, and keeps it queued while you
  have a Mac serving the model. Model lists from the coordinator wait at most
  3 s.
- **A plain `ws://` coordinator URL** (a test coordinator) sends the account
  key without TLS, as the provider already sends its own token there.
- **`max_completion_tokens`:** every local API serves a chat request that
  names only `max_completion_tokens` (what newer OpenAI clients send) with
  that value as `max_tokens`; with both, `max_tokens` wins
  (`LocalChatRequest`, `provider-swift/Sources/ProviderCore/Server/LocalChatRequest.swift`).
  Passed on, the body goes unchanged, as the coordinator reads all three names.
- **Cost on this Mac's path:** none of the above runs for a request this Mac
  serves. It stays in the process, its body is collected once (the engine
  collects it anyway) and not parsed by the router, no Keychain read happens,
  and the engine's response, streamed or not, is returned as it is with one
  header added. The upstream client is made by the first request that needs
  the coordinator (a pass-on, or a model list with a route that dials out). A
  CPU benchmark (`LocalRouterOverheadTests`) measures a few microseconds added
  per request.

`GET /v1/models` (and `/models`) answers this Mac's models first, then, with
an upstream route, your Macs' models (`self`), then with `my-macs-first` the
public list, each model once. A public alias of a build this Mac lists is that
build, listed once as `this-mac`: on a Mac that also serves Darkbloom, the
coordinator's `self` list names this Mac's own builds by their aliases.

| Field | Value |
|---|---|
| `owned_by` | `this-mac`, `my-macs` (your other Macs, free) or `darkbloom` (the network, billed). Before the router, this Mac's entries said `local` |
| `context_length`, `max_model_len` | This Mac's engine for its resident models (a pair's leader: the context the pair's mode serves); else the Darkbloom catalog (`/v1/models/catalog`), by model or by the alias's build; omitted when unknown |
| `max_output_length` | This Mac's loaded models: their context window too, as a request's prompt and output together may fill it ([each model's whole window](#each-models-whole-window-on-this-mac)). A pair's leader lists the output the pair's mode serves, which the pair holds every `max_tokens` to (it refuses a larger one, `output_too_long`), as its slot reports to the coordinator (`ProviderLoop.localModelLimits`). Else the catalog's; omitted when unknown |
| `input_modalities` | What a request may carry, as this Mac's engine serves the model, loaded or not: `["text", "image"]` for a model it serves with vision (`is_vision`, which the coordinator routes images on), else `["text"]`. On a pair's leader, the media the pair takes in its mode: `["text", "image", "video"]` for GLM-5.3-Flash and Qwen 3.8 27B in tensor parallel, `["text", "image"]` on the GLM and MiMo image candidate profiles, `["text"]` for every other pair, and nothing until its slot is up. Your Macs' and the network's models keep the coordinator's, when its list has one. Reasoning isn't listed: the catalog says which models reason (`provider-swift/Sources/ProviderCore/Server/LocalInputModalities.swift`, `LocalInputModalities`) |
| `name` | The coordinator's or the catalog's display name for your Macs' and the network's models |

The coordinator's lists are cached for 30 s and the catalog for 5 minutes; a
coordinator that can't be reached leaves this Mac's models alone in the list
and is asked again after 10 s. With `this-mac`, the list never leaves the Mac.
Integrations (OpenCode, Hermes) read this list and name each model with where
it runs: `this-mac` is `(this Mac)`, or `(your pair)` on a pair's API (the
pair's model, whatever the pair's size); `my-macs` is `(your Macs)`, and
`darkbloom` is `(Darkbloom network, billed)`.

### Each model's whole window, on this Mac

A model this Mac has loaded takes a prompt and its answer within its context
window, the `context_length` above: the model's own, from its config, except
GLM-5.3-Flash and Nemotron Super, which are held to 262,144 tokens on one Mac.
It writes up to what the prompt leaves of the window: up to 32,768 tokens when
the request names no `max_tokens` (Diffusion Gemma keeps its generation
config's `max_new_tokens`, 256 when it names none), and up to the rest of the
window when `max_tokens` asks for it. A larger `max_tokens` is cut to fit, on
every model, and the answer ends with `finish_reason: length` if it gets there;
only a prompt that leaves no room is refused. Within the window, this Mac's
memory decides: each request reserves room for its prompt and its output when
it starts. The answer says which bound a request met
([refused request shapes](#refused-request-shapes)): the window (400
`context_length_exceeded`, in words that name it) or this Mac's memory (503),
both before any SSE header, streamed or not, except a request that first queued
for memory and then waited out the 120 s admission lease or a full paged pool's
requeues, which still ends a streamed answer with an error event; the router
passes a 503 on when a route dials out.

Each model's input is in the list too (`input_modalities`, above), and for a
model served here (this Mac, or the pair it leads or relays to) the engine's
word is the one the tools follow: `start --opencode` and `--hermes` offer images
for it exactly when its engine takes them, whatever the catalog says. A Gemma 4
pair, which serves text alone, gets none (an image would be refused with 400);
MiMo V2.6 on one Mac gets them, though its catalog row lists text only. For your
other Macs' and the network's models, the catalog decides.

<!-- pending R-FULL: GLM-5.3-Flash and Nemotron Super at their 1,048,576-token configs on one Mac; video and audio input for the models this Mac serves them for, in this list; a memory refusal that names how many tokens this Mac holds; the same for direct use through the network; OpenRouter is separate. -->

## Routes

The responder stack is auth → the local router → CORS → `/metrics` →
chat-upload interception → the upstream `MLXLMServer` router
(`provider-swift/Sources/ProviderCore/Server/LocalInferenceHTTP.swift`,
`makeLocalInferenceApplication`). Routes are registered in
`libs/mlx-swift-lm/Libraries/MLXLMServer/HTTP/MLXServerApplication.swift`
(`buildRouter`):

| Method | Path | Notes |
|---|---|---|
| GET | `/health`, `/v1/health` | Unauthenticated |
| GET | `/models`, `/v1/models` | Advertised catalog, not just resident models, merged by the [local router](#when-this-mac-cant-take-a-request-the-local-router) |
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
A request that omits `max_tokens` may write up to 32,768 tokens (`SlotSizingSnapshot.defaultOutputTokens`, as on a pair), cut to the context window its prompt leaves; a `max_tokens` may ask for the rest of the window ([each model's whole window](#each-models-whole-window-on-this-mac)).

For Chat/Completions streaming, inspect every SSE event for `error`, even after
HTTP 200. A late generation failure ends with a sanitized error chunk and
`finish_reason: "error"`, without a success `[DONE]`; the HTTP transfer closes
normally. Pre-header errors retain their HTTP status, and client cancellation
still cancels generation. Responses uses `response.failed` for late failures.
The provider chat-upload interceptor selects the SDK service's HTTP framing
policy (`LocalChatUploadResponder.respond` and `MLXOpenAIService.streamChatCompletionFrames`).
A failed required tool call is still a failure; no argument repair or fabricated
call is performed. On a [two-Mac cluster](./two-mac-cluster.md) the leader's
local API ends such a stream with the same error chunk. This holds also when
the provider rejects the output mid-stream (a forced `tool_choice` answered
with text, a streamed tool call that fails validation) while the pair is still
finishing the cancelled request
(`provider-swift/Sources/ProviderCore/Server/Distributed/DistributedHTTPEventStream.swift`,
`DistributedHTTPEventStream`).

### A long prompt's progress

A long prompt takes minutes before its first token: a 255K-token prompt took 9
minutes on an M3 Ultra. While it is processed, a streamed request (chat
completions or Responses) gets an SSE comment every 5 seconds, from the moment
the engine accepts the request until its first token:

```text
: prefill in progress, 254953 prompt tokens
```

OpenAI clients ignore comments; to curl and to a client that reads the stream
they say the request is still working through its prompt, and connections that
end after a silence stay open. The number is the prompt's tokens as the engine
counts them, after the chat template and with any media. Once the engine
reports how much of the prompt it has computed, the comment gives that count
instead, `: prefill <done>/<total> tokens`. Today's engines report it only when
the prompt is done, so a long prompt reads "in progress" until its first token,
which ends the comments. A prompt done within 5 seconds gets none. The local
router and a pair member's relay pass them on unchanged. On a pair's own API
(`darkbloom cluster local`) the comment takes the place of the leader's 500 ms
keep-alive probe every 5 seconds (`LocalPrefillProgress`,
`provider-swift/Sources/ProviderCore/Server/LocalPrefillProgress.swift`).

Each streamed request has one timer, from its first frame to its first token,
and nothing runs per token. A request that isn't streamed gets nothing until its
answer, as HTTP has no interim bytes: give such a client a timeout of minutes
for a long prompt (the OpenAI SDKs wait 10 minutes by default), or stream.
Before the engine accepts a request, nothing is sent either, not even the
headers: while the model loads for it, while it waits for a pair's lane, and
while its prompt is tokenized. A client that limits how long it waits for
headers must allow a cold model load.

### Refused request shapes

The chat routes and Responses input answer these shapes with an OpenAI error
envelope, the same on one Mac and on a [two-Mac cluster](./two-mac-cluster.md):

| Request | Answer | Source |
|---|---|---|
| On one Mac, a prompt that fills the model's context window: the context it advertises (GLM-5.3-Flash and Nemotron Super: 262,144; MiMo V2.6, Qwen4, Flint, Bonsai 9B and Diffusion Gemma: their configs'), else its model's own (Gemma 4, Qwen 3.5, 3.6 and 3.8, GPT-OSS, Nemotron Lightning) | HTTP `400`, code `context_length_exceeded`, before the engine and before any SSE header: `The prompt fills this model's context window of <N> tokens, leaving no room for an answer. Shorten the prompt or start a new conversation.` A `max_tokens` beyond what a shorter prompt leaves is cut to it instead, on every model, and the answer ends with `finish_reason: length` if it gets there | `provider-swift/Sources/ProviderCore/Inference/Engine/Bridge/EngineV2Bridge+Translation.swift` (`outputTokens(requested:promptTokens:)`, `promptExceedsContextMessage`) |
| On one Mac, a request its memory can't hold now: the shared KV reservation of a contiguous slot, the engine's own admission of a paged slot (the automatic backend; it refuses one that can never fit and queues the rest), or the whole Mac's request limit | HTTP `503` before any SSE header, streamed or not: `This Mac's memory can't hold this request right now. Lower max_tokens or shorten the prompt (or send less media), or retry when this Mac's other requests finish.` The local router passes it on when a route dials out. A request a paged slot queued and then couldn't admit (the 120 s admission lease, or the pool full through its requeues) fails later: a streamed answer, whose head is already sent, ends with an error event, and a non-streamed one gets 503 (after the lease, with the older `Provider capacity is temporarily unavailable.`) | `provider-swift/Sources/ProviderCore/Inference/Engine/Bridge/EngineV2Bridge+Submission.swift` (`submitTokenized`); `provider-swift/Sources/ProviderCore/Server/StandaloneServer+HTTP.swift` (`CORSResponder`) |
| A content part whose `type` is none of `text`, `input_text`, `output_text`, `image_url`, `input_image`, `video_url`, `input_audio` (for example `input_file`, `input_video`, `refusal`) | HTTP `400` before model acquisition or SSE headers: `Content part type "<type>" is not supported. Send text, image_url, video_url or input_audio parts.` The type is shown with at most 64 of its letters, digits and `_.-:/`. Models without native audio still refuse `input_audio` | `libs/mlx-swift-lm/Libraries/MLXLMServer/Runtime/OpenAIRequestValidation.swift` (`OpenAIRequestValidationError.unsupportedContentPart`) |
| `response_format` `json_object`/`json_schema` whose answer stopped at `max_tokens` before it was complete (a reasoning model can spend the whole budget thinking) | HTTP `422`: `The output was cut off by max_tokens before the structured (response_format) answer was complete. Raise max_tokens or lower the reasoning effort, and retry.` Invalid JSON at a natural stop keeps its `422` with the closed internal-failure message. GLM-5.3-Flash validates its withheld JSON answer itself (`GLM5NextResponseFormat`) and answers a truncated one with that closed `422` | `libs/mlx-swift-lm/Libraries/MLXLMServer/Runtime/MLXOpenAIService.swift` (`MLXOpenAIServiceError.responseFormatCutOffByMaxTokens`); `provider-swift/Sources/ProviderCore/Server/StandaloneServer+HTTP.swift` (`CORSResponder`); `provider-swift/Sources/ProviderCore/Inference/Prompting/GLM5NextResponseFormat.swift` (`validatedContent`) |
| GLM-5.3-Flash with images or video and `response_format` `json_object`/`json_schema` or a required or named `tool_choice` | HTTP `400` `Invalid inference request.` (failure code `invalid_request`) before any media decode: only the text path withholds and validates such an answer or call. Hidden reasoning (`reasoning.exclude: true`, `include_reasoning: false`, `thinking.display: "omitted"`) is served with media too, its reasoning withheld | `provider-swift/Sources/ProviderCore/Inference/Engine/Scheduler/MultiModelBatchSchedulerEngine.swift` (`prepareCompletion`); `provider-swift/Sources/ProviderCore/Inference/Prompting/GLM5NextPromptPolicy.swift` (`withholdsOutput`, `withholdsReasoning`) |
| An image or video the model's processor refuses: for Qwen 3.5 and 3.8 a side below `patch_size × merge_size` (32 pixels) or an aspect ratio above 200:1, which it does not upscale; a video without a decodable track; more images or videos than the processor takes | HTTP `400` `Invalid media input.` (failure code `invalid_media`), before the vision tower or any native reservation, never the retryable `503` | `provider-swift/Sources/ProviderCore/Inference/Vision/EngineV2VisionPrefill.swift` (`clientFault(for:)`) |
| A video whose reader fails on GLM 5.3, MiMo V2.6, Qwen4 or Nemotron Super after its metadata checks passed, or whose audio track's reader fails on MiMo V2.6 | The provider decodes the track once more with a new reader. If that succeeds, the request is served. If it fails again with a decoder, hardware or interruption code, HTTP `503` (failure code `capacity`), which a coordinator retries on another provider; any other second failure is HTTP `400` `Invalid media input.` (failure code `invalid_media`). Each failed pass logs a WARN `engine_health` event, `video_reader_failed` or `audio_reader_failed`, with the reader status and error codes only | `libs/mlx-swift-lm/Libraries/MLXLMCommon/VideoReaderFailure.swift` (`VideoReaderRetry`); `provider-swift/Sources/ProviderCore/Inference/Vision/EngineV2VisionPrefill.swift` (`clientFault(for:)`); `provider-swift/Sources/ProviderCore/Inference/Vision/MiMo/MiMoV26EncodedMediaIngress.swift` (`outwardFailure`); `provider-swift/Sources/ProviderCore/Server/NemotronSuperLocalImageHTTP.swift` (`SuperHTTPErrors.map`) |
| A Nemotron Super video whose decoding outlasts its decode allowance (5 s, then 2 ms a frame and 4 ns a coded pixel, at most 120 s of wall time waiting on the decoder), as on a slow or loaded Mac | HTTP `503` (failure code `capacity`), which a coordinator retries on another provider. The video's own limits (coded frame size, frame grid, source frames, control markers, decoded pixels) stay HTTP `400` `Invalid media input.` (failure code `invalid_media`) | `provider-swift/Sources/ProviderCore/Inference/Vision/NemotronSuperVideoDecode.swift` (`decodeAllowance`); `provider-swift/Sources/ProviderCore/Server/NemotronSuperLocalImageHTTP.swift` (`SuperHTTPErrors.map`) |

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

Flint (`model_type: flint`) reads the same reasoning controls on Chat
Completions and Responses. Effort values and thinking switches are accepted
with no effect; `reasoning.exclude: true`, `include_reasoning: false` or
`reasoning.enabled: false` omit reasoning from the response while its tokens
are still counted. `stop` and JSON `response_format` apply to the answer after
reasoning. See [Native Flint](../architecture/inference.md#native-flint).

## Verify

```bash
darkbloom local
BASE=$(darkbloom local --json | jq -r .base_url)    # http://127.0.0.1:<port>/v1
curl -s "${BASE%/v1}/health"
curl -s "$BASE/models" -H "Authorization: Bearer $(darkbloom local --json | jq -r .api_key)"
```

`darkbloom status` says how this Mac serves, for both choices
(`Serving: only you, on this Mac …` or `Serving: Darkbloom and you, me first …`),
from the running provider's `~/.darkbloom/daemon-state.json`, which Only me
writes too (`StandaloneServer.startLifecycleControl`).

## Troubleshooting

| Symptom | Fix |
|---|---|
| `--local and --local-endpoint are mutually exclusive` | Use one flag |
| `401 Unauthorized` | Send `Authorization: Bearer $(cat ~/.darkbloom/local_token)`; the token in `local.json` is authoritative |
| `413` on a chat request with images | Body above `localInferenceMaxUploadBytes`; downscale or send fewer images |
| `darkbloom local` says no server is running but a process is listening | The listener is not a Darkbloom server (foreign process on the port) or a stale `local.json` was cleaned; restart with a free port |
| ``the local API isn't up: port 8001 is in use (`darkbloom start --port 8002`)`` (`status`, `local`) | Another program listens on this Mac's local API port. Free it and run `darkbloom restart`, or run the command it names: the new port is saved, and the start names each tool still set up for the old one: `darkbloom --opencode` or `--hermes` points it at the new one |
| Model not in `/v1/models` | Only models with an engine-v2 adapter are advertised; `darkbloom models list` |
| Endpoint unreachable from another machine | Default bind is loopback; `--bind 0.0.0.0` and open the port, then set a reverse proxy with TLS |
| A DevNet build (`darkbloom-dev`) fails a request for a model it hasn't loaded with ``The production Darkbloom on this Mac holds this Mac's GPU: … no model of this build loads here until production stops serving`` | The production app serves on this Mac, and two models don't fit one Mac's memory: a DevNet build refuses each cold load at its start, before any eviction, weight hash or reservation (`StandaloneServer.ensureModelLoaded`, `ClusterGPUHold.productionServesHere`). A model it loaded before production started keeps serving. Retry once production stops serving here; production's own build never refuses this way |

## Nemotron Super

With Both, me first, chat completions for `nvidia-nemotron-3.5-super` load the
managed slot through the ordinary local acquisition and run on its owner
(`provider-swift/Sources/ProviderCore/Server/NemotronSuperLocalEndpointEngine.swift`):
the controls in the table below apply, prefix reuse uses one partition per
local API (text checkpoints are complete SSD checkpoints by default; an
image turn reuses only with the resident bank, `DARKBLOOM_PREFIX_CACHE_MEMORY=1`,
and only checkpoints of the same images at the same positions), a text
response's `usage.prompt_tokens_details.cached_tokens` counts the prompt tokens
it restored, and inline images are served as described below, target-only on
the default speculating owner. Other routes for that id
(`/v1/completions`, `/v1/responses`) are refused; the generic engine never
serves Super. Only me (`darkbloom start --local`) does not list it.

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
| `response_format` `json_object`/`json_schema` (text) | Content is withheld and validated; invalid JSON returns 422, or ends a stream with an error event. With `tools`, calls return as `tool_calls` and only an answer without calls must be JSON |
| `logprobs: true`, `top_logprobs` 0 to 20 (text, image or video) | `choices[0].logprobs.content`, streamed and complete: one entry per generated token in generation order, covering reasoning, answer and tool-call tokens (as vLLM and SGLang return them), each with at least one alternative. Joined, the entry tokens spell the reasoning, the `</think>` marker and then the answer, not the answer alone. Reasoning chunks carry their tokens' entries, and a response that ends while reasoning still carries them. A complete response carries the stream's entries. Tool-call tokens lack entries only in the rare case that nothing follows the call. The request does not speculate; others keep speculating ([logprob rows](../architecture/inference.md#nemotron-super-logprobs)) |
| Contradictory controls, `top_logprobs` outside 0 to 20, `logit_bias`, `min_p`, `n > 1` | 400 before generation |
| A request beyond the owner's concurrency while others are in flight (text or image) | 429 once the service has decoded the request, before its prompt is planned or rendered and before any response starts; the owner serves one request unless `DARKBLOOM_NEMOTRON_SUPER_MAX_CONCURRENT` raises it, and one image at a time |
| Image input while speculation is installed | Served target-only: no speculation for that request, while text keeps speculating |
| Image whose media reservation does not fit the shared budget | 503 before decoding; nothing stays reserved |
| Visual tokens or an image or video prompt beyond the context | 400 before decoding; nothing stays reserved |
| A media request body above `localInferenceMaxUploadBytes` | 413 from the chat route; the owner's own 40 MiB bound (`NemotronSuperServingPolicy.maximumEncodedBodyBytes`) is above it |
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

- [Use your Mac yourself, first](./local-first.md) — Only me, Darkbloom network
  or Both, me first, and OpenCode or Hermes on this API.
- [Self-route](./self-route.md) — route your *fleet* requests to your own
  provider through the coordinator instead of a local socket; the local router
  uses it when this Mac can't take a request.
- [CLI reference](./cli-reference.md) — `start`, `local` flags and paths.
- [Beta features](./beta-features.md) — MTP and paged KV apply to local serving too.
- [`reference/configuration.md`](../reference/configuration.md) — media limits and engine variables.

## Graceful drain

After local admission closes for shutdown, a new POST receives HTTP `503`
with a structured capacity response (`invalid_request_error`) from `LocalDisconnectResponder`.
CORS headers remain present. Health checks and preflight requests still work,
and already admitted responses retain their existing owner. Retry a rejected
request after the provider is serving again.


### Queued cluster requests during a mode change

A cluster host configured for automatic batch replacement keeps the same authenticated local API while changing native modes for queued demand. Running requests finish on their existing workers. Requests still waiting keep their place, cancellation state and original queue wait limit while the old workers release and the replacement loads. A disconnected or expired request is not admitted after loading finishes. Diagnostics report the temporary reconfiguration as not ready; the bounded request queue remains available.

If a short burst drains before planning finishes, the host may retain the metadata-only proposal for up to 30 seconds. It uses that proposal only when fresh requests wait in the same serving generation; an idle endpoint does not reload. The planner considers the largest independently priced capacity first, and the deferred load still checks current memory after both previous workers release. Request cancellation and the original queue wait limit remain unchanged.

The replacement must preserve the exact model and request limits and must fit both Macs. If a wider mode cannot start, a fresh previous-mode session may be restored after the failed replacement releases. Missing release proof stops the transition; it is never treated as free memory. The HTTP API gains no mode-selection parameter or credential change from this mechanism.

### A pair's leader beside Darkbloom

The member that hosts a pair's slot while the pair serves through Darkbloom
(the coordinator-paired part on the plan's rank 0 Mac) can run this local API
too. It serves the published slot through the slot's own bridge and lanes, so
local and Darkbloom requests share one engine: no second process, engine or
copy of the stream (`provider-swift/Sources/ProviderCore/ProviderLoop+ClusterPairLocal.swift`,
`acquireClusterPairForLocal`). `darkbloom cluster` starts it when you choose
**Both, me first** for the pair
([Both, me first](./two-mac-cluster.md#both-me-first-the-pairs-own-api-beside-darkbloom)):
the cluster service adds `--local-endpoint --port <port> --bind <address>` to
that part's `darkbloom start --foreground --cluster-member`, with the pair's
key. Every other member runs none. <!-- pending LS-3: every other member runs the relay darkbloom cluster local uses (ClusterLocalRelay), so tools on each Mac of the pair use their own Mac's address and the same key. -->

| Case | Answer | Source |
|---|---|---|
| A member that does not host the slot, or a local API without a key | The member refuses to start (`ClusterMemberControlError.incompatibleConfiguration`), as before | `ProviderLoop.prepareClusterMemberControl`, `admitsClusterPairLocalAPI` |
| The pair is not serving (forming, re-forming, retired) | HTTP `503`, as `darkbloom cluster local` answers (`DistributedRequestQueue.unavailableMessage`) | `ProviderLoop.clusterPairNotServing` |
| A model the pair does not serve | HTTP `404` | `acquireClusterPairForLocal` |
| Every lane busy | Waits in arrival order with at most `DARKBLOOM_CLUSTER_QUEUE_WAITING` (default `64`) others; `429` when the queue is full; `503` after waiting longer than `requestTimeout * ((waiting + lanes) / lanes)` (`DistributedRequestQueue.Limits.waitCeiling`); a cancelled request or a reset connection leaves the queue at once, a connection closed normally only at its turn (below) | `ClusterPairLocalLanes` |
| The pair's warm-up request is running | Waits until admission opens; `503` if the slot retires instead | `ProviderLoop.publishClusterPairSlot` |
| A stop or an update drain | Waiting requests get `429` at once, as new ones do; running ones finish before the slot retires | `ProviderLoop.beginServingDrain` |
| A lost rank | Waiting requests get `503`; running ones end with their terminal | `ProviderLoop.retireClusterPairSlot` |

A waiting request costs nothing: it is parked, not polled, until a local
request releases a lane, a Darkbloom request ends (the capacity refresh that
follows it), admission opens, a drain begins or the slot retires. A request
that finds a lane free and nobody waiting takes it at once. Darkbloom requests
never wait for this queue, and their path through the pair is unchanged.

A client that closes its connection normally while it waits, as curl and
URLSession do when they give up, keeps its place in the queue until its turn,
then reaches the pair, the same as on `darkbloom cluster local`. Only a
cancelled request or a reset connection frees the place at once. The close is
noticed at the request's first write, which ends the request and frees its
lane: that bounds the waste to its turn, up to its first write. A stream
writes as its answer starts; an answer sent whole is written when it is done
(`provider-swift/Sources/ProviderCore/Server/LocalHTTPConnectionCancellation.swift`).

Me first applies to the whole pair. From the moment one of your requests
starts waiting for a lane, the leader's heartbeat says `draining` with
`busy_reason: owner`, and the pair takes no new Darkbloom requests. Darkbloom
requests already running finish; one that races the heartbeat is refused with
the typed draining answer and goes to another Mac. Two minutes after your last
request ends (`[local] me_first_idle_minutes`), the pair takes Darkbloom
requests again. `[local] me_first = false` keeps the shared serving above. The
other members don't change, and the pair keeps its session and its loaded
model ([owner pause](../architecture/owner-pause.md#pairs)).

On the deployed coordinator, while a pair is paused for you, both Macs lose
their base reward for the pause plus the 2 idle minutes, counted in 5-minute
periods, whereas a single Mac keeps it. `[local] me_first = false`, or choosing
*Darkbloom network*, avoids that.

### Speed records of cluster requests

A cluster endpoint records how fast each request ran that computed its whole
prompt, completed and had the pair to itself, for the next plan of the pair
(`~/.darkbloom/cluster/served-speed.json` on the Mac where requests enter;
values only: no prompt, output or client identity). Each record
names the worker build each Mac served the request with, and a plan or route
uses a speed only for the build that served it, so speeds an earlier build
served no longer steer the pair's plan after an update
([served speed records](../architecture/inference.md#served-speed-records-and-worker-builds)).
Each record also says the request came through this local API (not
Darkbloom) and whether Qwen's tensor assistant decoded it; a plan for serving
through Darkbloom uses none of the local records.
The HTTP API is unchanged. Source:
`provider-swift/Sources/ProviderCore/Server/Distributed/DistributedLocalServer+Startup.swift`
and `provider-swift/Sources/ProviderCore/Inference/Distributed/Observability/DistributedPairTelemetryRecorder.swift`.

### Qwen27 image and video requests on a pair

An installed pair that explicitly reports the Qwen media contract accepts the
existing OpenAI image/video content parts through the same local API.
The provider validates the exact registered 27B configuration and resolved
processor before preparing media. A model name or vision configuration alone
does not enable the route. The native pair must independently load and report
the supported media path; selecting an unsupported mode is not repaired by
silently discarding media.

Use default processing controls. Nondefault resize/pixel settings, forced media
tool choices and JSON/schema output constraints are refused on this route.
Image/video preprocessing and transport tests do not establish full-model
answers, native concurrency or automatic TP selection; retain those separate
qualification records. The implementation is in
`provider-swift/Sources/ProviderCore/Inference/Engine/Scheduler/MultiModelBatchSchedulerEngine.swift`
and `provider-swift/Sources/ProviderCore/Inference/Distributed/Requests/DistributedQwenMediaIngress+Preparation.swift`.

For every registered Qwen TP row (9B, 27B, Qwen3.5/3.6 35B A3B), a queued-demand
replacement can select a priced TP batch or plain pipeline. The chosen mode still follows measured stage/link rates,
qualification shape gates and current memory on both Macs. The installed width
default remains one; a wider saved plan propagates through both owners to the
native ranks. This integration does not claim a full-artifact throughput result.
See [automatic cluster batching](../architecture/inference.md#automatic-local-cluster-batching).
