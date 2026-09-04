# Self-route: use your own machine through the coordinator

> Last updated: 2026-09-03 · commit `5d400cf75`

Send your normal Darkbloom API requests to the provider your account owns —
free, end-to-end, through the same `api.darkbloom.dev` endpoint and SDK
configuration — by adding one request header or pinning an API key. For
operators who run a provider and also consume the network. Nothing changes on
the provider; the policy lives entirely on the coordinator
(`coordinator/api/self_route.go`, `resolveSelfRoutePolicy`).

Self-route is not [direct mode](./direct-mode.md): direct mode is a local
socket on the provider Mac with no coordinator involved; self-route is regular
fleet traffic whose scheduler is told which machine may serve it.

## Prerequisites

- A provider linked to your account: `darkbloom login` on the Mac, then
  `darkbloom start` ([quickstart](./quickstart.md)). Ownership is the account
  that linked the device (`Provider.AccountID`), stamped by the coordinator;
  the header cannot name a machine.
- A consumer API key issued to the same account.
- The model you request downloaded and advertised on that machine
  (`darkbloom models list`).

## Steps

1. Choose how to opt in. Three signals, resolved server-side from the
   authenticated identity; none comes from the request body:

   | Signal | Scope | Behaviour |
   |---|---|---|
   | `X-Darkbloom-Route: self` | one request | **Exclusive.** Only providers owned by the calling account; free; never falls back to the paid fleet — an explicit error if your machine cannot serve |
   | `X-Darkbloom-Route: prefer` | one request | **Prefer.** Owned machine first (free when it serves), otherwise the paid fleet. Takes a normal balance reservation up front; billing is decided at settlement by who served |
   | API key `self_route_only = true` | every request on that key | Hard ceiling: exclusive self-route regardless of header. Set in the console key form (`console-ui/src/components/api-keys/KeyForm.tsx`) or `PATCH` the key with `{"self_route_only": true}` (`coordinator/api/apikey_handlers.go`) |

   Header values are trimmed and case-insensitive. A key with
   `self_route_only` ignores `prefer`.

2. Send a request with the header:

   ```bash
   curl https://api.darkbloom.dev/v1/chat/completions \
     -H "Authorization: Bearer $DARKBLOOM_API_KEY" \
     -H "X-Darkbloom-Route: self" \
     -H "Content-Type: application/json" \
     -d '{"model":"<model-id>","messages":[{"role":"user","content":"hi"}]}'
   ```

   OpenAI SDKs accept extra headers (`default_headers` in Python,
   `defaultHeaders` in Node). The header is invisible to the body schema, so it
   also works with a sealed private-text body.

3. Discover what your machine serves with the same header. `GET /v1/models`
   follows the resolved route mode (`coordinator/api/models_endpoints.go`,
   `handleListModels`): with `self` (or a `self_route_only` key) it lists only
   models on your online owned machines; header-less and `prefer` requests see
   the public catalog.

   ```bash
   curl -s https://api.darkbloom.dev/v1/models \
     -H "Authorization: Bearer $DARKBLOOM_API_KEY" -H "X-Darkbloom-Route: self"
   ```

4. Optionally keep the machine private. `private_only = true` under
   `[coordinator]` in `provider.toml`
   (`provider-swift/Sources/ProviderCore/Config/ProviderConfig.swift`,
   `CoordinatorSettings.privateOnly`) registers the provider as private-only:
   the coordinator serves it exclusively to the owner's self-route requests and
   never to the public fleet (gate reason `private_only`,
   `coordinator/registry/routing_eligibility.go`). It then earns nothing;
   restart after changing the key.

5. In the console, the chat "Use my machine" toggle sends `prefer`
   (`console-ui/src/lib/chat/stream.ts`, forwarded upstream by
   `console-ui/src/app/api/chat/route.ts`); free-only routing there is the
   per-key `self_route_only` ceiling.

## What the coordinator relaxes — and what it does not

Self-route to an owned machine relaxes exactly two gates in the scheduler
(`coordinator/registry/scheduler.go`, `providerPassesRoutingGatesLocked`;
`relaxTrust := owned && (pr.SelfRouteOnly || pr.PreferOwner)`):

- the hardware-trust floor (`Registry.MinTrustLevel`, default `hardware`), so an
  un-enrolled or `self_signed` machine of yours can serve you;
- private-only admission, so a `private_only` provider is eligible.

Everything else still applies: liveness, challenge freshness, runtime
verification, private-text support, model/trait eligibility, and the APNs
code-identity gate once enforcement is switched on. Levels and flags are
explained in [attestation](./attestation.md); the mechanism in
[`architecture/security/attestation.md`](../architecture/security/attestation.md).

Requests served by an owned machine are free; `prefer` requests that fall back
to the fleet are charged normally. Settlement rules are in
[`architecture/billing.md`](../architecture/billing.md).

## Verify

```bash
darkbloom status          # Trust: <level>, connected, models advertised
```

Then send a `self` request and confirm it succeeds while `darkbloom logs -f`
shows the request on your machine; with `darkbloom stop` the same request
returns `503 machine_offline`.

## Troubleshooting

Exclusive self-route fails fast with the real cause instead of queueing
(`coordinator/api/self_route.go`, `selfRouteUnavailable`):

| Status / code | Meaning | Fix |
|---|---|---|
| `409 no_linked_machine` | No provider is linked to the account that owns the key | `darkbloom login` on the Mac under that account |
| `503 machine_offline` (`Retry-After: 30`) | Linked machine(s) exist but none is online | `darkbloom start`; `darkbloom doctor` for connection problems ([troubleshooting](./troubleshooting.md)) |
| `503 model_not_loaded` (`Retry-After: 15`) | Online, but no owned machine serves this model id | `darkbloom models download <id>`, then `darkbloom restart`; list ids with the `self` header |
| `503 model_capability_unsupported` | Machine serves the model but not this request shape (tool calls below the tools version floor, media on a text-only build) | `darkbloom update`; load a vision-capable build |
| `prefer` requests are billed | Your machine could not serve at that moment, so the fleet did | Check the same causes as above; use `self` if you never want the fallback |
| Key with `self_route_only` returns 409/503 for every request | The ceiling applies to all traffic on that key | Use a different key for public routing |

## Related

- [Direct mode](./direct-mode.md) — local HTTP endpoint without the coordinator.
- [Attestation](./attestation.md) — trust levels and the flags self-route does not bypass.
- [`architecture/billing.md`](../architecture/billing.md) — free vs. charged settlement.
- [CLI reference](./cli-reference.md) — `private_only` and the other `provider.toml` keys.
