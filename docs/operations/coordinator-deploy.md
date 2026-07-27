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
| Confidential compute | GCP reports AMD **SEV** with maintenance policy `MIGRATE`; Shielded VM Secure Boot, vTPM, and integrity monitoring are enabled. Do not claim SEV-SNP for this VM. |
| Access | IAP SSH only: `gcloud compute ssh darkbloom-coordinator --project darkbloom-mainnet --zone us-east4-a --tunnel-through-iap` |
| Domain | `api.darkbloom.dev` (host Caddy systemd service terminates TLS using the pre-provisioned static certificate, then proxies to `:8080`) |
| Coordinator | Docker container `coordinator`, **host network**, `--restart unless-stopped`, entrypoint [`coordinator/deploy/start.sh`](../../coordinator/deploy/start.sh) |
| MicroMDM | Port 9002, same container, **state on the persistent disk** (see below) |
| Database | AWS RDS PostgreSQL (external, `EIGENINFERENCE_DATABASE_URL`) |
| Persistent storage | Host disk `/mnt/disks/userdata`, bind-mounted into the container. Holds the MicroMDM BoltDB (`micromdm/`), prompt artifacts, and logs. `start.sh` symlinks `/data -> /mnt/disks/userdata`. Any old `step-ca/` tree is retired migration residue; no step-ca process is running and it must not be restored as an active dependency. |
| Images | Cloud Build trigger builds on every master push → `us-east4-docker.pkg.dev/darkbloom-mainnet/coordinator/coordinator:<SHORT_SHA>` |
| Env file | `/etc/d-inference/env` on the VM (root-only). It must live on the boot disk, not tmpfs. [`deploy/gcp/prod/refresh-env.sh`](../../deploy/gcp/prod/refresh-env.sh) preserves custom values, exact-migrates only explicitly retired defaults, fails if the observed live tuning set is incomplete, and adds absent release defaults. |
| Fallback | The previous container is kept stopped for forensics. Restart it only when its immutable image digest is on the reviewed marker-safe allowlist; pre-`backfill_withdrawable_balance_v1` images are never rollback targets. |

The live host still has stale Caddy `/acme/*` routing and lacks
`stream_close_delay 5m`. Those are separate Caddy-maintenance changes. Do not
reload Caddy during a coordinator swap because that reconnects the
provider fleet; the static certificate and loaded config remain in place.

## v0.7.13 release order

Shipping code and activating optimizations are separate operations:

1. Confirm the deployed coordinator already exposes
   `providers.unreported_loaded_models`, `lifecycle.donation_outcomes`, and
   `lifecycle.holder_removed` in `/v1/cache/status`. Do not redeploy it solely
   for this provider release. The new fields are optional observability;
   v0.7.12 providers omit them and remain routable.
2. Publish the signed/notarized v0.7.13 provider. A pre-v0.7.13 coordinator
   ignores the additive telemetry, but coordinator-first preserves each
   provider's initial registration snapshot.
3. Wait for enough routable v0.7.13 providers per public model. Require
   `/v1/cache/status` to move loaded models from `unreported_loaded_models` into
   bounded state/reason/backend/replay-strategy aggregates without registration
   churn.
4. Verify donation outcome counters and holder removal reasons remain monotonic,
   identity-free, and consistent with SSD lookup/donation lifecycle totals.
5. Exercise chat completions, completions, Responses, and Anthropic Messages,
   including auto/none/required/named tools, stop sequences, body limits, and
   mixed-version fallback.
6. Provider publication must not change any operator-selected cache control:
   routing mode, activation percentage, plan-QPS cap, holder TTL, maximum
   holders, maximum discount, maximum cost fraction, or master key. Use the
   complete root-only before/after environment digest in the deploy procedure,
   not a partial visible-field comparison.
7. MTP remains default-off and is a separate rollout.

The GitHub `benchmarks` environment approval is a human release gate. Do not
bypass or weaken it.

## Exact-cache ongoing rollout

The first production activation exposed a cold-load/restart loop; PR #565
repaired that path and production now carries an operator-selected staged
activation. An `on` status by itself is still not a promotion gate. Provider
releases and unrelated coordinator swaps must preserve the existing mode,
percentage, QPS cap, TTL, holder limits, discounts, cost fraction, and master
key exactly.

Before changing any cache-routing control, require all of the following:

1. Every active prompt artifact is ready and the sidecar has sequentially
   preloaded the complete active contract set. A contract that appears after
   startup remains cold-only until that explicit preload succeeds.
2. The production prompt-parity gate covers all four manifest snapshots and
   every supported endpoint. The sidecar load gate sustains 25 requests/second
   (above the 2026-07-22 six-hour observed peak of 22.1 requests/second), with
   cold-start concurrency, zero child restarts, and bounded RSS.
3. Mixed v1/v2 tests prove legacy providers remain cold candidates, and the
   real v2 integration test proves miss -> durable donation -> hit.
4. `/v1/cache/status` shows `preload.ready=true`, matching stable child/preload
   generations, zero restarts, no preload failures, no planning timeout/overload
   loop, and a stable RSS plateau below the configured memory limit. The
   recorded child generation and restart reason must make any later restart
   attributable. Under `providers`, require
   `loaded_models == reported_loaded_models`,
   `unreported_loaded_models == 0`, and inspect `by_reason` before treating
   protocol-v1 capacity as a rollout-version problem.

Interpret provider eligibility in this order:

1. `scan_pending` is transient after load; sustained growth means scans are not
   reaching readiness.
2. `config_disabled`, `weight_hash_unavailable`,
   `runtime_identity_unavailable`, `unsupported_layout`,
   `unsupported_backend`, and `paged_hybrid_unsupported` are deterministic
   exclusions. A binary-version upgrade alone does not make them ready.
   Note on `paged_hybrid_unsupported`: providers ≥ 0.8.0 can no longer
   produce it (the engine enum case was deleted), but **v0.7.x providers
   still send it** — it stays in the coordinator's accepted vocabulary and
   its count trends to zero as the fleet upgrades. Do not read a shrinking
   count as a fix, and do not remove the value while any pre-0.8.0 provider
   remains.
3. `scan_failed`, `disk_unavailable`, and `cache_init_failed` require provider
   disk/key/cache initialization investigation.
4. Donation outcomes explain durable-ready absence: policy/shape outcomes
   (`below_effective_token_floor`, `no_complete_block`, `lossy_snapshot`,
   `incomplete_layer_state`, `stage_size_exceeded`) differ from pressure/failure
   outcomes (`write_rate_limited`, `write_queue_full`, `cache_closed`,
   `disk_unavailable`, `write_failed`). `already_durable` is successful dedupe,
   and `already_queued` means an earlier write for the same blocks is still in
   flight; neither is a failed donation.
5. Holder removals are expected under `ttl`, `disconnect`, `epoch_change`,
   `capability_change`, `miss_invalidation`, and `capacity_eviction`; compare
   their deltas before diagnosing unexplained holder loss.

For every promotion, require both a 30-minute clean window and at least 100
successful plans before raising another control. A clean window has zero
restarts, bounded RSS, no health failure streak, a negligible planner-failure
rate, and positive SSD miss/donation/hit plus cached-token and
estimated-TTFT-saved evidence. Raise only one control per observation window.
Any restart loop, sustained timeout/overload growth, preload failure, or memory
growth rolls back immediately to the previously captured operator state.

### Exact-cache promotion gate

Every control change is a separate, human-reviewed container swap. Editing
`/etc/d-inference/env` and restarting the existing container is insufficient:
Docker does not reread an `--env-file` on restart. Before a swap, record every
cache control through the root-only hash procedure in step 2, change only the
approved control, and verify the visible activation controls together:

```bash
sudo grep -E '^EIGENINFERENCE_CACHE_ROUTING_(MODE|PERCENT|MAX_PLAN_QPS)=' \
  /etc/d-inference/env
```

After the activated container is ready, capture a protected baseline. Capture
the same files again only after at least 30 minutes of representative traffic.
The admin key is read without printing it and is unset immediately after use.

```bash
umask 077
EXACT_CACHE_GATE_DIR="$(mktemp -d /tmp/exact-cache-gate.XXXXXX)"
EXACT_CACHE_ADMIN_KEY="$(sudo sed -n 's/^EIGENINFERENCE_ADMIN_KEY=//p' /etc/d-inference/env)"
curl -fsS localhost:8080/v1/cache/status \
  >"$EXACT_CACHE_GATE_DIR/start-status.json"
EXPECTED_CACHE_MODE="$(jq -r '.routing_mode' "$EXACT_CACHE_GATE_DIR/start-status.json")"
EXPECTED_CACHE_PERCENT="$(jq -r '.activation.percent' "$EXACT_CACHE_GATE_DIR/start-status.json")"
EXPECTED_CACHE_MAX_PLAN_QPS="$(jq -r '.activation.max_plan_qps' "$EXACT_CACHE_GATE_DIR/start-status.json")"
curl -fsS -H "Authorization: Bearer $EXACT_CACHE_ADMIN_KEY" \
  localhost:8080/v1/admin/metrics \
  >"$EXACT_CACHE_GATE_DIR/start-metrics.json"
unset EXACT_CACHE_ADMIN_KEY

# Hold this stage for >=30 minutes under representative traffic, then capture:
EXACT_CACHE_ADMIN_KEY="$(sudo sed -n 's/^EIGENINFERENCE_ADMIN_KEY=//p' /etc/d-inference/env)"
curl -fsS localhost:8080/v1/cache/status \
  >"$EXACT_CACHE_GATE_DIR/end-status.json"
curl -fsS -H "Authorization: Bearer $EXACT_CACHE_ADMIN_KEY" \
  localhost:8080/v1/admin/metrics \
  >"$EXACT_CACHE_GATE_DIR/end-metrics.json"
unset EXACT_CACHE_ADMIN_KEY
```

This executable delta gate requires at least 100 successful plans, no new
restart/timeout/overload/preload-failure signal, bounded memory, and a complete
positive miss -> donation -> hit lifecycle with measurable cached-token and
TTFT benefit. The known dynamic-time contract is reported separately as
`cold_only`; it must never increment either real failure counter. The gate
intentionally fails closed when any required metric is absent.

```bash
jq -e -n \
  --arg expected_mode "$EXPECTED_CACHE_MODE" \
  --argjson expected_percent "$EXPECTED_CACHE_PERCENT" \
  --argjson expected_max_plan_qps "$EXPECTED_CACHE_MAX_PLAN_QPS" \
  --slurpfile ss "$EXACT_CACHE_GATE_DIR/start-status.json" \
  --slurpfile es "$EXACT_CACHE_GATE_DIR/end-status.json" \
  --slurpfile sm "$EXACT_CACHE_GATE_DIR/start-metrics.json" \
  --slurpfile em "$EXACT_CACHE_GATE_DIR/end-metrics.json" '
  ($ss[0]) as $s | ($es[0]) as $e |
  ($sm[0]) as $ms | ($em[0]) as $me |
  $e.routing_mode == $expected_mode and
  $e.activation.percent == $expected_percent and
  $e.activation.max_plan_qps == $expected_max_plan_qps and
  $e.sidecar.ready == true and $e.preload.ready == true and
  $e.preload.child_generation == $e.sidecar.child_generation and
  $e.preload.child_generation == $s.preload.child_generation and
  ($e.activation.planned - $s.activation.planned) >= 100 and
  ($e.activation.cold_only - $s.activation.cold_only) >= 0 and
  ($e.sidecar.planner.plans.cold_only - $s.sidecar.planner.plans.cold_only) >= 0 and
  ($e.activation.plan_failed - $s.activation.plan_failed) == 0 and
  ($e.sidecar.restarts - $s.sidecar.restarts) == 0 and
  $e.sidecar.restart_suppressed == false and
  $e.sidecar.consecutive_health_failures == 0 and
  ($e.sidecar.timeouts - $s.sidecar.timeouts) == 0 and
  ($e.sidecar.health_timeouts - $s.sidecar.health_timeouts) == 0 and
  ($e.sidecar.preload_timeouts - $s.sidecar.preload_timeouts) == 0 and
  ($e.sidecar.overloads - $s.sidecar.overloads) == 0 and
  ($e.preload.failures - $s.preload.failures) == 0 and
  ($e.sidecar.planner.plans.failed - $s.sidecar.planner.plans.failed) == 0 and
  ($e.sidecar.planner.plans.at_capacity - $s.sidecar.planner.plans.at_capacity) == 0 and
  ($e.sidecar.planner.plans.not_ready - $s.sidecar.planner.plans.not_ready) == 0 and
  ($e.sidecar.planner.plans.timed_out - $s.sidecar.planner.plans.timed_out) == 0 and
  $e.sidecar.rss_bytes > 0 and $e.sidecar.rss_bytes <= 1073741824 and
  ($e.sidecar.rss_bytes - $s.sidecar.rss_bytes) <= 134217728 and
  ($e.lifecycle.ssd_lookups - $s.lifecycle.ssd_lookups) > 0 and
  ($e.lifecycle.ssd_misses - $s.lifecycle.ssd_misses) > 0 and
  ($e.lifecycle.ssd_donations - $s.lifecycle.ssd_donations) > 0 and
  ($e.lifecycle.ssd_hits - $s.lifecycle.ssd_hits) > 0 and
  (($e.lifecycle.donation_outcomes.donated // 0) -
   ($s.lifecycle.donation_outcomes.donated // 0)) > 0 and
  (($me.counters["exact_cache_cached_tokens_total{tier=ssd}"] // 0) -
   ($ms.counters["exact_cache_cached_tokens_total{tier=ssd}"] // 0)) > 0 and
  (($me.counters["exact_cache_prefill_tokens_saved_total{tier=ssd}"] // 0) -
   ($ms.counters["exact_cache_prefill_tokens_saved_total{tier=ssd}"] // 0)) > 0 and
  (($me.histograms["exact_cache_estimated_ttft_saved_ms{tier=ssd}"].count // 0) -
   ($ms.histograms["exact_cache_estimated_ttft_saved_ms{tier=ssd}"].count // 0)) > 0
'
```

For every later stage, change only one of percentage or QPS, recreate the
container from the same reviewed digest, take fresh start/end snapshots, and
apply the same 30-minute/100-plan delta gate with the new expected cap. Preserve
the current production stage unless a separately approved promotion changes one
control; never reset to historical 1%/1-QPS defaults. Never raise planning above
the proven 25 requests/second. On a cache-related gate failure, recreate the
last known-good container and env snapshot (or set `MODE=off` when no staged
cache state is trustworthy) before investigating or changing code.

## Steps — coordinator deploy (prod)

### 1. Confirm the image is built

Cloud Build builds every master push automatically. Before trusting that image,
require the production trigger to use the checked-in provenance-aware build
configuration. Empty output here means the trigger is still using its legacy
inline Docker step ([#554](https://github.com/Layr-Labs/d-inference/issues/554))
and blocks the coordinator deploy:

```bash
gcloud builds triggers describe prod-build \
  --project=darkbloom-mainnet \
  --format='value(filename)' | grep -Fx 'deploy/gcp/cloudbuild-prod.yaml'
```

Then confirm your commit's image exists:

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

The historical withdrawable-balance backfill is no longer part of the repeatable
startup statement list. Migration `backfill_withdrawable_balance_v1` uses a unique
`schema_migrations` claim in the same transaction as its schema/data changes. On an
existing database that already has `balances.withdrawable_micro_usd`, it records the
marker without reading or rewriting `balances` or `ledger_entries`; this preserves
legitimate live zero balances. Only a legacy schema where the column is absent gets the
set-wise historical backfill. Concurrent starters serialize on the marker, and a
failure rolls back both the marker and all migration changes.
See
[`coordinator/store/postgres.go:1037-1041`](../../coordinator/store/postgres.go#L1037-L1041)
for the startup call,
[`coordinator/store/postgres_withdrawable_migration.go:175-244`](../../coordinator/store/postgres_withdrawable_migration.go#L175-L244)
for the transactional claim/schema boundary, and
[`coordinator/store/postgres_withdrawable_migration.go:15-108`](../../coordinator/store/postgres_withdrawable_migration.go#L15-L108)
for the legacy-only set-wise reconstruction.

Startup emits one privacy-safe `postgres migration completed` log with only the
migration name, result, and duration. Expected results are
`backfilled_legacy_schema` on a fresh or genuinely legacy schema,
`preserved_existing_schema` on the first upgraded startup of a database that already
has live split-balance accounting, and `already_applied` thereafter. A rollback to a
coordinator version before this migration reintroduces the old every-startup backfill
and is not financially safe; roll forward instead. A genuinely legacy schema with no
withdrawable column fails closed if its ledger contains generic refunds or account
migrations whose withdrawable provenance cannot be reconstructed exactly. The marker,
new column, and partial updates all roll back; reconcile that database offline rather
than bypassing the check.
The result/duration logging implementation is
[`coordinator/store/postgres_withdrawable_migration.go:123-140`](../../coordinator/store/postgres_withdrawable_migration.go#L123-L140);
the fail-closed ambiguity gate and transaction commit are
[`coordinator/store/postgres_withdrawable_migration.go:225-244`](../../coordinator/store/postgres_withdrawable_migration.go#L225-L244).

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
curl -s localhost:8080/v1/cache/status | jq -S \
  '{routing_mode, percent:.activation.percent, max_plan_qps:.activation.max_plan_qps}' \
  > /tmp/darkbloom-cache-controls.before.json
sudo sh -c 'umask 077
  awk -F= '\''$1 ~ /^EIGENINFERENCE_CACHE_ROUTING_/ ||
             $1 == "EIGENINFERENCE_CACHE_MASTER_KEY" { print }'\'' \
    /etc/d-inference/env |
    LC_ALL=C sort |
    sha256sum |
    awk '\''{ print $1 }'\'' \
    > /tmp/darkbloom-cache-env.pre-refresh.sha256'
```

### 3. Env changes (if any)

The current host was observed with `/etc/d-inference` mounted as tmpfs, so most
backups and the live file would disappear on reboot. A human must migrate it to
the boot disk once before using the refresh script:

```bash
# Human-only on the production VM. Preserve ownership and mode.
sudo install -d -m 0700 /var/lib/darkbloom-env
sudo cp -p /etc/d-inference/env /var/lib/darkbloom-env/env
sudo umount /etc/d-inference
sudo install -d -m 0700 /etc/d-inference
sudo cp -p /var/lib/darkbloom-env/env /etc/d-inference/env
findmnt -n -o FSTYPE --target /etc/d-inference   # must not print tmpfs

# Install the reviewed refresh inputs so reboot/restart uses repository logic.
sudo install -d -m 0755 /usr/local/lib/darkbloom-env
sudo install -m 0755 deploy/gcp/prod/refresh-env.sh \
  /usr/local/sbin/darkbloom-refresh-env
sudo install -m 0644 deploy/gcp/prod/required-env-keys.txt \
  /usr/local/lib/darkbloom-env/required-env-keys.txt
sudo install -m 0644 deploy/gcp/prod/release-env-defaults \
  /usr/local/lib/darkbloom-env/release-env-defaults
sudo install -m 0644 deploy/gcp/prod/darkbloom-env-refresh.service \
  /etc/systemd/system/darkbloom-env-refresh.service
sudo systemctl daemon-reload
sudo systemctl enable darkbloom-env-refresh.service

sudo REQUIRED_FILE=/usr/local/lib/darkbloom-env/required-env-keys.txt \
  DEFAULTS_FILE=/usr/local/lib/darkbloom-env/release-env-defaults \
  /usr/local/sbin/darkbloom-refresh-env --check
sudo REQUIRED_FILE=/usr/local/lib/darkbloom-env/required-env-keys.txt \
  DEFAULTS_FILE=/usr/local/lib/darkbloom-env/release-env-defaults \
  /usr/local/sbin/darkbloom-refresh-env --apply

# Verify every non-secret rollout control. Custom production values are
# authoritative; do not proceed if the refresh changed an approved value.
sudo grep -E '^EIGENINFERENCE_(CACHE_ROUTING_MODE|CACHE_ROUTING_PERCENT|CACHE_ROUTING_MAX_PLAN_QPS|PROMPT_SIDECAR_ENABLED)=' \
  /etc/d-inference/env
# Snapshot every cache-routing value after refresh and immediately before the
# swap. This provider release permits no cache-control edit, so require equality
# with the pre-refresh digest. Only digests are emitted; the key is never printed.
sudo sh -c 'umask 077
  awk -F= '\''$1 ~ /^EIGENINFERENCE_CACHE_ROUTING_/ ||
             $1 == "EIGENINFERENCE_CACHE_MASTER_KEY" { print }'\'' \
    /etc/d-inference/env |
    LC_ALL=C sort |
    sha256sum |
    awk '\''{ print $1 }'\'' \
    > /tmp/darkbloom-cache-env.pre-swap.sha256'
sudo cmp /tmp/darkbloom-cache-env.pre-refresh.sha256 \
  /tmp/darkbloom-cache-env.pre-swap.sha256
```

The check prints only safe key names, never existing values. The apply step
writes a same-directory temporary file, verifies that no existing key would be
dropped, keeps a root-only timestamped backup, and atomically renames the new
file. It never fetches or rewrites secrets. The historical v0.7.12 bounded
migration changed the exact broken `/data/prompt-contracts` artifact root to
`/mnt/disks/userdata/prompt-contracts`; every custom value is preserved. The
installed oneshot validates and extends the persistent file before Docker starts
on every reboot; a missing required variable fails the unit instead of
constructing a truncated file.

New env vars take effect only on container start. The live env file—not release
defaults or historical rollout values—is authoritative for cache controls.

### 4. Swap

Rules learned the hard way:

- **One host-network container at a time.** Stop the old container *before* starting the
  new one. Two containers fighting over `:8080` caused the 2026-07-03 outage.
- **Preserve the 10-minute application drain.** Docker's default 10-second stop
  timeout would SIGKILL active requests; every stop and new container uses 630
  seconds.
- **The volume mount is mandatory.** Omitting `-v /mnt/disks/userdata:/mnt/disks/userdata`
  boots a **blank MicroMDM** — every device lookup returns "device not found", the fleet
  falls to `self_signed` trust, and with `MIN_TRUST=hardware` the network is effectively
  down (2026-07-04 incident: ~6 minutes of near-zero traffic).

```bash
FALLBACK=coordinator_fallback_$(date +%Y%m%d-%H%M%S)
sudo docker rename coordinator $FALLBACK
sudo docker stop -t 630 $FALLBACK
sudo docker run -d --name coordinator \
  --network host \
  --restart unless-stopped \
  --stop-timeout 630 \
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
# Require the deployed commit/version/date embedded by cloudbuild-prod.yaml.
curl -s localhost:8080/health | jq -e \
  '.version == "0.7.13" and
   (.build_commit | test("^[0-9a-f]{40}$")) and
   .build_date != "unknown"'
# Cache controls are operator state, not release defaults. Require byte-for-byte
# preservation across the swap.
diff -u /tmp/darkbloom-cache-controls.before.json \
  <(curl -s localhost:8080/v1/cache/status | jq -S \
    '{routing_mode, percent:.activation.percent, max_plan_qps:.activation.max_plan_qps}')
sudo sh -c 'umask 077
  awk -F= '\''$1 ~ /^EIGENINFERENCE_CACHE_ROUTING_/ ||
             $1 == "EIGENINFERENCE_CACHE_MASTER_KEY" { print }'\'' \
    /etc/d-inference/env |
    LC_ALL=C sort |
    sha256sum |
    awk '\''{ print $1 }'\'' \
    > /tmp/darkbloom-cache-env.after.sha256'
sudo cmp /tmp/darkbloom-cache-env.pre-swap.sha256 \
  /tmp/darkbloom-cache-env.after.sha256
curl -s localhost:8080/v1/cache/status | jq -e \
  '.sidecar.enabled == true and
   .sidecar.ready == true and
   .sidecar.restarts == 0 and
   .sidecar.restart_suppressed == false and
   .sidecar.consecutive_health_failures == 0 and
   .sidecar.timeouts == 0 and
   .sidecar.health_timeouts == 0 and
   .sidecar.preload_timeouts == 0 and
   .sidecar.overloads == 0 and
   .sidecar.rss_bytes > 0 and
   .sidecar.rss_bytes <= 1073741824 and
   .preload.ready == true and
   .preload.failures == 0 and
   .preload.contract_count > 0 and
   .preload.child_generation > 0 and
   .preload.child_generation == .sidecar.child_generation and
   .sidecar.planner.plans.failed == 0 and
   .sidecar.planner.plans.at_capacity == 0 and
   .sidecar.planner.plans.not_ready == 0 and
   .sidecar.planner.plans.timed_out == 0 and
   .prompt_artifacts.ready > 0 and
   .prompt_artifacts.pending == 0 and
   .prompt_artifacts.failed == 0'

# Trust rebuild: hardware upgrades should dominate within ~2 minutes.
sudo docker logs coordinator 2>&1 | grep -c "upgraded to hardware trust"
# "device not found in MDM" should stay at the baseline (a few dozen genuinely
# unenrolled boxes). HUNDREDS of these = the volume mount is missing; go to Rollback.
sudo docker logs coordinator 2>&1 | grep -c "device not found in MDM"

# Startup config lines — confirm flags picked up
sudo docker logs coordinator 2>&1 | grep -E "quality-concurrency|servability|warm-pool|dedicated|cache routing"

# Public check (from anywhere)
curl -s https://api.darkbloom.dev/health
curl -s https://api.darkbloom.dev/v1/cache/status
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

Never restart a fallback coordinator that predates
`backfill_withdrawable_balance_v1`. Older binaries ignore the marker and run the
historical withdrawable-balance reconstruction on every startup, which can recreate
withdrawn funds. For the rollout that introduces this migration, recovery is
**roll-forward only**: fix the startup problem and restart the target image, or build a
patched image from the previous application commit with the marker-safe migration
included.
The marker ID is defined at
[`coordinator/store/postgres_withdrawable_migration.go:13`](../../coordinator/store/postgres_withdrawable_migration.go#L13),
and the marker-preserving existing-schema path is
[`coordinator/store/postgres_withdrawable_migration.go:182-217`](../../coordinator/store/postgres_withdrawable_migration.go#L182-L217).

```bash
# Use an immutable digest from the release's reviewed marker-safe allowlist.
# A mutable tag, stopped container name, or source-file presence is not proof.
FALLBACK_IMAGE=us-east4-docker.pkg.dev/darkbloom-mainnet/coordinator/coordinator@sha256:<reviewed-digest>
sudo docker stop -t 630 coordinator && sudo docker rm coordinator
sudo cp /etc/d-inference/env.bak.<timestamp> /etc/d-inference/env
sudo docker run -d --name coordinator \
  --network host \
  --restart unless-stopped \
  --stop-timeout 630 \
  -v /mnt/disks/userdata:/mnt/disks/userdata \
  --env-file /etc/d-inference/env \
  "$FALLBACK_IMAGE"
```

Providers reconnect automatically after a marker-safe recovery (the live registry is
in-process and rebuilt on reconnect; durable state is in RDS and on the persistent
disk).

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
| `vX.Y.Z-swift` or `vX.Y.Z-swift.N` | Accepted aliases during migration |

Dev publication uses `workflow_dispatch` with `environment=dev`; the requested
version must equal both checked-in source constants.

The fallback version advertised when no release is registered is `LatestProviderVersion` in
[`coordinator/api/server.go`](../../coordinator/api/server.go). Keep it in sync with
`ProviderCore.version`. `GET /v1/releases/latest` returns **404 when no release row
exists** — fixed by registering the release, not by bumping code.

Before a tag exists, run:

```bash
./scripts/check-release-version.sh 0.7.13
./scripts/sync-install-embed.sh check
```

The release workflow repeats the check against the requested tag, built CLI,
final archived CLI, and app plist. It does not mutate source to manufacture
agreement.

```bash
git tag -a v0.7.13 -m "Release v0.7.13"
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
| `EIGENINFERENCE_MODEL_SOLO_TPS_SEED` | Cold-start solo rates, `build-id[@Family\|Tier]=tok/s` CSV (e.g. `gemma-4-26b-qat-4bit=14,gemma-4-26b-qat-4bit@M4\|Max=70`); the in-memory TPS registry is restart-wiped. **Ships in `release-env-defaults` and is listed in `required-env-keys.txt`**, so `refresh-env.sh` installs it and then refuses an env where it is missing or blank — `deploy/environments/prod.env` is a sanitized reference and editing it changes nothing. A provider takes its own chip class's entry when one exists, else the unqualified entry, which is clamped to the slowest class named for that model — so a seed measured on one class can never over-admit a slower or unrecognized one. Seeding also re-enables cross-class solo-median transfer for a model: without a seed the coordinator refuses to transfer a median from chip classes that cannot bound it |
| `EIGENINFERENCE_WARM_POOL_*` | Warm-pool controller (active; `OBSERVE_ONLY=false`) |
| `EIGENINFERENCE_DEDICATED_MODELS` | Static dedicated-box partition (`gemma-4`) |
| `EIGENINFERENCE_PROMPT_SIDECAR_*` | Sidecar lifecycle, independent health/planning deadlines, failure threshold, diagnostics, preload, and resource bounds. Keep it enabled at the physical artifact root; provider releases must not alter its operator-selected values. |
| `EIGENINFERENCE_CACHE_ROUTING_MODE` | Strict product switch: `off` or `on`. The live env value is authoritative and must survive unrelated deploys unchanged. |
| `EIGENINFERENCE_CACHE_ROUTING_PERCENT`, `_MAX_PLAN_QPS` | Independent staged-rollout caps inside `on`. Preserve the current approved production stage; defaults apply only when bootstrapping a fresh environment. |
| `EIGENINFERENCE_CACHE_MASTER_KEY` | Independent random 256-bit key required whenever routing is `on`. Preserve it byte-for-byte across releases; never derive from or reuse `MNEMONIC`, API, release, or database keys. |
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
