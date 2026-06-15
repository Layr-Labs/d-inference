# Dev Environment Runbook

How to stand up, operate, and tear down the Darkbloom dev environment on Google Cloud. Dev exists so we can test coordinator, provider bundle, console-ui, Mac fleet, and release pipeline end-to-end without touching prod.

**Prod runs on EigenCloud and is human-deploy-only (see [`coordinator-deploy.md`](coordinator-deploy.md) and `CLAUDE.md`).** Nothing in this runbook deploys to prod.

## What dev looks like

| Component | Location | URL / identifier |
|---|---|---|
| Coordinator | GCE VM `d-inference-dev` (us-central1-a, Ubuntu 24.04 + Docker + systemd) | `https://api.dev.darkbloom.xyz` (static IP) |
| Persistent disk | GCE persistent disk `d-inference-dev-data` mounted at `/mnt/disks/userdata` (same path as EigenCloud prod) | 30 GB, pd-balanced |
| Console UI | Vercel project `darkbloom-console-dev`, built from `console-ui/` | `https://console.dev.darkbloom.xyz` |
| Database | Cloud SQL Postgres 16, instance `d-inference-dev-db`, `db-f1-micro` | 127.0.0.1:5432 from inside the container via cloud-sql-proxy sidecar |
| Release bucket | Cloudflare R2 `d-inf-app-dev` | R2 CDN URL in env vars |
| Secrets | Google Secret Manager, prefix `eigeninference-*`; fetched at VM boot into `/etc/d-inference/env` | See §Secrets |
| Mac fleet | 2–4 dev Macs | Listed in `deploy/provider-fleet/dev-inventory.txt` |
| DNS | Vercel Domains | `api.dev.darkbloom.xyz` A → VM static IP; `console.dev.darkbloom.xyz` CNAME → Vercel |
| Privy | Separate dev Privy app | Values in Secret Manager |
| Solana | Mainnet, dev-only BIP39 mnemonic | `EIGENINFERENCE_BILLING_MOCK=false` |
| MDM / attestation | Full stack — MicroMDM + step-ca run inside the coordinator container | `MIN_TRUST=hardware`, same as prod |

**Why GCE VM, not Cloud Run:** the coordinator container runs step-ca (writes CA keys to disk) and MicroMDM (BoltDB). Both need reliable local filesystem semantics. Cloud Run's ephemeral FS doesn't survive revisions, and gcsfuse is unsafe for BoltDB. The VM's persistent disk lives at `/mnt/disks/userdata` — the same path EigenCloud prod uses, so the container's `start.sh` works unchanged.

**Upgrade time:** ~2–4 minutes end-to-end for the coordinator (build + push + `systemctl restart`). ~30–60 seconds for the console UI on Vercel (auto-builds on git push). During a coordinator restart there is a ~10s blip when the container comes down and back up; providers auto-reconnect.

## Prerequisites

- [ ] `gcloud` authenticated against `sepolia-ai` (or the project you pass to `bootstrap.sh`).
- [ ] `mise install` run locally for coordinator/UI builds.
- [ ] A dev Privy app created and its credentials available.
- [ ] A dev R2 bucket `d-inf-app-dev` and bucket-scoped API token.
- [ ] (Optional but recommended) A Mac host available to join the dev fleet.

## Steps

### 1. Bootstrap GCP

From the repo root:

```bash
deploy/gcp/bootstrap.sh
```

This creates Artifact Registry repos, service accounts, empty Secret Manager entries, a Cloud SQL instance, a GCE VM, and a persistent disk. It is idempotent — re-run as needed. Reference: [`deploy/gcp/bootstrap.sh`](../../deploy/gcp/bootstrap.sh).

### 2. Populate secrets

For each entry created by the bootstrap script:

```bash
echo -n '<value>' | gcloud secrets versions add <secret-name> --data-file=-
```

Values:

| Secret | Value / source |
|---|---|
| `eigeninference-admin-key` | `openssl rand -hex 32` |
| `eigeninference-release-key` | `openssl rand -hex 32` |
| `eigeninference-solana-mnemonic` | Generate a **new** BIP39 mnemonic (never reuse prod). Derive the Solana public key and fund it with a small amount of USDC on mainnet for end-to-end testing. |
| `eigeninference-privy-app-id` | Dev Privy app dashboard |
| `eigeninference-privy-app-secret` | Dev Privy app dashboard |
| `eigeninference-privy-verification-key` | Dev Privy app dashboard (JWKS JSON or PEM) |
| `eigeninference-database-url` | Already set by bootstrap if Cloud SQL was just created |
| `eigeninference-micromdm-api-key` | `openssl rand -hex 32` (used by both MicroMDM and the coordinator's MDM client; they must match) |
| `eigeninference-mdm-push-p12-b64` | Base64url-encoded MDM push PKCS#12. Same Apple push cert prod uses (one cert per Apple Developer account). To encode: `base64 < push.p12 \| tr '/+' '_-' \| tr -d '\n='` |
| `eigeninference-r2-cdn-url` | Public URL of the `d-inf-app-dev` R2 bucket, e.g. `https://pub-<randomid>.r2.dev`. Used by the coordinator to template `install.sh` so dev providers pull artifacts from the dev bucket. |

### 3. DNS

The bootstrap reserves a static external IP and prints it. On Vercel Domains:

```
api.dev.darkbloom.xyz      A     <VM_STATIC_IP>
console.dev.darkbloom.xyz  CNAME cname.vercel-dns.com
```

The exact CNAME target is shown by Vercel after you add the custom domain in step 5.

### 4. First coordinator deploy

From the repo root:

```bash
gcloud builds submit --config=deploy/gcp/cloudbuild.yaml --project=sepolia-ai
```

This builds the image, pushes to Artifact Registry, writes the SHA to VM metadata, and restarts the systemd unit on the VM via IAP SSH. First build is ~4 minutes; subsequent deploys are ~2–3 minutes. Reference: [`deploy/gcp/cloudbuild.yaml`](../../deploy/gcp/cloudbuild.yaml).

### 5. Console UI on Vercel

In the Vercel dashboard:

1. Import the `d-inference` repo as a new project named `darkbloom-console-dev`. Set root directory to `console-ui/`.
2. Environment variables: `NEXT_PUBLIC_COORDINATOR_URL=https://api.dev.darkbloom.xyz`.
3. Add custom domain `console.dev.darkbloom.xyz`. Vercel provisions the cert; copy the CNAME target it shows and add it in step 3.
4. Every push to `master` auto-builds. Isolated preview branches still hit the dev coordinator.

### 6. Connect GitHub → Cloud Build

One-time, from the Cloud Console:

1. Install the Google Cloud Build GitHub App on `Gajesh2007/d-inference`.
2. Authorize the repo.
3. Create a trigger targeting `deploy/gcp/cloudbuild.yaml` on push to `master` with path filter `coordinator/**` and `deploy/gcp/**`.

The console UI on Vercel handles its own CI; no second Cloud Build trigger is needed.

### 7. First dev provider release

From the GitHub Actions UI, run **Release Provider Bundle** with `environment=dev`. It builds, signs, notarizes, uploads to R2 `d-inf-app-dev`, and registers with the dev coordinator. Alternatively, push a tag like `v0.3.6-dev.1` — the workflow routes dev/prod by tag shape.

Reference: [`coordinator-deploy.md`](coordinator-deploy.md).

### 8. Onboard the Mac fleet

On each dev Mac:

```bash
curl -fsSL https://api.dev.darkbloom.xyz/install.sh | bash
```

The install script is served by the dev coordinator with its URL templated in, so the installed provider only talks to dev. Add the Mac's SSH host alias to `deploy/provider-fleet/dev-inventory.txt`.

### 9. Smoke test

Run the dev smoke script:

```bash
scripts/smoke-dev.sh
```

It hits `/health`, `/v1/stats`, `/v1/models/catalog`, verifies `install.sh` templating, and optionally runs an authenticated chat round-trip if `API_KEY` is set. Reference: [`scripts/smoke-dev.sh`](../../scripts/smoke-dev.sh).

## Day-to-day flow

- **Push to `master`** → Cloud Build auto-deploys the coordinator; Vercel auto-deploys the console UI. No approval step.
- **Need a new provider release on dev?** Run the **Release Provider Bundle** workflow with `environment=dev` (or push a `-dev.N` tag).
- **Prod release after dev bake?** Use the same commit SHA and run the workflow with `environment=prod`. The prod GitHub Environment should require reviewer approval. Dev and prod never share artifacts.
- **Fleet refresh.** `deploy/provider-fleet/update-fleet.sh dev` reinstalls via SSH + `install.sh`.

## Secrets mapping

| Env var in coordinator | Secret Manager name | Source |
|---|---|---|
| `EIGENINFERENCE_ADMIN_KEY` | `eigeninference-admin-key` | Generated once, stored |
| `EIGENINFERENCE_RELEASE_KEY` | `eigeninference-release-key` | Generated once; also set in GH env `dev` → `RELEASE_KEY` |
| `EIGENINFERENCE_PRIVY_APP_ID` | `eigeninference-privy-app-id` | Privy dashboard (dev app) |
| `EIGENINFERENCE_PRIVY_APP_SECRET` | `eigeninference-privy-app-secret` | Privy dashboard |
| `EIGENINFERENCE_PRIVY_VERIFICATION_KEY` | `eigeninference-privy-verification-key` | Privy dashboard |
| `MNEMONIC` | `eigeninference-solana-mnemonic` | Generated fresh for dev |
| `EIGENINFERENCE_DATABASE_URL` | `eigeninference-database-url` | Bootstrap writes Cloud SQL conn string (via cloud-sql-proxy on 127.0.0.1:5432) |
| `MICROMDM_API_KEY` / `EIGENINFERENCE_MDM_API_KEY` | `eigeninference-micromdm-api-key` | Same value for both — keep in sync |
| `MDM_PUSH_P12_B64` | `eigeninference-mdm-push-p12-b64` | Apple push cert (base64url-encoded PKCS#12) |
| `PROFILE_SIGNING_P12_B64` / `PROFILE_SIGNING_P12_PASSWORD` | `eigeninference-profile-signing-p12-b64` / `…-password` | Developer ID Application identity (base64 PKCS#12 + password) used to CMS-sign the `/v1/enroll` profile. **Optional** — unset serves profiles unsigned. |

Non-secret configuration is baked into `deploy/gcp/cloudbuild.yaml` via `--set-env-vars`. If you need to change one (e.g. flip `MIN_TRUST`), edit that file; the next deploy picks it up.

## Verification

| Check | Command |
|---|---|
| Coordinator health | `curl https://api.dev.darkbloom.xyz/health` |
| Public stats | `curl https://api.dev.darkbloom.xyz/v1/stats` |
| Model catalog | `curl https://api.dev.darkbloom.xyz/v1/models/catalog` |
| Provider release registered | `curl https://api.dev.darkbloom.xyz/v1/releases/latest` |
| Cloud Build trigger status | `gcloud builds list --project=sepolia-ai` |
| VM systemd status | `gcloud compute ssh d-inference-dev --zone=us-central1-a --tunnel-through-iap -- 'sudo systemctl status d-inference-coordinator'` |

## Rollback

### Dev coordinator

Images are tagged by `$SHORT_SHA` in Artifact Registry. Point the VM at an older tag and restart:

```bash
gcloud compute instances add-metadata d-inference-dev --zone=us-central1-a \
  --metadata=DINF_IMAGE_TAG=<older-short-sha>
gcloud compute ssh d-inference-dev --zone=us-central1-a --tunnel-through-iap -- \
  'sudo systemctl restart d-inference-coordinator'
```

Rollback time: ~1 minute (image already in registry + VM already running — just a container swap).

### Dev provider bundle

Releases are immutable in R2. To roll back:

1. Re-run the dev release workflow against an older tag, **or**
2. Manually point the `latest/` prefix in the `d-inf-app-dev` bucket to the previous tarball and ask providers to re-run `install.sh`.

### Full dev teardown

Delete the VM, disk, SQL instance, and secrets only when you are sure you no longer need the dev state:

```bash
gcloud compute instances delete d-inference-dev --zone=us-central1-a --quiet
gcloud compute disks delete d-inference-dev-data --zone=us-central1-a --quiet
gcloud sql instances delete d-inference-dev-db --quiet
# Delete secrets manually if desired; bootstrap can recreate them.
```

## What dev does *not* cover

- **EigenCloud blue-green semantics.** The VM + systemd restart model is close but not identical to EigenCloud's blue-green disk transfer. Prod-only deploy paths still need a final smoke on prod (reviewer-approved).
- **External user traffic.** Dev is team-only; admin emails are gated to `gajesh@eigenlabs.org` by default.
- **In-memory mode data loss.** If `EIGENINFERENCE_DATABASE_URL` is unset, the coordinator resets state on every deploy. To re-register the current release and grant test credits after a redeploy, run `scripts/admin.sh EIGENINFERENCE_COORDINATOR_URL=https://api.dev.darkbloom.xyz releases latest`.

## Cost

Approximate monthly cost for the standard dev footprint:

| Resource | ~$/mo |
|---|---|
| GCE `e2-small` 24/7 | ~$13 |
| Cloud SQL `db-f1-micro` | ~$8 |
| GCE static IP | ~$1.50 |
| 30 GB persistent disk (pd-balanced) | ~$3 |
| Artifact Registry + Cloud Build + Logging | Free tier |
| R2 `d-inf-app-dev` | Free tier |
| Vercel console UI | Free/hobby tier |
| DNS | Vercel Domains (existing plan) |

**Total: ~$25–30/month.** Not optimizing for cost — correctness + realism-vs-prod take priority.
