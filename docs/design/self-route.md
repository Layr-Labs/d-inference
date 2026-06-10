# Self-Route — Free Private Inference on Your Own Mac

**Status:** implemented end-to-end (coordinator, console UI, provider).

**"Use my own machine, for free."** A consumer hitting the OpenAI-compatible
inference endpoint can opt in to route **only** to a Darkbloom provider machine
their own account owns. It is free (no charge, no platform fee, no provider
payout), end-to-end encrypted as usual, and — in exclusive mode — the
coordinator **never falls back to a paid public provider**: if the owner's
machine can't serve, the request fails with an explicit, actionable error.

This turns running a provider node from "earn when idle" into "stop paying for
your own usage **and** earn when idle" — the strongest incentive to keep nodes
online.

> When the client can reach the Mac directly (same machine / LAN / tailnet),
> **[direct mode](direct-mode.md)** skips the coordinator relay entirely —
> lower latency, offline-capable, bytes never leave the network. Self-route is
> the relayed path for when you're away.

---

## 1. Opt-in surfaces

Three intents, all OpenAI-client-safe (none touch the request body, so they
work with any SDK via `extra_headers` and survive optional body sealing). Two
are EXCLUSIVE (owned-only, free, no fallback); one is PREFER (owned-first, paid
fallback so it is never a dead end):

| Signal | Mode | Scope | Notes |
|---|---|---|---|
| `X-Darkbloom-Route: self` header | Exclusive | Per request | Owned-only, free, no fallback. |
| API key `self_route_only: true` | Exclusive | Per key (hard ceiling) | Every request on the key is owned-only and free; it can never spend balance or reach the public fleet, **regardless of header**. |
| `X-Darkbloom-Route: prefer` header | Prefer | Per request | Routes to an owned machine whenever it can serve (free); falls back to the **paid** public fleet when it can't. Takes a normal reservation up front (refunded if the owned machine serves), so the account needs a balance. |

```bash
# Strict free-or-error (exclusive):
curl https://api.darkbloom.dev/v1/chat/completions \
  -H "Authorization: Bearer dk-..." \
  -H "X-Darkbloom-Route: self" \
  -d '{"model":"gpt-oss-20b","messages":[{"role":"user","content":"hi"}]}'

# Prioritized with paid fallback (prefer):
curl https://api.darkbloom.dev/v1/chat/completions \
  -H "Authorization: Bearer dk-..." \
  -H "X-Darkbloom-Route: prefer" \
  -d '{"model":"gpt-oss-20b","messages":[{"role":"user","content":"hi"}]}'
```

Console UI mapping: the **My Machine** toggle in the chat composer sends
`prefer` (prioritized, never stuck); the **"My Machine only — free"** checkbox
on an API key sets the strict `self_route_only` ceiling.

### Exclusive vs prefer

- **Exclusive** (`self` / `self_route_only`): guarantees $0 — if the owned
  machine can't serve, the caller gets an explicit error, never a charge.
  Works at zero balance.
- **Prefer** (`prefer`): prioritizes the owned machine for free but never
  strands the caller — it falls back to the paid fleet. Because it might pay,
  it reserves up front (refunded when the owned machine serves), so the
  account must hold a balance. Routing relaxes the hardware-trust floor for
  the caller's own (possibly un-enrolled) machine only, never for public
  providers.

## 2. Policy resolution (`api/self_route.go`)

The decision is carried through dispatch as a `selfRoutePolicy` struct so that
the primary dispatch, sequential retry, and speculative-backup
`PendingRequest`s all inherit the same owner filter and free-billing flag:

```go
type selfRoutePolicy struct {
    enabled        bool   // EXCLUSIVE: owned-only, free, no fallback
    prefer         bool   // PREFER: owned-first, paid fallback (mutually exclusive with enabled)
    ownerAccountID string // account that must own the serving provider
}
```

`resolveSelfRoutePolicy` derives it **entirely server-side** from the
authenticated request:

1. Per-key `SelfRouteOnly` flag → EXCLUSIVE, regardless of header (hard ceiling).
2. Else `X-Darkbloom-Route: self` → EXCLUSIVE for this request.
3. Else `X-Darkbloom-Route: prefer` → PREFER for this request.
4. An unresolved identity (empty consumer key) disables self-route entirely,
   so it can never match a machine.

No field originates from the request body.

## 3. Ownership model (the crux)

"My machine" = a provider where `provider.AccountID == authenticated consumer
account`. Both sides are **stamped server-side**:

- `provider.AccountID` is set at WebSocket registration from the device-auth
  token (`darkbloom login`, RFC 8628 device-code flow), never from client input.
- The consumer account id comes from `consumerKeyFromContext` (Privy JWT /
  API key / provider device token) — the same namespace as `Provider.AccountID`.

The opt-in header only *requests* self-routing; it cannot *name* a machine.
Forging ownership would require forging both an account token and a provider
device token, so the binding is unforgeable.

## 4. Routing behaviour

The owner filter lives in the registry scheduler
(`selectBestCandidateLockedFull` → `providerOwnedBy`, mirrored in
`ReserveProviderEx` / `providerCanAdmitLocked`). A self-route request only ever
considers providers the caller owns — across **every** dispatch path: immediate
dispatch, sequential retry, speculative TTFT backup, and the 120s queue +
queue-drain.

**Trust relaxation:** a personal Mac is typically not MDM/MDA-enrolled, so
self-route relaxes the hardware-trust floor (`MIN_TRUST`) **for the owner's own
machine only**. Every privacy-critical gate still applies — runtime
verification, encrypted-chunks / SIP private-text support, challenge
freshness — so plaintext is never exposed, and the machine remains unroutable
to the **public** fleet on low trust.

### Pre-flight eligibility & errors (no fallback)

Before dispatch, `selfRouteUnavailable` checks
`registry.OwnedProviderSummary(owner, model)` and maps each failure state to a
precise, actionable terminal error rather than a silent reroute:

| State | Status | `code` | Detection |
|---|---|---|---|
| No machine linked to the account | 409 | `no_linked_machine` | zero online owned providers AND `store.ListProvidersByAccount` is empty |
| Machine(s) linked but offline | 503 + `Retry-After: 30` | `machine_offline` | zero online owned providers, ≥1 linked |
| Online but model not loaded / not in catalog | 503 + `Retry-After` | `model_not_loaded` | online > 0, `servesModel == 0` |
| Owned machine busy (after queueing) | 429 + `Retry-After` | `machine_busy` | downstream, after the 120s queue drains |

In PREFER mode these states are not terminal — they trigger the paid fallback
instead.

## 5. Billing & settlement

Exclusive self-route skips the pre-flight reservation, the per-key spend cap,
the charge, the platform fee, and the provider payout — a zero-balance owner is
never blocked. A **zero-cost usage row** is still recorded for transparency.

At settlement, `handleComplete` (in `api/provider.go`) **re-verifies** that the
provider which actually served the completion is owned by the consumer — read
from the serving provider object, race-free across deregistration. Only then is
the request free; on any mismatch it falls back to **paid** settlement rather
than grant free inference on a machine the caller doesn't own. In PREFER mode,
this settlement check is what decides free-vs-paid: the up-front reservation is
refunded when an owned machine served, charged otherwise.

**Rate limits still apply.** Account-level token (ITPM/OTPM) and request (RPM)
limits run before the billing skip. For a typical `self_route_only` key with no
per-key limits this is a no-op, but a configured account-tier limiter can still
throttle free self-route — a deliberate abuse guard (free ≠ unlimited fleet
amplification).

## 6. `private_only` provider mode (advanced)

A provider can register as **private-only** so the coordinator serves it
*exclusively* to its owner's self-route requests, never the public fleet (and
it does not count toward public model capacity):

```toml
[coordinator]
private_only = true
```

This adds a `private_only` field to the registration message, mirrored across
`coordinator/protocol/messages.go` (Go) and
`provider-swift/Sources/ProviderCore/Protocol/Messages.swift` (Swift), with
encode-when-true / decode-default-false symmetry on both sides (parity-tested,
like all protocol fields).

## 7. Security analysis

- **Can a caller route to someone else's machine?** No — the header carries no
  machine identifier; the owner filter matches on server-stamped account IDs.
- **Can a malicious provider claim ownership to earn free traffic?** No — the
  provider's `AccountID` comes from device-auth at registration, and free
  settlement re-verifies ownership at completion time.
- **Does the trust relaxation weaken the public fleet?** No — it applies only
  when the candidate provider is owned by the caller; public routing keeps the
  full `MIN_TRUST` floor.
- **Is plaintext ever exposed?** No — E2E encryption (X25519 NaCl box to the
  provider's key) is unchanged; self-route only changes *which* providers are
  candidates and *whether* billing applies.

## 8. Code map

- **Coordinator:** `api/self_route.go` (policy + eligibility),
  `api/consumer.go` (dispatch wiring, both handlers), `api/provider.go`
  (free settlement), `registry/scheduler.go` + `registry/registry.go`
  (owner filter, trust relaxation, `OwnedProviderSummary`, `private_only`
  gating), `store/{interface,memory,postgres}.go` (`self_route_only` API-key
  flag).
- **Console UI:** `lib/api.ts` (header + error mapping + types), `lib/store.ts`
  (`useMyMachine`), `app/api/chat/route.ts` (header forwarding),
  `components/ChatInput.tsx` + `components/api-keys/{KeyForm,KeyCard}.tsx`.
- **Provider (Swift):** `Protocol/Messages.swift`,
  `Coordinator/CoordinatorClient*.swift`, `Config/ProviderConfig.swift`,
  `ProviderLoop.swift`.
