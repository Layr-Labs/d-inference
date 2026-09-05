# Operations runbooks

> Last updated: 2026-09-05 · commit `4d9811f7c`

Procedures for deploying, migrating, and operating Darkbloom production
infrastructure. Every runbook has the same shape — when to use, prerequisites,
steps, verification, rollback — and is written for an operator with production
access. Architecture and security context live under
[`../architecture/README.md`](../architecture/README.md); API and protocol
shapes under [`../reference/README.md`](../reference/README.md).

| Runbook | Scope |
|---|---|
| [`coordinator-deploy.md`](coordinator-deploy.md) | Swap the production coordinator container to a reviewed build, verify, roll back |
| [`global-payouts.md`](global-payouts.md) | Enable international bank payouts, verify bank arrival and reconcile uncertain transfers |
| [`provider-release.md`](provider-release.md) | Ship a provider CLI release: version bump, tag, signed and notarized bundle to R2, registration with the coordinator, rollback by deactivation |
| [`dev-environment.md`](dev-environment.md) | Stand up, operate, and tear down the GCP dev environment |
| [`release-policy-rollout.md`](release-policy-rollout.md) | Deploy the release-policy routing gate in shadow, then flip it to enforce |
| [`routing-v2-rollout.md`](routing-v2-rollout.md) | Kill switches and flag flips for the shipped routing-v2 behaviours (TTFT gate, queue-before-shed, cold dispatch, warm pool, budget clamp, anomaly detector) |
| [`cache-routing-rollout.md`](cache-routing-rollout.md) | Turn exact prefix-cache routing on in production, widen the activation percent and plan-QPS bounds one at a time, verify with `GET /v1/cache/status`, roll back to `off` |
| [`profiler-queries.md`](profiler-queries.md) | Read-only SQL recipes against the profiler tables (`request_profiles`, `fleet_snapshots`) for latency, fleet and outcome questions |
| [`model-migration.md`](model-migration.md) | Publish a model build and move a public alias to it with zero downtime |
| [`state-export.md`](state-export.md) | Extract and rehydrate sealed coordinator state (`DAR-70`) |
| [`coordinator-perf-tier1-rollout.md`](coordinator-perf-tier1-rollout.md) | Roll out the 2026-09 coordinator performance Tier 1 branch: `GOGC` gate, Tier 0 env knobs, before/after checks |
| [`coordinator-perf-tier23-rollout.md`](coordinator-perf-tier23-rollout.md) | Prepare the remaining performance upgrade: exact build identity, dev checks, shared reservation mode, provider rollout dependency, and rollback |

The EigenCloud → GCP move is a frozen report, not a live runbook:
[`../reports/2026-07-17-eigencloud-to-gcp-migration.md`](../reports/2026-07-17-eigencloud-to-gcp-migration.md).

Two rules apply to every page here:

1. Production mutations — GCP deploys, Secret Manager, VM/container/service
   changes, database, DNS, traffic, release registration — require explicit
   human approval for the specific operation. Without it, agents prepare
   commands and perform read-only inspection only.
2. Validate on dev first. Anything that publishes a model, flips an alias, or
   changes routing runs against the dev coordinator
   ([`dev-environment.md`](dev-environment.md)) before production.

Provider CLI releases register a release with the production coordinator and
follow both rules: [`provider-release.md`](provider-release.md).
