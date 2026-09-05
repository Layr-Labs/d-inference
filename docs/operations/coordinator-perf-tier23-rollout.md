# Coordinator performance Tiers 2 and 3 rollout

> Last updated: 2026-09-04 · commit `376b4868f`

Prepare and verify the coordinator upgrade that combines indexed routing,
bounded lifecycle work, and per-identity reservation gates. Use
[coordinator-deploy.md](coordinator-deploy.md) for image selection, the
container swap, and rollback; this companion defines the checks specific to
the performance changes.

## When to use

The remaining changes from PRs #819, #822, and #823 are being promoted to
`master`. PRs #818, #820, and #821 already reached `master`; the other PRs
were merged into stack branches. The integration branch replays #819 and
the combined #823 patch onto that master, preserving the reviewed source.

## Prerequisites

- The integration PR is merged, the candidate is the reviewed `master`
  commit, and its required CI checks pass. Record any explicitly accepted
  check exception separately; a deferred check is not a passing check.
- Validate the candidate on [dev](dev-environment.md) before production.
  Record the full `/health` `build_commit`, model availability, and a
  successful streaming request through an eligible provider.
- Record the baseline model mix, request rate, TTFT distribution, error and
  rejection rates, routing scans, and registry lock waits. Compare similar
  traffic windows and retain the build commits alongside the measurements.
- Capture the previous image and environment using the deployment runbook.
  Production mutations require explicit human approval for the operation.

## Steps

1. Select the exact post-merge image using
   [coordinator-deploy.md](coordinator-deploy.md). Build tags and provider
   version strings alone do not identify the candidate: verify its full
   commit in both the image label and `/health`.
2. Record `EIGENINFERENCE_RESERVE_COMMIT_MODE` for the candidate. The default
   is `shared`; `global` restores fleet-wide reservation commit
   serialization. The setting is read at registry construction, so a change
   requires a new process. See the source and parsing rules in
   [configuration.md](../reference/configuration.md).
3. Use the deployment runbook's environment preservation and swap steps.
   Keep existing cache-routing, trust, health-ejection, and routing-concurrency
   settings in the deploy record. Tune concurrency separately after measuring
   the new scan and lock behavior. The Tier 1
   [`GOGC` gate](coordinator-perf-tier1-rollout.md) still applies.
4. Verify coordinator-only behavior first. The Swift drain-awareness changes
   in `provider-swift/Sources/ProviderCore/ProviderLoop+DrainState.swift`
   (`setRetirementReconnectBarrier`) require a provider build containing this patch;
   a coordinator swap does not update provider binaries. Exercise update,
   shutdown, and retirement barriers on dev with that provider build, then
   follow [provider-release.md](provider-release.md) for its separate release.

## Verification

Check immediately after the swap, compare matched traffic windows after
30–60 minutes, and retain a 24-hour follow-up. The telemetry names below
are catalogued in [telemetry-inventory.md](../reference/telemetry-inventory.md);
use [profiler-queries.md](profiler-queries.md) for request-level evidence.

| Check | Expected evidence |
|---|---|
| Identity and availability | `/health` reports the candidate commit; expected models have eligible capacity; a streaming request completes successfully. Connected-provider count alone does not prove routable capacity. |
| Admission and lock contention | Compare TTFT and admission timing with the baseline; inspect `d_inference.registry.mu.write_wait_ms` by `site` and `d_inference.registry.gate.wait_ms`. The latter requires DogStatsD and reports waits over its threshold, so missing samples alone do not prove zero contention. |
| Routing work | Compare `d_inference.routing.scans` per attempt, CPU, and queue depth/age at a similar model mix and load. Separate retries from first attempts. |
| Large requests | On dev, stream a vision request large enough to exercise continuation frames; the provider connection survives and ping/pong replies remain responsive. Application control messages still have non-preemptive priority. |
| Drain and restart | On dev, a draining refusal fences the provider before queued work is reconsidered; a recovery heartbeat makes it eligible again. Genuine provider faults survive version changes; only coordinator-marked disconnect flushes can reset. |
| Cancellation | On dev, cancel an active stream and verify generation terminates, terminal state is released once, and cancellation telemetry reflects actual send outcomes. |
| Telemetry and memory | Inspect bounded chip/version tags, departed-model queue gauges returning to zero, and stable tracker memory under repeated cancellations and reconnects. |

The Tier 3 proposal's latency and scan targets are acceptance goals, not
measurements from this deployment. Keep measured results and unmet goals in
the deploy record; see the
[Tier 3 report](../reports/2026-09-03-perf-pr-c-tier3-body.md).

## Rollback

- For a reservation-commit regression, an approved operator can set
  `EIGENINFERENCE_RESERVE_COMMIT_MODE=global` and recreate the container
  through the deployment runbook. This restores the global commit lock;
  per-identity fault recorders and the other performance changes remain.
- For other regressions, or if that mode does not restore service, use the
  previous image and captured environment from
  [coordinator-deploy.md](coordinator-deploy.md). Recheck build identity,
  routable capacity, streaming, and preserved cache controls after rollback.

## Related

- [Routing architecture](../architecture/routing.md) — indexes, gates, and
  reservation invariants.
- [Scheduling architecture](../architecture/scheduling.md) — queue and
  admission behavior.
- [Tier 1 rollout](coordinator-perf-tier1-rollout.md) — heap and GC gates.
