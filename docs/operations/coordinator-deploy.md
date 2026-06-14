# Coordinator and Provider CLI Deploy Runbook

How to build, deploy, and update the Darkbloom coordinator and the Swift provider CLI.

## Prerequisites

- [ ] `mise` installed and `mise install` run (toolchain versions are pinned in [`mise.toml`](../../mise.toml)).
- [ ] Coordinator tests pass locally:
  ```bash
  make coordinator-test
  ```
- [ ] For provider releases: a macOS Apple Silicon build host or the `release-swift.yml` GitHub Actions runner (macOS, Xcode, Developer ID cert).
- [ ] For prod EigenCloud deploys: `ecloud` CLI access and approval to push to `origin/master`.
- [ ] For dev GCP deploys: `gcloud` authenticated to project `sepolia-ai` with IAM to run Cloud Build and SSH via IAP.

## Infrastructure

| Item | Prod (EigenCloud) | Dev (GCP) |
|---|---|---|
| Platform | EigenCloud TEE | GCE VM (`d-inference-dev`) |
| Domain | `api.darkbloom.dev` | `api.dev.darkbloom.xyz` |
| App / VM | `d-inference` | `d-inference-dev` in `us-central1-a` |
| Reverse proxy | Caddy (injected by EigenCloud, [`coordinator/Caddyfile`](../../coordinator/Caddyfile)) | Host Caddy + Cloud Build-deployed container |
| Coordinator | Go binary, port 8080 ([`coordinator/cmd/coordinator`](../../coordinator/cmd/coordinator)) | Same Docker image as prod |
| MicroMDM | Port 9002, same container ([`coordinator/deploy/start.sh`](../../coordinator/deploy/start.sh)) | Same |
| step-ca | Port 9000, same container | Same |
| Database | AWS RDS PostgreSQL | Cloud SQL Postgres 16 via cloud-sql-proxy sidecar |
| Persistent storage | `/mnt/disks/userdata` | `/mnt/disks/userdata` persistent disk |
| Install script | `curl -fsSL https://api.darkbloom.dev/install.sh \| bash` | Templated to dev URL by coordinator |

The container entrypoint is [`coordinator/deploy/start.sh`](../../coordinator/deploy/start.sh). It symlinks `/data -> /mnt/disks/userdata`, initializes step-ca and MicroMDM on first boot, and `exec`s the coordinator as PID 1.

## Steps

### 1. Build and test locally

```bash
make coordinator-test
make coordinator-build
```

Cross-compile for the Linux/EigenCloud target:

```bash
make coordinator-build-linux
```

This produces `coordinator/coordinator-linux` ([`Makefile`](../../Makefile):`coordinator-build-linux`).

### 2. Push to master

EigenCloud builds from the repo. Push your changes:

```bash
git push origin master
```

### 3. Trigger prod deploy on EigenCloud

EigenCloud layers Caddy + TLS on top of [`coordinator/Dockerfile`](../../coordinator/Dockerfile). Deploy via the EigenCloud CLI or dashboard:

```bash
ecloud compute app deploy d-inference
```

### 4. Verify prod

```bash
# Health check
curl https://api.darkbloom.dev/health

# Provider connectivity / public stats
curl https://api.darkbloom.dev/v1/stats

# Logs
ecloud compute app logs d-inference
```

Expected deploy time: 5–7 minutes for EigenCloud blue-green upgrade.

## Provider CLI release

Provider releases are built and shipped by `.github/workflows/release-swift.yml` (CLI-only Swift; the legacy Rust/Python/app bundle pipeline was removed). The workflow:

1. Builds `darkbloom` and `darkbloom-enclave` from `provider-swift/`.
2. Fetches a matching `mlx.metallib` from the pinned MLX Python wheel (`MLX_PYTHON_PIN` in the workflow).
3. Embeds the provisioning profile and signs with Developer ID Application.
4. Notarizes with Apple.
5. Computes SHA-256 hashes **after** signing/notarization (see `Notarize bundle` step).
6. Uploads the tarball to R2 under `releases/v${VERSION}` and `releases/latest`.
7. Registers the release with `POST /v1/releases` using `RELEASE_KEY`.
8. Creates a GitHub release.

Reference: [`release-swift.yml`](../../.github/workflows/release-swift.yml), lines 1–653.

### Cutting a release

Tag conventions:

| Tag shape | Environment |
|---|---|
| `vX.Y.Z` | Prod (requires GitHub Environment approval if configured) |
| `vX.Y.Z-dev.N` | Dev |
| `vX.Y.Z-swift` or `vX.Y.Z-swift.N` | Accepted aliases during migration |

The fallback version advertised when no release is registered is `LatestProviderVersion` in [`coordinator/api/server.go`](../../coordinator/api/server.go):146 (currently `"0.6.4"`). Keep this in sync with the Swift binary's expected floor.

```bash
# Example prod release
git tag -a v0.7.0 -m "Release v0.7.0"
git push origin master --tags
```

### Required GitHub secrets

The workflow resolves prefixed secrets (`DEV_*` / `PROD_*`) with legacy unprefixed fallbacks for prod. Required:

| Secret | Purpose |
|---|---|
| `COORDINATOR_URL` / `DEV_COORDINATOR_URL` / `PROD_COORDINATOR_URL` | Coordinator base URL |
| `RELEASE_KEY` / `DEV_RELEASE_KEY` / `PROD_RELEASE_KEY` | `POST /v1/releases` registration key |
| `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_ENDPOINT`, `R2_BUCKET`, `R2_PUBLIC_URL` | R2 artifact storage |
| `APPLE_CERTIFICATE_P12`, `APPLE_CERTIFICATE_PASSWORD` | Developer ID signing |
| `APPLE_ID`, `APPLE_APP_PASSWORD` | Notarization |
| `PROVISIONING_PROFILE_BASE64` | Required since PR #146; grants `keychain-access-groups` and `aps-environment=production` |

### Install

Users install via the coordinator-served script:

```bash
curl -fsSL https://api.darkbloom.dev/install.sh | bash
```

The script is embedded in the coordinator binary via `go:embed` ([`scripts/install.sh`](../../scripts/install.sh)). The coordinator substitutes its own URL at serve time so the same binary works for dev and prod.

## Verification

| Check | Command / signal |
|---|---|
| Coordinator health | `curl https://api.darkbloom.dev/health` |
| Latest provider release | `curl https://api.darkbloom.dev/v1/releases/latest` |
| Provider reconnects after restart | `/v1/stats` shows capacity returning; provider logs show `register` success |
| Install script templating | `curl -fsSL https://api.dev.darkbloom.xyz/install.sh \| grep COORD_URL` should show dev URL |

## Rollback

### Coordinator

- **EigenCloud prod:** use the EigenCloud dashboard/CLI to roll back to the previous revision. EigenCloud keeps the previous revision warm during blue-green.
- **Dev GCP:** point the VM at an older image tag and restart:
  ```bash
  gcloud compute instances add-metadata d-inference-dev --zone=us-central1-a \
    --metadata=DINF_IMAGE_TAG=<older-short-sha>
  gcloud compute ssh d-inference-dev --zone=us-central1-a --tunnel-through-iap -- \
    'sudo systemctl restart d-inference-coordinator'
  ```
  Rollback time is ~1 minute because the image is already in the registry.

### Provider CLI release

Releases are immutable in R2. To roll back:

1. Re-run the release workflow against an older tag, **or**
2. Use the admin API to mark an older release as active (if your coordinator build supports it), **or**
3. Update the `latest` pointer in R2 to the previous bundle and re-run `install.sh` on affected providers.

## Environment variables

Managed via EigenCloud KMS (prod) or GCP Secret Manager (dev). Core coordinator env vars:

| Variable | Purpose |
|---|---|
| `EIGENINFERENCE_PORT` | Coordinator HTTP port (default 8080) |
| `EIGENINFERENCE_ADMIN_KEY` | Admin API access (constant-time compared in state-export, etc.) |
| `EIGENINFERENCE_DATABASE_URL` | Postgres DSN |
| `EIGENINFERENCE_CONSOLE_URL` | Console UI URL |
| `EIGENINFERENCE_RELEASE_KEY` | Scoped key for CI release registration |
| `EIGENINFERENCE_PRIVY_APP_ID`, `EIGENINFERENCE_PRIVY_APP_SECRET`, `EIGENINFERENCE_PRIVY_VERIFICATION_KEY` | Privy JWT auth |
| `EIGENINFERENCE_ADMIN_EMAILS` | Comma-separated admin emails |
| `EIGENINFERENCE_MDM_URL` | Internal MicroMDM URL, e.g. `https://localhost:9002` |
| `EIGENINFERENCE_MDM_API_KEY` | Must match `MICROMDM_API_KEY` |
| `MICROMDM_API_KEY` | Used by `start.sh` to launch MicroMDM |
| `MDM_PUSH_P12_B64` | Base64url-encoded Apple MDM push PKCS#12 |
| `EIGENINFERENCE_STEP_CA_ROOT`, `EIGENINFERENCE_STEP_CA_INTERMEDIATE` | CA cert paths |
| `MNEMONIC` | 12-word BIP39 Solana wallet for coordinator |
| `EIGENINFERENCE_SOLANA_RPC_URL` | Solana RPC endpoint |
| `DOMAIN` | Public domain, used by Caddyfile and `start.sh` |
| `APP_PORT` | Port Caddy reverse-proxies to (default 8080) |

`MICROMDM_API_KEY` and `EIGENINFERENCE_MDM_API_KEY` must be byte-identical; a mismatch causes MicroMDM device lookup to fail.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `/v1/models` empty or providers show `self_signed` trust | MicroMDM not running or API key mismatch | Verify `MICROMDM_API_KEY` == `EIGENINFERENCE_MDM_API_KEY`; check `start.sh` logs |
| MDM webhook 403 | `EIGENINFERENCE_MDM_WEBHOOK_SECRET` set on coordinator but `?token=` missing from MicroMDM webhook URL | Ensure `start.sh` templates the token into `-command-webhook-url` |
| step-ca re-initializes on every boot | Persistent storage not mounted or `/data` symlink missing | Confirm `/mnt/disks/userdata` is mounted and `/data -> /mnt/disks/userdata` exists |
| Provider disconnects frequently | Caddy health check timeout or WebSocket EOF | Check EigenCloud/Caddy logs; increase idle timeout if needed |
| Release registration 500 | `releases` table schema mismatch | Run pending Postgres migrations |
| Signed provider binary lacks keychain access | Missing provisioning profile or wrong entitlements | Check `release-swift.yml` entitlement verification steps |
