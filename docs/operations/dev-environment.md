# Dev environment

> Last updated: 2026-10-05

Runbook for the Darkbloom dev environment on Google Cloud (project
`darkbloom-dev`): a GCE VM running the same coordinator container as production,
plus a dev console on Vercel, a dev R2 bucket, and a small Mac fleet. Cloud
Build deploys the VM on each push to `master` once the trigger in step 6
exists; that trigger does not exist yet
([#1067](https://github.com/Layr-Labs/d-inference/issues/1067)). The previous
dev project, `sepolia-ai`, is retired. Dev exists so coordinator, provider
bundle, console, MDM enrollment, and the release pipeline can be exercised
end-to-end without touching production. Nothing here deploys to
production (`darkbloom-mainnet`); that is
[coordinator-deploy.md](coordinator-deploy.md).

## When to use

- Standing up dev from scratch (steps 1–6) or re-bootstrapping after teardown.
- Changing a dev secret or non-secret setting (step 7).
- Publishing a dev provider release, onboarding a dev Mac, or rolling the dev
  coordinator back to an older image.
- Filling an empty dev database with synthetic data (step 10) to test
  migrations and account erasure. The remaining human-only work is in the
  [DevNet checklist](#devnet-checklist).

## Prerequisites

The dev templates set `EIGENINFERENCE_DEPLOYMENT_ENVIRONMENT=development`.
This explicit classification skips the production App Attest cutover prerequisite
and legacy-cohort freeze, including with dev Postgres; `DD_ENV=development`
alone does not. Local startup using actual opted-in memory-store fallback also
skips the freeze. A database subsequently started as production freezes its
then-current eligible cohort, not a cutoff from dev startup. See the
[deployment setting](../reference/configuration.md#deployment-environment).

- `gcloud` authenticated against `darkbloom-dev` with rights to Compute, Cloud
  Build, Artifact Registry, Secret Manager, and Cloud SQL.
- `mise install` locally (for `scripts/smoke-dev.sh`, `jq`, `gh`).
- A dev Privy app, a dev Stripe account, and a Cloudflare R2 bucket
  `d-inf-app-dev` with a bucket-scoped token (for the release workflow's
  `DEV_R2_*` secrets; see [`provider-release.md`](provider-release.md)).
- Optional: one or more Apple Silicon Macs to enrol as dev providers.

### What dev looks like

| Component | Where | Identifier |
|---|---|---|
| Coordinator | GCE VM `d-inference-dev`, zone `us-central1-a`, `e2-small` (default in [`deploy/gcp/bootstrap.sh`](../../deploy/gcp/bootstrap.sh)), Ubuntu + Docker + systemd | `https://api.dev.darkbloom.xyz` (static IP `d-inference-dev-ip`) |
| Image | Artifact Registry `us-central1-docker.pkg.dev/darkbloom-dev/coordinator/coordinator:<SHORT_SHA>` (+ `:latest`), built by [`deploy/gcp/cloudbuild.yaml`](../../deploy/gcp/cloudbuild.yaml) with `BUILD_VERSION=dev`, `BUILD_COMMIT=$COMMIT_SHA` | `/health` reports `version: "dev"` and the full `build_commit` |
| Container | `d-inference-coordinator`, `--network host`, `--env-file /etc/d-inference/env`, bind mount `/mnt/disks/userdata`; run by systemd unit `d-inference-coordinator.service` via `/usr/local/bin/d-inference-run.sh`, which reads the tag from VM metadata `DINF_IMAGE_TAG` (default `latest`) and `docker pull`s on every start | [`deploy/gcp/vm-startup.sh`](../../deploy/gcp/vm-startup.sh) |
| Persistent disk | `d-inference-dev-data` mounted at `/mnt/disks/userdata` (MicroMDM BoltDB, prompt artifacts) — same path as prod so `start.sh` is unchanged | |
| Database | Cloud SQL Postgres 16 `d-inference-dev-db` (`db-f1-micro`), reached via `cloud-sql-proxy.service` on `127.0.0.1:5432` | `EIGENINFERENCE_DATABASE_URL` |
| Ingress | Host Caddy (systemd) terminates TLS and proxies to `:8080` | `DOMAIN=api.dev.darkbloom.xyz` |
| Telemetry | Host Datadog Agent (`DD_ENV=development`, `DD_SERVICE=d-inference-coordinator`) | secrets `eigeninference-dd-api-key`, `eigeninference-dd-site` |
| Console UI | Vercel project `darkbloom-console-dev` from `console-ui/` | `https://console.dev.darkbloom.xyz` |
| Release bucket | Cloudflare R2 `d-inf-app-dev`; its public URL is secret `eigeninference-r2-cdn-url` → `EIGENINFERENCE_R2_CDN_URL` | |
| Mac fleet | [`deploy/provider-fleet/dev-inventory.txt`](../../deploy/provider-fleet/dev-inventory.txt) | `deploy/provider-fleet/update-fleet.sh dev` |
| Trust posture | Same as prod: MicroMDM inside the container, `EIGENINFERENCE_MIN_TRUST=hardware`, `EIGENINFERENCE_BILLING_MOCK=false` | |

Why a VM and not Cloud Run: MicroMDM keeps BoltDB and the push certificate on
local disk; Cloud Run's ephemeral filesystem does not survive revisions and
gcsfuse is unsafe for BoltDB.

## Steps

### 1. Bootstrap GCP

```bash
deploy/gcp/bootstrap.sh          # PROJECT/REGION/ZONE/INSTANCE/MACHINE_TYPE/SQL_INSTANCE overridable via env
```

Idempotent. Creates the Artifact Registry repo `coordinator`, the coordinator
service account, Cloud SQL `d-inference-dev-db`, the data disk, the static IP,
and the VM with `deploy/gcp/vm-startup.sh` as its startup script. It prints the
static IP. It creates empty Secret Manager entries for 10 secrets only
(`create_secret` in `deploy/gcp/bootstrap.sh`): the admin key, release key,
mnemonic, three Privy secrets, database URL, MicroMDM API key, MDM push
certificate and R2 CDN URL. Step 2 lists the secrets you must create yourself.

### 2. Populate secrets

```bash
echo -n '<value>' | gcloud secrets versions add <secret-name> --data-file=- --project=darkbloom-dev
```

Bootstrap does not create the profile-signing, Stripe, Datadog or ip-api
secrets. Create each of them once before you add its first version:

```bash
gcloud secrets create <secret-name> --replication-policy=automatic --project=darkbloom-dev
```

| Secret | Value |
|---|---|
| `eigeninference-admin-key`, `eigeninference-release-key` | `openssl rand -hex 32` each. The release key must also be set as the GitHub secret `DEV_RELEASE_KEY` |
| `eigeninference-solana-mnemonic` | Legacy name. A **new** BIP39 mnemonic for the coordinator's X25519 key derivation (`MNEMONIC`); never reuse production's |
| `eigeninference-privy-app-id`, `eigeninference-privy-app-secret`, `eigeninference-privy-verification-key` | Dev Privy app dashboard |
| `eigeninference-database-url` | Written by bootstrap when it creates Cloud SQL |
| `eigeninference-micromdm-api-key` | `openssl rand -hex 32`; injected as both `MICROMDM_API_KEY` and `EIGENINFERENCE_MDM_API_KEY` |
| `eigeninference-mdm-push-p12-b64` | Apple MDM push PKCS#12, base64url: `base64 < push.p12 \| tr '/+' '_-' \| tr -d '\n='` |
| `eigeninference-profile-signing-p12-b64`, `eigeninference-profile-signing-p12-password` | Optional Developer ID identity used to CMS-sign the `/v1/enroll` profile; unset serves it unsigned |
| `eigeninference-r2-cdn-url` | Public URL of `d-inf-app-dev`, e.g. `https://pub-<id>.r2.dev`; required by `POST /v1/releases`, which checks release URLs against it |
| `eigeninference-stripe-secret-key`, `eigeninference-stripe-webhook-secret`, `eigeninference-stripe-connect-webhook-secret`, `eigeninference-stripe-success-url`, `eigeninference-stripe-cancel-url`, `eigeninference-stripe-connect-return-url`, `eigeninference-stripe-connect-refresh-url` | Dev Stripe account |
| `eigeninference-dd-api-key`, `eigeninference-dd-site` | Datadog |
| `eigeninference-ipapi-key` | Optional ip-api.com PRO key; empty falls back to the free tier |

`deploy/gcp/refresh-env.sh` refuses to overwrite the env file when any of
`EIGENINFERENCE_ADMIN_KEY`, `EIGENINFERENCE_DATABASE_URL`,
`EIGENINFERENCE_STRIPE_SECRET_KEY`, `EIGENINFERENCE_STRIPE_WEBHOOK_SECRET`,
`EIGENINFERENCE_STRIPE_CONNECT_WEBHOOK_SECRET` resolves empty, so set those
before the first deploy.

### 3. DNS

```
api.dev.darkbloom.xyz      A      <VM static IP>
console.dev.darkbloom.xyz  CNAME  <target Vercel shows after step 5>
```

### 4. First coordinator deploy

```bash
gcloud builds submit --config=deploy/gcp/cloudbuild.yaml --project=darkbloom-dev
```

The build tags `:$SHORT_SHA` and `:latest`, pushes both, then the `deploy`
step: writes `DINF_IMAGE_TAG=$SHORT_SHA` to VM metadata, refreshes the
`startup-script` metadata from `deploy/gcp/vm-startup.sh`, pipes
`deploy/gcp/refresh-env.sh` over IAP SSH (`sudo bash -s`) to regenerate
`/etc/d-inference/env` from Secret Manager, runs
`sudo systemctl restart d-inference-coordinator`, and polls
`https://api.dev.darkbloom.xyz/health` for up to 4 minutes. ~2–4 minutes
end-to-end; the fleet sees a ~10 s blip and reconnects.

### 5. Console UI on Vercel

1. Import the repo as project `darkbloom-console-dev`, root directory
   `console-ui/`.
2. Env: `NEXT_PUBLIC_COORDINATOR_URL=https://api.dev.darkbloom.xyz`.
3. Add domain `console.dev.darkbloom.xyz`; copy the CNAME target into step 3.

Every push to `master` auto-builds; preview branches also talk to the dev
coordinator.

The repository-root `vercel.json` and `console-ui/vercel.json` both exclude
exactly `release/0.9.0-validation` from Git deployments. These cover a project
configured at the repository root or at the documented console UI root. Other
branches retain Vercel's default behavior; no project-wide settings or deployment
environments are changed by this branch-specific rule.

### 6. Connect GitHub → Cloud Build

One-time in the Cloud Console: install the Cloud Build GitHub App on
`Layr-Labs/d-inference`, then create a trigger on push to `master` using
`deploy/gcp/cloudbuild.yaml` with the path filter `coordinator/**`,
`deploy/gcp/**`. From then on every merge touching those paths redeploys dev
with no approval step.

### 7. Change a setting

- **Secret:** add a new version in Secret Manager, then either redeploy (any
  Cloud Build run re-runs `refresh-env.sh`) or on the VM run
  `sudo bash deploy/gcp/refresh-env.sh && sudo systemctl restart d-inference-coordinator`.
- **Non-secret value** (`EIGENINFERENCE_MIN_TRUST`, `EIGENINFERENCE_ADMIN_EMAILS`,
  `EIGENINFERENCE_BASE_URL`, …): these are
  literal lines in **both** `deploy/gcp/refresh-env.sh` and
  `deploy/gcp/vm-startup.sh` (the boot path). Edit both, merge, then redeploy
  with step 4's `gcloud builds submit` until the step 6 trigger exists. There is
  no `--set-env-vars`; the env file is the only source.
- Variables are read once at process start; a restart is always required.

### 8. Dev provider release

```bash
gh workflow run release-swift.yml --ref <branch> -f environment=dev   # optional -f version_override=X.Y.Z
```

Builds, signs, notarizes, uploads to R2 `d-inf-app-dev`, and registers with
the dev coordinator using the `DEV_*` secrets. Dev tags (`-dev.*`) are
rejected; only dispatch is supported. Details:
[`provider-release.md`](provider-release.md).

### 9. Onboard a Mac

```bash
curl -fsSL https://api.dev.darkbloom.xyz/install.sh | bash
```

The dev coordinator serves `install.sh` with its own URL templated in. Because
that URL is not production, the installer writes
`url = "wss://api.dev.darkbloom.xyz/ws/provider"` under `[coordinator]` in
`~/.config/darkbloom/provider.toml` and keeps every other line of the file
(`scripts/install.sh`, `bind_provider_coordinator`). `darkbloom start`,
`login`, `update`, the LaunchAgent and the watchdog then use dev. A provider
that is already running keeps its old coordinator until you run
`darkbloom start` again.

The installer always binds the provider to the coordinator that served it. To
move a dev Mac back to production, run the production installer
(`curl -fsSL https://api.darkbloom.dev/install.sh | bash`): it removes the `url`
line under `[coordinator]`, keeps every other line, and the provider then uses
its built-in production default. Run `darkbloom start` afterwards. One Mac
cannot serve dev and production at the same time.

Add the host's SSH alias to `deploy/provider-fleet/dev-inventory.txt`;
`deploy/provider-fleet/update-fleet.sh dev` re-runs the installer on every
listed Mac.

### 10. Seed synthetic data

`coordinator/cmd/devnet-seed` fills an **empty** dev database with fake
accounts (`seed-<n>@example.invalid`, `did:privy:seed-<n>`), API keys,
provider machines (serials `SEED00000001`, …) with closed sessions, usage
rows, provider earnings, ledger entries and balances. It writes through the
`store` package methods the coordinator uses. It refuses to run when the
`users` table has any row, and it checks this before it runs migrations. The
command is a thin entry point to `coordinator/internal/command/devnetseed`.

```bash
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o /tmp/devnet-seed ./coordinator/cmd/devnet-seed
gcloud compute scp /tmp/devnet-seed d-inference-dev:/tmp/devnet-seed \
  --zone=us-central1-a --project=darkbloom-dev --tunnel-through-iap
gcloud compute ssh d-inference-dev --zone=us-central1-a --project=darkbloom-dev --tunnel-through-iap -- \
  'EIGENINFERENCE_DATABASE_URL="$(sudo sed -n "s/^EIGENINFERENCE_DATABASE_URL=//p" /etc/d-inference/env)" /tmp/devnet-seed; rm -f /tmp/devnet-seed'
```

Add flags after `/tmp/devnet-seed` to change the scale:

| Flag | Default | Meaning |
|---|---|---|
| `--accounts` | `20` | Accounts (users) |
| `--keys-per-account` | `1` | API keys per account |
| `--providers` | `5` | Provider machines, owned round-robin by the accounts |
| `--sessions-per-provider` | `3` | Closed sessions per machine; each has its own `providers` row |
| `--requests-per-account` | `10` | Requests per account: one charge, one `usage` row and one provider earning each |
| `--balance-micro-usd` | `5000000` | Balance each account keeps after its requests are charged |
| `--workers` | `8` | Accounts or machines written in parallel |

The defaults are small. For a production-like volume, raise the counts, for
example `--accounts 50000 --providers 2000 --requests-per-account 100`. Every
row is a separate store write, so a large run takes a long time on
`db-f1-micro`; that instance also allows few connections, so keep `--workers`
at its default while the coordinator is running.

## Verification

The fleet updater visits every configured host and exits nonzero if any update
fails. Authenticated smoke runs use a unique temporary response file and remove
it when the process exits. Admin login and release-deactivation commands encode
input as JSON values, preserving quotes and backslashes.

```bash
scripts/smoke-dev.sh                              # /health, /v1/stats, /v1/models/catalog, install.sh templating
API_KEY=<dev api key> scripts/smoke-dev.sh        # + an authenticated chat completion
curl -fsS https://api.dev.darkbloom.xyz/health | jq .            # version "dev", build_commit = deployed SHA
curl -fsS https://api.dev.darkbloom.xyz/v1/releases/latest | jq .
gcloud builds list --project=darkbloom-dev --limit=5
gcloud compute ssh d-inference-dev --zone=us-central1-a --project=darkbloom-dev --tunnel-through-iap -- \
  'sudo systemctl status d-inference-coordinator --no-pager; sudo docker logs --tail 50 d-inference-coordinator'
```

## Rollback

**Coordinator** — images stay in Artifact Registry by short SHA. Point the VM
at an older one and restart (~1 minute):

```bash
gcloud compute instances add-metadata d-inference-dev --zone=us-central1-a --project=darkbloom-dev \
  --metadata=DINF_IMAGE_TAG=<older-short-sha>
gcloud compute ssh d-inference-dev --zone=us-central1-a --project=darkbloom-dev --tunnel-through-iap -- \
  'sudo systemctl restart d-inference-coordinator'
```

Once the step 6 trigger exists, the next `master` push moves `DINF_IMAGE_TAG`
forward again. Until then, the next `gcloud builds submit` does.

**Provider bundle** — deactivate the release on the dev coordinator
(`DELETE /v1/admin/releases`, or `scripts/admin.sh releases deactivate <version>`)
so `/v1/releases/latest` falls back to the previous version, then
`deploy/provider-fleet/update-fleet.sh dev`. R2 objects are immutable per
version; see [`provider-release.md`](provider-release.md) ("Rollback").

**Full teardown** (destroys dev state; secrets survive unless deleted):

```bash
gcloud compute instances delete d-inference-dev --zone=us-central1-a --project=darkbloom-dev --quiet
gcloud compute disks delete d-inference-dev-data --zone=us-central1-a --project=darkbloom-dev --quiet
gcloud sql instances delete d-inference-dev-db --project=darkbloom-dev --quiet
```

## DevNet checklist

These steps need a person with the right access. Agents cannot do them.

1. Re-authenticate `gcloud` against `darkbloom-dev` (`gcloud auth login`).
2. Make sure the dev VM is up. Check `gcloud compute instances describe
   d-inference-dev --zone=us-central1-a --project=darkbloom-dev`, start it if
   it is stopped, then run the [verification](#verification) commands.
3. Add the Cloud Build trigger (step 6,
   [#1067](https://github.com/Layr-Labs/d-inference/issues/1067)).
4. Put Stripe **test-mode** keys and the Connect test setup into dev Secret
   Manager (step 2). Global Payouts also needs the
   `EIGENINFERENCE_STRIPE_GLOBAL_PAYOUTS_*` variables
   (`coordinator/billing/config.go`); neither `deploy/gcp/refresh-env.sh` nor
   `deploy/gcp/vm-startup.sh` writes them.
5. Ask Stripe for Redaction Jobs access on the dev account, so that account
   erasure can be tested against Stripe.
6. Enrol at least one dev Mac (step 9).
7. Run `devnet-seed` against the empty dev database (step 10).

## What dev does not cover

- Production's human-approved drain, fallback container, and env-refresh
  contract (`deploy/gcp/prod/`). Dev restarts via systemd with a 30 s stop
  timeout.
- Real users: admin access is limited to `EIGENINFERENCE_ADMIN_EMAILS`
  (`gajesh@eigenlabs.org`).
- Cost realism: `e2-small` + `db-f1-micro` + 30 GB disk + static IP is roughly
  \$25–30/month.

## Related

- [coordinator-deploy.md](coordinator-deploy.md) — production.
- [`provider-release.md`](provider-release.md) — release workflow, `DEV_*` secrets.
- [`../developer/build.md`](../developer/build.md) — the Dockerfile Cloud Build builds.
- [`../provider/installation.md`](../provider/installation.md) — what `install.sh` does on a Mac.
