# admin-ui — internal read-only ops dashboard

A small Next.js 16 app that reads the **read-only Postgres replica** of the prod
coordinator DB and renders raw user / machine / billing / earnings / uptime
data for operators. It issues **SELECT-only** queries (the `readonly` role has
no write grants, and the replica is physically read-only).

## ⚠️ Deployment security

This tool exposes raw user, billing, and API-key metadata. The only app-level
control is a single shared HTTP Basic Auth credential (see `src/proxy.ts` →
`src/lib/auth.ts`), which fails closed when unconfigured. **Before exposing it
beyond `localhost`, put it behind a real network gate** — VPN, IAP, Cloudflare
Access, or an IP allowlist. Do not run it on a public origin with only Basic
Auth. (Slated to move behind SSO/IAP — see the TODO in `auth.ts`.)

## Environment variables

| Var | Required | Purpose |
|-----|----------|---------|
| `ADMIN_DB_URL` | yes | Postgres connection string for the **read-only replica** (use the `readonly` role). The app fails to start if unset. |
| `ADMIN_BASIC_USER` | yes | Basic Auth username. Auth fails closed (denies all) if unset. |
| `ADMIN_BASIC_PASS` | yes | Basic Auth password. |
| `ADMIN_DB_SSL_NO_VERIFY` | no | `true` to encrypt without verifying the server cert (internal use only). **Leave unset/false in any exposed deployment** — unset means full cert verification. RDS uses a CA not in the default trust store, so install the AWS RDS global CA bundle and keep verification on. |

Set these in `.env.local` (gitignored) for local dev, or via the deploy
environment. Never commit real connection strings or credentials.

## Scripts

```bash
npm install
npm run dev     # http://localhost:4001
npm run build
npm run lint    # eslint src/
npm test        # vitest
```
