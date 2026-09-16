# Install the Datadog Agent on the production coordinator

> Last updated: 2026-09-16 · commit `4595d7e65`

Runbook for provisioning the host Datadog Agent on the production VM
`darkbloom-coordinator` and then deploying the coordinator build that submits
every metric through it. The two halves are **ordered**: the coordinator has one
metric path — DogStatsD to `localhost:8125` — and no HTTPS fallback, so the
agent must be installed and *proven* to be receiving datagrams before the image
that removes the fallback lands. Every command here runs as root on the
production VM, so the whole runbook is **human-only**; agents prepare and review
the commands and read the resulting health output.

Why a host agent rather than direct submission, and what changed in the client,
is [`../architecture/telemetry.md`](../architecture/telemetry.md). The dashboard
and percentile aggregators are a separate, later step:
[`datadog-dashboard.md`](datadog-dashboard.md).

## When to use

- First provisioning of the agent on the production host (the ordered path
  below, once).
- The agent is unhealthy, was removed, or the VM was rebuilt — and the
  coordinator is logging `DogStatsD delivery failing (metrics are being
  dropped)`.
- `DD_API_KEY` or `DD_SITE` rotated: the agent's config carries its own copy, so
  `refresh-env.sh --apply` alone does not update it.

Dev already runs an agent from [`deploy/gcp/vm-startup.sh`](../../deploy/gcp/vm-startup.sh);
nothing here applies to it.

## Prerequisites

- `gcloud` with IAP SSH into `darkbloom-mainnet` (see
  [`coordinator-deploy.md`](coordinator-deploy.md#infrastructure) for the exact
  command), and root on the host.
- Explicit human approval for a production mutation (rule 1 in
  [README.md](README.md)).
- `DD_API_KEY` present and non-empty in `/etc/d-inference/env`. The installer
  reads it from there and never prints it — only its length. It is deliberately
  **not** in [`required-env-keys.txt`](../../deploy/gcp/prod/required-env-keys.txt):
  `darkbloom-env-refresh.service` runs `Before=docker.service`, so making a
  telemetry secret required would let a missing key stop the coordinator from
  starting at all.
- `DD_ENV`, `DD_SERVICE` and `DD_AGENT_HOST` in the env file. These are
  non-secret and come from
  [`release-env-defaults`](../../deploy/gcp/prod/release-env-defaults), so
  step 1 installs them; the agent installer warns if they are still missing.
- Outbound HTTPS from the VM to `s3.amazonaws.com` (the agent install script)
  and to `${DD_SITE}` (agent intake).

## Steps

### 1. Add the `DD_*` keys to the env file

```bash
sudo deploy/gcp/prod/refresh-env.sh --check    # report only, no writes
sudo deploy/gcp/prod/refresh-env.sh --apply    # HUMAN ONLY
```

`--check` writes nothing to the live file. It prints one `ADD <key>=<value>` line
per key it would add, one `MIGRATE <key>` per rename, and a count — the candidate
file itself is built in a temp file and deleted on exit, so there is nothing to
inspect afterwards. The merge only adds **absent** keys and a drop-guard rejects
any generation that would remove an existing one, so an operator value already on
the box wins. Expect `ADD` lines for `DD_ENV=production`,
`DD_SERVICE=d-inference-coordinator`, `DD_AGENT_HOST=localhost` and
`DD_SITE=datadoghq.com`.

This does not restart anything. The running coordinator keeps its old
environment until the swap in step 4 — which is fine: the deployed build still
submits counters and gauges over HTTPS.

### 2. Report what the agent installer would do

```bash
sudo deploy/gcp/prod/install-datadog-agent.sh --check
```

Writes nothing. It reports whether the agent is installed, whether
`/etc/datadog-agent/datadog.yaml` matches the config it would write (as a diff
with `api_key` redacted on both sides), and — when the service is active — the
agent's cumulative DogStatsD packet count and whether it considers the API key
valid. That packet count is a total since the agent started, not a rate: run
`--check` twice if you want to see it climb.

### 3. Install and verify the agent

**HUMAN ONLY.**

```bash
sudo deploy/gcp/prod/install-datadog-agent.sh --apply
```

What it does, in order: installs Agent 7 with `DD_INSTALL_ONLY=true` if absent;
writes `datadog.yaml` (`0640`, `dd-agent`-owned, previous file kept as
`.bak.<UTC timestamp>`, root-only because it holds the key) with `env` and the
probe's `service` taken from the env file's `DD_ENV`/`DD_SERVICE`,
`hostname: darkbloom-coordinator`, `dogstatsd_port: 8125`,
`apm_config.enabled: true`, `logs_enabled: false`, and UDS explicitly empty;
`systemctl enable` + `restart`; waits for `datadog-agent status` to actually
answer; then sends one throwaway `d_inference.deploy.agent_install_probe` counter
to `127.0.0.1:8125` and requires three things — the agent's own **Metric
Packets** counter to advance within ~15 s, the API key to not be reported
invalid, and the forwarder's success count to advance.

Those checks are the point of the script, and each covers a different silent
failure. Writing to a UDP socket succeeds whether or not anything is listening —
which is exactly how production ran without an agent unnoticed — so the packet
counter has to come from the agent, not from the send. But an accepted datagram
still proves nothing about delivery: a rotated or truncated key passes that gate
and drops everything one hop later, which is the same failure class moved
downstream. An invalid key is fatal to the script; an unreadable forwarder count
is a loud warning rather than an abort, because those status section names have
moved between agent versions and a false abort strands an operator mid-runbook
with a freshly restarted agent.

It is idempotent in what it installs and writes — re-running reinstalls nothing
and rewrites the config only when it differs — but it does restart the agent
every time, so a no-op `--apply` still briefly interrupts this host's metric
path. Use `--check` to look without touching.

`enable` matters. The coordinator container runs under
`--restart unless-stopped` with no systemd unit, so nothing on this host orders
the agent before it. At steady state that is tolerable — DogStatsD is stateless
UDP, the coordinator recovers the moment the agent answers, and it now logs
while it does not — but the agent has to survive a reboot on its own.

### 4. Only now, deploy the coordinator image

Follow [`coordinator-deploy.md`](coordinator-deploy.md) unchanged. **Do not run
it before step 3 has printed `DogStatsD is receiving`.** The image being deployed
deletes the in-process HTTPS series submission, so between the swap and a working
agent there is no metric path at all.

The reverse window — agent installed, old image still running — is safe by
design: the old build's `httpMetrics()` sends counters and gauges over HTTPS
*instead of* DogStatsD rather than to both, so nothing double-counts. Its
histograms will land on the fresh agent as `|h|` and mint a few orphan
`.avg`/`.95percentile` series until the swap; harmless, and they stop accruing
once the new image is up.

## Verification

1. On the host:

   ```bash
   sudo datadog-agent status | sed -n '/DogStatsD/,/^$/p'
   sudo systemctl is-enabled datadog-agent && sudo systemctl is-active datadog-agent
   ```

   `Metric Packets` must keep climbing across two runs a minute apart.

2. In the container logs, the delivery-error line must be **absent**:

   ```bash
   sudo docker logs --since 10m coordinator 2>&1 | grep -i 'DogStatsD delivery failing' || echo 'clean'
   ```

   That warning is rate-limited to one line a minute and carries
   `errors_since_last_report`; if it appears, metrics are being dropped. It covers
   both drop modes: a dead or unreachable agent, and a DogStatsD client that
   failed to construct at startup (the latter says `never initialized` in the
   error, and is also preceded once by `DogStatsD client init failed`). Note what
   the *absence* of the line does not prove — the agent can accept every datagram
   and still fail to ship it upstream on a bad key, which the coordinator cannot
   see. That is what the installer's API-key and forwarder checks are for; run
   `install-datadog-agent.sh --check` to re-read them at any time.

3. In Datadog, a counter and a gauge from the new path arrive with the right
   tags:

   ```
   sum:d_inference.http.requests{env:production}.as_count()
   avg:d_inference.providers.online{env:production}
   ```

4. Histograms arrive as **distributions**, not agent-aggregated gauges. On the
   metric summary page
   (`https://app.datadoghq.com/metric/summary?filter=d_inference.`),
   `d_inference.http.latency_ms` must show type `distribution`, and
   `d_inference.http.latency_ms.95percentile` must **not** exist. A
   `.95percentile` name means something is submitting `|h|` instead of `|d|`,
   which cannot be re-aggregated across a queried range.

5. On the dashboard, set the `env` template variable to `production` — it
   defaults to `development`, so prod widgets read "No data" until it is
   switched. `service` already defaults to `d-inference-coordinator`.

6. Percentile widgets (`pNN:`) stay empty until the aggregators are enabled per
   metric. That is [`datadog-dashboard.md`](datadog-dashboard.md), and it can
   only run *after* this deploy has flushed each metric at least once.

## Cost

Two separate charges, and the larger one is the deploy.

The agent itself adds one **billed infrastructure host**. Production has no agent
today, so this VM is not currently counted as a Datadog host; installing one adds
it. `apm_config.enabled: true` also makes the host APM-capable — that is ~$0 as
long as nothing creates spans, and today nothing does (no `dd-trace-go` contrib
package is imported anywhere, and `ddtracer.Start` only sets service/env), but it
is one import away from an APM host charge. Worth knowing before someone adds
tracing and wonders where the line item came from.

The deploy is the bigger step. Every coordinator histogram becomes a Datadog
distribution, and a distribution bills as ~5 custom metrics per timeseries (~10
with percentiles enabled). So the image swap is the 5× step and
[enabling percentiles](datadog-dashboard.md#cost-check) is only 2× on top of it.
In production the baseline is zero for histograms — they were being handed to a
DogStatsD socket nobody was listening on — so this is where they start costing
anything at all.

The same deploy also switches 35 provider snapshot names from gauge to
distribution: 14 `provider.process_memory.*`, 15 `provider.paged_storage.*` and 6
`provider.prefix_cache.*` point-in-time values (`coordinator/api/provider_*_telemetry.go`).
That is deliberate — a gauge tagged only by chip family and provider version is
client-side aggregated to one arbitrary provider's reading per flush window, so no
fleet average or maximum exists — and it is free to decide only now, because none
of those names is stored in Datadog yet and the type cannot be changed
afterwards (the reason `provider.mlx_*` is stuck as a gauge). It is the same 5×:
each of those timeseries bills ~5 custom metrics instead of 1, so with one
`chip_family` × `provider_version` combination on the fleet it is roughly 35 → 175
custom metrics, and multiples of that per additional combination. The `.sample_fresh`
and `.sample_age_ms` members are the cheapest to drop first if the number lands
badly; they are freshness diagnostics, not capacity signals.

Read the real number after the deploy (**Plan & Usage → Usage → Custom
Metrics**, or the metric summary page filtered to `d_inference.`) rather than
trusting the estimate. Whoever ran the deploy owns that check. If it jumped more
than expected, the lever is tag cardinality on the biggest contributors — not
turning the transport back off, which returns to silently dropping metrics.

## Rollback

- **Metrics stopped after the deploy** — roll the coordinator image back
  ([`coordinator-deploy.md`](coordinator-deploy.md#rollback)). Know what that
  does and does not restore: the previous image carries the HTTPS **series**
  leg, so counters and gauges resume without an agent, but it has no HTTPS
  distribution leg — on `master`, `Histogram` calls `Statsd.Histogram` and
  nothing else. So a rollback returns histograms to being handed to DogStatsD:
  dropped entirely if the agent is gone, or submitted as `|h|` if it is running,
  which mints `.avg`/`.count`/`.95percentile` series under the old names for as
  long as the old image is up. There is no flag on the new build that re-enables
  the HTTPS path, so rollback is the only lever — it is just a partial one, and
  fixing the agent is usually the shorter path.
- **Agent misbehaving, coordinator fine** — `sudo systemctl stop datadog-agent`.
  Metrics are dropped (and logged) while it is down; traces stop; the
  coordinator's own log and telemetry-event forwarding is unaffected, since that
  goes to the Logs API and never touched the agent.
- **Bad config** — the previous `datadog.yaml` is at
  `/etc/datadog-agent/datadog.yaml.bak.<UTC timestamp>`; restore it and
  `systemctl restart datadog-agent`.
- **Uninstall** — `sudo apt-get remove --purge datadog-agent`. Do not do this
  while the current image is deployed: it is the whole metric path.

## Related

- [`../architecture/telemetry.md`](../architecture/telemetry.md) — what each
  metric kind does on the wire and why there is no fallback.
- [`datadog-dashboard.md`](datadog-dashboard.md) — dashboard apply and
  percentile aggregators, after this.
- [`coordinator-deploy.md`](coordinator-deploy.md) — the image swap in step 4
  and its rollback.
- [`dev-environment.md`](dev-environment.md) — dev's agent, provisioned by the
  VM startup script instead.
- [`../reference/configuration.md#telemetry-datadog-and-profiling`](../reference/configuration.md#telemetry-datadog-and-profiling)
  — the `DD_*` variables the coordinator reads.
