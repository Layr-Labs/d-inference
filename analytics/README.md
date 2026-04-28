# Analytics

Standalone read-only analytics service for Darkbloom / EigenInference.

This service is meant to sit beside the coordinator, not inside it.
It serves public read models like:

- network overview
- earnings leaderboards
- pseudonymous rankings
- future provider/model aggregates

## Current API

- `GET /healthz`
- `GET /v1/overview`
- `GET /v1/leaderboard/earnings?scope=account|node&window=24h|7d|30d|all&limit=25`

`scope=account` is the default. That is the main public leaderboard shape because
it ranks operators, not individual nodes.

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

Recommended DB user shape:

- read-only user
- `SELECT` on the analytics tables only
- no write privileges

## Design Notes

- The analytics service is a separate top-level module so it can evolve without
  bloating the coordinator.
- The first real feature is a public earnings leaderboard.
- The service already supports a real Postgres backend, but defaults to memory
  so we can build the API and UI before touching production credentials.
- Live coordinator-only fields like queue depth or backend capacity are not part
  of this first pass because they are not durable in Postgres today.
