# Autopilot shadow evidence and calibration

> Last updated: 2026-10-07

Production shadow control was healthy but rarely proposed a placement in the
retained runtime window. Read-only request data and executable policy probes
identify output-work estimation and multi-shape valuation as concrete improvement
targets; they do not establish a missed safely executable production action or
measured Autopilot gains. The proposed sequence is in the
[quality improvement plan](../design/autopilot-quality-improvements.md).

## Scope and provenance

| Evidence | Scope |
|---|---|
| Production identity | Coordinator 0.9.18, `f57a671856bd7a9dd3646e0c77db6ef46751c854`; healthy at the October 7 reads; container started 03:50:20Z |
| Runtime observations | October 7, 19:01:05.862Z through 19:54:56.230Z: complete captured current Docker-log snapshot, not the whole process lifetime |
| Demand rollups | Day: October 6 19:00Z through October 7 19:00Z; week: September 30 19:00Z through October 7 19:00Z; half-open UTC windows |
| Logical requests/output | October 7 13:00-13:05Z and 19:10-19:15Z by request `received_at`, with one-minute field-presence and query-cost probes first; five-minute calibration extracted at 19:58:26Z and 19:57:38Z respectively |
| Fleet/cold-wait samples | October 7 16:20-16:25Z and 19:10-19:15Z; fleet uses `sampled_at`, profiles use `created_at`, not request arrival; slot samples collapsed by session and sample time before device-level comparisons |
| Operation ledger | All retained rows as of October 7 19:55:02Z; first retained decision October 2 02:25:42Z |
| Local policy probes | Go 1.26.8 against actual production policy functions; audited math unchanged between deployed `f57a671856` and local base `52b8384830f0f8c10cc031ad3178775ffce3fa05` |

Analytical queries used the existing Cloud SQL read replica through a local
authenticated proxy. Every capture verified `pg_is_in_recovery()=true` and
`transaction_read_only=on`, with a 15-second statement timeout, one-second lock
timeout, and no parallel query workers. Primary access was limited to bounded
schema/index metadata inspection while replica connectivity was established.
No production configuration, database rows, services, provider state or traffic
were changed, and no inference requests were generated.

The largest measured analytical query took 12.826 seconds. Exact queries,
connection/time metadata, aggregate outputs and executable synthetic probes are
retained outside Git in the local `autopilot-research-20261007` directory under
the approved OpenCode temporary directory. They contain no credentials, prompt
content, raw request/provider/account identifiers or key hashes.

| Artifact family | Contents and limits |
|---|---|
| `queries-demand.py`, `demand-*.jsonl` | Twelve named bounded query definitions, ten captures; requested/observed output, logical outcomes, day/week rollups and evidence-presence counters |
| `queries-fleet.py`, `fleet-*.jsonl` | Ledger, fleet, cold-wait and identity aggregates. Use `fleet-machine-census-complete.jsonl`; the first census is explicitly output-truncated. `fleet-snapshot-1910.jsonl` omits a version cross-tab, not the reported tick/model/gate aggregates |
| `runtime-readonly.py`, `runtime-metadata.json`, `runtime-observations.json`, `runtime-findings.md` | Bounded streaming log collection, fragment reassembly, runtime configuration and timing evidence |
| `policy-audit.go`, `policy-audit.md` | Executable assertions using public production policy, complete results and source fingerprints; synthetic, not a replay of production |

The demand-query module SHA-256 is
`19690563df403d249d3158c2ec0833cbb9d994a0187f718bc16a264921217f18`.
Repeated policy-probe JSON SHA-256 is
`187b927726473e34f8f7e2ee3be62bb25b60b4efe7058658aeeee8568f1357c0`.
The exact probe Git blob is `117234e623ef3b15307806de28a110846dee955b`;
fingerprinting did not write a Git object or commit.

## Controller activity

Both explicit runtime overrides were true: `EIGENINFERENCE_AUTOPILOT_ENABLED`
and `EIGENINFERENCE_AUTOPILOT_OBSERVE_ONLY`. Other inspected controls used their
source defaults. The authenticated admin read at 19:54Z reported running and
not paused.

| Runtime signal | Observation |
|---|---|
| Ticks | 323, from 19:01:13Z through 19:54:53Z |
| No-proposal ticks | 321 |
| Proposal-positive ticks | One proposal at 19:44:43Z and one at 19:53:53Z, using log-completion timestamps |
| Shadow safety | Every tick reported shadow, zero issued commands, zero pending and zero uncertain Autopilot operations |
| Planner population | `opted_in` 259-267 connected nodes, not unique machines |
| Duration | 239.825-541.995 ms; none over one second |
| Cadence | Completion spacing 9.776-10.173 seconds; no gap over 15 seconds |
| Warning/error records | No Autopilot ledger, command-write or watchdog warnings in this retained span |

The principal 292-tick segment had duration p50/p95/p99 of
320.010/416.358/476.172 ms. Quantiles from the separate 31-tick prefix were not
combined as though they were raw samples. Tick duration includes locking,
persistence, renewal, snapshot creation and planning, not just policy CPU time.

All target tick messages were split into Docker fragments; the collector
reassembled them before parsing. There were zero incomplete target records or
parse errors. A 512 MiB tail scan plus only the unread prefix consumed about
593 MB total IO. No rotated sibling files were present. This does not rule out
other observability sinks or establish why earlier file history was absent.

## Decisions are not executions

The retained ledger had **31 rows across 23 provider sessions**, all phase
`proposed`, reason `demand`, and additions with empty unload sets. Ten first
decisions across eight sessions fell in the last 24 hours at the database read.
No `reserved`, `started`, `succeeded`, `failed` or `uncertain` rows were retained.

| Target | Retained distinct proposals |
|---|---:|
| Qwen3.5 9B | 11 |
| Ternary Bonsai 2 27B | 8 |
| GPT-OSS 20B | 5 |
| Qwen3.5 35B A3B | 4 |
| Qwen3.8 27B MTP | 2 |
| Nemotron 3.5 Lightning | 1 |

Proposal identity omits time, capacity sequence and benefit changes. Repeated
unchanged proposals keep their first timestamp and score; ledger counts are
not proposing-tick counts. The controller's current `proposed=0`, in contrast,
means planning returned no action or its action budget was suppressed. The
19:54 admin response preceded persistence of the 19:53 proposal, explaining its
nine recent events versus the later database count of ten.

Sources: `coordinator/internal/registry/autopilotledger/proposal.go` (`ProposalID`),
`coordinator/store/postgres/autopilot.go` (`RecordAutopilot`), and
`coordinator/internal/registry/autopilotcontrol/controller.go` (`Controller.Tick`).

## Qualified request history

The revision-aware public-demand rollup contained rows in every requested clock
hour. Outcome partitions reconciled within the retained rows; this is not proof
of lossless collection, upstream receipt, or complete traffic coverage.

| Window | Hours with rows | Included requests | Excluded records | Unknown outcomes |
|---|---:|---:|---:|---:|
| Day | 24/24 | 6,074,278 | 9,030 | 7,249 |
| Week | 168/168 | 35,724,426 | 42,694 | 63,765 |

Collection epoch metadata began September 27 at 04:44:03Z. Public-demand scope
is not identical to Autopilot scope: for example, the former can classify
`routing_saturated` as a capacity rejection while Autopilot excludes it.
Hourly records retain requested public model IDs; dominant Gemma and GPT series
are `gemma-4-26b-a4b-it` and `openai-gpt-oss-20b`, not the resolved build IDs used
below. Aliases were not silently merged.

MiMo's recorded public series had **41.69% HTTP 429 over the day** and
**53.46% over the week**. The week contained 1,188,045 included MiMo requests.
Its highest selected pressure hour, October 5 at 16:00Z, had 50,702
supply-related outcomes among 53,573 included requests. These classifications
include causes that adding a resident model cannot necessarily resolve.

Sources: `coordinator/store/postgres/model_demand_series.go`,
`coordinator/internal/observation/outcomes/public_demand.go` (`PublicDemandOutcome`),
and [request-accounting semantics](../architecture/request-accounting.md).

## Expected work versus output limits

Calibration starts with completed, explicit-public, conflict-free logical
requests, identifies one successful winning attempt, and joins its route by
both request ID and attempt. All completed target cohorts below had a usable
route and output count; no ambiguous winners, model mismatches or calibration
bins were omitted. This conditions on completion and does not invent the
counterfactual output of a failed request.

| Exact resolved model | UTC window | Completed requests | Mean requested maximum | Mean observed output | Ratio of sums |
|---|---|---:|---:|---:|---:|
| `gemma-4-26b-qat-4bit` | 19:10-19:15 | 20,453 | 2,448.27 | 102.46 | 23.90 |
| `gemma-4-26b-qat-4bit` | 13:00-13:05 | 16,618 | 4,577.93 | 76.37 | 59.95 |
| `gpt-oss-20b` | 19:10-19:15 | 5,286 | 23,697.96 | 536.21 | 44.20 |
| `gpt-oss-20b` | 13:00-13:05 | 5,780 | 22,966.01 | 477.73 | 48.07 |
| `qwen3.6-35b-a3b-vl-mtp-mxfp8` | 19:10-19:15 | 585 | 4,636.13 | 655.43 | 7.07 |
| `qwen3.6-35b-a3b-vl-mtp-mxfp8` | 13:00-13:05 | 449 | 5,073.01 | 704.62 | 7.20 |
| `mimo-v2.6-flash-mopd` | 19:10-19:15 | 367 | 17,545.00 | 594.58 | 29.51 |
| `mimo-v2.6-flash-mopd` | 13:00-13:05 | 384 | 31,916.04 | 295.48 | 108.01 |

The dominant GPT short-prompt, large-limit, text/no-tools band is especially
informative. At 19:10-19:15Z, 1,751 completions with estimated prompts 65-256
tokens had a mean requested maximum of 32,768 but averaged **56.19** output tokens, with output
p50 **21** and p90 **67**. The ratio was **583.20**. The comparison window had
2,199 such completions, mean output 76.45 and ratio 428.62. These dimensions do
not reconstruct every hard-trait/SLA component of an Autopilot shape.

The current code first learns observed output after sufficient completions,
then `withLiveDemand` raises that estimate to the largest live requested cap.
`ModelFit` prices service using this enlarged output but separately preserves the
requested cap for KV feasibility. An executable probe using nine observations
across three buckets reproduced expected output **100 -> 8,192** and
**100 -> 32,768**, while the observed service reference remained ten seconds.
The real tracker and live-demand functions were called; the historical input
map and logical-request count were unchanged.

This confirms an estimation inconsistency and substantial requested/observed
differences in production traffic. It does **not** measure a 583-fold speedup,
prove how frequently the live overwrite affected a particular tick, or justify
reducing the token-admission envelope.

Sources: `coordinator/registry/autopilot/demand.go` (`DemandTracker.Snapshot`),
`coordinator/registry/autopilot/live_work.go` (`withLiveDemand`), and
`coordinator/internal/registry/autopilotcontrol/fit.go` (`ModelFit`).

## Multi-shape valuation probe

A second deterministic fixture uses four sustained compatible shapes of one
cached model, an empty eligible recipient, adequate memory/slots and an existing
resident satisfying the warm floor. The recipient's synthetic measured fit is
0.07 RPS per shape and its load cost is 30 seconds. `NodeContribution` correctly
divides one device into 0.0175 RPS per shape.

The real `Plan` returns no action at the default 30-second minimum benefit.
Changing only the diagnostic fixture threshold to zero returns the same demand
addition with benefit **17.25 seconds**, showing that other gates are feasible.
One-shape and higher-rate controls return additions at the unchanged threshold.

```text
Current single-shape net = 0.0175 * 10 * (300 - 30) - 30 = 17.25
Combined-model comparison = 4 * 0.0175 * 10 * (300 - 30) - 30 = 159
```

The second value is explicitly a counterfactual valuation, not the four-shape
planner's result. The probe establishes a scoring blind spot without changing
donor safety. It is not a replay of an observed production machine or a measured
159-second customer improvement.

Source: `coordinator/registry/autopilot/planner.go` (`Plan`) and
`coverage.go` (`NodeContribution`) in the same directory.

## Actual supply and load evidence

| Fleet observation per sample | 16:20-16:25Z | 19:10-19:15Z |
|---|---:|---:|
| Provider-session samples | 1,170-1,178 | 1,184-1,194 |
| All observed work counters zero | 563-649 | 572-635 |
| Counter-zero plus a generic-eligible warm slot | 198-278 | 206-278 |
| Heartbeat age over 90 seconds | 0-5 | 0-4 |
| GPT-OSS warm positions | 332-334 | 337-340 |
| GPT-OSS generic-eligible positions | 66-109 | 43-97 |
| GPT-OSS eligible positions on wholly counter-zero devices | 0-2 | 1-2 |
| MiMo warm positions | 12-13 | 15 |
| MiMo generic-eligible positions | 1-12 | 0-11 |

Slot observations were collapsed before describing device work. These counts
are not Autopilot actionability: the generic gate uses a fixed text probe,
heartbeat age is not capacity-sample age, and the snapshots omit consent, pins,
no-eviction headroom, exact load history and some local/pending work. Model
positions must not be added as independent GPUs. Raw warm counts substantially
overstate usable coverage in these samples.

Only six valid cold-flagged request waits were retained across the two
five-minute profile creation windows. Ordinary successful attempts are sampled,
and `created_at` does not align profiles to the logical arrival cohorts: the
19:10-19:15Z capture includes requests received as early as 17:46:29Z.
The two successful waits were 5.765 and 6.079
seconds on different model/hardware combinations. These are conditional attempt
waits, potentially shared by several requests, not independent model-load
measurements or a basis for replacing the 30-second load prior.

At 19:58:51Z the recent-open inventory associated 1,191 sessions with 1,185
database machine records. Historical assurance was hardware-verified for 757
sessions, key-bound for 408 and provisional for 26. Neither those associations
nor the assurance labels establish current verified live cohort eligibility.

Sources: `coordinator/registry/fleet_sample.go`,
`coordinator/store/postgres/profiles.go`, and
`admin-ui/src/lib/queries/app-attest.ts` (`appAttestMachines`).

## What no-op ticks do not establish

Every sampled tick had a deficit row with `eligible_idle > 0`, but no safe missed
production action is proven. That count includes already-resident targets and
precedes donor, victim and benefit checks. The whole-device donor gate is an
intentional safety boundary: loading temporarily removes retained models too.

Legacy warm-pool control was active while Autopilot shadowed. Its overlapping
per-model pending-load-or-cooldown buckets were frequently positive, but those
buckets are not the exact global `LegacyPending` count used to cap Autopilot's
action budget. The latter, per-tick ledger readiness, remaining budget, individual
candidate vetoes and benefit components were not present in inspected tick
records. A zero-proposal tick therefore cannot be assigned a dominant cause from
these summaries alone.

The prior logical window also retained 108 public rows with no resolved model,
unfinished handlers and incomplete attempt evidence at extraction. They are not
included in known-build completion denominators and prevent a blanket claim of
complete period accounting.

Exact historical replay additionally needs consent/state revisions, pins,
capacity sequences and freshness, actual and hypothetical permissions, complete
load allowances, pending operations, timing identities and catalog constraints
from the same tick. The inspected relational schemas do not retain that full
Autopilot input. A live canary remains necessary to measure completed-request
effects and actual operation recovery, not merely higher proposal counts.

## Related

- [Proposed quality improvements](../design/autopilot-quality-improvements.md)
- [Current Autopilot mechanism](../architecture/model-autopilot.md)
- [Machine-cohort operation and recovery](../operations/model-autopilot.md)
- [Earlier capacity and 429 evidence](2026-09-11-autopilot-capacity-evidence.md)
