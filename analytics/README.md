# Analytics

Standalone read-only analytics service for Darkbloom / EigenInference.

This service is meant to sit beside the coordinator, not inside it.
It serves public read models like:

- network overview
- earnings leaderboards
- pseudonymous rankings
- future provider/model aggregates

## Current API

Public-facing:

- `GET /healthz`
- `GET /v1/overview`
- `GET /v1/leaderboard/earnings?scope=account|node&window=24h|7d|30d|all&limit=25`

Provider liveness (intended for internal / admin dashboards — gate or
leave un-routed at the public DNS layer):

- `GET /v1/providers/{id}/liveness` — pre-aggregated reliability summary
  (uptime, MTBF, P10/P50/P90 session length, P(stays ≥4h / ≥8h), hourly
  availability matrix, disconnect reason histogram).
- `GET /v1/providers/{id}/sessions?window=24h|7d|30d&limit=N` — recent
  session intervals with connect/disconnect timestamps and reasons.
- `GET /v1/providers/{id}/heartbeats?window=24h|7d|30d&limit=N` — recent
  heartbeat samples (status + memory pressure + CPU + thermal).
- `GET /v1/providers/reliability?min_uptime=0.95&min_stays_4h=0.8&limit=N` —
  shortlist of providers meeting a reliability bar, ordered by uptime
  descending. Foundation for sticky / job-aware scheduling.
- `GET /v1/network/availability` — fleet-wide distribution
  (mean / p10 / p50 / p90 uptime + count of highly-reliable providers).

`scope=account` is the default for the earnings leaderboard. That is the main
public leaderboard shape because it ranks operators, not individual nodes.

Aliases are deterministic and secret-backed:

- same account => same alias every time
- no account ID leaks to the client
- no direct reverse mapping without the secret

## Run

Memory-backed dev mode is the default and does not touch Postgres:

```bash
cd analytics
go run ./cmd/analytics
```

Then hit:

```bash
curl http://localhost:8090/healthz
curl "http://localhost:8090/v1/overview"
curl "http://localhost:8090/v1/leaderboard/earnings?scope=account&window=7d&limit=10"
```

## Config

Environment variables:

- `ANALYTICS_ADDR` default `:8090`
- `ANALYTICS_BACKEND` default `memory`, optional `postgres`
- `ANALYTICS_DATABASE_URL` required when backend is `postgres`
- `ANALYTICS_PSEUDONYM_SECRET` required for `postgres`, optional in `memory`
- `ANALYTICS_ALLOW_ORIGIN` default `*`
- `ANALYTICS_ACTIVE_NODE_WINDOW` default `2m`

In memory mode, if no pseudonym secret is provided, the service generates a
fresh random secret on boot so aliases stay deterministic for that process
without shipping a known default secret.

## Postgres Mode

When the dedicated DB user exists, switch to:

```bash
export ANALYTICS_BACKEND=postgres
export ANALYTICS_DATABASE_URL="postgres://analytics_readonly:password@host:5432/dbname?sslmode=require"
export ANALYTICS_PSEUDONYM_SECRET="replace-me"
go run ./cmd/analytics
```

This service currently reads from:

- `providers`
- `provider_earnings`
- `provider_heartbeats` (populated by the coordinator's liveness writer)
- `provider_sessions` (populated by the coordinator's session tracker)
- `provider_reliability_features` (populated by the coordinator's rollup worker)

Recommended DB role:

```sql
CREATE ROLE analytics_readonly WITH LOGIN PASSWORD '…' CONNECTION LIMIT 8;
GRANT CONNECT ON DATABASE <db> TO analytics_readonly;
GRANT USAGE ON SCHEMA public TO analytics_readonly;
GRANT SELECT ON providers, provider_earnings,
                provider_heartbeats, provider_sessions,
                provider_reliability_features
      TO analytics_readonly;
ALTER ROLE analytics_readonly SET statement_timeout = '10s';
ALTER ROLE analytics_readonly SET idle_in_transaction_session_timeout = '5s';
```

In prod, point `ANALYTICS_DATABASE_URL` at a Postgres read replica so
analytics queries never compete with operational queries for I/O. In dev /
test, the primary is fine. **Do not** grant this role any `INSERT` / `UPDATE`
/ `DELETE` privileges — the analytics service is read-only by design.

## Design Notes

- The analytics service is a separate top-level module so it can evolve without
  bloating the coordinator.
- The first real feature is a public earnings leaderboard.
- The service already supports a real Postgres backend, but defaults to memory
  so we can build the API and UI before touching production credentials.
- Live coordinator-only fields like queue depth or backend capacity are not part
  of this first pass because they are not durable in Postgres today.
