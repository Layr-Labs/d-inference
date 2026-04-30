# Dev Environment Runbook

The d-inference dev environment runs on Google Cloud (GCP project `sepolia-ai`, region `us-central1`). It exists so we can test every code path — coordinator, provider bundle, console-ui, Mac fleet, release pipeline — end-to-end without touching prod.

**Prod runs on EigenCloud and is human-deploy-only (see CLAUDE.md).** Nothing in this runbook deploys to prod.

## What dev looks like

| Component | Location | URL / identifier |
|---|---|---|
| Coordinator | GCE VM `d-inference-dev` (us-central1-a, Ubuntu 24.04 + Docker + systemd) | `https://api.dev.darkbloom.xyz` (static IP) |
| Persistent disk | GCE persistent disk `d-inference-dev-data` mounted at `/mnt/disks/userdata` (same path as EigenCloud prod) — holds step-ca state + MicroMDM BoltDB | 30 GB, pd-balanced |
| Console UI | Vercel (separate "darkbloom-console-dev" project, built from `console-ui/`) | `https://console.dev.darkbloom.xyz` |
| Database | Cloud SQL Postgres 16, instance `d-inference-dev-db`, `db-f1-micro`, accessed via cloud-sql-proxy sidecar on the VM | 127.0.0.1:5432 from inside the container |
| Release bucket | Cloudflare R2 `d-inf-app-dev` | R2 CDN URL in env vars |
| Secrets | Google Secret Manager, prefix `eigeninference-*`. Fetched at VM boot into `/etc/d-inference/env` | see §Secrets |
| Mac fleet | 2–4 Macs with hostnames `dev-*` | listed in `deploy/provider-fleet/dev-inventory.txt` |
| DNS | Vercel Domains: `api.dev.darkbloom.xyz` A → VM static IP; `console.dev.darkbloom.xyz` CNAME → Cloud Run | — |
| Privy | Separate dev Privy app (not the prod one) | values in Secret Manager |
| Solana | Mainnet, but with a dev-only BIP39 mnemonic (new wallet) | `EIGENINFERENCE_BILLING_MOCK=false` |
| MDM / attestation | Full stack — MicroMDM + step-ca run inside the coordinator container on the VM. `MIN_TRUST=hardware`, same as prod. | |

**Why GCE VM, not Cloud Run:** the coordinator container runs step-ca (writes CA keys to disk) and MicroMDM (BoltDB). Both need reliable local filesystem semantics. Cloud Run's ephemeral FS doesn't survive revisions, and gcsfuse is unsafe for BoltDB. The VM's persistent disk lives at `/mnt/disks/userdata` — the same path EigenCloud prod uses, so the container's `start.sh` works unchanged.

**Upgrade time:** ~2–4 minutes end-to-end for the coordinator (build + push + `systemctl restart`). ~30–60 sec for the console UI on Vercel (auto-builds on git push). During a coordinator restart there is a ~10s blip when the container comes down and back up — providers auto-reconnect.

## Standing up dev from scratch

1. **Bootstrap GCP.** From a workstation with `gcloud` authenticated against `sepolia-ai`:
   ```bash
   deploy/gcp/bootstrap.sh
   ```
   This creates Artifact Registry repos, service accounts, empty Secret Manager entries, and a Cloud SQL instance. Idempotent — re-run as needed.

2. **Populate secrets.** For each entry created by the bootstrap script:
   ```bash
   echo -n '<value>' | gcloud secrets versions add <secret-name> --data-file=-
   ```
   Values:
   - `eigeninference-admin-key` — `openssl rand -hex 32`
   - `eigeninference-release-key` — `openssl rand -hex 32`
   - `eigeninference-solana-mnemonic` — generate a **new** BIP39 mnemonic (never reuse prod). Derive the Solana public key, fund it with a small amount of USDC on mainnet for end-to-end testing.
   - `eigeninference-privy-app-id` — from the dev Privy app dashboard
   - `eigeninference-privy-app-secret` — same
   - `eigeninference-privy-verification-key` — same (JWKS JSON or PEM)
   - `eigeninference-database-url` — already set by bootstrap if Cloud SQL was just created
   - `eigeninference-micromdm-api-key` — `openssl rand -hex 32` (used by both MicroMDM and the coordinator's MDM client; they must match)
   - `eigeninference-mdm-push-p12-b64` — base64url-encoded MDM push PKCS#12. Same Apple push cert prod uses (one cert per Apple Developer account). To encode: `base64 < push.p12 | tr '/+' '_-' | tr -d '\n='`
   - `eigeninference-r2-cdn-url` — the public URL of the `d-inf-app-dev` R2 bucket (e.g. `https://pub-<randomid>.r2.dev`). Used by the coordinator to template install.sh so dev providers pull artifacts from the dev bucket.

3. **DNS.** The bootstrap reserves a static external IP and prints it. On Vercel Domains:
   - `api.dev.darkbloom.xyz`      A     `<VM_STATIC_IP>`
   - `console.dev.darkbloom.xyz`  CNAME `cname.vercel-dns.com` (Vercel shows the exact target when you add the custom domain in step 5)

4. **First coordinator deploy.** From the repo root:
   ```bash
   gcloud builds submit --config=deploy/gcp/cloudbuild.yaml --project=sepolia-ai
   ```
   This builds the image, pushes to Artifact Registry, writes the SHA to VM metadata, and `systemctl restart`s the unit on the VM via IAP SSH. First build is ~4 min; subsequent deploys are ~2–3 min.

5. **Console UI on Vercel.** In the Vercel dashboard:
   - Import the `d-inference` repo as a new project named `darkbloom-console-dev`. Set root directory to `console-ui/`.
   - Environment variables: `NEXT_PUBLIC_COORDINATOR_URL=https://api.dev.darkbloom.xyz`.
   - Add custom domain `console.dev.darkbloom.xyz`. Vercel provisions the cert; copy the CNAME target it shows and add it in step 3.
   - Every push to `master` auto-builds. For isolated preview branches Vercel gives preview URLs that still hit dev coordinator.

6. **Connect GitHub → Cloud Build.** One-time, from the Cloud Console: install the Google Cloud Build GitHub App on `Gajesh2007/d-inference`, authorize the repo, create a trigger targeting `deploy/gcp/cloudbuild.yaml` on push to `master` with path filter `coordinator/**` and `deploy/gcp/**`. (Console UI on Vercel handles its own CI — no second Cloud Build trigger needed.)

7. **First dev release.** From GitHub Actions UI: run `Release Provider Bundle` with `environment=dev`. It builds, signs, notarizes, uploads to R2 `d-inf-app-dev`, registers with the dev coordinator. (Alternative: push a tag like `v0.3.6-dev.1` — the workflow routes dev/prod by tag shape.)

8. **Onboard the Mac fleet.** On each dev Mac:
   ```bash
   curl -fsSL https://api.dev.darkbloom.xyz/install.sh | bash
   ```
   The install script is served by the dev coordinator with its URL templated in, so the installed provider only talks to dev. Add the Mac's SSH host alias to `deploy/provider-fleet/dev-inventory.txt`.

9. **Smoke test.** `scripts/smoke-dev.sh` hits `/health`, `/v1/stats`, `/v1/models/catalog`, verifies install.sh templating, and optionally runs an authenticated chat round-trip if `API_KEY` is set.

## Day-to-day flow

- **Push to `master`** → Cloud Build auto-deploys coordinator + console-ui to dev. No approval step.
- **Need a new provider release on dev?** Run the `Release Provider Bundle` workflow with `environment=dev` (or push a `-dev.N` tag).
- **Prod release after dev bake?** Same commit SHA, run the workflow with `environment=prod`. The prod GitHub Environment requires reviewer approval. The provider binary gets rebuilt with the prod coordinator URL baked in — dev and prod never share artifacts.
- **Fleet refresh.** `deploy/provider-fleet/update-fleet.sh dev` reinstalls via SSH + `install.sh`.

## Secrets mapping

| Env var in coordinator | Secret Manager name | Source |
|---|---|---|
| `EIGENINFERENCE_ADMIN_KEY` | `eigeninference-admin-key` | generated once, stored |
| `EIGENINFERENCE_RELEASE_KEY` | `eigeninference-release-key` | generated once, also set in GH env `dev`→`RELEASE_KEY` |
| `EIGENINFERENCE_PRIVY_APP_ID` | `eigeninference-privy-app-id` | Privy dashboard (dev app) |
| `EIGENINFERENCE_PRIVY_APP_SECRET` | `eigeninference-privy-app-secret` | Privy dashboard |
| `EIGENINFERENCE_PRIVY_VERIFICATION_KEY` | `eigeninference-privy-verification-key` | Privy dashboard |
| `MNEMONIC` | `eigeninference-solana-mnemonic` | generated fresh for dev |
| `EIGENINFERENCE_DATABASE_URL` | `eigeninference-database-url` | bootstrap writes Cloud SQL conn string (via cloud-sql-proxy on 127.0.0.1:5432) |
| `MICROMDM_API_KEY` / `EIGENINFERENCE_MDM_API_KEY` | `eigeninference-micromdm-api-key` | same value for both — keep in sync |
| `MDM_PUSH_P12_B64` | `eigeninference-mdm-push-p12-b64` | Apple push cert (base64url-encoded PKCS#12) |

Non-secret configuration is baked into `deploy/gcp/cloudbuild.yaml` via `--set-env-vars`. If you need to change one (e.g. flip `MIN_TRUST`), edit that file — the next deploy picks it up.

## GitHub Environments

Two environments exist: `dev` and `prod`. Each holds its own copy of:

| Key | Type | Dev value | Prod value |
|---|---|---|---|
| `COORDINATOR_URL` | secret | `https://api.dev.darkbloom.xyz` | `https://api.darkbloom.dev` |
| `RELEASE_KEY` | secret | dev release key | prod release key |
| `R2_ACCESS_KEY_ID` | secret | R2 token scoped to `d-inf-app-dev` | R2 token for `d-inf-app` |
| `R2_SECRET_ACCESS_KEY` | secret | same | same |
| `R2_ENDPOINT` | secret | Cloudflare R2 endpoint | same endpoint (bucket-scoped token) |
| `R2_PUBLIC_URL` | secret | dev public R2 URL | prod public R2 URL |
| `APPLE_CERTIFICATE_P12` | secret | shared (one Developer ID cert) | same |
| `APPLE_CERTIFICATE_PASSWORD` | secret | shared | same |
| `APPLE_ID` | secret | shared | same |
| `APPLE_APP_PASSWORD` | secret | shared | same |
| `R2_BUCKET` | variable | `d-inf-app-dev` | `d-inf-app` |
| `R2_CDN` | variable | dev public R2 CDN URL | prod public R2 CDN URL |

Prod environment: enable **required reviewers** under Settings → Environments → prod.

## Rollback

- **Dev coordinator.** Images are tagged by `$SHORT_SHA` in Artifact Registry. Point the VM at an older tag and restart:
  ```bash
  gcloud compute instances add-metadata d-inference-dev --zone=us-central1-a \
    --metadata=DINF_IMAGE_TAG=<older-short-sha>
  gcloud compute ssh d-inference-dev --zone=us-central1-a --tunnel-through-iap -- \
    'sudo systemctl restart d-inference-coordinator'
  ```
  Rollback time: ~1 min (image already in registry + VM already running — just a container swap).
- **Dev provider bundle.** Releases are immutable in R2; to roll back, reregister an older bundle as "active" via the coordinator admin API, or run the dev release workflow against an older tag.

## What dev does *not* cover

- **EigenCloud blue-green semantics.** The VM + systemd restart model is close but not identical to EigenCloud's blue-green disk transfer. Prod-only deploy paths still need a final smoke on prod (reviewer-approved).
- **External user traffic.** Dev is team-only; admin emails are gated to `gajesh@eigenlabs.org`.

## Seeding after a redeploy (if using in-memory mode)

If `EIGENINFERENCE_DATABASE_URL` is unset, the coordinator resets state on every deploy. To re-register the current release and grant test credits after a redeploy, run:

```bash
scripts/admin.sh EIGENINFERENCE_COORDINATOR_URL=https://api.dev.darkbloom.xyz releases latest
```

(Wire a `seed-dev.sh` here when we converge on a pattern.)

## Cost

- GCE `e2-small` 24/7 (coordinator VM): ~$13/mo
- Cloud SQL `db-f1-micro` Postgres: ~$8/mo
- GCE static IP (attached): ~$1.50/mo
- 30 GB persistent disk (pd-balanced): ~$3/mo
- Artifact Registry + Cloud Build + Logging: free tier
- R2 `d-inf-app-dev`: free tier
- Vercel console UI: free/hobby tier
- DNS: Vercel Domains (existing plan)

Total: ~$25–30/month. Not optimizing for cost — correctness + realism-vs-prod take priority.
