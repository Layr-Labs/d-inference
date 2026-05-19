# Dev Environment Runbook

> The Darkbloom dev environment runs on Google Cloud (GCP project `sepolia-ai`, region `us-central1`). It exists so we can test every code path — coordinator, provider bundle, console-ui, Mac fleet, release pipeline — end-to-end without touching prod.

**Prod runs on EigenCloud and is human-deploy-only (see CLAUDE.md).** Nothing in this runbook deploys to prod.

---

## Table of Contents

- [Infrastructure Overview](#infrastructure-overview)
- [Standing Up Dev from Scratch](#standing-up-dev-from-scratch)
- [Day-to-Day Flow](#day-to-day-flow)
- [Secrets Mapping](#secrets-mapping)
- [GitHub Environments](#github-environments)
- [Rollback](#rollback)
- [Limitations](#limitations)
- [Seeding After a Redeploy](#seeding-after-a-redeploy)
- [Cost](#cost)

---

## Infrastructure Overview

| Component | Location | URL / Identifier |
|-----------|----------|-----------------|
| Coordinator | GCE VM `d-inference-dev` (us-central1-a, Ubuntu 24.04 + Docker + systemd) | `https://api.dev.darkbloom.xyz` (static IP) |
| Persistent disk | GCE persistent disk `d-inference-dev-data` mounted at `/mnt/disks/userdata` | 30 GB, pd-balanced |
| Console UI | Vercel (separate "darkbloom-console-dev" project, built from `console-ui/`) | `https://console.dev.darkbloom.xyz` |
| Database | Cloud SQL Postgres 16, instance `d-inference-dev-db`, `db-f1-micro` | `127.0.0.1:5432` via cloud-sql-proxy |
| Release bucket | Cloudflare R2 `d-inf-app-dev` | R2 CDN URL in env vars |
| Secrets | Google Secret Manager, prefix `eigeninference-*` | Fetched at VM boot into `/etc/d-inference/env` |
| Mac fleet | 2–4 Macs with hostnames `dev-*` | Listed in `deploy/provider-fleet/dev-inventory.txt` |
| DNS | Vercel Domains | `api.dev.darkbloom.xyz` A → VM static IP |
| Privy | Separate dev Privy app (not the prod one) | Values in Secret Manager |
| Solana | Mainnet, dev-only BIP39 mnemonic (new wallet) | `EIGENINFERENCE_BILLING_MOCK=false` |
| MDM / attestation | Full stack — MicroMDM + step-ca inside coordinator container | `MIN_TRUST=hardware` (same as prod) |

### Architecture Decisions

| Decision | Rationale |
|----------|-----------|
| **GCE VM, not Cloud Run** | The coordinator container runs step-ca (writes CA keys to disk) and MicroMDM (BoltDB). Both need reliable local filesystem semantics. Cloud Run's ephemeral FS doesn't survive revisions, and gcsfuse is unsafe for BoltDB. |
| **Same `/mnt/disks/userdata` path** | Matches EigenCloud prod, so `start.sh` works unchanged. |
| **Full MDM + step-ca stack** | `MIN_TRUST=hardware`, same as prod — dev exercises the real attestation chain. |

**Upgrade time:** ~2–4 minutes end-to-end for the coordinator (build + push + `systemctl restart`). ~30–60 sec for the console UI on Vercel (auto-builds on git push). During a coordinator restart there is a ~10s blip when the container comes down and back up — providers auto-reconnect.

## Standing Up Dev from Scratch

### 1. Bootstrap GCP

From a workstation with `gcloud` authenticated against `sepolia-ai`:

```bash
deploy/gcp/bootstrap.sh
```

Creates Artifact Registry repos, service accounts, empty Secret Manager entries, and a Cloud SQL instance. Idempotent — re-run as needed.

### 2. Populate Secrets

For each entry created by the bootstrap script:

```bash
echo -n '<value>' | gcloud secrets versions add <secret-name> --data-file=-
```

| Secret | Source |
|--------|--------|
| `eigeninference-admin-key` | `openssl rand -hex 32` |
| `eigeninference-release-key` | `openssl rand -hex 32` |
| `eigeninference-solana-mnemonic` | Generate a **new** BIP39 mnemonic (never reuse prod). Derive the Solana public key, fund with a small amount of USDC on mainnet. |
| `eigeninference-privy-app-id` | Privy dashboard (dev app) |
| `eigeninference-privy-app-secret` | Privy dashboard |
| `eigeninference-privy-verification-key` | Privy dashboard (JWKS JSON or PEM) |
| `eigeninference-database-url` | Already set by bootstrap if Cloud SQL was just created |
| `eigeninference-micromdm-api-key` | `openssl rand -hex 32` (used by both MicroMDM and coordinator; must match) |
| `eigeninference-mdm-push-p12-b64` | Base64url-encoded MDM push PKCS#12. Same Apple push cert prod uses. Encode: `base64 < push.p12 \| tr '/+' '_-' \| tr -d '\n='` |
| `eigeninference-r2-cdn-url` | Public URL of the `d-inf-app-dev` R2 bucket |

### 3. DNS

The bootstrap reserves a static external IP and prints it. On Vercel Domains:

| Record | Type | Value |
|--------|------|-------|
| `api.dev.darkbloom.xyz` | A | `<VM_STATIC_IP>` |
| `console.dev.darkbloom.xyz` | CNAME | `cname.vercel-dns.com` (Vercel shows the exact target in step 5) |

### 4. First Coordinator Deploy

From the repo root:

```bash
gcloud builds submit --config=deploy/gcp/cloudbuild.yaml --project=sepolia-ai
```

Builds the image, pushes to Artifact Registry, writes the SHA to VM metadata, and `systemctl restart`s the unit on the VM via IAP SSH. First build is ~4 min; subsequent deploys are ~2–3 min.

### 5. Console UI on Vercel

In the Vercel dashboard:

1. Import the `d-inference` repo as a new project named `darkbloom-console-dev`. Set root directory to `console-ui/`.
2. Environment variable: `NEXT_PUBLIC_COORDINATOR_URL=https://api.dev.darkbloom.xyz`
3. Add custom domain `console.dev.darkbloom.xyz`. Vercel provisions the cert; copy the CNAME target and add it in step 3.
4. Every push to `master` auto-builds. Preview branches get Vercel preview URLs that still hit the dev coordinator.

### 6. Connect GitHub → Cloud Build

One-time, from the Cloud Console: install the Google Cloud Build GitHub App on `Gajesh2007/d-inference`, authorize the repo, create a trigger targeting `deploy/gcp/cloudbuild.yaml` on push to `master` with path filter `coordinator/**` and `deploy/gcp/**`.

Console UI on Vercel handles its own CI — no second Cloud Build trigger needed.

### 7. First Dev Release

From GitHub Actions UI: run `Release Provider Bundle` with `environment=dev`. Builds, signs, notarizes, uploads to R2 `d-inf-app-dev`, registers with the dev coordinator.

Alternative: push a tag like `v0.3.6-dev.1` — the workflow routes dev/prod by tag shape.

### 8. Onboard the Mac Fleet

On each dev Mac:

```bash
curl -fsSL https://api.dev.darkbloom.xyz/install.sh | bash
```

The install script is served by the dev coordinator with its URL templated in, so the installed provider only talks to dev. Add the Mac's SSH host alias to `deploy/provider-fleet/dev-inventory.txt`.

### 9. Smoke Test

```bash
scripts/smoke-dev.sh
```

Hits `/health`, `/v1/stats`, `/v1/models/catalog`, verifies install.sh templating, and optionally runs an authenticated chat round-trip if `API_KEY` is set.

## Day-to-Day Flow

| Action | How |
|--------|-----|
| **Deploy coordinator** | Push to `master` → Cloud Build auto-deploys. No approval step. |
| **New provider release on dev** | Run `Release Provider Bundle` workflow with `environment=dev` (or push a `-dev.N` tag) |
| **Prod release after dev bake** | Same commit SHA, run workflow with `environment=prod`. Prod GitHub Environment requires reviewer approval. Dev and prod never share artifacts. |
| **Fleet refresh** | `deploy/provider-fleet/update-fleet.sh dev` reinstalls via SSH + `install.sh` |

## Secrets Mapping

| Env Var in Coordinator | Secret Manager Name | Source |
|------------------------|-------------------|--------|
| `EIGENINFERENCE_ADMIN_KEY` | `eigeninference-admin-key` | Generated once, stored |
| `EIGENINFERENCE_RELEASE_KEY` | `eigeninference-release-key` | Generated once, also set in GH env `dev` → `RELEASE_KEY` |
| `EIGENINFERENCE_PRIVY_APP_ID` | `eigeninference-privy-app-id` | Privy dashboard (dev app) |
| `EIGENINFERENCE_PRIVY_APP_SECRET` | `eigeninference-privy-app-secret` | Privy dashboard |
| `EIGENINFERENCE_PRIVY_VERIFICATION_KEY` | `eigeninference-privy-verification-key` | Privy dashboard |
| `MNEMONIC` | `eigeninference-solana-mnemonic` | Generated fresh for dev |
| `EIGENINFERENCE_DATABASE_URL` | `eigeninference-database-url` | Bootstrap writes Cloud SQL conn string (via cloud-sql-proxy on 127.0.0.1:5432) |
| `MICROMDM_API_KEY` / `EIGENINFERENCE_MDM_API_KEY` | `eigeninference-micromdm-api-key` | Same value for both — keep in sync |
| `MDM_PUSH_P12_B64` | `eigeninference-mdm-push-p12-b64` | Apple push cert (base64url-encoded PKCS#12) |

Non-secret configuration is baked into `deploy/gcp/cloudbuild.yaml` via `--set-env-vars`. To change one (e.g. flip `MIN_TRUST`), edit that file — the next deploy picks it up.

## GitHub Environments

Two environments exist: `dev` and `prod`.

| Key | Type | Dev Value | Prod Value |
|-----|------|-----------|------------|
| `COORDINATOR_URL` | secret | `https://api.dev.darkbloom.xyz` | `https://api.darkbloom.dev` |
| `RELEASE_KEY` | secret | Dev release key | Prod release key |
| `R2_ACCESS_KEY_ID` | secret | R2 token scoped to `d-inf-app-dev` | R2 token for `d-inf-app` |
| `R2_SECRET_ACCESS_KEY` | secret | — | — |
| `R2_ENDPOINT` | secret | Cloudflare R2 endpoint | Same endpoint (bucket-scoped token) |
| `R2_PUBLIC_URL` | secret | Dev public R2 URL | Prod public R2 URL |
| `APPLE_CERTIFICATE_P12` | secret | Shared (one Developer ID cert) | Same |
| `APPLE_CERTIFICATE_PASSWORD` | secret | Shared | Same |
| `APPLE_ID` | secret | Shared | Same |
| `APPLE_APP_PASSWORD` | secret | Shared | Same |
| `R2_BUCKET` | variable | `d-inf-app-dev` | `d-inf-app` |
| `R2_CDN` | variable | Dev public R2 CDN URL | Prod public R2 CDN URL |

> **Important:** Enable **required reviewers** under Settings → Environments → prod.

## Rollback

### Dev Coordinator

Images are tagged by `$SHORT_SHA` in Artifact Registry. Point the VM at an older tag and restart:

```bash
gcloud compute instances add-metadata d-inference-dev --zone=us-central1-a \
  --metadata=DINF_IMAGE_TAG=<older-short-sha>
gcloud compute ssh d-inference-dev --zone=us-central1-a --tunnel-through-iap -- \
  'sudo systemctl restart d-inference-coordinator'
```

Rollback time: ~1 min (image already in registry + VM already running — just a container swap).

### Dev Provider Bundle

Releases are immutable in R2. To roll back, reregister an older bundle as "active" via the coordinator admin API, or run the dev release workflow against an older tag.

## Limitations

| What Dev Does *Not* Cover | Why |
|--------------------------|-----|
| EigenCloud blue-green semantics | The VM + systemd restart model is close but not identical to EigenCloud's blue-green disk transfer. Prod-only deploy paths still need a final smoke on prod (reviewer-approved). |
| External user traffic | Dev is team-only; admin emails are gated to `gajesh@eigenlabs.org`. |

## Seeding After a Redeploy

If `EIGENINFERENCE_DATABASE_URL` is unset (in-memory mode), the coordinator resets state on every deploy. To re-register the current release and grant test credits:

```bash
scripts/admin.sh EIGENINFERENCE_COORDINATOR_URL=https://api.dev.darkbloom.xyz releases latest
```

## Cost

| Resource | Monthly Cost |
|----------|-------------|
| GCE `e2-small` 24/7 (coordinator VM) | ~$13 |
| Cloud SQL `db-f1-micro` Postgres | ~$8 |
| GCE static IP (attached) | ~$1.50 |
| 30 GB persistent disk (pd-balanced) | ~$3 |
| Artifact Registry + Cloud Build + Logging | Free tier |
| R2 `d-inf-app-dev` | Free tier |
| Vercel console UI | Free/hobby tier |
| DNS (Vercel Domains) | Existing plan |

**Total: ~$25–30/month.** Not optimizing for cost — correctness and realism-vs-prod take priority.
