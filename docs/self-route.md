# Self-Route — free private inference on your own Mac

**"Use my own machine, for free."** A consumer hitting the OpenAI-compatible
inference endpoint can opt in to route **only** to a Darkbloom provider machine
their own account owns. It is free (no charge, no platform fee, no provider
payout), end-to-end encrypted as usual, and the coordinator **never falls back
to a paid public provider** — if the owner's machine can't serve, the request
fails with an explicit, actionable error.

This turns running a provider node from "earn when idle" into "stop paying for
your own usage **and** earn when idle," the strongest incentive to keep nodes
online.

> When the client can reach your Mac directly (same machine / LAN / tailnet),
> **[direct mode](direct-mode.md)** skips the coordinator relay entirely —
> lower latency, offline-capable, bytes never leave your network. Self-route is
> the relayed path for when you're away.

## Opting in

Two signals, both OpenAI-client-safe:

| Signal | Scope | Notes |
|---|---|---|
| `X-Darkbloom-Route: self` header | Per request | Invisible to the OpenAI body schema; works with any SDK (`extra_headers`). Never enters the (optionally sealed) request body. |
| API key `self_route_only: true` | Per key (hard ceiling) | Every request on the key self-routes and is free; the key can never spend balance or reach the public fleet, regardless of header. |

```bash
curl https://api.darkbloom.dev/v1/chat/completions \
  -H "Authorization: Bearer dk-..." \
  -H "X-Darkbloom-Route: self" \
  -d '{"model":"gpt-oss-20b","messages":[{"role":"user","content":"hi"}]}'
```

In the console UI: the **My Machine** toggle in the chat composer, or the
**"My Machine only — free"** checkbox when creating/editing an API key.

## Ownership model (the crux)

"My machine" = a provider where `provider.AccountID == authenticated consumer
account`. Both sides are **stamped server-side**:

- `provider.AccountID` is set at WebSocket registration from the device-auth
  token (`darkbloom login`), never from client input.
- The consumer account id comes from `consumerKeyFromContext` (Privy / API key /
  provider device token).

The opt-in header only *requests* self-routing; it cannot *name* a machine.
Forging would require forging both an account token and a provider device token,
so it is unforgeable.

## Routing behaviour

The owner filter lives in the registry scheduler
(`selectBestCandidateLockedFull` → `providerOwnedBy`, mirrored in
`ReserveProviderEx`/`providerCanAdmitLocked`). A self-route request only ever
considers providers the caller owns — across immediate dispatch, sequential
retry, speculative backup, and the 120s queue + queue-drain.

**Trust:** a personal Mac is not MDM/MDA-enrolled, so self-route relaxes the
hardware-trust floor (`MIN_TRUST`) **for the owner's own machine only**. Every
privacy-critical gate (runtime-verified, encrypted-chunks/SIP private-text
support, challenge freshness) still applies — plaintext is never exposed and the
machine remains unroutable to the **public** fleet on low trust.

**Errors (no fallback):**

| State | Status | code |
|---|---|---|
| No machine linked | 409 | `no_linked_machine` |
| Machine(s) offline | 503 + Retry-After | `machine_offline` |
| Online but model not loaded/in-catalog | 503 + Retry-After | `model_not_loaded` |
| Owned machine busy (after queue) | 429 + Retry-After | `machine_busy` |

## Billing

Self-route skips the pre-flight reservation, the per-key spend cap, the charge,
the platform fee, and the provider payout — a zero-balance owner is never
blocked. A **zero-cost usage row** is still recorded for transparency.

At settlement, `handleComplete` **re-verifies** that the provider which actually
served the completion is owned by the consumer (read from the serving provider
object, race-free across deregistration). Only then is it free; on any mismatch
it falls back to **paid** settlement rather than grant free inference on a
machine the caller doesn't own.

**Rate limits still apply.** Account-level token (ITPM/OTPM) and request (RPM)
limits run before the billing skip. For a typical `self_route_only` key with no
per-key limits this is a no-op, but a configured account-tier limiter can still
throttle free self-route. This is a deliberate abuse guard.

## `private_only` provider mode (advanced)

A provider can register as **private-only** so the coordinator serves it
*exclusively* to its owner's self-route requests, never the public fleet (and it
does not count toward public model capacity). Set it in the provider config:

```toml
[coordinator]
private_only = true
```

This adds a `private_only` field to the registration message, mirrored across
`coordinator/protocol/messages.go` (Go) and
`provider-swift/Sources/ProviderCore/Protocol/Messages.swift` (Swift), with
encode-when-true / decode-default-false symmetry on both sides.

## Where it lives

- **Coordinator:** `api/self_route.go` (policy + eligibility), `api/consumer.go`
  (dispatch wiring, both handlers), `api/provider.go` (free settlement),
  `registry/scheduler.go` + `registry/registry.go` (owner filter, trust
  relaxation, `OwnedProviderSummary`, `private_only` gating),
  `store/{interface,memory,postgres}.go` (`self_route_only` API-key flag).
- **Console UI:** `lib/api.ts` (header + error mapping + types), `lib/store.ts`
  (`useMyMachine`), `app/api/chat/route.ts` (header forwarding),
  `components/ChatInput.tsx` + `components/api-keys/{KeyForm,KeyCard}.tsx`.
- **Provider (Swift):** `Protocol/Messages.swift`, `Coordinator/CoordinatorClient*.swift`,
  `Config/ProviderConfig.swift`, `ProviderLoop.swift`.
