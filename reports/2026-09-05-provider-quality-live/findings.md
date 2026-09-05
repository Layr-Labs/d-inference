# Live baseline and first implementation

Observed September 5, 2026. Source base: `4d9811f7c240b37f2915a6475f8476d7db01340e`. Implementation branch: `codex/provider-service-quality`.

The original reputation audit used source and local reproductions. This follow-up independently queried production Datadog and the Cloud SQL physical read replica. It validates the need for accurate, scoped provider information; it does not validate proposed estimator constants or establish the production incidence of every local reproduction.

## Datadog: 18:07:31–18:37:31 UTC / 11:07:31–11:37:31 Pacific

Query: `sum:d_inference.inference.request_outcome_or_view{env:production,service:d-inference-coordinator} by {model,class}.as_count()`.

| Recorded request outcome | Count |
|---|---:|
| Success | 104,831 |
| Rate limited | 19,173 |
| Provider 5xx | 29 |
| Mid-stream failure | 60 |
| Timeout | 16 |
| Client gone | 890 |
| Client error | 26 |

There were 105 service-fault outcomes. Service success excluding rate limits is approximately 99.90%; completion yield including rate limits is approximately 84.47%. Both exclude client-gone/client-error outcomes. These are recorded metric events, not independent proof of complete telemetry or unique users. Rate limits include policy/quota refusals, so the 19,173 outcomes are not all avoidable capacity loss.

Qwen3.5-35B-A3B contributed 3,089 successes, 10,714 rate limits, 10 service faults and 670 client departures in this window. This warrants model-specific admission investigation; the current snapshot does not identify the cause of those refusals.

## Read-replica evidence and freshness

GCP identified the selected production replica as a running `READ_REPLICA_INSTANCE`. SQL independently confirmed `pg_is_in_recovery() = true` and `transaction_read_only = on`. Every query used a read-only transaction, 15-second statement timeout and one-second lock timeout. No primary database query or production mutation was performed.

At 18:39:07 UTC the last replay timestamp was 18:33:15 UTC, approximately 351 seconds behind. At 18:40:11 UTC the latest fleet snapshot was 18:33:05 UTC. Consequently those fleet observations are historical, not instant live state. A later bounded reputation sample reached a snapshot timestamp of 18:45:05 UTC; freshness changed during the investigation.

Using the latest record per session/model within the two-minute fleet-snapshot window:

- Gemma-4-26B: 318 rows passed the recorded plain-text probe; 219 of those reported zero running/waiting work. Another 35 rows failed `no_headroom`, and four failed `free_memory`.
- GPT-OSS-20B: 269 rows passed the probe; 131 reported zero running/waiting work. Twelve rows failed `private_text`.
- Qwen3.5-35B-A3B: 173 rows passed; 120 reported zero running/waiting work. Seven rows failed `private_text`, and four failed `no_headroom`.
- Provider-level records with no resident-model row included 157 `private_text`, 73 `trust_floor`, and 60 `untrusted` exclusions. Another 317 passed only the provider-level check; that does not establish model-specific capacity.

These are session/model observations, not unique physical-device totals across models. Idle reports and passing a small probe do not prove capacity for the actual workload or deadline. They do demonstrate why connected, idle, trusted, schedulable and receiving work must remain distinct descriptions.

A bounded, nonrandom sample of 20 session IDs at the latest snapshot had 20 reputation rows; seven had zero recorded jobs. Their cumulative rows totaled 105,898 jobs, including 575 recorded failures. These lifetime/session counters cannot be compared directly with the Datadog window and are not an unbiased fleet reliability estimate.

The broad oldest/latest-session comparison and a 20-device version each hit the 15-second statement timeout. They were not retried with relaxed safety limits. Production incidence of the stale-history restoration defects therefore remains unquantified; their deterministic local reproductions stand separately. Replica `pg_stat_user_tables` estimates were zero despite actual rows, so they were not treated as row counts.

## First implementation and remaining work

Implemented locally:

- Add an account-scoped `service_status` to the provider API, evaluated through normal scheduler gates for a stated 500-input/256-output plain-text probe.
- Report readiness/partial restrictions/capacity/draining and expiration separately from requests in progress. Do not claim that readiness means earning or that historical warnings imply a routing penalty.
- Show per-model gate reasons and correct the adjusted-latency label. Replace coarse restart/re-link advice with diagnosis.
- Preserve newest stored identity records regardless of iteration order; serialize/coalesce reputation writes per session.
- Copy backend slot slices into the response so later registry mutations do not alter an in-progress API snapshot.

Still proposed: latest stable history across same-process reconnects; unified attribution of synthetic failed attempts; complete durable device history; new reliability estimates and routing costs; bounded node recovery; provider wire/CLI status and comfort controls. The API observation does not change dispatch behavior, automatic recovery or payment policy.

## Evidence

`request-outcomes.json` preserves the Datadog response; `request-outcome-summary.json` contains per-series sums and exact query timestamps. `schema.jsonl`, `baseline.jsonl`, and `reputation-sample.jsonl` preserve content-free SQL results. `baseline.jsonl` contains successful earlier statements before the history query timed out. The `.sql` files and `query-replica.py` retain the read-only query contract. Credentials, prompts, output, raw serials, account IDs and request IDs are not included.

## Validation of the first implementation

- Full `go test ./coordinator/registry ./coordinator/api -count=1 -timeout=180s`: passed (registry 15.654 s; API 151.241 s).
- Focused race-detector tests for provider status, account-scoped API output, slot snapshot isolation, newest-session selection and reputation persistence: passed in both packages. The macOS linker emitted an `LC_DYSYMTAB` warning; the test process succeeded.
- Provider dashboard tests: 99 passed across 12 files, including automatic snapshot expiry while no new network response arrives.
- Console production build: passed. ESLint: zero errors, 75 warnings across the existing source tree.
- Documentation checks: 127 files passed, including the new design. `git diff --check`: passed.

These checks validate local source, not deployment. The live query results do not attest that production is running this exact source commit. The original audit artifacts are historical baseline evidence; the ordinary regression tests in this worktree are the acceptance checks for the fixes.

## PR preparation follow-up

Integrated newer master changes, preserving both changelog entries. Focused Go and documentation checks passed after the merge. The required pre-push hook passed its full Go suite, lint and Next.js build.

A clean standalone `tsc --noEmit --incremental false` found a missing `unknown` sort rank in the new grid status model; that entry is fixed. The remaining 13 type diagnostics reproduce on an archived master baseline with the same dependencies (matching diagnostic identity/counts, ignoring shifted line numbers). Existing diagnostics affect earnings fetch headers, RUM/Privy types, Vitest configuration and old test fixtures. Next.js is configured with `typescript.ignoreBuildErrors: true`; its successful build does not establish standalone type-check success.
