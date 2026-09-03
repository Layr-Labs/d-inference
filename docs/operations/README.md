# Operations runbooks

> Last updated: 2026-09-03 · commit `5d400cf75`

Procedures for deploying, migrating, and operating Darkbloom production
infrastructure. Every runbook has the same shape — when to use, prerequisites,
steps, verification, rollback — and is written for an operator with production
access. Architecture and security context live under
[`../architecture/README.md`](../architecture/README.md); API and protocol
shapes under [`../reference/README.md`](../reference/README.md).

| Runbook | Scope |
|---|---|
| [`coordinator-deploy.md`](coordinator-deploy.md) | Swap the production coordinator container to a reviewed build, verify, roll back |
| [`dev-environment.md`](dev-environment.md) | Stand up, operate, and tear down the GCP dev environment |
| [`release-policy-rollout.md`](release-policy-rollout.md) | Deploy the release-policy routing gate in shadow, then flip it to enforce |
| [`routing-v2-rollout.md`](routing-v2-rollout.md) | Staged rollout of the routing-v2 admission and routing flags |
| [`model-migration.md`](model-migration.md) | Publish a model build and move a public alias to it with zero downtime |
| [`state-export.md`](state-export.md) | Extract and rehydrate sealed coordinator state (`DAR-70`) |
| [`../reports/2026-07-17-eigencloud-to-gcp-migration.md`](../reports/2026-07-17-eigencloud-to-gcp-migration.md) | Record of the EigenCloud → GCP move (frozen report, not a live runbook) |

Two rules apply to every page here:

1. Production mutations — GCP deploys, Secret Manager, VM/container/service
   changes, database, DNS, traffic, release registration — require explicit
   human approval for the specific operation. Without it, agents prepare
   commands and perform read-only inspection only.
2. Validate on dev first. Anything that publishes a model, flips an alias, or
   changes routing runs against the dev coordinator
   ([`dev-environment.md`](dev-environment.md)) before production.

Provider CLI releases are a developer runbook:
[`../developer/release.md`](../developer/release.md).
