# W5 — Code-attestation churn: root cause & fix plan

Goal: grow the routable pool (≈67/176 today) by making attestation resilient,
without weakening the fail-closed code-identity property. There are **two
independent challenge systems**, both gate `providerSupportsPrivateTextLocked`:

| Flow | Transport | Cadence | State | Freshness |
|---|---|---|---|---|
| SE liveness | WebSocket | 5-min ticker | `LastChallengeVerified` | `challengeFreshnessMaxAge=6m` (scheduler.go:37) |
| APNs code-identity | APNs push → WS reply | once/connection + bounded retry | `CodeAttested` | per-connection + 30-min reuse |

The 67/176 cap is the **APNs flow** timing out; the 6-min freshness is a
**second** churn source on the routable pool.

## Root causes (ranked)
- **A. Background push is best-effort + budget-throttled, and `apns-expiration=60s` < `CodeAttestResponseTimeout=90s`** (attestor.go:68, provider.go:501). APNs returns 200 on *accept*, not delivery; a sleepy/over-budget device misses it and the coordinator waits 90s for a reply that can't come after 60s.
- **B. Round-trip is connection-scoped** (`codeAttestTracker` per read loop, provider.go). Any reconnect during the 90s window strands the attempt (reply lands on a tracker that never knew the nonce).
- **C. Retry is slow + self-throttling**: `pushCooldown=20m` is reused as retry spacing, and `allowPush` is a device-level gate — a missed first push strands a provider ~20–60m.
- **D. In-memory throttle wiped on every blue-green deploy** → post-deploy push storm against a ~3/hour/device budget.
- **E. APNs token only in RegisterMessage + 10s provider await** → headless/late-token boxes never get challenged, with no re-arm.
- **F. No observability** in the code-attest path (only the SE flow + a coverage gauge).

## Fixes (ordered by ROI / risk)
- **Fix 0 — `APNS_MODE=alert` (config, zero code, HUMAN applies).** Already wired (`main.go` → `apns.ModeAlert`, priority 10, not background-throttled). The design's explicit fallback for unreliable background delivery. Safe only while the provider never requests `UNUserNotificationCenter` auth (it doesn't — INV-6). **Single biggest mover.**
- **Fix 6 — observability (DONE on this branch).** `code_attest_total{outcome=...}` counter (no_token, reused, push_sent, push_send_failed, attested, nonce_mismatch, verify_failed, timeout, max_attempts) via ddIncr + the in-process registry (visible at `/v1/admin/metrics`). Lets us measure the 26% by cohort and gate the alert rollout. Metadata only.
- **Fix 1 — decouple round-trip from the 90s connection-blocking wait.** Verify in the read-loop delivery path (any connection); push lives longer (`challengeExpirySeconds`→~300–600). Kills A+B. Concurrency-sensitive (set `CodeAttested` under `provider.Mu()`).
- **Fix 3 — mode-aware retry/backoff + jitter.** Separate delivery-retry spacing from the device budget; alert ⇒ ~60–90s cooldown. Kills C.
- **Fix 2 — survive deploys + re-arm on late token.** Persist reuse behind the store seam (same 30-min, version-gated semantics); add APNs token to HeartbeatMessage to re-arm without reconnect. Kills D+E. *NOTE: touches protocol/messages.go + registry Heartbeat → sequence AFTER W1 (monitors) to avoid conflict.*
- **Fix 4 — widen `challengeFreshnessMaxAge` 6→16m.** Stops single-missed-tick routable flapping. Security-staleness trade (liveness, not code identity) — ROLL OUT BEHIND REVIEW; single const, revertable.
- **Fix 5 — fix timeout ordering** (expiry vs wait), coupled to Fix 1.

## Security invariants preserved
Fail-closed code identity (nonce==pushed AND `Sign_SE` verifies against the
registration-bound SE key); Apple-gated encrypted challenge; single fail-closed
chokepoint; per-connection reset + bounded version-gated reuse. Fix 1 *moves*
verification byte-for-byte (no new attest path); persistence keeps the same
window+version gate; freshness widening is a liveness bound only. Add a CI
assertion that the provider never requests notification-center auth (protects
the alert-mode safety condition INV-6).

## Sequencing
1. **Fix 6 (done)** → measure baseline.
2. **Fix 0** (`APNS_MODE=alert`) in dev → prod, watch `code_attest_total` (human).
3. Fix 1 + Fix 5 (event-driven await, expiration ordering).
4. Fix 3 (backoff + jitter); Fix 2 (after W1; token re-arm + persistence).
5. Fix 4 (freshness 6→16m) last, independently revertable.
