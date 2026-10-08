# Evidence-led Autopilot quality improvements

> Last updated: 2026-10-07

Status: **Proposed** - 2026-10-07 - production read-only evidence and synthetic policy probes support the sequence below; no policy improvement or live benefit is claimed as deployed.

Improve completed-request service by correcting workload estimates and placement
valuation, making rejected decisions explainable, and measuring bounded live
operations. Retain the existing execution and safety machinery rather than
replace it with a new scheduler. The [measurement record](../reports/2026-10-07-autopilot-shadow-evidence.md)
contains exact windows, denominators, limitations and source fingerprints.
Machine-cohort authorization is separate implementation work described in the
[current architecture](../architecture/model-autopilot.md#machine-selected-live-control).

## Objective and non-goals

The objective is more completed qualified logical requests within first-content
requirements, without degrading donor coverage, local work, reliability or memory
safety. Proposal count, resident-copy count, tokens reserved and command success
are diagnostics, not the optimization objective.

Do not change provider consent, auto-download models, admit against average
output instead of the requested KV envelope, reduce OS/activation/KV safeguards,
weaken trust or donor protection, or infer successful delivery from HTTP 200.
Do not combine live rollout with pricing, reward, provider-version or numerical
model-policy experiments. Existing tests and telemetry are substantial; extend
their specific missing decision inputs rather than introduce a parallel stack.

## Prioritized sequence

| Order | Work | Evidence | Acceptance gate |
|---|---|---|---|
| 1 | Separate expected service work from admission limits | Completed output was 7-108 times below requested limits across model/window averages; a dominant GPT band differed by 583 times; real policy probes reproduce the live overwrite | Historical output survives live/queued projections; requested envelope and all admission tests remain unchanged; calibration error improves on held-out windows |
| 2 | Explain no-op decisions and preserve bounded replay inputs | 321 of 323 ticks proposed nothing; exact legacy budget and candidate vetoes are absent | Every no-op distinguishes suppressed planning from evaluated rejection; deterministic captured-input replay reproduces the original decision |
| 3 | Value the complete placement across compatible shapes | Real four-shape policy fixture rejects 17.25-second per-shape net despite a 159-second combined-model comparison | Shared GPU work counted once, shared load cost charged once, all affected-model losses priced, and donor/memory invariants unchanged |
| 4 | Learn load-to-ready cost and qualify execution failures | Only six conditional cold-wait profile samples; zero live Autopilot outcomes in retained ledger | Exact-build timing coverage and uncertainty are visible; preflight and post-victim failures are tested with actual provider execution |
| 5 | Target workload-compatible useful supply | GPT had 337-340 resident positions but 43-97 generic-eligible positions in sampled ticks; MiMo has high recorded rejection pressure and little observed warm supply | Candidate diagnosis distinguishes missing inventory, hardware/KV mismatch, queueing and intrinsic deadline misses; no invented placement recovery |
| 6 | Measure a controlled live cohort, then expand | Shadow is stable but supplies no actuator or causal outcome evidence | Cohort isolation and recovery pass; enough actual operations and qualified traffic support safety and outcome evaluation |

Orders 1 and 2 can proceed in parallel in shadow. A small execution canary can
qualify the existing actuator once cohort isolation and exact-build recovery
checks pass; it need not wait for proof of performance uplift. Expand or change
policy only with the corresponding calibration and outcome evidence.

## 1. Separate expected work from reservations

Keep `RequestedMaxTokens` and tail prompt bounds as the hard routing/KV
envelope. Keep expected generated output as a distinct service estimate. A live
request must update occupancy and its hard requirements without replacing
measured expected output for every request in its shape.

Start with the existing bounded per-shape history and conservative sparse-data
prior, not an additional learning service. Preserve explicit counts, age and
provenance so unknown data is not treated as measured. Evaluate censored
limit-ending completions and survivor bias separately; failed requests do not
come with known hypothetical completion lengths. Keep request-size bins,
capability/SLA separation and logical-arrival deduplication.

Change scope: `coordinator/registry/autopilot/live_work.go` (`withLiveDemand`),
`demand.go` (`DemandTracker`) in the same directory, and
`coordinator/internal/registry/autopilotcontrol/fit.go` (`ModelFit`) only where
the service/admission distinction needs to be explicit.

Validation should reproduce the nine-completion/one-live-request regression,
queued and occupancy-only requests, sparse history, cancellations, output-limit
and prompt-bin boundaries, and mixed deadlines. Compare predicted service and
useful capacity with held-out model/hardware/workload observations. Do not turn
the 583-times token ratio into a capacity or latency forecast.

## 2. Explain decisions before relaxing policy

Add bounded tick-level diagnostics for `legacy_pending`, remaining operation
budget, pause and ledger readiness. Report whether planning ran. Keep candidate
vetoes and score terms in closed aggregate categories: nonrecipient, missing live
grant, busy/pending, already resident, incompatible shape/deadline, donor floor,
donor work, infeasible victims/headroom, dwell/pins, and insufficient benefit.
Do not label a later gate as the cause when it was never evaluated.

Expose gross recovered-work value, load/switch cost, retained-model cost and
scarce-compatible-capacity cost for a bounded set of considered alternatives.
Existing proposed-event deduplication should remain an operation-history
contract, not be repurposed as a complete decision trace.

Capture a bounded, content-free detached planner input for selected diagnostic
ticks. Include every donor required to reproduce the decision, actual versus
hypothetical permissions, immutable configuration/catalog identity, demand
history versus live occupancy, freshness/sequence, pins, headroom, pending work
and timing provenance. Use access-controlled pseudonymous correlation, not raw
consumer/request identifiers. Mark oversized or incomplete captures as
non-replayable; silently truncating donors invalidates the comparison.

Reuse the pure `autopilot.Plan`, `Coverage` and existing simulation/testing
patterns. Replay must reproduce the baseline no-op before comparing alternatives.
Any claim of useful recovery additionally needs demand after load completion and
credible load-to-ready timing. A modelled alternative is not an observed gain.

Do not raise concurrency limits or disable legacy warming because its
pending/cooldown telemetry is nonzero. First measure the exact shared budget and
whether useful Autopilot plans are actually starved.

## 3. Score a placement, not one shape

Use one candidate post-placement resident set and its shared-device contribution
to value all affected compatible workloads. Cap each credited recovery by that
workload's unmet need; price lost service on retained or removed models and
charge load/cache destruction once. Do not sum independent per-shape GPU
capacities or credit the same recovered request repeatedly.

The four-shape synthetic fixture is a regression seed, not a tuned production
constant. Add variants with asymmetric shape demand, donor pressure, retained
co-residents, slow recipients, pending operations, floor repair and no positive
net gain. More bins for the same workload should not multiply a shared fixed
cost or create capacity.

The existing restricted-capacity penalty is applied per unmet restricted fit,
including separate shapes of one model. Audit this alongside full-placement
valuation: scarcity protection remains intentional, but charge a defensible
device opportunity cost rather than an accidental count of bins. Change it only
after replay shows the corrected valuation and preserves restricted workloads.

The whole-device transition donor check remains a hard constraint. Correct
pessimistic work estimates before interpreting widespread donor rejection as a
reason to weaken that constraint.

## 4. Measure and harden execution

Use exact model/build/hash-matched load history, with measurement age, sample
coverage and separate release/load/terminal-heartbeat durations. Existing
provider history is a starting point, but latest-per-model local entries and
request-side cold waits do not supply a robust population load distribution.
Retain a conservative fallback when evidence is missing or stale.

Before an eviction-capable pilot, qualify target availability before any victim
is unloaded, then test post-victim load failure and resulting resident state.
At this review, [PR #1350](https://github.com/Layr-Labs/d-inference/pull/1350)
already proposed earlier rejection of unavailable Autopilot targets; inspect and
integrate reviewed work rather than duplicate it or assume it has shipped.

Exercise real cached addition, replacement, unload, optional-assistant fallback,
local/public work overlap, identity/lease changes, disconnect, process restart,
ledger failure and uncertain delivery. Existing unit tests and bootstrap E2E
remain valuable; they do not collectively prove every real-hardware recovery
case. No timeout, pause response or completed command alone proves rollback or
restored useful serving capacity.

## 5. Focus on useful compatible capacity

Prioritize GPT service-estimate calibration and MiMo pressure diagnosis, while
retaining Gemma's high-volume impact. Classify a failed request as placement-
addressable only when a consenting cached machine can pass its actual hardware,
runtime, token, deadline, headroom and donor constraints and become ready in time.
Context-invalid requests and intrinsically infeasible first-content deadlines
need other remedies.

Use the existing measured model/hardware performance profiles, current shared
GPU work and validated local capacity, not chip generation or warm-copy count as
the primary ranking signal. Avoid broad TTL relaxation: observed stale liveness
was rare, and the historical fleet data lacks accepted-capacity-sample age.

If MiMo has too little compatible approved cached inventory, residency scheduling
alone cannot create it. Any inventory/download recruitment should remain a
separate explicit operator action. Publish that constraint rather than repeatedly
proposing impossible placements or auto-expanding consent.

## 6. Run a bounded live experiment

Start with five to ten explicitly consenting, verified machines selected by
canonical identity, plus comparable shadow observations. Keep membership stable
across reconnects, cap concurrent operations at one initially, and keep ordinary
shadow behavior outside the cohort. No global live fallback is acceptable.

Separate addition-only qualification from replacement/unloading. The existing
`ALLOW_IDLE_UNLOAD=false` setting does not disable replacement victims. Use
verified pin protection or a separately explicit restriction when additions
only are intended; do not describe the machine allowlist as that restriction.

Predeclare safety stop criteria: any outside-cohort command, consent/pin/memory
violation, unexplained protected-donor loss, uncertain operation or unreconciled
terminal state. Pause new work and inspect actual residency; do not clear an
uncertain operation or assume pause cancels accepted work. Preserve a durable
approved shadow configuration across restart because runtime pause is volatile.

For an initial 24-48-hour qualification window, inspect a meaningful set of
completed transitions, for example twenty, rather than graduating by elapsed
time alone. Too few feasible transitions is inconclusive. Measure logical
completion, first-content outcomes, timeout/capacity rejection, local-work
interference, donor coverage, churn and load-to-ready prediction error.

Use the existing request-outcome completion contract and retain unknowns,
in-progress records, sink loss, version and sample denominators. Stable cohorts
share queues and donor capacity; provider-level comparisons have routing and
spillover interference. Treat the first canary as safety and directional outcome
evidence, not a clean causal A/B test. A later efficacy experiment needs an
explicit traffic/interference design and adequate request volume.

## Delivery boundaries

Keep policy calibration, decision diagnostics, valuation, execution fixes and
rollout promotion in separately reviewable changes. Each change ships meaningful
regressions, its canonical docs, the repository's dedicated refactor pass, and
final combined validation. Production deployment and cohort activation require
separate human approval; this plan authorizes neither.
