# Direct / local mode — talk to your own Mac, no relay

[Self-route](self-route.md) routes "use my own machine, for free" requests
through the coordinator (the only rendezvous point, since the provider is an
outbound-only WebSocket client behind NAT). **Direct mode** removes the relay
entirely for the case where the client can reach the Mac itself — same machine,
LAN, or tailnet:

- **Lower latency** — localhost/LAN, no WAN round-trip to the coordinator.
- **Works offline** — your own inference keeps running with no internet.
- **Bytes never leave your network** — stronger than E2E-through-relay.

The provider already ships an OpenAI-compatible HTTP server backed by the same
MLX engine (`StandaloneServer`); direct mode makes it **secure** (a local API
key) and **discoverable**, and adds a client that prefers it with automatic
fallback to the relayed self-route.

## Run it

```bash
darkbloom start --local                 # serve locally on 127.0.0.1:8000
darkbloom start --local --port 8080     # custom port
darkbloom start --local --bind 100.x.y.z  # bind a tailnet IP for same-account devices
darkbloom start --local --no-auth       # disable the API key (trusted/airgapped only)
```

`--local` runs the OpenAI server **only** (no coordinator connection). It mints a
persistent bearer token (`~/.darkbloom/local_token`, `0600`) and writes a
discovery record (`~/.darkbloom/local.json`, `0600`).

## Find the endpoint

```bash
darkbloom local            # prints base URL + API key + ready-to-paste examples
darkbloom local --json     # machine-readable discovery record
```

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

## Discover from Node (`~/.darkbloom/local.json`)

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

## Local-first with coordinator fallback

`console-ui/src/lib/localFirst.ts` prefers the local endpoint and falls back to
the coordinator self-route on a connection failure (the Mac is asleep, you're
away, or local mode isn't running). Fallback fires **only** on a connection-level
error — a reachable-but-erroring local server returns its own error rather than
silently rerouting. Both paths are free.

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

## Security

- **API key, not just loopback.** A loopback server with no auth is reachable by
  any local process and — because it sends `Access-Control-Allow-Origin: *` — by
  a hostile web page. The bearer token is the boundary. Every inference route
  requires `Authorization: Bearer <token>`; `OPTIONS` (CORS preflight) and
  `GET /health` / `GET /` are exempt. Comparison is constant-time; the 401
  carries a CORS header so browsers can read it.
- **`--bind` exposes the server to the network** (still token-gated). Prefer a
  tailnet IP over `0.0.0.0`. The discovery record always advertises a dialable
  loopback URL when bound to a wildcard.
- The token persists across restarts (so existing clients keep working) and is
  written atomically at `0600` (no umask window). The discovery file is removed
  on graceful shutdown; because a Ctrl-C/SIGKILL/crash skips that cleanup, the
  record carries the server `pid` and `darkbloom local` (via `readLiveInfo`)
  treats a stale file whose process is gone as "not running" rather than
  advertising a dead endpoint.

## How it relates to self-route

| | Direct (local) | Self-route (relayed) |
|---|---|---|
| Path | client → your Mac | client → coordinator → your Mac |
| Best for | same machine / LAN / tailnet | remote, away from your Mac |
| Coordinator needed | no | yes |
| Auth | local API key | your Darkbloom API key + `X-Darkbloom-Route: self` |
| Cost | free | free |

They are complementary modes a client picks by reachability — `localFirst.ts`
does exactly that.

## Limitations / future

- `--local` is a distinct serve mode: it does not also connect to the coordinator
  (coordinator mode builds its own scheduler, so running both would load each
  model twice). A shared-scheduler "serve publicly **and** locally at once" mode
  is future work.
- The hosted browser console can't read `~/.darkbloom/local.json`; a settings
  field to paste the `darkbloom local` URL + token (then prefer it via
  `localFirst.ts`) is a natural follow-on.
