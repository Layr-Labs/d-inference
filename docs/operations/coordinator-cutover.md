# Rust coordinator cutover

This runbook governs evidence only. The tooling never deploys, drains, changes
traffic, writes Datadog, or writes a database. Production ownership changes are
the serial human procedure in
[`coordinator-deploy.md`](coordinator-deploy.md).

## Honest traffic model

The production host has one listener, one active coordinator, and one database
owner. It cannot perform a weighted Go/Rust canary. The supported progression
is:

1. `isolated-pilot` and `sampled-shadow-replay`: offline/isolated request samples are replayed to
   Rust in observe-only mode. `import-route-trace` computes the observed sample
   ratio from source and routed counts. Mutations and money operations must be
   zero.
2. `dedicated-canary`: a separate listener/environment sends 100% of requests
   entering that listener to one Rust owner. It uses a database identity
   distinct from production and synthetic isolated money.
3. `full-cutover`: `deploy-prod.sh` performs one atomic, quiescence-gated
   ownership handoff. Production goes from one Go owner to one Rust owner;
   there is no dual ownership or intermediate percentage.
4. The 24-hour, 7-day, 30-day, and 90-day bakes run sequentially after the
   handoff and observe the sole production Rust owner.

A future production cohort canary requires an explicitly separate listener,
separate database, isolated money, and reviewed Caddy cohort routing. It is not
implemented or authorized by this policy.

## Trust and collector prerequisites

- Policy and evidence schema are both version 2. Authorizations bind the exact
  SHA-256 of `deploy/cutover/gates.json`; an artifact from another policy is
  invalid.
- Fault/load/rollback test jobs receive no signing secret and have
  `id-token: none`. They emit unsigned canonical-hash reports. A separate
  protected default-branch signer downloads only successful-job artifacts,
  verifies their hashes without executing repository code, then creates GitHub
  attestations and Sigstore keyless signatures. Fault receipts use a per-run
  ephemeral key only.
- Every collector consumes the same daily renewed, signed environment
  manifest. Its `environment_id` hashes production/canary HTTPS origins,
  listener and database identities, PostgreSQL `system_identifier`, read-only
  DSN and writer-endpoint fingerprints, coordinator ownership/App IDs,
  Datadog site/organization ID, and exact distinct candidate/fallback image
  digests. Coordinator, Datadog, and RDS collectors report that ID
  independently.
- Signing jobs run only for `Layr-Labs/d-inference` on protected `master` in
  the `cutover-evidence-signer` GitHub Environment. Configure required
  reviewers and a default-branch deployment rule. Jobs verify immutable
  workflow ref/SHA before OIDC access.
- The coordinator collector uses the dedicated
  `EIGENINFERENCE_READ_ONLY_KEY`. An admin credential does not authorize
  metrics, utilization, or quiescence reads.
- Datadog site is explicit (`us1`, `us3`, `us5`, `eu`, `ap1`, or `ap2`).
  Queries are fixed in `deploy/cutover/datadog-queries.json` or
  `datadog-queries-canary.json`, use exact 900-second rollups, and return exact
  non-overlapping bucket timestamps. The collector fetches authenticated
  organization identity and rejects another signed site or tenant.
- PostgreSQL uses `/usr/bin/psql`, the exact role
  `darkbloom_cutover_readonly`, and the fixed
  `deploy/cutover/rds-readonly.sql`. The DSN must set
  `sslmode=verify-full`, `target_session_attrs=read-only`, and
  `default_transaction_read_only=on`. SQL also starts a read-only repeatable
  read transaction with fixed lock and statement timeouts and verifies that
  the role has no write/elevated privileges. Replica evidence reads
  `pg_control_system().system_identifier` and must match the signed writer
  cluster; canary and production cluster IDs must differ.
- Signing keys are regular files with mode `0600` or stricter. Gate and human
  approver keys are distinct.
- Every report admitted to a gate must carry either a configured-key signature
  or both a pinned-workflow Sigstore bundle and offline GitHub attestation
  bundle.

Missing, stale, unsigned where required, future-dated, checksum-invalid,
wrong-policy, inconclusive, or failed evidence is a hard stop.
Live evidence requires both the commit and immutable image digest reported by
health to match signed provenance and the descriptor. Deployment corroborates
the digest against Docker `RepoDigests`, `Config.Image`, and a container label.

## Gates

| Gate | Environment and evidence |
|---|---|
| `isolated-pilot` | Signed fault receipts, load, and Go/Rust differential |
| `sampled-shadow-replay` | Isolated measured sample ratio, no owner, no mutation |
| `rollback-drill` | Distinct immutable local images; fallback → candidate → injected failure → fallback |
| `dedicated-canary` | Separate canary listener and DB, 100% self-route, isolated money |
| `bake-24h` / `bake-7d` | Sole production Rust owner; fixed-window latency, unique requests, errors, and durable states |
| `full-cutover` | Fresh canary proof, rollback proof, immutable target commit/images, human approval |
| `bake-30d` / `bake-90d` | Sole production Rust owner; same latency/request/error/durable gates |
| `go-retirement` | 90-day non-overlapping DB audit of zero Go writes/sessions/ownership plus inventory |

Full-cutover authorization and live evidence expire after 15 minutes.
Deployment verifies once during planning and again immediately before the
migration/drain transaction. Historical bake predecessors are checked at the
signed bake-window start, when they were still valid; only the newest
authorization must be fresh now.

## Collect evidence

Release security first reviews the canonical descriptor and seals it. The raw
JSON must contain every schema-2 descriptor field; signing an arbitrary origin
does not help because production and canary origins are fixed by the tool:

```bash
python3 scripts/cutover-readiness.py create-environment-manifest \
  --source artifacts/cutover/environment-descriptor.json \
  --signing-key "$GATE_PRIVATE" \
  --output artifacts/cutover/environment.json
```

Import load/differential evidence with `import-pilot`. Import a route trace
whose raw schema contains source/routed/failed request counts, listener and
production-listener identities, and database identities. Shadow replay must
name `offline-replay` with no database; a dedicated canary must name listener
and database identities distinct from production:

```bash
python3 scripts/cutover-readiness.py import-route-trace \
  --source artifacts/cutover/shadow-route-trace.json \
  --environment isolated \
  --environment-manifest artifacts/cutover/environment.json \
  --trusted-environment-key "$GATE_PUBLIC" \
  --signing-key "$COLLECTOR_PRIVATE" \
  --output artifacts/cutover/shadow.json
```

The `Coordinator Pilot Load` workflow runs both the paired differential
profile and the component profile. Scheduled runs import
`scheduled/report.json` as differential evidence and
`component-scheduled/report.json` as load evidence and emit unsigned hashed
reports. Pull requests and test jobs cannot obtain OIDC or signing secrets.
The protected signer verifies successful-job hashes, then attests and
keyless-signs the reports. The importer re-derives load
coverage from the named executable commands and their exit codes; a report's
own coverage booleans are not authoritative.

Collect a dedicated-canary or production snapshot. There is no traffic
percentage argument and no query or `psql` override:

```bash
env -u DATABASE_URL -u EIGENINFERENCE_DATABASE_URL \
python3 scripts/cutover-readiness.py collect-live \
  --environment production \
  --base-url https://api.darkbloom.dev \
  --ops-read-key-file "$OPS_READ_KEY_FILE" \
  --public-key-file "$PUBLIC_READ_KEY_FILE" \
  --datadog-site "$DATADOG_SITE" \
  --datadog-api-key-file "$DATADOG_API_KEY_FILE" \
  --datadog-application-key-file "$DATADOG_APP_KEY_FILE" \
  --rds-dsn-file "$RDS_READONLY_DSN_FILE" \
  --rds-writer-endpoint "$RDS_WRITER_ENDPOINT" \
  --minimum-provider-version 0.7.5 \
  --window-start 2026-07-12T09:45:00Z \
  --window-end 2026-07-12T10:00:00Z \
  --environment-manifest artifacts/cutover/environment.json \
  --trusted-environment-key "$GATE_PUBLIC" \
  --production-read-only-ack "READ-ONLY PRODUCTION EVIDENCE" \
  --signing-key "$COLLECTOR_PRIVATE" \
  --output artifacts/cutover/live.json
```

`build-bake` accepts signed live reports whose 15-minute Datadog buckets and
RDS interval are identical. Windows must tile the bake exactly: overlaps,
gaps, mixed interval sizes, duplicated reports, and trailing-window summation
are rejected. Policy enforces minimum samples and distinct RDS job IDs,
latency/error budgets, zero pending durable states, and one unchanged commit.
The 90-day bake also requires zero Go database/background/financial writes,
sessions, ownership epochs, and unknown ownership epochs. It verifies enabled
trigger state, exact `pg_get_triggerdef`/`pg_get_functiondef` hashes, and
manifest-pinned owner/table coverage including ownership history.

## Assess and approve

Assess one gate with exactly its reports and direct predecessor
authorizations. For `full-cutover`, target binding is mandatory:

```bash
python3 scripts/cutover-readiness.py assess \
  --gate full-cutover \
  --report artifacts/cutover/canary-live.json \
  --prior artifacts/cutover/dedicated-canary.authorization.json \
  --prior artifacts/cutover/rollback-drill.authorization.json \
  --commit "$FULL_COMMIT_SHA" \
  --candidate-image "$RUST_IMAGE_DIGEST" \
  --fallback-image "$GO_IMAGE_DIGEST" \
  --signing-key "$GATE_PRIVATE" \
  --trusted-gate-key "$GATE_PUBLIC" \
  --trusted-evidence-key "$COLLECTOR_PUBLIC" \
  --output artifacts/cutover/full-cutover.assessment.json
```

Approval is deliberately two-step and interactive. CI/agents and non-TTY
sessions are refused. The first command writes the exact bytes for a hardware
or offline signer; it never reads an approver private key:

```bash
python3 scripts/cutover-readiness.py prepare-approval \
  --assessment artifacts/cutover/full-cutover.assessment.json \
  --approver operator@example.com \
  --approver-key-id "$APPROVER_KEY_ID" \
  --trusted-gate-key "$GATE_PUBLIC" \
  --trusted-approver-key "$APPROVER_PUBLIC" \
  --output artifacts/cutover/full-cutover.approval-request.json \
  --payload-output artifacts/cutover/full-cutover.approval.payload

# Example offline command; a hardware-backed equivalent is preferred.
openssl dgst -sha256 -sign "$OFFLINE_APPROVER_PRIVATE" \
  -out artifacts/cutover/full-cutover.approval.sig \
  artifacts/cutover/full-cutover.approval.payload

python3 scripts/cutover-readiness.py finalize-approval \
  --request artifacts/cutover/full-cutover.approval-request.json \
  --signature artifacts/cutover/full-cutover.approval.sig \
  --trusted-approver-key "$APPROVER_PUBLIC" \
  --output artifacts/cutover/full-cutover.approval.json
```

Release security creates a self-contained authorization. Each predecessor is
embedded recursively with its assessment and human approval, so deployment can
verify the complete chain from one artifact:

```bash
python3 scripts/cutover-readiness.py authorize \
  --assessment artifacts/cutover/full-cutover.assessment.json \
  --approval artifacts/cutover/full-cutover.approval.json \
  --prior artifacts/cutover/dedicated-canary.authorization.json \
  --prior artifacts/cutover/rollback-drill.authorization.json \
  --policy deploy/cutover/gates.json \
  --signing-key "$GATE_PRIVATE" \
  --trusted-gate-key "$GATE_PUBLIC" \
  --trusted-approver-key "$APPROVER_PUBLIC" \
  --output artifacts/cutover/full-cutover.authorization.json
```

## Deployment boundary and rollback

`deploy-prod.sh` refuses a Rust deployment unless the full-cutover artifact
verifies against the fixed operator-host keys
`/etc/darkbloom/cutover/gate-public.pem` and
`/etc/darkbloom/cutover/approver-public.pem`. Verification occurs before any
remote command and is repeated immediately before migration/drain. It checks
gate/environment, signature, current
policy/version/hash, maximum age, complete predecessor chain, human approval,
full commit, and distinct immutable candidate/fallback image digests.
The gate and approver trust sets must be disjoint, and every embedded
assessment check must be an explicit pass.

The rollback workflow verifies the signed environment target and pulls its
exact distinct immutable pair. The unprivileged rehearsal emits unsigned
hashed evidence; the protected signer later verifies, attests, and
keyless-signs it. The rehearsal starts and health-checks Go, drains and stops it,
migrates additively, starts and health-checks Rust, injects a hard failure,
runs Go `rollback-check`, exercises v1/historical terminal-ACK recovery, and
starts and health-checks Go again. It labels and checks owners so no two serving
containers share its database. Health responses report the signed
`environment_id`, source revision, and immutable image digest; Docker inspect
metadata must agree. Docker uses only those pre-pulled authorized digests with
`--pull never`.

On a production failure, preserve the sole fenced owner and follow
[`coordinator-incident-response.md`](coordinator-incident-response.md). Never
edit timestamps, recalculate a checksum after editing evidence, substitute an
image, or bypass quiescence.
