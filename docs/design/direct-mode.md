# Direct / Local Mode — Talk to Your Own Mac, No Relay

**Status:** implemented (`--local` and `--local-endpoint` both shipped; see
[Limitations](#7-limitations--future) for the small follow-ons).

[Self-route](self-route.md) routes "use my own machine, for free" requests
through the coordinator — the only rendezvous point, since the provider is an
outbound-only WebSocket client behind NAT. **Direct mode** removes the relay
entirely for the case where the client can reach the Mac itself — same machine,
LAN, or tailnet:

- **Lower latency** — localhost/LAN, no WAN round-trip to the coordinator.
- **Works offline** — your own inference keeps running with no internet.
- **Bytes never leave your network** — stronger than E2E-through-relay.

The provider already ships an OpenAI-compatible HTTP server backed by the same
MLX engine (`StandaloneServer`, in `ProviderCore/Server/`); direct mode makes
it **secure** (a persistent local API key), **discoverable** (an on-disk
discovery record + the `darkbloom local` command), and adds a client helper
that prefers it with automatic fallback to the relayed self-route.

---

## 1. Running it

```bash
darkbloom start --local                   # local server ONLY (no coordinator)
darkbloom start --local --port 8080       # custom port
darkbloom start --local --bind 100.x.y.z  # bind a tailnet IP for same-account devices
darkbloom start --local --no-auth         # disable the API key (trusted/airgapped only)

# Unified mode: serve the public fleet AND a local endpoint at once, off the
# SAME loaded models:
darkbloom start --local-endpoint                 # coordinator + local on :8000
darkbloom start --local-endpoint --port 8080 --bind 100.x.y.z
```

| Flag | Coordinator connection | Local OpenAI server | Discovery record |
|---|---|---|---|
| `--local` | no | yes | yes (`~/.darkbloom/local.json`) |
| `--local-endpoint` | yes | yes | no (URL printed at startup) |

Both modes mint the same persistent bearer token at
`~/.darkbloom/local_token` (mode `0600`, written atomically — no umask window),
so existing clients keep working across restarts.

## 2. Discovery

```bash
darkbloom local            # prints base URL + API key + ready-to-paste examples
darkbloom local --json     # machine-readable discovery record
```

The discovery record (`~/.darkbloom/local.json`, `0600`) contains the base URL,
the API key, and the server `pid`. Because a Ctrl-C / SIGKILL / crash skips the
graceful-shutdown cleanup that removes the file, `darkbloom local` (via
`readLiveInfo`) treats a stale record whose process is gone as "not running"
rather than advertising a dead endpoint. When the server is bound to a wildcard
address, the record always advertises a dialable loopback URL.

Point any OpenAI client at it:

```bash
export OPENAI_BASE_URL=http://127.0.0.1:8000/v1
export OPENAI_API_KEY=dk-local-…      # from `darkbloom local`
```

```python
from openai import OpenAI
client = OpenAI()  # picks up OPENAI_BASE_URL / OPENAI_API_KEY
client.chat.completions.create(model="…", messages=[{"role": "user", "content": "hi"}])
```

From Node, read the discovery record directly:

```ts
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export function discoverLocalEndpoint() {
  try {
    const info = JSON.parse(readFileSync(join(homedir(), ".darkbloom", "local.json"), "utf8"));
    return { baseURL: info.base_url as string, apiKey: info.api_key as string | undefined };
  } catch {
    return null; // local mode not running
  }
}
```

## 3. Unified mode internals (`--local-endpoint`)

`--local-endpoint` keeps the coordinator connection (serving the public fleet)
**and** exposes the local OpenAI endpoint off the **same** loaded models. There
is no double-load:

- Both front-ends dispatch through **one shared `BatchScheduler` registry**
  (`MultiModelBatchSchedulerEngine`) and one `GlobalKVCacheBudget` — a local
  request and a coordinator request feed the same continuous-batching engine
  and count against the same capacity the coordinator sees in heartbeats.
- Local in-flight requests hold a reservation that keeps the idle monitor /
  load-gate from evicting a model mid-stream.
- The HTTP layer is identical to `--local` (shared builder:
  `StandaloneServer+HTTP.swift`, `LocalInferenceHTTP.swift`,
  `LocalAuthResponder.swift`), so auth, CORS, and error mapping behave the
  same in both modes.

This means a provider earning from the public fleet pays no extra memory or
throughput tax to also serve its owner locally — weights load once.

## 4. Local-first client with coordinator fallback

`console-ui/src/lib/localFirst.ts` prefers the local endpoint and falls back to
the coordinator self-route on a connection failure (the Mac is asleep, you're
away, or local mode isn't running). Fallback fires **only** on a
connection-level error — a reachable-but-erroring local server returns its own
error rather than silently rerouting (so application errors stay visible).
Both paths are free.

```ts
import { chatCompletionWithFallback } from "@/lib/localFirst";

const { response, via } = await chatCompletionWithFallback(
  { model, messages, stream: true },
  {
    local: discoverLocalEndpoint(),        // or null
    coordinatorURL: "/api/chat",            // proxy, or a coordinator /v1/chat/completions
    coordinatorApiKey: "dk-…",
  }
);
// `via` is "local" or "coordinator"; stream `response` as usual.
```

## 5. Security model

- **API key, not just loopback.** A loopback server with no auth is reachable
  by any local process and — because it sends
  `Access-Control-Allow-Origin: *` — by a hostile web page making
  cross-origin requests. The bearer token is the boundary. Every inference
  route requires `Authorization: Bearer <token>`; `OPTIONS` (CORS preflight)
  and `GET /health` / `GET /` are exempt. Token comparison is constant-time;
  the 401 carries a CORS header so browsers can read it.
- **`--bind` exposes the server to the network** (still token-gated). Prefer a
  tailnet IP over `0.0.0.0`.
- **`--no-auth` is opt-in only** and intended for trusted or air-gapped
  machines; the default is always authenticated.
- Token and discovery files are `0600` and written atomically. The discovery
  file's liveness check (pid-based) prevents a stale record from directing
  clients at a port now owned by some other process.

## 6. Direct mode vs self-route

| | Direct (local) | Self-route (relayed) |
|---|---|---|
| Path | client → your Mac | client → coordinator → your Mac |
| Best for | same machine / LAN / tailnet | remote, away from your Mac |
| Coordinator needed | no | yes |
| Works offline | yes | no |
| Auth | local API key | Darkbloom API key + `X-Darkbloom-Route: self` |
| Cost | free | free |

They are complementary modes a client picks by reachability — `localFirst.ts`
does exactly that.

## 7. Limitations / future

- `--local` and `--local-endpoint` mint the same bearer token, but only
  `--local` writes the `~/.darkbloom/local.json` discovery record today; for
  unified mode the endpoint URL is printed at startup. Writing the discovery
  record from unified mode (so `darkbloom local` finds it too) is a small
  follow-on.
- The hosted browser console can't read `~/.darkbloom/local.json`; a settings
  field to paste the `darkbloom local` URL + token (then prefer it via
  `localFirst.ts`) is a natural follow-on.

## 8. Code map

- **Provider (Swift):** `ProviderCore/Server/StandaloneServer.swift` (+
  `StandaloneServer+HTTP.swift`, `LocalInferenceHTTP.swift`,
  `LocalAuthResponder.swift`, `LocalEndpoint.swift`),
  `darkbloom/StartCommand.swift` (flags), `darkbloom/LocalCommand.swift`
  (discovery).
- **Console UI:** `src/lib/localFirst.ts` (local-first fallback client).
