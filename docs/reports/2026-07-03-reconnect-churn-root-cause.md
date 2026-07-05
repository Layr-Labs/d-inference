# Provider Reconnect Churn — Root Cause Analysis

**Date:** 2026-07-03
**Scope:** production `provider_sessions` (Jun 27 – Jul 3, 2026), coordinator WS lifecycle (`coordinator/api/provider.go`, `coordinator/registry/registry.go`), provider reconnect logic (`provider-swift/Sources/ProviderCore/Coordinator/`)
**Data source:** prod Postgres, read-only. 31,202 sessions across 509 distinct serials in the window (median 18 sessions/machine, mean 61, max 728).

## TL;DR

The dominant churn mechanism (~65% of session closes) is **machines going silent shortly after connecting — overwhelmingly macOS sleep — and being reaped by the coordinator's stale-eviction sweep** (90 s heartbeat timeout × 2 strikes ≈ close 120–150 s after last heartbeat). The provider's own suspension detector then reconnects immediately on the next wake, producing one short session per wake cycle. This is **not** a ping/pong bug, not a handshake bug, and not a load-balancer idle timeout — a live connection is kept alive by client-initiated pings every 10 s with a 30 s pong timeout, and heartbeats every 5 s.

A secondary finding is coordinator-side and fixable: **`disconnect_reason` was a single catch-all**. Every `registry.Disconnect` path (graceful close, abrupt read error, stale eviction, duplicate-serial kick) wrote the same string `"disconnect"` — 96.9% of all rows — so the table could not distinguish any of these mechanisms without staleness inference. That telemetry blindness is fixed in this PR (see § Fix).

## Data

### 1. disconnect_reason distribution (Jun 27 – Jul 3)

| reason | sessions | share |
|---|---|---|
| `disconnect` | 30,196 | 96.9% |
| `coordinator_restart` | 637 | 2.0% |
| (empty = still open at query time) | 321 | 1.0% |

`disconnect` is written by every `registry.Disconnect` path, so this distribution carries no diagnostic signal — motivating both the staleness-based inference below and the code fix.

Per day (sessions with reason `disconnect` / `coordinator_restart`): 06-27: 5421/0 · 06-28: 4211/0 · 06-29: 4340/0 · 06-30: 3838/1 · 07-01: 4139/157 · 07-02: 3137/96 · 07-03: 5165/383. Churn is flat across the week (13–18 sessions/serial/day); the `coordinator_restart` rows track actual deploys.

### 2. Session durations

Global histogram (closed sessions):

| duration | sessions | share |
|---|---|---|
| <10 s | 267 | 0.9% |
| 10–30 s | 644 | 2.1% |
| 30–60 s | 1,289 | 4.2% |
| **1–5 min** | **19,491** | **63.2%** |
| 5–30 min | 2,347 | 7.6% |
| 30 min–2 h | 3,365 | 10.9% |
| 2–12 h | 2,480 | 8.0% |
| >12 h | 950 | 3.1% |

The 1–5 min bucket is a sharp spike at **120–180 s** (15,092 sessions between 120–195 s; per-15 s peak at 135–150 s). These are not 30-second handshake failures and not hours-long natural sessions — they are exactly the shape the eviction pipeline produces (§ Mechanism).

Percentiles by reason: `disconnect` p10 = 80 s, **p50 = 157 s**, p90 = 2.1 h, p99 = 28.8 h. `coordinator_restart` p50 = 2.2 h (deploys mid-natural-session, as expected).

### 3. Mechanism inference via silence-at-close

`disconnected_at − last_seen` separates "the coordinator saw a live socket event" from "the row was closed long after the machine went quiet". (`last_seen` is advanced by the 30 s-throttled heartbeat persist, so a live close shows ≤ ~35 s staleness and an eviction shows ≥ 90 s.)

| inferred mechanism | sessions | share | p50 duration | p50 reconnect gap |
|---|---|---|---|---|
| **eviction-like** (silence >60 s before close) | 19,777 | **65.4%** | 150 s | 834 s (~14 min); 71% reconnect in 5 min–1 h |
| live close (socket event while heartbeating) | 8,376 | 27.7% | 35 min | 29 s; 14% reconnect <5 s |
| ambiguous (35–60 s) | 2,098 | 6.9% | ~2 min | — |

For the 120–180 s spike specifically: 93.9% show >2 min of silence before close, and 69.5% heartbeated for **less than one minute** before going quiet (27.2% never advanced `last_seen` past connect at all). Pattern: connect → register → heartbeat briefly → silence → evicted ~2–2.5 min after connect → machine reappears 5 min–1 h later.

The two populations also differ in reconnect behavior: eviction-like closes are followed by long gaps (sleep), live closes by near-instant reconnects (process restart / update / brief network blip).

### 4. Top-20 churning serials

The top 20 serials account for 8,839 sessions (28% of the week). 19 of 20 show the same signature — p50 duration 135–165 s, majority of sessions in the 120–180 s bucket, `disconnect` reason, eviction-like staleness (7,316 of their 8,839 closes are eviction-like vs 927 live):

| serial (prefix) | sessions | p50 dur | sessions in 120–180 s | latest version |
|---|---|---|---|---|
| K66KK9JVDF | 727 | 150 s | 456 | 0.7.3 |
| D71W2TF6FX | 604 | 138 s | 429 | 0.7.3 |
| W6VXLXHG4L | 594 | 149 s | 428 | 0.7.3 |
| LCD7VCQ5KK | 576 | 142 s | 379 | 0.7.3 |
| DY62JNVWDF | 538 | 145 s | 331 | 0.7.3 |
| G272CLWML2 | 514 | **16 s** | 16 | 0.7.1 |
| CT62WWY4GJ | 477 | 141 s | 462 | 0.7.2 |
| … | | | | |

Version correlation: none that matters — churners run current builds (0.7.x). Machines whose latest version is 0.7.1/0.7.2 average higher (112–120 sessions/machine) than 0.7.3 (62), but that is confounded by 0.7.1/0.7.2 selecting for always-on boxes that churn through wake cycles all week; the top churner runs 0.7.3.

**Outlier `G272CLWML2`** (514 sessions, p50 16 s): a distinct pathology. Sessions live 15–60 s, die on a *live* socket error 11–16 s after connect, at an exact ~6-minute cadence for hours (11:06:42, 11:12:44, 11:18:45, …). That periodicity is a local crash/restart or network-path failure loop on that one box — provider-side investigation (its crash logs / `provider_log_reports`), not a coordinator behavior.

### 5. Reconnect gaps (all sessions, same-serial disconnect → next connect)

| gap | share |
|---|---|
| <1 s | 4.9% |
| 1–5 s | 1.9% |
| 5–15 s | 3.7% |
| 15–60 s | 22.3% |
| 1–5 min | 11.6% |
| **5 min–1 h** | **52.6%** |
| >1 h | 2.9% |

No evidence of tight reconnect storms: <1 s gaps are only 4.9% (and concentrate in the live-close population — restart/update loops). The dominant gap (5 min–1 h) is sleep-cycle-shaped, not backoff-shaped (provider backoff caps at 30 s).

## Code-level mechanism, per major pattern

### Eviction-like closes (65%) — sleep/wake churn

Provider side (`CoordinatorClient+Connection.swift`): heartbeat every 5 s (`heartbeatIntervalSecs = 5`), client-initiated WS ping every 10 s with a 30 s pong timeout, and a **suspension detector** — if the 10 s ping-timer tick arrives >30 s late (wall clock), the process was suspended (sleep/App Nap) and the client throws `suspensionDetected` to reconnect immediately on wake. `ExponentialBackoff(base: 1 s, max: 30 s)`. The provider spawns `caffeinate -s -i -w <pid>`, but `-s` only prevents sleep **on AC power**; battery boxes, lid-closed Macs, and forced sleeps still suspend.

Coordinator side: no server-initiated pings and **no read deadline** on the provider WS (`handleProviderWS` → blocking `conn.Read`) — a silent peer is detected only by the registry's eviction sweep: `StartEvictionLoop(ctx, 90 s)` sweeps every 30 s and evicts after 2 consecutive stale strikes (`registry.go: evictStale`), i.e. 120–150 s after the last heartbeat. `Disconnect` closes the socket (`closeWriterNow`), unblocking the read loop, and writes the session row.

Composite timeline that produces the observed 120–180 s sessions: box wakes → provider reconnects within ~1 s → registers, heartbeats for 5–60 s → box sleeps again → coordinator hears nothing → evicted 120–150 s after silence → row closed (`disconnect`, staleness > 90 s) → box wakes 5 min–1 h later → repeat. Each cycle burns a new `provider_id` (a fresh UUID per connection), wiping learned TPS EWMAs and cache affinity, and inflating telemetry cardinality.

### Live closes (28%) — natural ends and restart loops

Socket dies while heartbeats are current: provider process stop/update (WS close frame), crash (TCP reset — the `G272CLWML2` loop), or genuine network loss. p50 duration 35 min, reconnect gap p50 29 s. This population is the ordinary lifecycle plus a tail of per-box pathologies; pre-fix it was indistinguishable from eviction in the DB.

### `coordinator_restart` (2%)

Startup reconcile (`CloseOpenProviderSessions` in `cmd/coordinator/main.go`) closes rows orphaned by a dead coordinator process, fenced on `last_seen < staleBefore` so blue-green peers aren't truncated. Working as designed; tracks deploy days (07-01 through 07-03).

## Root cause conclusion

Reconnect churn is **provider-environment-driven, not coordinator-protocol-driven**: machines (overwhelmingly a ~20-serial heavy-churn cohort) sleep shortly after waking and reconnecting, the coordinator correctly evicts them ~2–2.5 min later, and the wake→reconnect→sleep→evict cycle repeats. The coordinator's WS lifecycle, ping/pong, and eviction settings are functioning as designed; there is no coordinator-side bug that *causes* the reconnects. The genuine coordinator-side defects were observability ones: (a) `disconnect_reason` was a non-diagnostic catch-all across all disconnect paths, and (b) peer-initiated closes were unmetered (only `read_error` incremented `ws_disconnects_total`). Both fixed here.

## Fix shipped in this PR (coordinator-side, `api/provider.go` only)

1. **Session `disconnect_reason` enrichment.** On read-loop exit, the coordinator now stamps the session row with the observed socket outcome **before** the deferred `registry.Disconnect` writes its generic close (the store's first-close-wins upsert keeps the earlier, more specific reason):
   - `ws_close_<code>` — peer sent a WS close frame (1000 normal, 1001 going away, 1008 = coordinator challenge force-reconnect, …);
   - `oom_suspected` — abrupt drop under memory pressure with in-flight work (reuses `registry.ClassifyDisconnectReason`, previously metric-only);
   - `read_error` — socket died without a close frame (reset, NAT teardown, sleep mid-write).

   The stamp is skipped when the provider never registered (no row exists), when the coordinator itself is shutting down (startup reconcile owns `coordinator_restart`), and when the registry disconnected first (eviction / duplicate-serial kick) — so post-fix, a lingering `"disconnect"` value ≈ "reaped by the stale-eviction sweep", making the dominant churn mechanism directly queryable instead of inferred from staleness.
2. **Missing metric tag**: peer-close disconnects now increment `ws_disconnects_total{reason="peer_close"}` and Datadog `ws.disconnects` with the close code; previously only `read_error` was counted, so graceful closes were invisible on dashboards.

No protocol messages changed, no WS restructure, no session resume, no registry/ edits. Tests: `coordinator/api/provider_disconnect_reason_test.go` (reason mapping; peer-close, abrupt-close, and registry-first-eviction integration paths over the real WS handler); full `go test ./api/...` green, `gofmt -l` clean.

## Prioritized fix list

| # | Fix | Side | Impact / rationale |
|---|---|---|---|
| 1 | Stamp real socket outcome into `disconnect_reason` + peer-close metric (**shipped, this PR**) | coordinator | Unblocks all future churn work: eviction vs graceful vs crash becomes directly measurable per serial/day. |
| 2 | Label the stale-eviction path distinctly (e.g. `stale_eviction` instead of `disconnect` in `registry.Disconnect`, or a reason parameter) | coordinator (`registry/` — **owned by the breaker-state agent, do not touch in this PR**) | Completes the taxonomy; today eviction is only identifiable as "the reason nothing else claimed". |
| 3 | Session resume / stable provider identity across reconnects (keyed by serial or SE key rather than per-connection UUID) | coordinator (protocol + registry; explicitly out of scope here) | The real churn *cost* is state loss + cardinality, not the reconnects themselves. A sleeping Mac fleet will always churn; making reconnects cheap is the durable fix. The breaker-state agent's work is the first slice of this. |
| 4 | Sleep prevention hardening: `caffeinate -s` is AC-only — consider `-i`-scoped assertions plus surfacing "this box sleeps constantly" to operators (`darkbloom doctor` check; the top 20 serials = 28% of all churn) | provider | Attacks the root cause on the heavy-churn cohort. Needs Swift changes; not this PR. |
| 5 | Investigate `G272CLWML2`-class outliers (exact 6-min live-close loop) via `provider_log_reports` | provider / ops | One box ≈ 500 sessions/week; likely crash-restart loop. |
| 6 | Optional: raise eviction grace for boxes with clean heartbeat history, or make eviction latency adaptive | coordinator (registry) | Low value until #3 lands — longer grace merely delays the same eviction and keeps unroutable boxes in candidate sets. Not recommended now. |

## Appendix: environment notes

- Eviction math: 90 s timeout, 30 s sweep cadence, 2-strike threshold → eviction fires 120–150 s after last heartbeat; DB `last_seen` lags true heartbeat by ≤30 s (persist throttle), matching the observed 120–180 s staleness/duration peak.
- Query hygiene: all analysis queries ran <1 s against `provider_sessions` (104 k rows), SELECT-only.
