# Rust coordinator observability runbook

This runbook covers the Rust migration dashboards and monitors in
`deploy/datadog/`. It does not authorize a production deploy. Production
handoff and rollback remain human-operated procedures in
`coordinator-deploy.md`.

Cutover evidence is collected by the GET-only, explicit-site client in
`scripts/cutover_readiness/clients.py` under
[`coordinator-cutover.md`](coordinator-cutover.md). A missing Datadog site,
empty series, stale snapshot, or threshold ambiguity blocks the gate; it is not
permission to query another site or waive the signal.
The collector cannot accept a query file override: canary/production query
definitions are repository-pinned and their hashes are signed into evidence.
Coordinator metrics, utilization, and quiescence require the dedicated
read-only operations bearer; the admin bearer is intentionally rejected.

## Signal contract

The Rust process sends custom metrics to the local Datadog Agent over
DogStatsD, exports batched traces to the Agent APM listener, and writes
single-line JSON logs to stdout. The systemd units retain stdout/stderr in
journald, and the host Agent collects only the coordinator and offline
recovery units.

Unified tags are:

- `service:d-inference-coordinator`
- `env:development` or `env:production`
- image build `version`
- `git_commit`

The metric mailbox is finite and request paths only use `try_send`. Its
accepted, full-drop, closed-drop, transport-drop, send-failure, and
remaining-capacity counters are available from authenticated
`GET /v1/admin/metrics`. Metric and tag names are constrained by
`deploy/datadog/rust-metrics-allowlist.json`.
Account, request, API-key, prompt, provider ID, serial, UDID, token, and secret
values are forbidden as metric tags.

Validate the committed contract before applying dashboards or monitors:

```bash
python3 deploy/datadog/validate-rust-observability.py
bash deploy/datadog/test-rust-observability.sh
```

## Availability

The availability monitor uses the five-minute HTTP 5xx ratio. It also alerts
on no data because the host health check continuously calls the Rust HTTP
surface.

1. Check `/readyz` and `/health`; compare `build.commit`, schema versions, and
   `ownership_healthy`.
2. Check structured journald errors:
   `journalctl -u d-inference-coordinator.service --since '-15 min' -o cat`.
3. If ownership, schema, or a supervisor is unhealthy, do not restart a second
   owner. Follow the serial handoff procedure.
4. For route-local 5xx errors, correlate the `http.request` APM resource with
   JSON logs by time. IDs are deliberately not metric tags.

## Stage latency

The p95 and p99 monitors cover parse, reserve, prepare, start, TTFT, chunk, and
settle independently. The bridge emits these samples as DogStatsD histograms
(`|h`). Host setup configures `histogram_percentiles` for `0.95` and `0.99`,
and the monitors query the Agent-generated `.95percentile` and
`.99percentile` series. Each latency monitor alerts on no data after 15
minutes so a missing generated percentile cannot silently disable alerting.

After host setup or an Agent upgrade, verify the active configuration and
generated series before cutover:

```bash
sudo sed -n '/BEGIN D-INFERENCE HISTOGRAMS/,/END D-INFERENCE HISTOGRAMS/p' \
  /etc/datadog-agent/datadog.yaml
sudo datadog-agent configcheck
sudo datadog-agent status
```

Then send traffic through every monitored stage and confirm both
`d_inference.rust.http.stage.duration_ms.95percentile` and
`d_inference.rust.http.stage.duration_ms.99percentile` are queryable in
Metrics Explorer with `service:d-inference-coordinator`. A no-data latency
alert after rollout means either the stage received no samples or histogram
derivation/transport is broken; verify traffic and the Agent before muting it.

- Parse: inspect body-size rejection and CPU saturation.
- Reserve/start: inspect response semaphore, fleet admission reasons, and
  writer headroom.
- Prepare: inspect catalog, API-key controls, and database latency.
- TTFT/chunk: inspect provider trust, admission, writer `sent_unknown`, timeout,
  and byte-pipe overflow.
- Settle: inspect ledger transitions, ambiguous commits, ownership, and database
  health.

Do not increase a threshold until the responsible stage and its correctness
budget are understood.

## Queue saturation

Any writer `outcome:saturated` is actionable. Control-lane saturation fences
the provider session; data-lane saturation rejects the dispatch without
consuming correctness reserve.

1. Compare writer item and byte histograms by `lane`.
2. Check `writer.timeout`, `writer.delivery{outcome:sent_unknown}`, and fleet
   admission reasons.
3. Check provider reconnect/trust events.
4. Do not add provider IDs as tags. Use bounded admin snapshots for an
   incident-specific provider inspection.

## Stuck durable state

The supervised state reporter emits every allowed active `(kind,state)` pair
every 10 seconds, including zeroes, so old nonzero gauges do not remain stale. The
age monitor covers jobs, attempts, terminals, financial operations, external
events, outbox, fee projection, MDM expectations, and durable telemetry.

Run the read-only, PII-free diagnostic from the pinned image:

```bash
docker run --rm \
  --network host \
  --env-file /etc/d-inference/env \
  --mount type=bind,source=/etc/d-inference/secrets,target=/run/d-inference-secrets,readonly \
  --entrypoint /usr/local/bin/coordinator-rs \
  IMAGE_DIGEST state-counts | jq .
```

The output contains only relation/state counts, oldest ages, schema metadata,
and the Go-fallback rollback guard. Do not manually mutate a row. Let the
leased recovery worker reconcile it, or use the documented reviewed-resolution
command when an invariant report explicitly requires that action.

## Trust and provider version

Production and dev require hardware trust. An established `self_signed` or
`untrusted` event is a regression.

1. Check attestation and MDM logs for the same time window.
2. Verify `MIN_TRUST=hardware`.
3. Do not lower trust to recover capacity.

Provider versions are reduced to fixed buckets: `below_floor`,
`older_supported`, `current`, `newer`, `at_or_above_floor`, `invalid`, or
`unconfigured`. No raw version string becomes a metric tag. The floor monitor
also alerts on invalid versions and missing floor configuration.

## Ownership and split-brain

`ownership.healthy=0` is a hard stop. Ownership loss publishes `0` immediately
before cancellation and shutdown. While healthy, the supervised publisher
refreshes ownership health/epoch, schema versions/checksum, drain/quiescence,
rollback guard, and durable state counts every 10 seconds. Monitor no-data
therefore identifies process absence or broken telemetry, separately from a
healthy process explicitly reporting `1`. Epoch churn is a split-brain
warning, not proof that starting another process is safe.

1. Verify the one-container invariant and both systemd units.
2. Verify the PostgreSQL ownership holder.
3. Preserve the failed candidate and follow the ownership-loss branch in the
   deploy runbook.
4. Never disable the ownership lock or bypass the host owner lock.

## Migration checksum

Rust startup verifies all public migration rows against checksums compiled from
the authoritative SQL files. A mismatch prevents serving. The checksum monitor
also treats missing data as critical.

1. Stop cutover.
2. Compare the database migration catalog with
   `coordinator/store/migrations/`.
3. Do not edit a checksum row or apply schema DDL from serving startup.
4. Use the external migration command and canonical deployment runbook.

## Stripe unknown outcome

`billing.external_unknown{source:stripe}` means a caller-visible result cannot
prove whether the external operation committed.

1. Do not replay the operation manually.
2. Inspect outbox and external-event state with `state-counts`.
3. Let idempotent Stripe and ledger recovery reconcile the event.
4. Escalate if the durable age monitor remains active past its lease/retry
   window.

## Drain, quiescence, and rollback guard

Drain and quiescence are separate. A draining process may still own durable or
external work. Automatic fallback is allowed only when the continuously
reported `rollback_guard{mode:go_fallback}` is `1` and the authoritative
`coordinator-go rollback-check` succeeds during the handoff.

If the guard is `0`, do not stop or replace the sole owner. Continue bounded
recovery until the guard clears, or follow manual incident recovery. Never
delete `/run/d-inference/automatic-rollback-refused` or a systemd rollback
fence to force an older binary to start.
