# Production Cutover & Rollback (Milestones 7–8)

**Human-gated.** Agents must not deploy to EigenCloud / mutate prod.

## Prerequisites (architecture §24)

1. MicroMDM extracted to independently supervised service
2. Same-zone Postgres (or coordinator co-located with DB) meeting §16 budgets
3. Additive `rust_coord` migrations applied; no startup DDL pending
4. Rollback-safe Go image understands `rust_coord` + ownership epoch
5. Distinct Go/Rust ports; Caddy can switch consumer / provider WS / MDM independently
6. Encryption KID identical between Go and Rust

## Cutover sequence (serial)

1. Freeze Go fallback + Rust image digests
2. Confirm migrations/indexes applied
3. Capture baselines (capacity, TTFT, balances, Stripe, trust)
4. Freeze releases/models/enrollment/payouts/admin mutations
5. Drain Go; poll `/v1/admin/quiescence` to zero
6. Close Go sessions; release coordinator epoch; stop Go
7. Keep MicroMDM running
8. Start Rust passive; verify schema/secrets/KID
9. Acquire Rust epoch; enable provider WS + MDM callbacks first
10. Wait for trust/capacity thresholds
11. Switch Caddy consumer routes to Rust
12. Smoke plaintext+sealed, stream+non-stream
13. Unfreeze reads → inference → models → admin → Stripe

## Immediate rollback triggers

- Duplicate/unexplained money
- Plaintext/invalid encrypted provider traffic
- <90% model capacity after 5m / <95% aggregate after 10m
- 5xx +0.25pp for 5 consecutive minutes
- Fleet-wide MDM/APNs spike
- FleetActor / terminal worker / reconcile invariant failure

## Normal rollback (§26.1)

1. Drain Rust; quiescence to zero including fee-projection backlog
2. No `review_pending` rows; every external intent Go-reconcilable
3. Release Rust epoch; start rollback-safe Go passive
4. Acquire Go epoch; provider WS first, then consumer
5. Do **not** restore PostgreSQL for normal rollback

## Emergency

Use same-release Rust `recovery` subcommand/image — not an arbitrary older image.
Go must not serve new paid traffic over active Rust jobs unless explicitly fenced.
