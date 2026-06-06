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
darkbloom start --local                 # local server ONLY (no coordinator)
darkbloom start --local --port 8080     # custom port
darkbloom start --local --bind 100.x.y.z  # bind a tailnet IP for same-account devices
darkbloom start --local --no-auth       # disable the API key (trusted/airgapped only)

# Unified mode: serve the public fleet AND a local endpoint at once, off the
# SAME loaded models (weights load once; local + coordinator requests share one
# continuous-batching engine and KV budget):
darkbloom start --local-endpoint                 # coordinator + local on :8000
darkbloom start --local-endpoint --port 8080 --bind 100.x.y.z
```

`--local` runs the OpenAI server **only** (no coordinator connection).
`--local-endpoint` runs it **alongside** the coordinator connection. Both mint a
persistent bearer token (`~/.darkbloom/local_token`, `0600`); `--local` also
writes a discovery record (`~/.darkbloom/local.json`, `0600`).

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

## Serve publicly AND locally at once (`--local-endpoint`)

`--local-endpoint` is the unified mode: the provider keeps its coordinator
connection (serving the public fleet) **and** exposes the local OpenAI endpoint
off the **same** loaded models. There is no double-load — both front-ends
dispatch through ONE shared `BatchScheduler` registry and `GlobalKVCacheBudget`,
so a local request and a coordinator request feed the same continuous-batching
engine and count against the same capacity the coordinator sees. Local in-flight
requests hold a reservation that keeps the idle monitor / load-gate from evicting
a model mid-stream. The HTTP layer is identical to `--local` (shared builder), so
auth, CORS, and error mapping behave the same.

## Limitations / future

- `--local` and `--local-endpoint` mint the same bearer token, but only `--local`
  writes the `~/.darkbloom/local.json` discovery record today; for unified mode
  the endpoint URL is printed at startup. Writing the discovery record from
  unified mode (so `darkbloom local` finds it too) is a small follow-on.
- The hosted browser console can't read `~/.darkbloom/local.json`; a settings
  field to paste the `darkbloom local` URL + token (then prefer it via
  `localFirst.ts`) is a natural follow-on.
