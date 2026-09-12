# Model autopilot rollout and rollback

> Last updated: 2026-09-11 · commit `c7fda9228`

Use this runbook to validate, observe and gradually activate model residency
control on explicitly enrolled providers. It describes operator procedures;
no production activation, provider enrollment or rollout is recorded as executed
by this document.

## When to use

Use after the compatible coordinator and provider changes have passed their
release checks. The [architecture](../architecture/model-autopilot.md) explains
ownership and failure behavior; the [evidence report](../reports/2026-09-11-autopilot-capacity-evidence.md)
explains why fewer 429s cannot be assumed from more resident copies alone.

## Prerequisites

- Review the exact coordinator/provider build identities and protocol support;
  provider version alone does not establish autopilot consent.
- Validate on the [dev environment](dev-environment.md) first. Production
  deployments, configuration changes, traffic changes and fleet restarts require
  explicit human approval for the specific operation under
  [coordinator deployment](coordinator-deploy.md) and
  [provider release](provider-release.md).
- Use a small operator-owned or consenting provider set with known cached
  primary builds and any configured MTP assistants. Record existing resident
  models, local-work expectations, pins and current idle policy.
- Preserve a timestamped logical-request baseline by model and prompt shape:
  429 reasons, final-stream completion, first-content/decode quality, retry
  amplification and current eligible capacity. Keep exact/broad short-input
  cohorts separate from a claim that traffic is abusive.

## Steps

1. **Validate the code and failure paths locally.** Run the focused suites and
   applicable provider tests described in the developer workflow:

   ```bash
   go test ./coordinator/registry ./coordinator/api ./coordinator/protocol -run Autopilot -count=1
   go test -race ./coordinator/registry ./coordinator/api -run Autopilot -count=1
   ```

   Include opt-out parity, stale/paired heartbeats, duplicate/expired commands,
   ambiguous delivery, whole-device busy guards, pins/dwell, assistant cache,
   donor floors, tool-choice/grammar capability gates, partial load failure and
   release-policy serialization. Passing
   these checks does not authorize a production rollout.

2. **Prepare a shadow coordinator configuration.** Through the approved
   environment/deployment workflow, set:

   ```dotenv
   EIGENINFERENCE_AUTOPILOT_ENABLED=true
   EIGENINFERENCE_AUTOPILOT_OBSERVE_ONLY=true
   EIGENINFERENCE_AUTOPILOT_ALLOW_IDLE_UNLOAD=false
   ```

   Settings are read at startup, not hot-reloaded. Leave action limits and
   conservative timing priors at the
   [documented defaults](../reference/configuration.md#model-autopilot) initially.

3. **Enroll only the chosen providers.** Inspect configured consent first:

   ```bash
   darkbloom autopilot status --json
   darkbloom autopilot enable --min-dwell-seconds 1800 --pin MODEL_TO_RETAIN
   darkbloom restart
   darkbloom autopilot status
   darkbloom status
   ```

   Substitute an actual model ID for `MODEL_TO_RETAIN`, or omit `--pin` when
   none is required. The flag replaces the saved pin list when supplied;
   [CLI reference](../provider/cli-reference.md#darkbloom-autopilot) describes
   configuration and pin removal. `status` reports saved configuration, not
   proof that the coordinator accepted a live heartbeat. Verify live consent
   and the paired capacity/residency state in coordinator/provider logs.

   Enrollment pauses the provider idle timer and delegates cold network loads
   to autopilot even during shadow mode. With no active controller, only already
   warm models receive network work. Preserve sufficient manual capacity while
   observing the canary.

4. **Inspect shadow plans over representative traffic.** Read coordinator
   `model autopilot tick` logs: `observe_only`, `opted_in`, `pending`, `uncertain`,
   `proposed`, `issued`, `excluded`, and per-model offered/ready/future capacity,
   useful warm count, eligible idle candidates, protected floor and deficit.
   `issued` must remain zero. Compare predicted victims and deficits with actual
   cached inventory, live occupancy and hardware eligibility; do not count
   hypothetical future placements as measured capacity.

5. **Activate a bounded canary after review.** Apply the approved coordinator
   change to `EIGENINFERENCE_AUTOPILOT_OBSERVE_ONLY=false` and restart through the
   deployment runbook. Keep the enrolled set small and standalone idle unloading
   disabled. Change one dimension at a time: enrollment, action limits and
   surplus-unload policy should not widen together.

6. **Expand only after complete command reconciliation.** Observe enough load
   and unload cycles to cover genuine deficits, quiet periods and failures.
   Require stable donor coverage and acceptable per-model completion/latency,
   not just a better aggregate throughput number. Optional standalone unloading
   requires a separate reviewed change to
   `EIGENINFERENCE_AUTOPILOT_ALLOW_IDLE_UNLOAD=true`; first verify its quiet,
   pressure, dwell, pin and floor conditions.

## Verification

| Check | Expected evidence |
|---|---|
| Consent boundary | Manual/private providers receive no autopilot command; advertising all models alone does not enroll them. |
| Command lifecycle | A command ID names the complete expected resident set and explicit victims; its terminal acknowledgement is followed by a newer accepted capacity sequence carrying the same terminal ID and matching actual residents. |
| Resource safety | No busy/pinned eviction, no implicit LRU victim, no unplanned primary/assistant download; donor capacity remains sufficient through the whole device transition. |
| Recovery | Same-ID retransmission remains bounded; expired unseen commands fail safely; uncertain operations remain fenced rather than becoming optimistic capacity. |
| Release independence | Desired-build reconciliation resumes after an autopilot owner; explicitly superseded residents clean up without dropping supported co-residents or violating local ownership. |
| Network outcome | Compare model/shape-matched logical completions, first-content/decode quality, 429 reasons and attempts per request against the timestamped baseline; retain external traffic and cohort changes as confounders. |
| Churn and overhead | Review load/unload count, failures, pending age, candidate exclusions, tick duration and registry/routing latency alongside any apparent capacity gain. |

The coordinator emits `provider.model_autopilot_status` by status and
`provider.model_autopilot_status_rejected` for rejected acknowledgements
(`coordinator/api/provider.go`). These count messages, including retransmission
responses; they are not unique successful placement counters. Use command IDs
and paired heartbeat reconciliation for completed operations. `AutopilotSnapshot`
is a registry accessor; this change does not add a public autopilot HTTP endpoint.

Local synthetic 1,000-provider benchmarks are described in the
[architecture](../architecture/model-autopilot.md#failure-modes-and-estimation-limits).
They are not a production tail-latency gate. The historical website replay is
also not proof of production 429 reduction.

## Rollback

1. **Stop new scheduling through the approved deployment workflow.** Set
   `EIGENINFERENCE_AUTOPILOT_OBSERVE_ONLY=true`, or disable
   `EIGENINFERENCE_AUTOPILOT_ENABLED`, and apply with the required coordinator
   restart. This stops future controller issuance; it is not a cancellation of
   a command already accepted by a provider.
2. **Reconcile operations already in progress.** Inspect provider command state
   and fresh actual capacity. Do not clear an uncertain fence merely because
   the acceptance deadline or watchdog elapsed. Retries preserve the original
   ID; a partial failure does not promise automatic restoration of all victims.
   If operator recovery requires a provider restart, authorize that specific
   action, preserve logs and verify the new session/resident snapshot.
3. **Revoke the selected provider's configured consent when appropriate.**

   ```bash
   darkbloom autopilot disable
   darkbloom restart
   darkbloom autopilot status
   darkbloom status
   ```

   This takes effect on restart, restores ordinary idle-policy ownership and
   leaves model files on disk. A disabled coordinator alone does not revoke
   provider consent or restore legacy cold-load behavior on enrolled providers.
4. **Verify baseline behavior and capacity.** Check live consent, no new command
   issuance, actual warm/idle slots, donor coverage and logical request outcomes.
   Roll back binaries separately only under the release/deployment procedures.
