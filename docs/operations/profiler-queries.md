# Profiler queries

> Last updated: 2026-09-04 · commit `d574bd5af`

How to answer the recurring latency, routing and fleet questions from the
system profiler's two Postgres tables, `request_profiles` and
`fleet_snapshots`, with copy-paste SQL. What the columns mean, how rows get
there and why some are `NULL` is explained in
[`../architecture/system-profiler.md`](../architecture/system-profiler.md);
this page only runs the queries.

## Prerequisites

- Read-only access to the production Postgres that
  `EIGENINFERENCE_DATABASE_URL` points at — use the read replica, never the
  primary. The tables are `request_profiles` (one row per attempt of a
  logical request, keyed `(request_id, attempt)`) and `fleet_snapshots` (one
  row per provider × model per sampler tick, plus a `provider_id =
  'coordinator'` row). Both are created by the boot migrations in
  `coordinator/store/postgres.go`; the optional `request_waterfall` view is
  applied by hand from `coordinator/store/migrations/request_waterfall.sql`.
- Rows exist only while retention keeps them
  ([`../reference/telemetry-inventory.md#coordinator-per-request-records-postgres`](../reference/telemetry-inventory.md#coordinator-per-request-records-postgres))
  and, for `request_profiles`, only for sampled or always-recorded attempts
  ([`../architecture/system-profiler.md#sampling-sink-retention`](../architecture/system-profiler.md#sampling-sink-retention)).
- Without database access, the same rows are available as NDJSON through the
  admin API (`EIGENINFERENCE_ADMIN_KEY`; filters in
  [`../architecture/system-profiler.md#operations`](../architecture/system-profiler.md#operations)):

  ```sh
  curl -sS -H "Authorization: Bearer $ADMIN_KEY" "$COORD/v1/admin/profiles/export?since=24h&model=$MODEL"  > profiles.ndjson
  curl -sS -H "Authorization: Bearer $ADMIN_KEY" "$COORD/v1/admin/snapshots/export?since=6h&provider=$PID" > snapshots.ndjson
  curl -sS -H "Authorization: Bearer $ADMIN_KEY" "$COORD/v1/admin/profiles?coord_request_id=$CID&limit=20" | jq .
  ```

Reading the offsets: every `*_us` column in `request_profiles` is microseconds
from `received_at`. Subtract two **coordinator** columns to get a segment;
never subtract a coordinator column from a provider (`prov_*`, `eng_*`) column
— they are different clocks
([`../architecture/system-profiler.md#invariants`](../architecture/system-profiler.md#invariants)).
`transport_est_us` is the only cross-hop figure.

## Steps

### 1. Waterfall for one logical request

Every attempt of one `coord_request_id`, backups included, oldest attempt
first:

```sql
SELECT attempt, backup_of, winning, provider_id, final_status, error_reason,
       handler_entry_us, parsed_us, reserved_us, preflight_done_us, plan_done_us,
       attempt_start_us, reserve_lock_acquired_us, reserve_done_us, queued_us, dequeued_us,
       encrypted_us, write_submitted_us, write_dequeued_us, write_done_us, accepted_us,
       first_chunk_ingress_us, first_content_ingress_us, first_content_us, headers_written_us,
       first_flush_us, last_flush_us, client_gone_us, cancel_sent_us, complete_ingress_us,
       done_flushed_us, finalized_us, prov_total_us, transport_est_us
FROM request_profiles WHERE coord_request_id = $1 ORDER BY attempt, id;
```

One row per attempt; `winning` marks the attempt whose bytes reached the
client, `backup_of` links a hedged attempt to the one it backed up. A `NULL`
stamp means that phase never happened for that attempt (for example
`complete_ingress_us` after `provider_outcome = no_terminal`).

### 2. p50 / p95 per coordinator segment by model

Winning attempts of the last 24 h, one row per model × segment:

```sql
SELECT model, seg,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY us) AS p50_us,
       percentile_cont(0.95) WITHIN GROUP (ORDER BY us) AS p95_us, count(*) AS n
FROM request_profiles p
CROSS JOIN LATERAL (VALUES
  ('pre_handler', handler_entry_us),
  ('parse',       parsed_us - handler_entry_us),
  ('reserve',     reserved_us - parsed_us),
  ('preflight',   preflight_done_us - reserved_us),
  ('route',       reserve_done_us - attempt_start_us),
  ('queue',       dequeued_us - queued_us),
  ('encrypt',     encrypted_us - GREATEST(reserve_done_us, topup_done_us)),
  ('writer',      write_dequeued_us - write_submitted_us),
  ('socket',      write_done_us - write_dequeued_us),
  ('provider_ack',accepted_us - write_done_us),
  ('to_first_chunk', first_chunk_ingress_us - write_done_us),
  ('to_first_flush', first_flush_us - first_chunk_ingress_us),
  ('stream',      last_flush_us - first_flush_us)) AS s(seg, us)
WHERE p.created_at > now() - interval '24 hours' AND p.winning AND s.us IS NOT NULL AND s.us >= 0
GROUP BY model, seg ORDER BY model, p95_us DESC;
```

The segment with the largest `p95_us` is where the request spends its tail.
`to_first_chunk` includes the provider's own prefill; compare it with step 3
before blaming the network.

### 3. Provider-vs-coordinator split

Where the round trip goes for profiler-aware providers (rows from pre-profiler
providers have `provider_profile_valid = false` and are excluded):

```sql
SELECT model, provider_id,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY complete_ingress_us - write_done_us) AS p50_round_trip_us,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY prov_total_us)                        AS p50_provider_us,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY transport_est_us)                     AS p50_transport_est_us,
       percentile_cont(0.95) WITHIN GROUP (ORDER BY slept_us)                            AS p95_slept_us
FROM request_profiles
WHERE created_at > now() - interval '24 hours' AND provider_profile_valid
GROUP BY model, provider_id ORDER BY p50_transport_est_us DESC;
```

`p50_round_trip_us − p50_provider_us` is the time outside the provider process;
a large `p50_transport_est_us` for one provider points at its link. `slept_us`
is the provider's continuous-clock delta minus its suspending-clock delta, so a
large `p95_slept_us` means the Mac was suspended mid-request.

### 4. Routing regret proxy

Runner-up versus winner predicted cost against the first-content latency the
client actually saw:

```sql
SELECT model, selection_path,
       CASE WHEN runner_up_provider_id = '' THEN 'no_runner_up'
            WHEN runner_up_cost_ms - (candidates->0->>'cost_ms')::float < 250 THEN 'near_tie'
            ELSE 'clear_winner' END AS margin,
       count(*) AS n,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY predicted_ttft_ms) AS p50_predicted_ttft_ms,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY (first_content_us - write_done_us) / 1000.0) AS p50_realised_first_content_ms,
       percentile_cont(0.95) WITHIN GROUP (ORDER BY (first_content_us - write_done_us) / 1000.0) AS p95_realised_first_content_ms
FROM request_profiles
WHERE created_at > now() - interval '24 hours' AND winning AND candidates IS NOT NULL
GROUP BY 1, 2, 3 ORDER BY 1, 2, 3;
```

`candidates->0` is the chosen provider (`cost_ms` is a key of the persisted
candidate JSON, `candidateJSON` in `coordinator/api/profiler_record.go`). A `near_tie`
bucket whose realised first-content latency is far above its predicted TTFT
means the cost model is not separating the candidates.

### 5. Idle warm alternative not chosen

How often a warm, idle provider for the model existed but a different one won:

```sql
SELECT model, date_trunc('hour', created_at) AS hour, count(*) AS n,
       count(*) FILTER (WHERE best_idle_provider_id <> '' AND best_idle_provider_id <> provider_id) AS idle_alternative,
       count(*) FILTER (WHERE best_idle_provider_id <> '' AND best_idle_provider_id <> provider_id
                          AND best_idle_ttft_ms < predicted_ttft_ms) AS idle_alternative_faster_by_estimate
FROM request_profiles WHERE created_at > now() - interval '24 hours' AND winning
GROUP BY 1, 2 ORDER BY 1, 2;
```

`idle_alternative_faster_by_estimate / n` is the share of requests where the
scheduler's own estimate preferred an idle provider it did not pick — expected
to be near zero; a rising value after a routing change is a regression signal.

### 6. Gate rejection reasons by hour

```sql
SELECT date_trunc('hour', created_at) AS hour, g.key AS reason, sum(g.value::int) AS rejections, count(*) AS attempts
FROM request_profiles, jsonb_each_text(gate_rejections) AS g
WHERE created_at > now() - interval '24 hours'
GROUP BY 1, 2 ORDER BY 1, 3 DESC;
```

`reason` is a `GateReason` name (`coordinator/registry/gate_reason.go`);
`rejections` counts candidate providers rejected for that reason across the
hour's attempts. Only attempts that reached routing appear — pre-dispatch
rejections live in `request_rejections`, not here. For their counterfactual
servable rate, count only evaluated rows and report unknowns separately:

```sql
SELECT count(*) FILTER (WHERE could_have_served IS NULL) AS unknown,
       count(could_have_served) AS evaluated,
       count(*) FILTER (WHERE could_have_served IS TRUE)::float
         / NULLIF(count(could_have_served), 0) AS servable_rejection_fraction
FROM request_rejections
WHERE created_at > now() - interval '24 hours';
```

The [rejection record contract](../architecture/request-outcome-observability.md)
defines the nullable field; saturation shedding skips its fleet scan.

### 7. Slot occupancy for one provider session

```sql
SELECT sampled_at, model, slot_state, eligibility_reason, num_running, num_waiting,
       active_token_budget_used, active_token_budget_max, pending_count, effective_cap,
       cooldown_active, breaker_open, clamp_active, heartbeat_age_ms, observed_decode_tps
FROM fleet_snapshots
WHERE provider_id = $1 AND sampled_at > now() - interval '6 hours' ORDER BY sampled_at, model;
```

One row per sampler tick per model the provider advertises. `slot_state` and
`eligibility_reason` are the folded enums from the heartbeat; `breaker_open`,
`cooldown_active` and `clamp_active` show why a warm provider was not
routable at that instant.

### 8. Sink drop rate

The coordinator's own fleet row carries cumulative counters; the `lag()`
turns them into per-tick deltas:

```sql
SELECT sampled_at,
       profile_sink_dropped_total - lag(profile_sink_dropped_total) OVER (ORDER BY sampled_at) AS profile_drops,
       route_sink_dropped_total   - lag(route_sink_dropped_total)   OVER (ORDER BY sampled_at) AS route_drops,
       unknown_request_frames_total - lag(unknown_request_frames_total) OVER (ORDER BY sampled_at) AS unknown_frames,
       profile_sink_depth, queue_depth_total, inflight_requests, goroutines
FROM fleet_snapshots WHERE provider_id = 'coordinator' AND sampled_at > now() - interval '24 hours'
ORDER BY sampled_at;
```

Non-zero `profile_drops` means `request_profiles` is missing rows for that
window (the request itself was unaffected); a growing `profile_sink_depth`
before the drops means the store write, not the sampler, is the bottleneck.

### 9. Providers routed on a stale snapshot

```sql
SELECT provider_id, count(*) AS n,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY snapshot_age_ms)  AS p50_age_ms,
       percentile_cont(0.95) WITHIN GROUP (ORDER BY snapshot_age_ms) AS p95_age_ms,
       count(*) FILTER (WHERE snapshot_age_ms > 10000) AS older_than_10s
FROM request_profiles WHERE created_at > now() - interval '24 hours' AND winning
GROUP BY provider_id ORDER BY p95_age_ms DESC LIMIT 30;
```

`snapshot_age_ms` is `now − LastHeartbeat` for the chosen provider at the
moment the routing snapshot was taken. A provider whose `p95_age_ms`
approaches the eviction window
([`../architecture/scheduling.md#heartbeat-cadence-and-eviction`](../architecture/scheduling.md#heartbeat-cadence-and-eviction))
is being routed on nearly-expired state.

## Verify

- Step 1 returns at least one row for a `coord_request_id` taken from
  `GET /v1/admin/profiles?since=1h&limit=1` (or the coordinator log), and its
  `winning` attempt has `complete_ingress_us IS NOT NULL`.
- Every `p50_us`/`p95_us` in step 2 is non-negative: the query filters
  `s.us >= 0`, and rows with decreasing stamps are flagged
  `timing_anomaly = true` rather than rejected.
- Step 8 returns a `coordinator` row for every sampler tick in the window; a
  gap means the coordinator was down or the fleet sampler was off
  (`EIGENINFERENCE_PROFILER=off`).

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Step 1 returns nothing for a known request | The attempt was sampled out and hit no always-record predicate, or it is older than retention | Look the request up in `inference_routes` instead; raise `EIGENINFERENCE_PROFILE_SAMPLE_RATE` ([`../reference/configuration.md`](../reference/configuration.md)) if the miss rate is a problem |
| `prov_*`, `eng_*`, `transport_est_us`, `slept_us` all `NULL` | Provider older than the profiler build; step 3 already excludes these rows via `provider_profile_valid` | Expected for a mixed fleet ([`../architecture/system-profiler.md#invariants`](../architecture/system-profiler.md#invariants)) |
| `relation "request_waterfall" does not exist` | The view is not part of the boot migrations | `psql "$EIGENINFERENCE_DATABASE_URL" -f coordinator/store/migrations/request_waterfall.sql` |
| Queries are slow or time out on the primary | Percentile scans over 24 h of rows are heavy and compete with the hourly retention DELETE | Run on the read replica; narrow the `created_at` window |

## Related

- [`../architecture/system-profiler.md`](../architecture/system-profiler.md) — what every column means, sampling, sink, retention and the admin endpoints
- [`../reference/telemetry-inventory.md`](../reference/telemetry-inventory.md) — retention and where these tables sit among the other telemetry
- [`../architecture/request-outcome-observability.md`](../architecture/request-outcome-observability.md) — `final_status`, `error_class`, `terminal_cause` vocabularies used in the rows
- [`../architecture/scheduling.md`](../architecture/scheduling.md), [`../architecture/routing.md`](../architecture/routing.md) — the decisions steps 4–6 and 9 measure
- [`../reference/configuration.md`](../reference/configuration.md) — `EIGENINFERENCE_PROFILER`, `EIGENINFERENCE_PROFILE_SAMPLE_RATE`, `EIGENINFERENCE_DATABASE_URL`
