# Coordinator and Provider CLI Deploy Runbook

How to build, deploy, and update the Darkbloom coordinator and the Swift provider CLI.

> **Prod moved off EigenCloud (July 2026).** The production coordinator now runs on a GCE VM
> in project `darkbloom-mainnet`. If you are reading instructions that mention `ecloud`,
> they are for the retired EigenCloud deployment — see
> [`eigencloud-to-gcp-migration.md`](eigencloud-to-gcp-migration.md) for the migration record.

## Prerequisites

- [ ] `mise` installed and `mise install` run (toolchain versions are pinned in [`mise.toml`](../../mise.toml)).
- [ ] Coordinator tests pass locally:
  ```bash
  make coordinator-test
  ```
- [ ] For prod deploys: `gcloud` authenticated with IAM to SSH via IAP into project `darkbloom-mainnet`.
- [ ] `psql` access to the prod RDS database (for the pre-swap lock check).
- [ ] For provider releases: the `release-swift.yml` GitHub Actions runner (macOS, Xcode, Developer ID cert).
- [ ] For dev GCP deploys: `gcloud` authenticated to project `sepolia-ai` (see [`dev-environment.md`](dev-environment.md)).

## Infrastructure (prod)

| Item | Value |
|---|---|
| Platform | GCE VM `darkbloom-coordinator` (`c3d-highcpu-30`), zone `us-east4-a`, project `darkbloom-mainnet` |
| Access | IAP SSH only: `gcloud compute ssh darkbloom-coordinator --project darkbloom-mainnet --zone us-east4-a --tunnel-through-iap` |
| Domain | `api.darkbloom.dev` (host Caddy systemd service terminates TLS, proxies to `:8080`) |
| Coordinator | Docker container `coordinator`, **host network**, `--restart unless-stopped`, entrypoint [`coordinator/deploy/start.sh`](../../coordinator/deploy/start.sh) |
| MicroMDM | Port 9002, same container, **state on the persistent disk** (see below) |
| Database | AWS RDS PostgreSQL (external, `EIGENINFERENCE_DATABASE_URL`) |
| Persistent storage | Host disk `/mnt/disks/userdata`, bind-mounted into the container. Holds the MicroMDM BoltDB (`micromdm/`), step-ca state (`step-ca/`), and logs. `start.sh` symlinks `/data -> /mnt/disks/userdata`. |
| Images | Cloud Build trigger builds on every master push → `us-east4-docker.pkg.dev/darkbloom-mainnet/coordinator/coordinator:<SHORT_SHA>` |
| Env file | `/etc/d-inference/env` on the VM (root-only). **Hand-maintained:** several tuned vars are NOT emitted by any generator script — never regenerate this file; edit it in place and keep a timestamped backup. |
| Fallback | The previous container is kept (stopped) as `coordinator_fallback_<timestamp>` for instant rollback |

## Steps — coordinator deploy (prod)

### 1. Confirm the image is built

Cloud Build builds every master push automatically. Confirm your commit's image exists:

```bash
gcloud builds list --project darkbloom-mainnet --limit 5 \
  --format 'table(createTime.date(tz=LOCAL),substitutions.SHORT_SHA,status)'
```

The image tag is the 7-char short SHA of the master commit.

### 2. Pre-swap checks

**Check RDS for lock holders before restarting.** Coordinator startup runs schema
migrations; an `ALTER TABLE` queued behind a long-running query's relation lock will
hang the whole deploy (2026-07-03 outage: repeated restarts stacked migrations behind a
58-minute runaway query — recovery was killing the blocking PID, not more restarts).

```bash
# No rows = safe to proceed. Rows here = investigate/kill blockers first.
psql "$PROD_DB_URL" -c "select pid, now()-query_start as runtime, state, left(query,80)
  from pg_stat_activity
  where state <> 'idle' and query_start < now() - interval '60 seconds'
    and pid <> pg_backend_pid();"
psql "$PROD_DB_URL" -c "select count(*) as blocked from pg_locks where granted = false;"
```

Then, on the VM: pull the image and snapshot current health.

```bash
sudo docker pull us-east4-docker.pkg.dev/darkbloom-mainnet/coordinator/coordinator:<TAG>
curl -s localhost:8080/health   # note the provider count for post-swap comparison
```

### 3. Env changes (if any)

```bash
sudo cp /etc/d-inference/env /etc/d-inference/env.bak.$(date +%Y%m%d-%H%M%S)
sudo vim /etc/d-inference/env   # or targeted sed
sudo grep -E "^THE_VARS_YOU_CHANGED" /etc/d-inference/env   # verify
```

New env vars take effect only on container start — flip flags in the same maintenance
window as the swap.

### 4. Swap

Rules learned the hard way:

- **One host-network container at a time.** Stop the old container *before* starting the
  new one. Two containers fighting over `:8080` caused the 2026-07-03 outage.
- **The volume mount is mandatory.** Omitting `-v /mnt/disks/userdata:/mnt/disks/userdata`
  boots a **blank MicroMDM** — every device lookup returns "device not found", the fleet
  falls to `self_signed` trust, and with `MIN_TRUST=hardware` the network is effectively
  down (2026-07-04 incident: ~6 minutes of near-zero traffic).

```bash
FALLBACK=coordinator_fallback_$(date +%Y%m%d-%H%M%S)
sudo docker rename coordinator $FALLBACK
sudo docker stop $FALLBACK
sudo docker run -d --name coordinator \
  --network host \
  --restart unless-stopped \
  -v /mnt/disks/userdata:/mnt/disks/userdata \
  --env-file /etc/d-inference/env \
  us-east4-docker.pkg.dev/darkbloom-mainnet/coordinator/coordinator:<TAG>
```

Startup takes ~15–40 s (MicroMDM init + migrations + listeners). If health does not
respond after ~60 s, suspect a migration stuck behind a DB lock — re-run the
`pg_stat_activity` query from step 2 and kill the blocking PID (`select
pg_terminate_backend(<pid>)`); do **not** restart the container again.

### 5. Verify

```bash
# Health + provider reconnection ramp (fleet reconnects within ~1 min)
curl -s localhost:8080/health

# Trust rebuild: hardware upgrades should dominate within ~2 minutes.
sudo docker logs coordinator 2>&1 | grep -c "upgraded to hardware trust"
# "device not found in MDM" should stay at the baseline (a few dozen genuinely
# unenrolled boxes). HUNDREDS of these = the volume mount is missing; go to Rollback.
sudo docker logs coordinator 2>&1 | grep -c "device not found in MDM"

# Startup config lines — confirm flags picked up
sudo docker logs coordinator 2>&1 | grep -E "quality-concurrency|servability|warm-pool|dedicated"

# Public check (from anywhere)
curl -s https://api.darkbloom.dev/health
curl -s https://api.darkbloom.dev/v1/stats | head -c 300
```

Traffic-level verification (from any machine with DB access): served requests per minute
should return to the pre-swap rate within ~2 minutes:

```bash
psql "$PROD_DB_URL" -c "select date_trunc('minute', created_at) m,
  count(*) filter (where outcome='selected') selected,
  count(distinct provider_id) filter (where outcome='selected') providers
  from inference_routes where created_at > now() - interval '15 minutes'
  group by 1 order by 1;"
```

### 6. Rollback

The old container is still on the box, stopped, with the pre-swap image and env:

```bash
sudo docker stop coordinator && sudo docker rm coordinator
sudo docker rename <fallback-name> coordinator   # or docker start <fallback-name>
sudo docker start coordinator
# If env was changed, restore the timestamped backup first:
sudo cp /etc/d-inference/env.bak.<timestamp> /etc/d-inference/env
```

Rollback time: ~30 seconds. Providers reconnect automatically (the live registry is
in-process and rebuilt on reconnect; durable state is in RDS and on the persistent disk).

## Provider CLI release

Provider releases are built and shipped by `.github/workflows/release-swift.yml` (CLI-only Swift). The workflow:

1. Builds `darkbloom` and `darkbloom-enclave` from `provider-swift/`.
2. Fetches a matching `mlx.metallib` (built from the MLX source nested in `libs/mlx-swift`).
3. Embeds the provisioning profile and signs with Developer ID Application.
4. Notarizes with Apple.
5. Computes SHA-256 hashes **after** signing/notarization.
6. Uploads the tarball to R2 under `releases/v${VERSION}` and `releases/latest`.
7. Registers the release with `POST /v1/releases` using `RELEASE_KEY`.
8. Creates a GitHub release.

Reference: [`release-swift.yml`](../../.github/workflows/release-swift.yml).

### Cutting a release

Tag conventions:

| Tag shape | Environment |
|---|---|
| `vX.Y.Z` | Prod (requires GitHub Environment approval if configured) |
| `vX.Y.Z-dev.N` | Dev |
| `vX.Y.Z-swift` or `vX.Y.Z-swift.N` | Accepted aliases during migration |

The fallback version advertised when no release is registered is `LatestProviderVersion` in
[`coordinator/api/server.go`](../../coordinator/api/server.go). Keep it in sync with
`ProviderCore.version`. `GET /v1/releases/latest` returns **404 when no release row
exists** — fixed by registering the release, not by bumping code.

```bash
git tag -a v0.7.4 -m "Release v0.7.4"
git push origin master --tags
```

### Required GitHub secrets

The workflow resolves prefixed secrets (`DEV_*` / `PROD_*`) with legacy unprefixed fallbacks for prod:

| Secret | Purpose |
|---|---|
| `COORDINATOR_URL` / `DEV_COORDINATOR_URL` / `PROD_COORDINATOR_URL` | Coordinator base URL |
| `RELEASE_KEY` / `DEV_RELEASE_KEY` / `PROD_RELEASE_KEY` | `POST /v1/releases` registration key |
| `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_ENDPOINT`, `R2_BUCKET`, `R2_PUBLIC_URL` | R2 artifact storage |
| `APPLE_CERTIFICATE_P12`, `APPLE_CERTIFICATE_PASSWORD` | Developer ID signing |
| `APPLE_ID`, `APPLE_APP_PASSWORD` | Notarization |
| `PROVISIONING_PROFILE_BASE64` | Grants `keychain-access-groups` and `aps-environment=production` |

### Install

Users install via the coordinator-served script:

```bash
curl -fsSL https://api.darkbloom.dev/install.sh | bash
```

The script is embedded in the coordinator binary via `go:embed`
([`scripts/install.sh`](../../scripts/install.sh)); the coordinator substitutes its own
URL at serve time so the same binary works for dev and prod.

## Environment variables (prod env file)

Lives at `/etc/d-inference/env` on the VM. Secrets and operational flags together;
timestamped backups sit alongside. The authoritative reference for routing-flag
semantics is the code (`coordinator/registry/`, `coordinator/api/`); the highlights:

| Variable | Notes |
|---|---|
| `EIGENINFERENCE_DATABASE_URL` | RDS DSN — presence selects the Postgres store |
| `EIGENINFERENCE_ADMIN_KEY`, `EIGENINFERENCE_RELEASE_KEY` | Admin / CI release auth |
| `EIGENINFERENCE_PRIVY_*` | Consumer JWT auth |
| `MICROMDM_API_KEY` = `EIGENINFERENCE_MDM_API_KEY` | Must be byte-identical or MDM lookups fail |
| `MDM_PUSH_P12_B64`, `PROFILE_SIGNING_P12_*` | Apple MDM push + profile signing |
| `EIGENINFERENCE_MDM_WEBHOOK_SECRET` | Optional; unset logs a startup warning (webhook then relies on the CommandUUID gate alone) |
| `MNEMONIC` | X25519 key derivation (legacy name) |
| `EIGENINFERENCE_TTFT_HARD_REJECT`, `_TTFT_LIVE_DEADLINE_BASE_MS`, `_TTFT_CALIBRATION`, `_TTFT_TERMINAL_REJECT` | TTFT gate + calibration + ladder termination |
| `EIGENINFERENCE_QUEUE_BEFORE_SHED`, `_QUEUE_MAX_DEPTH`, `_QUEUE_MAX_WAIT` | Capacity queueing (dedicated pools included) |
| `EIGENINFERENCE_HEALTH_EJECTION` | Stable-identity ejection kill switch — **`on` in prod**; `off` disables black-hole ejection entirely |
| `EIGENINFERENCE_QUALITY_CONCURRENCY_OVERCOMMIT`, `_BY_MODEL` | Per-box admission density (default 1.2) |
| `EIGENINFERENCE_QUALITY_CAP_PER_MODEL_TPS` | Quality cap reads each model's own solo decode rate (default `true`; `false` restores the provider-level benchmark) |
| `EIGENINFERENCE_QUALITY_CAP_SOLO_MIN_SAMPLES` | Solo samples required before a per-(model, chip) median is trusted (default 5) |
| `EIGENINFERENCE_MODEL_SOLO_TPS_SEED` | Cold-start solo rates, `build-id=tok/s` CSV (e.g. `gemma-4-26b-qat-4bit=14,gpt-oss-20b=30`); the in-memory TPS registry is restart-wiped |
| `EIGENINFERENCE_WARM_POOL_*` | Warm-pool controller (active; `OBSERVE_ONLY=false`) |
| `EIGENINFERENCE_DEDICATED_MODELS` | Static dedicated-box partition (`gemma-4`) |
| `EIGENINFERENCE_V2_VERSION_FLOOR` | v0.7.5-migration audit: providers at/above this version are engine-v2-only, so a heartbeat `max_concurrency` above the v2 ceiling is clamped + counted on the `provider.v2_concurrency_tripwire` Datadog tripwire (silent-legacy-fallback resurfaced). Default empty = off; set to `0.7.5` with deploy batch B; permanent audit thereafter |
| `EIGENINFERENCE_V2_MAX_CONCURRENCY_CEILING` | Chat-slot concurrency ceiling for ≥floor providers (default 4 = the v2 engine's box-wide cap) |
| `EIGENINFERENCE_MODEL_VERSION_FLOORS` | Per-model provider-version routing floors, `pattern=version` CSV (e.g. `gemma-4=0.7.5`; substring match like `_DEDICATED_MODELS`). Floored models route/pre-warm only onto ≥floor providers; empty-version providers fail every floor. Default empty = off; set at ≥70% online-fleet v0.7.5 adoption, retire after convergence |
| `EIGENINFERENCE_TTFT_PREFILL_MEDIANS` | Prefill-honest TTFT: use the per-(model, chip) median of fleet-observed `observed_prefill_tps` in the TTFT estimate once trusted (default `true`; `false` restores the pure ratio-derived path). Live-read, no restart |
| `EIGENINFERENCE_TTFT_PREFILL_MIN_SAMPLES` | Prefill samples required before a per-(model, chip) median is trusted by the TTFT estimate (default 5). Live-read |
| `EIGENINFERENCE_PREFILL_FALLBACK_MODE` | Data-derived prefill fallback anchor for UNMEASURED fleets (`off`\|`shadow`\|`enforce`, default `off`): `shadow` emits `routing.prefill_fallback{would_admit\|would_shed}` without changing routing; `enforce` lifts the static sqrt(bandwidth)×ratio estimate (~280 tok/s) to the fallback anchor when neither a slot measurement nor a trusted median exists |
| `EIGENINFERENCE_PREFILL_FALLBACK_TPS` | The fallback anchor (default 6500 = measured fleet prefill p50, 2026-06-22 live check) |
| `EIGENINFERENCE_MAX_PREFILL_TPS` | Prefill sanity ceiling shared by heartbeat ingest zeroing and routing caps (default 20000, above the measured p90 17,707 so real v0.7.5 `observed_prefill_tps` reports survive ingest; the old 5000 would zero the majority of them) |
| `EIGENINFERENCE_IPAPI_KEY` | ip-api.com PRO key; unset falls back to the free 45 req/min tier |

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Startup hangs, no health response >60 s | Migration stuck behind an RDS relation lock | `pg_stat_activity` → `pg_terminate_backend(<blocking pid>)`. Do NOT restart the container repeatedly — restarts stack migrations (2026-07-03 outage) |
| Fleet drops to `self_signed`, "device not found in MDM" storms | Container started **without** `-v /mnt/disks/userdata:/mnt/disks/userdata` → blank MicroMDM BoltDB | Stop container, re-run with the mount (2026-07-04 incident) |
| `/v1/models` empty or providers show `self_signed` | MicroMDM not running or API key mismatch | Verify `MICROMDM_API_KEY` == `EIGENINFERENCE_MDM_API_KEY`; check container logs |
| Port conflict / crash loop on start | Another host-network container still running | `docker ps`, stop the old one first — one at a time |
| MDM webhook 403 | `EIGENINFERENCE_MDM_WEBHOOK_SECRET` set but `?token=` missing from webhook URL | `start.sh` templates the token into `-command-webhook-url`; restart the container |
| MicroMDM state resets on every boot | Persistent disk not mounted or `/data` symlink missing | Confirm the bind mount and `/data -> /mnt/disks/userdata` inside the container |
| Release registration 500 | `releases` table schema mismatch | Run pending Postgres migrations |
| New routing flags "not working" | Env var kill switch still set from a previous incident | `grep` the env file — flags like `HEALTH_EJECTION=off` / `QUEUE_BEFORE_SHED=false` silently disable whole subsystems |
