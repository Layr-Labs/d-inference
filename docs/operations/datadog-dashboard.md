# Datadog dashboard and distribution percentiles

> Last updated: 2026-09-16 · commit `8e74f2126`

Apply the observability dashboard and enable the percentile aggregators its
latency widgets depend on. The two steps are separate scripts and the **order
matters**: a `pNN:` widget stays empty until both the coordinator has submitted
the metric and the metric has percentiles enabled.

Transport background — why histograms are distributions and what the agent no
longer does — is in
[`../architecture/telemetry.md#mechanism`](../architecture/telemetry.md#mechanism).

## When to use

- A dashboard widget was added, removed or re-queried in
  `deploy/datadog/dev-network-dashboard.json`.
- A coordinator deploy changed which metrics are emitted, or moved a metric
  between legs (DogStatsD ↔ HTTPS).
- A latency widget reads "No data" while `avg:` on the same metric works — that
  is exactly the missing-percentile-aggregator signature.
- A histogram not on the dashboard needs `pNN:` for an ad-hoc query.

## Prerequisites

- `DD_API_KEY` **and** a Datadog **application** key. Both scripts read
  `DD_API_KEY` / `DD_APPLICATION_KEY` (or `DD_APP_KEY` / `DD_WRITE_KEY`) from the
  environment, falling back to Secret Manager (`eigeninference-dd-api-key`,
  `eigeninference-dd-app-key`) in `${DD_GCP_PROJECT:-sepolia-ai}`. The
  application key is what authorizes writes; the API key alone cannot configure
  a metric.
- `python3` and `curl`.
- The coordinator build carrying the metric is already deployed to the
  environment you are configuring. **Production deploys and Secret Manager
  access are human-only** — see the deploy gate in
  [`coordinator-deploy.md`](coordinator-deploy.md).

A tag configuration is **per metric, per organization**, not per environment.
Enabling percentiles on `d_inference.http.latency_ms` from dev also enables it
for production data on the same metric name. Do the dev pass first anyway: it is
where a wrong metric name shows up as a skip rather than as a wrong widget.

## Steps

### 1. Deploy the coordinator, then wait for one flush

Datadog derives a metric's type from submitted data, so a metric it has never
received cannot be configured — the write returns 404 and the script reports it
as `skipped`. The coordinator flushes every 5 s, but a metric only appears once
something emits it, so a low-traffic metric can take minutes. Wait for the
metric to exist:

```bash
export DD_SITE=datadoghq.com   # the scripts default this; curl does not
curl -sS "https://api.${DD_SITE}/api/v1/search?q=metrics:d_inference.http.latency_ms" \
  -H "DD-API-KEY: ${DD_API_KEY}" -H "DD-APPLICATION-KEY: ${DD_APPLICATION_KEY}"
```

### 2. Report what the percentile script would do

```bash
./deploy/datadog/enable-distribution-percentiles.sh
```

Default mode is `--check`: it writes nothing. It derives the metric list from
every `pNN:d_inference.*` query in the dashboard JSON, GETs each metric's tag
configuration, and prints the current state plus the write it would make. A
non-zero exit means a GET failed (network, credentials, permissions), not that
anything is missing.

### 3. Apply

**Human-only.** This is an org-wide write that changes what production data
bills as, so it needs the same explicit human approval as a production deploy
([`coordinator-deploy.md`](coordinator-deploy.md)); agents run `--check` and
prepare the command.

```bash
./deploy/datadog/enable-distribution-percentiles.sh --apply
```

Each write sets `include_percentiles: true` with `exclude_tags_mode: true` and an
empty tag list — "exclude nothing", so every submitted tag stays queryable. Do
not replace that with a `tags` allowlist: an allowlist silently stops resolving
every key not on it, and `http.latency_ms` alone is emitted with `method`, `path`
and `status_code`.

The summary line is the thing to read:

```
configured=6 unchanged=1 skipped=0 failed=0 of 7
```

- `configured` — written now.
- `unchanged` — already correct; re-running is safe and idempotent.
- `skipped` — Datadog has no data for that metric yet. Go back to step 1, or the
  metric has no emitter at all (see [Known-empty widgets](#known-empty-widgets)).
- `failed` — a real API error, with the status and Datadog's own reason. Exit
  code is non-zero. Exit is also non-zero when *nothing* was configured, so an
  `--apply` that achieved nothing cannot look like success.

Aggregators apply to data submitted **from now on**. Percentiles do not
backfill: a widget stays empty for its lookback window even after a successful
apply.

### 4. Apply the dashboard

```bash
./deploy/datadog/apply-dev-dashboard.sh
```

Idempotent `PUT` against `DD_DASHBOARD_ID` (default `vij-8u7-xhf`). It also runs
three Logs API validation queries and prints an event count per query, which is
the fastest check that `env`/`service` tagging still matches what the widgets
scope by.

### 5. To make one more histogram answer `pNN:`

Percentiles are **not** enabled for every histogram the coordinator emits —
about 35 names — because enabling them roughly doubles what that metric bills
(see [Cost check](#cost-check)). Pass the full name:

```bash
./deploy/datadog/enable-distribution-percentiles.sh --apply d_inference.inference.ttft_ms
```

Without that, the metric still answers `avg:` / `count:` / `max:` / `min:` /
`sum:`; only the percentile aggregators are off. If the query is going on the
dashboard, add the widget to the JSON instead — then the script picks the metric
up on its own and no one has to remember the argument.

## Verification

1. Every dashboard latency widget renders a line rather than "No data" (allow
   one lookback window).
2. The metric summary page shows the metric as a **distribution** with
   percentiles enabled:
   `https://app.<DD_SITE>/metric/summary?metric=d_inference.http.latency_ms`
   (`app.datadoghq.com` for US1).
3. Re-running `--apply` reports `unchanged` for everything and configures
   nothing.
4. Tag keys still resolve. On a widget, group `p95:d_inference.http.latency_ms`
   by `status_code` — an empty result means a tag allowlist got applied somewhere
   and is narrowing the metric.

## Cost check

This is the step that is easy to skip and expensive to skip, and the expensive
part is **not** this script. Every histogram the coordinator emits becomes a
distribution the moment the build is deployed, whether or not the script ever
runs, and a distribution is not billed as one custom metric:

| | Custom metrics per timeseries |
|---|---|
| Distribution, percentiles off | ~5 (count, sum, min, max, avg) |
| Distribution, percentiles on | ~10 (the above, plus five more for percentiles) |

So the deploy is the 5× step and enabling percentiles is only 2× on top of it.
In production, where histograms were previously discarded for want of an agent,
the baseline being compared against is zero: the deploy is where the custom
metric count appears, not the apply.

Timeseries count is driven by tag cardinality, not by the number of metric
names. The dominant contributor is `http.latency_ms` (`path` × `method` ×
`status_code`; `path` is bounded to the registered route patterns by
`httpPathLabel`, which already encode the method, so a few hundred series), then
the model-tagged inference families. Order of magnitude for the whole
coordinator: hundreds to low thousands of distribution timeseries — call it
thousands to ~10k custom metrics after the deploy, before anything is
percentile-enabled.

One nuance in the other direction: under cardinality-based pricing Datadog
counts *configured* metrics toward ingested custom-metric volume, so writing a
tag configuration is not perfectly free even when it excludes nothing. It does
not change what is queryable.

After a deploy plus an apply, read the real number rather than the estimate:
**Plan & Usage → Usage → Custom Metrics**, or the metric summary page
(`https://app.<DD_SITE>/metric/summary?filter=d_inference.`) filtered to
`d_inference.`. Whoever ran the deploy owns this check. If the count
jumped more than expected, the lever is tag cardinality on the biggest
contributors — not turning the transport back off, which would return the
metrics to being silently dropped.

## Known-empty widgets

Not every empty widget is a transport problem. These are empty because nothing
emits them, and no dashboard or percentile change fixes that:

| Widget | Why | Fix |
|---|---|---|
| `routing.cost_ms` percentiles | The only `ddHistogram("routing.cost_ms", …)` calls are in `coordinator/api/routing_metrics_test.go`. No production code emits it. | Emit it from the scheduler's cost computation, or drop the widget. |
| `trace.http.request.latency.*` (APM) | `ddtracer.Start()` runs whenever `DD_API_KEY` is set, but no coordinator code creates spans. Needs instrumentation, not a sidecar. | Add spans, or drop the widgets. |

The percentile script will report these as `skipped`, which is correct and does
not fail the run.

## Rollback

Nothing here mutates the coordinator or its data path; both scripts only write
Datadog configuration.

- **Dashboard**: re-`PUT` the previous `deploy/datadog/dev-network-dashboard.json`
  from git.
- **Percentiles**: `DELETE /api/v2/metrics/{metric}/tags` removes a tag
  configuration, which turns percentiles back off and halves what that metric
  bills.
  The raw distribution data is unaffected, and `avg:`/`count:`/`max:` keep
  working. Deleting does not restore agent-style `.95percentile` gauges — those
  came from a local agent aggregating DogStatsD and stopped when histograms moved
  to HTTPS.
- **Whole transport**: unsetting `DD_API_KEY` returns counters, gauges and
  histograms to DogStatsD — which on a host with no agent means they are silently
  discarded again — and stops log and event forwarding outright, since those have
  no UDP leg at all. That is the bug this replaced, not a rollback target.
