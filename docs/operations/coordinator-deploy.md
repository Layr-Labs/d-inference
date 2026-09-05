# Deploy the coordinator (production)

> Last updated: 2026-09-05 · commit `4d9811f7c`

Runbook for swapping the production coordinator container on the GCE VM
`darkbloom-coordinator` to a Cloud-Build image of a reviewed `master` commit,
verifying it, and rolling back. Every VM mutation here is **human-only**; agents
may read build metadata and health endpoints but must not pull, stop, start, or
edit the env file. Provider CLI releases are a separate runbook:
[`provider-release.md`](provider-release.md); the dev coordinator is
[dev-environment.md](dev-environment.md).

For the remaining coordinator performance upgrade, also follow
[the Tiers 2 and 3 rollout checks](coordinator-perf-tier23-rollout.md).

For international payout configuration and validation, also follow [Global Payouts](global-payouts.md).

## When to use

- Shipping a coordinator change to production (including the coordinator half
  of a provider version bump: `LatestProviderVersion` in
  `coordinator/api/server.go`).
- Applying an env-file change (env vars are read once at process start, so any
  change needs a container recreate — the same swap procedure).
- Recovering from a bad deploy (see Rollback).

## Prerequisites

- `gcloud` authenticated with IAM to SSH via IAP into project `darkbloom-mainnet`
  and to read Cloud Build / Artifact Registry.
- `psql` access to the production RDS database (`PROD_DB_URL`) for the
  pre-swap lock check.
- Explicit human approval for the production mutation (rule 1 in
  [README.md](README.md) is the canonical statement), recorded where your team
  records deploys; a second human on hand during the swap.
- `APPROVED_PREVIOUS_IMAGE`: the `sha256:<64 hex>` image ID of the container
  currently in production, confirmed known-good and written into the same
  deploy record before you touch the host. Step 3 refuses to continue if the
  live container is not that image, so the rollback target is decided — and
  reviewed — before anything is mutated. There is no file or script behind it;
  it is a value you paste from the deploy record.
- The candidate commit is `origin/master`, CI is green, and
  [`.github/workflows/ci.yml`](../../.github/workflows/ci.yml) job "Release
  Integrity" passed (`scripts/check-release-version.sh`,
  `scripts/sync-install-embed.sh check`, `scripts/test-prod-env-refresh.sh`).

### Infrastructure

| Item | Value |
|---|---|
| Host | GCE VM `darkbloom-coordinator` (`c3d-highcpu-30`), zone `us-east4-a`, project `darkbloom-mainnet`; AMD SEV confidential VM with Shielded VM options; IAP SSH only |
| Access | `gcloud compute ssh darkbloom-coordinator --project darkbloom-mainnet --zone us-east4-a --tunnel-through-iap` |
| Ingress | `api.darkbloom.dev` → host Caddy (systemd, static certificate) → `:8080`. Do not reload Caddy during a swap; it reconnects the whole provider fleet |
| Image | `us-east4-docker.pkg.dev/darkbloom-mainnet/coordinator/coordinator:<SHORT_SHA>` built by [`deploy/gcp/cloudbuild-prod.yaml`](../../deploy/gcp/cloudbuild-prod.yaml) from [`coordinator/Dockerfile`](../../coordinator/Dockerfile) |
| Container | `coordinator`: `--network host`, `--restart unless-stopped`, `--stop-timeout 630`, `-v /mnt/disks/userdata:/mnt/disks/userdata`, `--env-file /etc/d-inference/env`; entrypoint [`coordinator/deploy/start.sh`](../../coordinator/deploy/start.sh) |
| Inside the container | `start.sh` symlinks `/data -> /mnt/disks/userdata`, starts MicroMDM on `:9002` (state in `/data/micromdm`, command webhook `http://localhost:8080/v1/mdm/webhook`), then `exec coordinator` as PID 1. `/usr/local/bin/promptsidecar` is spawned by the coordinator when `EIGENINFERENCE_PROMPT_SIDECAR_ENABLED=true` |
| Persistent disk | `/mnt/disks/userdata`: MicroMDM BoltDB, prompt-contract artifacts (`EIGENINFERENCE_PROMPT_SIDECAR_ARTIFACT_ROOT=/mnt/disks/userdata/prompt-contracts`), logs. **Omitting the bind mount boots a blank MDM and drops the fleet to `self_signed` trust** (2026-07-04 incident) |
| Database | AWS RDS PostgreSQL via `EIGENINFERENCE_DATABASE_URL`; schema migrations run at coordinator start |
| Env file | `/etc/d-inference/env`, root-only `0600`, on the boot disk (never tmpfs). Managed by [`deploy/gcp/prod/refresh-env.sh`](../../deploy/gcp/prod/refresh-env.sh) with [`deploy/gcp/prod/required-env-keys.txt`](../../deploy/gcp/prod/required-env-keys.txt) and [`deploy/gcp/prod/release-env-defaults`](../../deploy/gcp/prod/release-env-defaults); applied at boot by [`deploy/gcp/prod/darkbloom-env-refresh.service`](../../deploy/gcp/prod/darkbloom-env-refresh.service) (`Before=docker.service`) |
| Fallback | The previous container is renamed `coordinator_fallback_<timestamp>` and kept stopped |

### How the image is tagged (read this once)

`cloudbuild-prod.yaml` tags the image with the **7-character `SHORT_SHA`** of
the trigger commit and refuses to build unless `SHORT_SHA` equals the first 7
characters of the 40-character `COMMIT_SHA`. The full commit is recorded in
the image label `org.opencontainers.image.revision` (`Dockerfile` `LABEL`) and
in the binary (`-X …/coordinator/api.BuildCommit`), which `/health` reports as
`build_commit`. So: the **tag** is short, the **identity check** is the full
commit read back from the label and from `/health`. The smoke step in Cloud
Build already asserts the label equals `COMMIT_SHA` and that
`/usr/local/bin/coordinator` and `/usr/local/bin/promptsidecar` are executable.
There is no full-SHA tag; do not wait for one.

## Steps

### 1. Pin the candidate (local shell)

```bash
: "${CANDIDATE_VERSION:?unprefixed X.Y.Z, equal to LatestProviderVersion in coordinator/api/server.go}"
: "${CANDIDATE_COMMIT:?reviewed 40-character commit}"
[[ "$CANDIDATE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || { echo "CANDIDATE_COMMIT must be 40 lowercase hex" >&2; exit 2; }
git fetch origin master
[[ "$(git rev-parse origin/master)" == "$CANDIDATE_COMMIT" ]] || { echo "candidate is not origin/master" >&2; exit 2; }
CANDIDATE_TAG=${CANDIDATE_COMMIT:0:7}
CANDIDATE_IMAGE="us-east4-docker.pkg.dev/darkbloom-mainnet/coordinator/coordinator:${CANDIDATE_TAG}"

# The prod trigger must build from the checked-in config, not an inline step.
gcloud builds triggers describe prod-build --project=darkbloom-mainnet \
  --format='value(filename)' | grep -Fx 'deploy/gcp/cloudbuild-prod.yaml'
# A SUCCESS build for exactly this commit must exist.
gcloud builds list --project darkbloom-mainnet --limit=1 \
  --filter="substitutions.COMMIT_SHA=$CANDIDATE_COMMIT AND status=SUCCESS" \
  --format='value(substitutions.COMMIT_SHA)' | grep -Fx "$CANDIDATE_COMMIT"
CANDIDATE_DIGEST=$(gcloud artifacts docker images describe "$CANDIDATE_IMAGE" \
  --project=darkbloom-mainnet --format='value(image_summary.digest)')
[[ "$CANDIDATE_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "no digest for $CANDIDATE_IMAGE" >&2; exit 2; }
echo "image=$CANDIDATE_IMAGE digest=$CANDIDATE_DIGEST"
```

Carry `CANDIDATE_VERSION`, `CANDIDATE_COMMIT`, and `CANDIDATE_DIGEST` to the VM
by hand; shell variables do not cross SSH.

### 2. Pre-swap checks (VM and DB)

Startup runs schema migrations. An `ALTER TABLE` queued behind a long query's
relation lock hangs the deploy (2026-07-03 outage — the fix was killing the
blocker, not restarting). No rows means safe to proceed:

```bash
psql "$PROD_DB_URL" -c "select pid, now()-query_start as runtime, state, left(query,80)
  from pg_stat_activity where state <> 'idle'
    and query_start < now() - interval '60 seconds' and pid <> pg_backend_pid();"
psql "$PROD_DB_URL" -c "select count(*) as blocked from pg_locks where granted = false;"
```

On the VM, pull the candidate and prove it is the reviewed commit:

```bash
: "${CANDIDATE_VERSION:?}" "${CANDIDATE_COMMIT:?}" "${CANDIDATE_DIGEST:?}"
CANDIDATE_IMAGE="us-east4-docker.pkg.dev/darkbloom-mainnet/coordinator/coordinator:${CANDIDATE_COMMIT:0:7}"
sudo docker pull "$CANDIDATE_IMAGE"
sudo docker image inspect "$CANDIDATE_IMAGE" --format '{{json .RepoDigests}}' \
  | jq -e --arg want "${CANDIDATE_IMAGE%:*}@${CANDIDATE_DIGEST}" 'index($want) != null' >/dev/null
sudo docker image inspect "$CANDIDATE_IMAGE" \
  --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}' | grep -Fx "$CANDIDATE_COMMIT"
sudo docker image inspect "$CANDIDATE_IMAGE" \
  --format '{{ index .Config.Labels "org.opencontainers.image.version" }}' | grep -Fx "$CANDIDATE_VERSION"
curl -fsS localhost:8080/health | jq .          # current coordinator must be healthy before you touch it
```

Snapshot the operator-owned cache controls so the swap can be proven not to
have changed them (values are never printed, only digests):

```bash
curl -fsS localhost:8080/v1/cache/status | jq -S \
  '{routing_mode, percent:.activation.percent, max_plan_qps:.activation.max_plan_qps}' \
  > /tmp/darkbloom-cache-controls.before.json
sudo sh -c 'umask 077; awk -F= '\''$1 ~ /^EIGENINFERENCE_CACHE_ROUTING_/ || $1 == "EIGENINFERENCE_CACHE_MASTER_KEY"'\'' \
  /etc/d-inference/env | LC_ALL=C sort | sha256sum | cut -d" " -f1 > /tmp/darkbloom-cache-env.before.sha256'
```

### 3. Refresh the env file and capture rollback inputs

`refresh-env.sh --check` validates the live file against the required-key
manifest and prints only key names; `--apply` writes a same-directory temp
file, refuses to drop any existing key, adds absent release defaults, migrates
only explicitly retired defaults, keeps a root-only timestamped backup, and
renames atomically. It never touches secrets. It fails if `/etc/d-inference` is
tmpfs.

```bash
# First time on a host only: install the reviewed inputs and the boot-time unit.
sudo install -d -m 0755 /usr/local/lib/darkbloom-env
sudo install -m 0755 deploy/gcp/prod/refresh-env.sh /usr/local/sbin/darkbloom-refresh-env
sudo install -m 0644 deploy/gcp/prod/required-env-keys.txt /usr/local/lib/darkbloom-env/required-env-keys.txt
sudo install -m 0644 deploy/gcp/prod/release-env-defaults  /usr/local/lib/darkbloom-env/release-env-defaults
sudo install -m 0644 deploy/gcp/prod/darkbloom-env-refresh.service /etc/systemd/system/darkbloom-env-refresh.service
sudo systemctl daemon-reload && sudo systemctl enable darkbloom-env-refresh.service

# Every deploy:
sudo REQUIRED_FILE=/usr/local/lib/darkbloom-env/required-env-keys.txt \
     DEFAULTS_FILE=/usr/local/lib/darkbloom-env/release-env-defaults \
     /usr/local/sbin/darkbloom-refresh-env --check
REFRESH_OUTPUT=$(sudo REQUIRED_FILE=/usr/local/lib/darkbloom-env/required-env-keys.txt \
     DEFAULTS_FILE=/usr/local/lib/darkbloom-env/release-env-defaults \
     /usr/local/sbin/darkbloom-refresh-env --apply)
echo "$REFRESH_OUTPUT"                              # "... applied N additions and M migrations; backup=/etc/d-inference/env.bak.<UTC>"
PREVIOUS_ENV_BACKUP=${REFRESH_OUTPUT##*backup=}
PREVIOUS_ENV_BACKUP_SHA256=$(sudo sha256sum "$PREVIOUS_ENV_BACKUP" | cut -d' ' -f1)

# The refresh must not have changed operator-selected controls.
sudo sh -c 'umask 077; awk -F= '\''$1 ~ /^EIGENINFERENCE_CACHE_ROUTING_/ || $1 == "EIGENINFERENCE_CACHE_MASTER_KEY"'\'' \
  /etc/d-inference/env | LC_ALL=C sort | sha256sum | cut -d" " -f1 > /tmp/darkbloom-cache-env.pre-swap.sha256'
sudo cmp /tmp/darkbloom-cache-env.before.sha256 /tmp/darkbloom-cache-env.pre-swap.sha256
sudo grep -Fx 'EIGENINFERENCE_TTFT_LIVE_DEADLINE_BASE_MS=9000' /etc/d-inference/env   # production first-content base
```

Record the current container's immutable image and persist the rollback state
root-only, then confirm the running image is the approved rollback target
(`APPROVED_PREVIOUS_IMAGE`, see Prerequisites):

```bash
: "${APPROVED_PREVIOUS_IMAGE:?sha256:<64 hex> from the reviewed rollback allowlist}"
PREVIOUS_IMAGE=$(sudo docker inspect --format '{{.Image}}' coordinator)
[[ "$PREVIOUS_IMAGE" == "$APPROVED_PREVIOUS_IMAGE" ]] || { echo "running image is not the approved rollback image" >&2; exit 2; }
FALLBACK=coordinator_fallback_$(date +%Y%m%d-%H%M%S)
sudo install -d -m 0700 /var/lib/darkbloom-deploy
printf '%s\n%s\n%s\n%s\n' "$PREVIOUS_IMAGE" "$PREVIOUS_ENV_BACKUP" "$PREVIOUS_ENV_BACKUP_SHA256" "$FALLBACK" \
  | sudo install -m 0600 /dev/stdin /var/lib/darkbloom-deploy/rollback-state
```

### 4. Swap

Rules: **one host-network container at a time** (stop before start; two
containers on `:8080` caused the 2026-07-03 outage); **630-second stop
timeout** so the 10-minute application drain completes instead of Docker's
10-second SIGKILL; **the volume mount is mandatory**.

```bash
sudo docker rename coordinator "$FALLBACK"
sudo docker stop -t 630 "$FALLBACK"               # drains: /readyz goes 503, new requests get retryable 429s
sudo docker run -d --name coordinator \
  --network host --restart unless-stopped --stop-timeout 630 \
  -v /mnt/disks/userdata:/mnt/disks/userdata \
  --env-file /etc/d-inference/env \
  "$CANDIDATE_IMAGE"
```

Startup takes ~15–40 s (MicroMDM init, migrations, listeners). If `/health`
does not answer after ~60 s, suspect a migration behind a DB lock: re-run the
`pg_stat_activity` query and `pg_terminate_backend(<pid>)` the blocker. **Do
not restart the container again** — restarts stack migrations.

## Verification

```bash
HEALTH=$(curl -fsS localhost:8080/health); echo "$HEALTH"
echo "$HEALTH" | jq -e --arg v "$CANDIDATE_VERSION" --arg c "$CANDIDATE_COMMIT" \
  '.status == "ok" and .version == $v and .build_commit == $c and .build_date != "unknown"'
curl -fsS localhost:8080/readyz                       # 200 once not draining
[[ "$(sudo docker inspect --format '{{.Config.Image}}' coordinator)" == "$CANDIDATE_IMAGE" ]]

# Operator controls preserved byte-for-byte across the swap.
diff -u /tmp/darkbloom-cache-controls.before.json <(curl -fsS localhost:8080/v1/cache/status | jq -S \
  '{routing_mode, percent:.activation.percent, max_plan_qps:.activation.max_plan_qps}')
sudo sh -c 'umask 077; awk -F= '\''$1 ~ /^EIGENINFERENCE_CACHE_ROUTING_/ || $1 == "EIGENINFERENCE_CACHE_MASTER_KEY"'\'' \
  /etc/d-inference/env | LC_ALL=C sort | sha256sum | cut -d" " -f1 > /tmp/darkbloom-cache-env.after.sha256'
sudo cmp /tmp/darkbloom-cache-env.pre-swap.sha256 /tmp/darkbloom-cache-env.after.sha256

# Prompt sidecar healthy and preloaded.
curl -fsS localhost:8080/v1/cache/status | jq -e \
  '.sidecar.enabled and .sidecar.ready and .sidecar.restarts == 0 and .preload.ready and .preload.failures == 0
   and .prompt_artifacts.pending == 0 and .prompt_artifacts.failed == 0'

# Fleet trust rebuild (~2 min) and MDM sanity.
sudo docker logs coordinator 2>&1 | grep -c "upgraded live provider to hardware trust"   # should climb
sudo docker logs coordinator 2>&1 | grep -c "device not found in MDM"        # baseline is a few dozen; hundreds = missing volume mount → Rollback
sudo docker logs coordinator 2>&1 | grep "postgres migration completed"      # one line per migration; result already_applied on steady state

# Public.
curl -fsS https://api.darkbloom.dev/health
```

Traffic should return to the pre-swap rate within ~2 minutes:

```bash
psql "$PROD_DB_URL" -c "select date_trunc('minute', created_at) m,
  count(*) filter (where outcome='selected') selected,
  count(distinct provider_id) filter (where outcome='selected') providers
  from inference_routes where created_at > now() - interval '15 minutes' group by 1 order by 1;"
```

## Rollback

Roll back only to the image and env captured in step 3. Never start a
coordinator older than the `backfill_withdrawable_balance_v1` migration
(`coordinator/store/postgres_withdrawable_migration.go`): pre-marker binaries
re-run the historical balance backfill on every start, which is not
financially safe — for those cases roll **forward** with a patched image.

```bash
ROLLBACK_STATE=/var/lib/darkbloom-deploy/rollback-state
[[ "$(sudo stat -c '%U:%G:%a' "$ROLLBACK_STATE")" == "root:root:600" ]]
PREVIOUS_IMAGE=$(sudo sed -n 1p "$ROLLBACK_STATE")
PREVIOUS_ENV_BACKUP=$(sudo sed -n 2p "$ROLLBACK_STATE")
PREVIOUS_ENV_BACKUP_SHA256=$(sudo sed -n 3p "$ROLLBACK_STATE")
FALLBACK=$(sudo sed -n 4p "$ROLLBACK_STATE")
[[ "$(sudo sha256sum "$PREVIOUS_ENV_BACKUP" | cut -d' ' -f1)" == "$PREVIOUS_ENV_BACKUP_SHA256" ]]
sudo docker image inspect "$PREVIOUS_IMAGE" --format '{{.Id}}'

sudo docker stop -t 630 coordinator && sudo docker rm coordinator     # one host-network container at a time
sudo docker ps -q --filter "name=$FALLBACK" | grep -q . && sudo docker stop -t 630 "$FALLBACK"
sudo cp "$PREVIOUS_ENV_BACKUP" /etc/d-inference/env
sudo docker run -d --name coordinator \
  --network host --restart unless-stopped --stop-timeout 630 \
  -v /mnt/disks/userdata:/mnt/disks/userdata \
  --env-file /etc/d-inference/env \
  "$PREVIOUS_IMAGE"
```

### Verify the rollback

The same checks as [Verification](#verification), keyed to the previous image
instead of the candidate:

```bash
PREVIOUS_COMMIT=$(sudo docker image inspect "$PREVIOUS_IMAGE" \
  --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')
HEALTH=$(curl -fsS localhost:8080/health); echo "$HEALTH"
echo "$HEALTH" | jq -e --arg c "$PREVIOUS_COMMIT" \
  '.status == "ok" and .build_commit == $c and .build_date != "unknown"'
curl -fsS localhost:8080/readyz                       # 200 once not draining
[[ "$(sudo docker inspect --format '{{.Image}}' coordinator)" == "$PREVIOUS_IMAGE" ]]
sudo docker logs coordinator 2>&1 | grep -c "upgraded live provider to hardware trust"   # climbs over ~2 min
sudo docker logs coordinator 2>&1 | grep -c "device not found in MDM"        # a few dozen is normal; hundreds = volume mount missing
curl -fsS https://api.darkbloom.dev/health
```

Then run the `inference_routes` traffic query from Verification and confirm
the pre-incident rate returns within ~2 minutes. Record the rollback and its
cause in the deploy record; the failed candidate image stays in Artifact
Registry for diagnosis.

Providers reconnect on their own; the live registry is in-process and rebuilt
from reconnects, durable state is in RDS and on the persistent disk.

## Environment file

`/etc/d-inference/env` holds secrets and operator controls together. The
meaning, type, and default of every `EIGENINFERENCE_*` variable is documented
once in [`../reference/configuration.md`](../reference/configuration.md); this
page only says which keys production must have. `refresh-env.sh` fails
`--check`/`--apply` when any key in `required-env-keys.txt` is missing or blank
and appends any `release-env-defaults` key that is absent (existing values win).

**Required keys** (`deploy/gcp/prod/required-env-keys.txt`): `DOMAIN`,
`APNS_AUTH_KEY_P8_B64`, `APNS_ENFORCE_AFTER`, `APNS_KEY_ID`, `APNS_MODE`,
`APNS_TEAM_ID`, `APNS_TOPIC`, `MICROMDM_API_KEY`, `MDM_PUSH_P12_B64`,
`MNEMONIC`, `MODEL_REGISTRY_PUBLISHING_KEY`, and these `EIGENINFERENCE_*`
keys: `ADMIN_KEY`, `BASE_URL`, `COLD_DISPATCH`, `CONSOLE_URL`, `DATABASE_URL`,
`DEDICATED_MODELS`, `HEALTH_EJECTION`, `MDM_API_KEY` (must be byte-identical
to `MICROMDM_API_KEY`), `MIN_DECODE_TPS`, `MIN_PROVIDER_VERSION`,
`MODEL_SOLO_TPS_SEED`, `PORT`, `PREFILL_DECODE_RATIO`, `PRIVY_APP_ID`,
`PRIVY_APP_SECRET`, `PRIVY_VERIFICATION_KEY`, `PROMPT_CALIBRATION`,
`QUEUE_BEFORE_SHED`, `QUEUE_MAX_DEPTH`, `QUEUE_MAX_WAIT`, `R2_CDN_URL`,
`RELEASE_KEY`, `SERVABILITY_GATE`, `SERVICE_EXPECTED_OUTPUT_ADMISSION_CEILING`,
`SERVICE_EXPECTED_OUTPUT_ADMISSION_ENABLED`,
`SERVICE_EXPECTED_OUTPUT_ADMISSION_FLOOR`,
`SERVICE_EXPECTED_OUTPUT_ADMISSION_FRACTION`, `SERVICE_RESERVATIONS_ENABLED`,
`STATE_EXPORT_ENABLED`, `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`,
`TRUST_GEO_HEADERS`, `TTFT_ADMISSION_MODE`, `TTFT_HARD_REJECT`,
`TTFT_LIVE_DEADLINE_BASE_MS`, `TTFT_OCCUPANCY_ALPHA`, and the fifteen
`WARM_POOL_*` keys (`CAPACITY_REJECT_THRESHOLD`, `COLD_DISPATCH_THRESHOLD`,
`ENABLED`, `INTERVAL`, `LOAD_DURATION_THRESHOLD`, `MAX_GLOBAL_PENDING_LOADS`,
`MAX_LOADS_PER_TICK`, `MIN_DWELL`, `MIN_WARM`, `OBSERVE_ONLY`,
`QUEUE_AGE_THRESHOLD`, `SPECULATIVE_START_THRESHOLD`,
`SPECULATIVE_WIN_THRESHOLD`, `TTFT_MISS_THRESHOLD`,
`WARM_SATURATION_THRESHOLD`).

**Release defaults added when absent** (`deploy/gcp/prod/release-env-defaults`):
`EIGENINFERENCE_CACHE_ROUTING_{MODE,PERCENT,MAX_PLAN_QPS,TTL,MAX_HOLDERS,MAX_DISCOUNT_MS,MAX_COST_FRACTION}`,
the `EIGENINFERENCE_PROMPT_SIDECAR_*` set (`ENABLED`, `BINARY`, `SOCKET`,
`ARTIFACT_ROOT`, `ARTIFACT_BASE_URL`, timeouts, restart policy, resource
bounds), `EIGENINFERENCE_MEDIA_FETCH_ENABLED`, and
`EIGENINFERENCE_MODEL_SOLO_TPS_SEED`.

**Operator-owned, never changed by a deploy:** every
`EIGENINFERENCE_CACHE_ROUTING_*` value and `EIGENINFERENCE_CACHE_MASTER_KEY`
(the live file, not `release-env-defaults`, is authoritative; the digests in
steps 2–4 prove preservation). `deploy/environments/prod.env` is a sanitized
reference copy; editing it changes nothing on the host.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| No `/health` after 60 s | migration behind an RDS relation lock | `pg_stat_activity` → `pg_terminate_backend(<pid>)`; do not restart the container |
| Fleet drops to `self_signed`; "device not found in MDM" storm | container started without `-v /mnt/disks/userdata:/mnt/disks/userdata` (blank MicroMDM) | Rollback, then redo the swap with the mount |
| `/v1/models` empty; providers `self_signed` | MicroMDM not running or `MICROMDM_API_KEY` ≠ `EIGENINFERENCE_MDM_API_KEY` | fix the env file, recreate the container |
| Port conflict / crash loop | a second host-network container is running | `docker ps`; stop the old one first |
| `refresh-env: … is tmpfs` | `/etc/d-inference` mounted as tmpfs | migrate the directory to the boot disk (copy to `/var/lib/darkbloom-env`, `umount`, recreate `0700`, copy back), then re-run |
| `refresh-env: missing required key` | a `required-env-keys.txt` key is absent on this host | add the value by hand (secrets are never fetched by the script), re-run `--check` |
| New flag "not working" | value read once at start; or a kill switch left from an incident (`EIGENINFERENCE_HEALTH_EJECTION=off`, `EIGENINFERENCE_QUEUE_BEFORE_SHED=false`) | `grep` the env file; recreate the container |
| Release registration `503 not_configured` | `EIGENINFERENCE_R2_CDN_URL` unset | set it, recreate the container |
| A manual SQL edit to `users` (role, platform fee, Stripe fields) or the model-registry tables "did not apply" | those lookups are served from an in-process read-through cache (`store.NewCached`: users 30 s, model records 10 s, misses 5 s); only writes made through the coordinator invalidate at once | wait out the TTL, or make the change through the admin API (`PUT /v1/admin/users/role`, `POST /v1/admin/models/...`) |

## Related

- [dev-environment.md](dev-environment.md) — the dev coordinator (`sepolia-ai`), which auto-deploys from Cloud Build.
- [`provider-release.md`](provider-release.md) — provider CLI release runbook.
- [`../developer/build.md`](../developer/build.md) — what the Dockerfile builds.
- [`../reference/configuration.md`](../reference/configuration.md) — every environment variable.
- [`../architecture/cache-aware-routing.md`](../architecture/cache-aware-routing.md) — what the cache-routing controls do.
- [`../reports/2026-07-17-eigencloud-to-gcp-migration.md`](../reports/2026-07-17-eigencloud-to-gcp-migration.md) — why prod is on GCE (historical).
