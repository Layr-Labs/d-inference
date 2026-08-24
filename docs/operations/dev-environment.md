# Dev environment

> Last updated: 2026-09-03 · commit `5d400cf75`

Runbook for the Darkbloom dev environment on Google Cloud (project
`sepolia-ai`): a GCE VM running the same coordinator container as production,
auto-deployed by Cloud Build on every push to `master`, plus a dev console on
Vercel, a dev R2 bucket, and a small Mac fleet. Dev exists so coordinator,
provider bundle, console, MDM enrollment, and the release pipeline can be
exercised end-to-end without touching production. Nothing here deploys to
production (`darkbloom-mainnet`); that is
[coordinator-deploy.md](coordinator-deploy.md).

## When to use

- Standing up dev from scratch (steps 1–6) or re-bootstrapping after teardown.
- Changing a dev secret or non-secret setting (step 7).
- Publishing a dev provider release, onboarding a dev Mac, or rolling the dev
  coordinator back to an older image.

## Prerequisites

- `gcloud` authenticated against `sepolia-ai` with rights to Compute, Cloud
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
| Image | Artifact Registry `us-central1-docker.pkg.dev/sepolia-ai/coordinator/coordinator:<SHORT_SHA>` (+ `:latest`), built by [`deploy/gcp/cloudbuild.yaml`](../../deploy/gcp/cloudbuild.yaml) with `BUILD_VERSION=dev`, `BUILD_COMMIT=$COMMIT_SHA` | `/health` reports `version: "dev"` and the full `build_commit` |
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
service account, empty Secret Manager entries, Cloud SQL `d-inference-dev-db`,
the data disk, the static IP, and the VM with
`deploy/gcp/vm-startup.sh` as its startup script. It prints the static IP.

### 2. Populate secrets

```bash
echo -n '<value>' | gcloud secrets versions add <secret-name> --data-file=- --project=sepolia-ai
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
| `eigeninference-r2-cdn-url` | Public URL of `d-inf-app-dev`, e.g. `https://pub-<id>.r2.dev`; templated into `install.sh` and required by `POST /v1/releases` |
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
gcloud builds submit --config=deploy/gcp/cloudbuild.yaml --project=sepolia-ai
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
  `EIGENINFERENCE_REFERRAL_SHARE_PCT`, `EIGENINFERENCE_BASE_URL`, …): these are
  literal lines in **both** `deploy/gcp/refresh-env.sh` and
  `deploy/gcp/vm-startup.sh` (the boot path). Edit both, merge, and let Cloud
  Build redeploy. There is no `--set-env-vars`; the env file is the only
  source.
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

The dev coordinator serves `install.sh` with its own URL and CDN templated in,
so the provider can only ever register with dev. Add the host's SSH alias to
`deploy/provider-fleet/dev-inventory.txt`; `deploy/provider-fleet/update-fleet.sh dev`
re-runs the installer on every listed Mac.

## Verification

```bash
scripts/smoke-dev.sh                              # /health, /v1/stats, /v1/models/catalog, install.sh templating
API_KEY=<dev api key> scripts/smoke-dev.sh        # + an authenticated chat completion
curl -fsS https://api.dev.darkbloom.xyz/health | jq .            # version "dev", build_commit = deployed SHA
curl -fsS https://api.dev.darkbloom.xyz/v1/releases/latest | jq .
gcloud builds list --project=sepolia-ai --limit=5
gcloud compute ssh d-inference-dev --zone=us-central1-a --project=sepolia-ai --tunnel-through-iap -- \
  'sudo systemctl status d-inference-coordinator --no-pager; sudo docker logs --tail 50 d-inference-coordinator'
```

## Rollback

**Coordinator** — images stay in Artifact Registry by short SHA. Point the VM
at an older one and restart (~1 minute):

```bash
gcloud compute instances add-metadata d-inference-dev --zone=us-central1-a --project=sepolia-ai \
  --metadata=DINF_IMAGE_TAG=<older-short-sha>
gcloud compute ssh d-inference-dev --zone=us-central1-a --project=sepolia-ai --tunnel-through-iap -- \
  'sudo systemctl restart d-inference-coordinator'
```

The next `master` push will move `DINF_IMAGE_TAG` forward again.

**Provider bundle** — deactivate the release on the dev coordinator
(`DELETE /v1/admin/releases`, or `scripts/admin.sh releases deactivate <version>`)
so `/v1/releases/latest` falls back to the previous version, then
`deploy/provider-fleet/update-fleet.sh dev`. R2 objects are immutable per
version; see [`provider-release.md`](provider-release.md) ("Rollback").

**Full teardown** (destroys dev state; secrets survive unless deleted):

```bash
gcloud compute instances delete d-inference-dev --zone=us-central1-a --project=sepolia-ai --quiet
gcloud compute disks delete d-inference-dev-data --zone=us-central1-a --project=sepolia-ai --quiet
gcloud sql instances delete d-inference-dev-db --project=sepolia-ai --quiet
```

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

### Enrollment profile signing

Hardware-trust coordinators require a valid `PROFILE_SIGNING_P12_B64` /
`PROFILE_SIGNING_P12_PASSWORD` identity and reject unsigned enrollment profiles.
`EIGENINFERENCE_ALLOW_UNSIGNED_PROFILES=true` is a development/test exception;
production must leave it unset or `false`.
