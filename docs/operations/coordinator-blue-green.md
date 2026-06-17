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

Run on the box. `deploy.sh`:

1. **Detect** the active color from the Caddyfile upstream port.
2. **Pin** the new image for the idle color (`--image`, optional → `DINF_IMAGE`
   in `/etc/d-inference/deploy.env`, read by `darkbloom-run.sh`).
3. **Start** the idle color: `systemctl start darkbloom-coordinator@<idle>`.
4. **Wait** for the idle color's `/health` **and** `/readyz` to return 200
   (Phase 1 endpoints).
5. **Cut over**: `flip_upstream` the Caddy port old→new + graceful `caddy reload`.
6. **Drain** the old color: `POST /v1/admin/drain` (Phase 1), then poll its
   `/readyz` until `inflight == 0` (or timeout).
7. **Stop** the old color: `systemctl stop darkbloom-coordinator@<old>`.

Stopping the old color triggers the coordinator's `going_away` provider broadcast
(**DAR-327 Phase 3**, separate PR) so providers reconnect to the new color
instantly instead of waiting for a heartbeat timeout. `deploy.sh` only performs
the graceful stop; the broadcast ships in Phase 3.

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
reloads. If the old color was already stopped, start it again first
(`systemctl start darkbloom-coordinator@<old>`), then `--rollback`. `deploy.sh`
also auto-rolls-back the flip if `caddy reload` fails mid-cutover.

## Cross-phase contracts

`deploy.sh` consumes endpoints/behaviors delivered by sibling PRs:

- **Phase 1** — `GET /readyz` (exposes an `inflight` counter, e.g.
  `{"inflight":0}`) and `POST /v1/admin/drain` (admin-authenticated). Until
  Phase 1 lands, steps 4 and 6 will not see these endpoints.
- **Phase 3** — graceful coordinator stop broadcasts `going_away` to providers.

## One-time install on the box

```bash
# Wrapper + units (committed, secret-free):
sudo install -m 0755 deploy/gcp/prod/darkbloom-run.sh /usr/local/bin/darkbloom-run.sh
sudo install -m 0644 deploy/gcp/prod/darkbloom-platform.service     /etc/systemd/system/darkbloom-platform.service
sudo install -m 0644 deploy/gcp/prod/darkbloom-coordinator@.service /etc/systemd/system/darkbloom-coordinator@.service

# Host Caddy config (single swap point + loopback webhook listener):
sudo install -m 0644 deploy/gcp/prod/Caddyfile /etc/caddy/Caddyfile

sudo systemctl daemon-reload
sudo systemctl enable --now darkbloom-platform.service
sudo systemctl enable --now darkbloom-coordinator@blue   # initial active color
sudo systemctl reload caddy
```

Secrets are unchanged: GCP Secret Manager → tmpfs `/etc/d-inference/env`
(written by `deploy/gcp/refresh-env.sh`) → `--env-file` inside
`darkbloom-run.sh`. Nothing secret is committed; registry auth uses the VM
service-account token from the metadata server. `/etc/d-inference/deploy.env`
holds only the non-secret `DINF_IMAGE` pin.

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
