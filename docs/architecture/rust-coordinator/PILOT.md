# Isolated Pilot Runbook (Milestone 5)

Status: prepared — **human-gated**. Do not run against production.

## Isolation checklist

- [ ] Separate hostname (e.g. `api.pilot.darkbloom…`)
- [ ] Separate Postgres instance or dedicated database
- [ ] Separate MicroMDM enrollment + persistent volume
- [ ] Dedicated provider tokens / SE identities
- [ ] Dedicated API keys (`DARKBLOOM_PILOT_API_KEYS`)
- [ ] No production Stripe webhooks
- [ ] 6–10 owned Macs across hardware classes

## Minimum scope (enabled)

- `/health`, `/readyz`, `/v1/encryption-key`, `/v1/models`
- `/v1/chat/completions` (stream + non-stream)
- `/ws/provider` registration / heartbeat / prepare / start
- `/v1/admin/quiescence`, `/v1/admin/deposits`, `/v1/admin/terminal-ingest`,
  `/v1/admin/force-settle`, `/v1/admin/force-settle-batch`, `/v1/admin/recover-undispatched`, `/v1/admin/recover-undispatched-batch`, `/v1/admin/held-review`, `/v1/admin/held-review-batch`,
  `/v1/admin/adopt-job`, `/v1/admin/adopt-jobs`, `/v1/admin/clear-orphans`, `/v1/admin/outbox-drain`, `/v1/admin/cutover-drain`, `/v1/admin/cancel-attempt`
- Mock provider: `coordinator-rs/scripts/mock_provider_ws.py`
- Self-route first, then pre-funded paid

## Excluded (must return unsupported, never proxy to Go)

Production Stripe webhooks (pilot uses `/v1/admin/deposits` only), Privy admin,
vision/tools, multi-model placement, releases/installer, enrollment, invites,
referrals, public stats.

## Success gates (from architecture §23.3)

| Gate | Requirement |
| --- | --- |
| Duration | ≥ 7 continuous days |
| Volume | ≥ 10,000 completed requests |
| Paid | ≥ 2,000 settled, 500 cancels, 100 terminal replays |
| Money | Zero unexplained balance/usage/earning diffs |
| TTFT | Matched p95 ≤ max(Go×1.20, Go+250ms) |

## Start commands (dev)

```bash
cd coordinator-rs
cargo build --release -p darkbloom-coordinator
PORT=8080 \
  DARKBLOOM_PILOT_API_KEYS=sk-pilot \
  DARKBLOOM_PILOT_MODEL=pilot-text-model \
  DARKBLOOM_PILOT_ACCOUNT=pilot-account \
  DARKBLOOM_OWNERSHIP_HOLDER=pilot-coord-1 \
  DARKBLOOM_OWNERSHIP_LEASE_SECS=30 \
  ./target/release/darkbloom-coordinator
```

### Env vars (pilot)

| Var | Purpose | Default |
| --- | --- | --- |
| `PORT` | Listen port | `8080` |
| `DARKBLOOM_PILOT_API_KEYS` | Comma-separated pilot keys (empty = open) | empty |
| `DARKBLOOM_PILOT_ACCOUNT` | Ledger account for pilot traffic | `pilot-account` |
| `DARKBLOOM_PILOT_MODEL` | Model id advertised in `/v1/models` | `pilot-text-model` |
| `DARKBLOOM_OWNERSHIP_HOLDER` | Local ownership lease holder id | `pid-<pid>` |
| `DARKBLOOM_OWNERSHIP_LEASE_SECS` | Lease TTL for heartbeat steal | `30` |
| `DARKBLOOM_REFUSE_ON_RUST` | Refuse startup if rust_coord active | `false` |
| `DARKBLOOM_ENCRYPTION_KID` | Encryption key id | `dev` |
| `DARKBLOOM_COORDINATOR_SEED_B64` | Optional 32-byte seed (base64) | random |

Apply schema before paid path:

```bash
make migrate
# or:
psql "$DATABASE_URL" -f migrations/0001_rust_coord.sql
psql "$DATABASE_URL" -f migrations/0002_late_terminals.sql
```
