# Coordinator blue-green deploys (DAR-327 Phase 2)

True zero-downtime coordinator deploys on the GCE box: run two coordinator
"colors" (blue / green) side by side, cut traffic over at the host Caddy, then
drain and retire the old color. This replaces the in-place
`systemctl restart d-inference-coordinator` (which drops every in-flight request
and every provider WebSocket for the duration of the restart).

> Scope: this document describes the **GCP-hosted** coordinator. EigenCloud prod
> does its own blue-green at the platform layer and keeps using the combined
> `coordinator/deploy/start.sh` entrypoint, which is intentionally unchanged.

## The split: platform vs coordinator

The single container entrypoint is split into two roles (same image, different
command):

| Role | Entrypoint | systemd unit | Lifetime | Owns |
|------|-----------|--------------|----------|------|
| **platform** | `start-platform.sh` | `darkbloom-platform.service` | long-lived, survives deploys | `/mnt/disks/userdata` + `/data` symlink, step-ca (`:9000`) incl. first-boot init, MicroMDM (`:9002`) |
| **coordinator** | `start-coordinator.sh` | `darkbloom-coordinator@<color>.service` | swappable per deploy | just the coordinator process, on `EIGENINFERENCE_PORT` (blue=8080, green=8081) |

Why split: step-ca holds the CA state and MicroMDM holds BoltDB + provider-trust
state. Those must NOT be restarted on every coordinator deploy (a CA/MDM bounce
disrupts ACME and device attestation). Keeping them in a separate long-lived
unit lets the coordinator swap freely underneath them.

Both colors bind-mount the same `/mnt/disks/userdata` and each re-creates its own
`/data` symlink, so they share step-ca certs and all persistent state. The
coordinator reads the step-ca root at `EIGENINFERENCE_STEP_CA_ROOT`
(`/data/step-ca/certs/root_ca.crt`); `start-coordinator.sh` waits (bounded) for
that file so a cold box doesn't crash-loop before the platform finishes init.

`coordinator/deploy/start.sh` (the combined EigenCloud entrypoint) is left
unchanged. `start-platform.sh` is a faithful factoring of its step-ca + MicroMDM
sections; keep them diff-able so they stay in sync.

```
                          ┌────────────────────────── GCE box ──────────────────────────┐
   api.darkbloom.dev ───► │  Caddy (:443/:80)  ── (coordinator_routes) snippet           │
                          │     │                    └─ reverse_proxy 127.0.0.1:<active>  │  ← single swap point
                          │     │                                                         │
                          │     ├─► darkbloom-coordinator@blue   :8080  (active OR idle)  │
                          │     ├─► darkbloom-coordinator@green  :8081  (idle OR active)  │
                          │     │                                                         │
                          │     ├─ /acme/* ─► step-ca  :9000  ┐                           │
                          │     └─ /scep,/mdm/* ─► MicroMDM :9002 ├─ darkbloom-platform   │
   MicroMDM webhook ──────┼─► http://127.0.0.1:8090 (loopback)  ┘  (long-lived)          │
     (loopback only)      │        └ imports the SAME snippet ⇒ follows the active color  │
                          └──────────────────────────────────────────────────────────────┘
```

## The single swap point

`deploy/gcp/prod/Caddyfile` defines all coordinator routing once, in the
`(coordinator_routes)` snippet, imported by `api.darkbloom.dev`,
`coord-staging.darkbloom.dev`, and the internal `http://127.0.0.1:8090` listener.
The snippet contains exactly **one** coordinator upstream line:

```
reverse_proxy 127.0.0.1:8080 { health_uri /health; ... }
```

Flipping that one line `8080 ↔ 8081` and reloading Caddy atomically moves **all**
traffic — both public sites and the internal MDM-webhook listener — to the new
color. Do not add a second `reverse_proxy 127.0.0.1:<port>` line; that breaks the
invariant `deploy.sh` / `flip_upstream` rely on. (The step-ca `:9000` and
MicroMDM `:9002` upstreams use the `https://` scheme and different ports, so the
port flip never touches them.)

## MDM webhook coupling fix

The combined `start.sh` hardcodes MicroMDM's command-webhook URL to
`http://localhost:8080/v1/mdm/webhook` — correct only when the coordinator shares
the container on `:8080`. In the split the active coordinator may be on `:8080`
**or** `:8081`, and MicroMDM lives in the platform, so it can't be hardcoded to
either color.

Fix: `start-platform.sh` reads the webhook base URL from
`EIGENINFERENCE_MDM_WEBHOOK_URL` (default keeps legacy `localhost:8080`). The
platform unit sets it to the stable loopback Caddy listener:

```
EIGENINFERENCE_MDM_WEBHOOK_URL=http://127.0.0.1:8090/v1/mdm/webhook
```

That listener binds to `127.0.0.1` only (no firewall change, never publicly
reachable) and imports the same `(coordinator_routes)` snippet, so the webhook
falls through to the one swap-target upstream and is rerouted to the active color
by the exact same single-line flip — no extra swap point, no per-deploy MicroMDM
restart. The shared `?token=` secret is still appended by `start-platform.sh`
from `EIGENINFERENCE_MDM_WEBHOOK_SECRET` (never stored in the Caddyfile).

## Deploy sequence (`deploy.sh`)

Run on the box. `deploy.sh` moves providers to the new color **before** draining
and stopping the old one, so the new color never serves consumers with zero
providers (which would 429):

1. **Detect** the active color from the Caddyfile upstream port.
2. **Pin** the new image for the idle color (`--image`, optional → `DINF_IMAGE`
   in `/etc/d-inference/deploy.env`, read by `darkbloom-run.sh`). The pin is
   snapshotted and rolled back if the deploy aborts before cutover; it is kept
   once the cutover is accepted (so an aborted deploy never leaves the shared pin
   file pointing at an unaccepted image).
3. **Restart** the idle color: `systemctl restart darkbloom-coordinator@<idle>`
   (**restart, not start** — a stale already-running idle container must re-exec
   `darkbloom-run.sh` to pick up the newly pinned `DINF_IMAGE`).
4. **Wait** for the idle color's `/health` **and** `/readyz` to return 200
   (Phase 1 endpoints).
5. **Cut over**: `flip_upstream` the Caddy port old→new + graceful `caddy reload`.
6. **Going-away**: `POST /v1/admin/going-away` to the **old** color
   (**DAR-327 Phase 3**, PR #396; admin-gated, returns `{"sent":N}`) so its
   providers reconnect and — Caddy already flipped — land on the **new** color.
7. **Wait for providers**: poll the new color's `/health` until its `providers`
   count is `> 0` (the reconnects landed). Warns (does not abort) on timeout.
8. **Drain** the old color: `POST /v1/admin/drain` (Phase 1), then poll its
   `/readyz` until `inflight == 0`. If it does **not** drain in time the old
   color is **not** stopped (that would cut in-flight requests) — `deploy.sh`
   exits nonzero with the cutover already done; re-run with `--force` to stop
   despite in-flight requests.
9. **Stop** the old color: `systemctl stop darkbloom-coordinator@<old>`
   (`deploy.sh` fails if the stop returns nonzero, so a still-attached old color
   never lingers silently).

The going-away POST in step 6 is what hands providers to the new color; steps 8–9
then retire the old color with no capacity gap. (`going_away` is also broadcast
when a coordinator is stopped, but step 6 triggers it explicitly and early so the
reconnects happen *before* the drain rather than after the old color is gone.)

```bash
# Preview everything, change nothing:
./deploy.sh --dry-run --image <REGISTRY>/coordinator:<sha>

# Real deploy (interactive confirmations at each destructive step):
sudo ./deploy.sh --image <REGISTRY>/coordinator:<sha>

# Non-interactive (CI):
sudo ./deploy.sh -y --image <REGISTRY>/coordinator:<sha>
```

### Rollback

Valid any time **after** the cutover flip and **before** the old color is
stopped (the "rollback window" `deploy.sh` prints):

```bash
sudo ./deploy.sh --rollback
```

This flips the Caddy upstream back to the other (still-running) color and
reloads. Before flipping, `deploy.sh` health-checks the rollback target with a
single-shot `GET /health` liveness probe so it never cuts traffic over to a dead
port (which would surface as 502s). If the target is **not** healthy the rollback
is refused; start it again first (`systemctl start darkbloom-coordinator@<old>`),
then re-run `--rollback`.

To override the health gate and flip anyway (for example, you are certain the
probe is wrong), add `--force`:

```bash
sudo ./deploy.sh --rollback --force   # DANGEROUS: may route traffic to a dead port
```

`deploy.sh` also auto-rolls-back the flip if `caddy reload` fails mid-cutover.

## Cross-phase contracts

`deploy.sh` consumes endpoints/behaviors delivered by sibling PRs:

- **Phase 1** — `GET /readyz` (exposes an `inflight` counter, e.g.
  `{"inflight":0}`) and `POST /v1/admin/drain` (admin-authenticated). Until
  Phase 1 lands, steps 4 and 8 will not see these endpoints.
- **Phase 3** (PR #396) — `POST /v1/admin/going-away` (admin-authenticated;
  returns `200 {"sent":N}`) tells the old color's providers to reconnect so they
  re-land on the already-flipped new color. (`going_away` is also broadcast on a
  graceful coordinator stop.) Until Phase 3 lands, step 6 has no endpoint to call
  (it warns and continues; providers still reconnect within the heartbeat
  timeout).

## One-time install on the box

> **Prerequisite units.** `darkbloom-coordinator@.service` declares
> `Requires=docker.service cloud-sql-proxy.service`, so both must already be
> installed and startable on the box (the coordinator reaches Cloud SQL via the
> proxy on `127.0.0.1:5432` when `EIGENINFERENCE_DATABASE_URL` is set). Install
> `cloud-sql-proxy.service` the same way `deploy/gcp/vm-startup.sh` does before
> enabling a color, or the unit will refuse to start instead of crash-looping.

> **PROD ENV — required before starting any service.**
> `deploy/gcp/refresh-env.sh` (and `vm-startup.sh`) currently hardcode **DEV**
> values into `/etc/d-inference/env`: `DOMAIN=api.dev.darkbloom.xyz`,
> `EIGENINFERENCE_BASE_URL=https://api.dev.darkbloom.xyz`,
> `EIGENINFERENCE_CONSOLE_URL`/`CORS_ORIGIN=…console.dev.darkbloom.xyz`. The
> platform passes `DOMAIN` to MicroMDM's `-server-url` and step-ca's `--dns`
> (`start-platform.sh`), and the coordinator builds enrollment/callback URLs from
> `EIGENINFERENCE_BASE_URL`. Starting the **prod** box with dev values mis-issues
> the MDM server URL, ACME DNS name, and enrollment profiles. Before
> `enable --now` below you MUST either:
> - add a **prod** env generator (a prod variant of `refresh-env.sh`), or
> - override `DOMAIN`, `EIGENINFERENCE_BASE_URL`, `EIGENINFERENCE_CONSOLE_URL`,
>   and `CORS_ORIGIN` in `/etc/d-inference/env` to the prod hostnames (e.g.
>   `api.darkbloom.dev`).
>
> The `/dl/*` route added to `deploy/gcp/prod/Caddyfile` serves static bundles
> from `/var/www/html` (same as the combined `coordinator/Caddyfile`); ensure
> that directory exists on the box and holds the published provider bundle, or the
> release fallback URL `/dl/eigeninference-bundle-macos-arm64.tar.gz` 404s and
> `scripts/install.sh` breaks.

```bash
# Wrapper + units (committed, secret-free):
sudo install -m 0755 deploy/gcp/prod/darkbloom-run.sh /usr/local/bin/darkbloom-run.sh
sudo install -m 0644 deploy/gcp/prod/darkbloom-platform.service     /etc/systemd/system/darkbloom-platform.service
sudo install -m 0644 deploy/gcp/prod/darkbloom-coordinator@.service /etc/systemd/system/darkbloom-coordinator@.service

# Host Caddy config (single swap point + loopback webhook listener):
sudo install -m 0644 deploy/gcp/prod/Caddyfile /etc/caddy/Caddyfile

sudo systemctl daemon-reload

# MIGRATION (existing box only): the pre-split single unit d-inference-coordinator
# owns ports 8080 / 9000 / 9002. Disable it FIRST so the platform (9000/9002) and
# coordinator@blue (8080) can bind those ports and Caddy stops proxying the old
# process. Skip on a fresh box that never ran the combined unit.
sudo systemctl disable --now d-inference-coordinator.service || true

sudo systemctl enable --now darkbloom-platform.service
sudo systemctl enable --now darkbloom-coordinator@blue   # initial active color
sudo systemctl reload caddy
```

Secrets are unchanged: GCP Secret Manager → tmpfs `/etc/d-inference/env`
(written by `deploy/gcp/refresh-env.sh`) → `--env-file` inside
`darkbloom-run.sh`. Nothing secret is committed; registry auth uses the VM
service-account token from the metadata server. `/etc/d-inference/deploy.env`
holds only the non-secret `DINF_IMAGE` pin.

`deploy.sh` **parses** `EIGENINFERENCE_ADMIN_KEY` from `/etc/d-inference/env`
(path overridable via `DINF_ENV_FILE`) **only at cutover time**, to authenticate
the going-away and drain POSTs. It reads that single line with `grep`/`cut` and
**never `source`s/`. `s the file** — the file is docker `--env-file` syntax
(`KEY=VALUE`), not shell, so sourcing it would execute secret values (the 12-word
`MNEMONIC`, `&`/URL/`$()` characters) as shell commands **as root**. The key is
never printed or written, and is not read under `--dry-run`. If the key is missing
the going-away/drain steps warn and continue (the explicit going-away may be
rejected, but providers still reconnect within the heartbeat timeout; the graceful
container stop still finishes in-flight requests).

## Manual validation (human-only, on the GCP box)

Real blue-green validation requires the live box and is **not** run in CI or from
a worktree. The infra-free unit tests (`deploy/gcp/prod/deploy_test.sh`) only
cover the pure `flip_upstream` / `current_upstream_port` logic.

1. `systemctl status darkbloom-platform` — step-ca `:9000`, MicroMDM `:9002` up.
2. `./deploy.sh --dry-run --image <ref>` — confirm the detected active/idle
   colors and the printed plan.
3. Start a deploy; while both colors run, in another shell:
   - `curl -s 127.0.0.1:8080/health` and `curl -s 127.0.0.1:8081/health` → 200.
   - drive sustained traffic at `https://api.darkbloom.dev` and confirm zero
     errors across the cutover.
4. After the flip: `current_upstream_port /etc/caddy/Caddyfile` (sourced from
   `deploy.sh`) shows the new port; `caddy validate --config /etc/caddy/Caddyfile`.
5. Enroll/trigger an MDM SecurityInfo callback and confirm it reaches the
   **active** color (check coordinator logs for the webhook hit on the new port).
6. Test `--rollback` before stopping the old color; confirm traffic returns to
   the previous color with no errors.
 7. Verify providers reconnect promptly after the old color stops (instant once
    Phase 3 `going_away` lands; otherwise within the heartbeat timeout).
