# Experimental Autopilot operation and recovery

> Last updated: 2026-10-01

Use this runbook to observe explicitly enrolled providers in shadow and prepare
a separately approved live rollout. Startup opt-in records interest/consent, not
activation; the coordinator defaults to shadow observation.

## When to use

Use with compatible protocol-2 coordinator and provider releases. See the
[architecture](../architecture/model-autopilot.md) for ownership and eligibility.

## Prerequisites

- Complete coordinator/provider validation and the normal release process.
- Already have eligible active network models downloaded. Enrollment verifies
  cached inventory but never downloads; see [provider setup](../provider/quickstart.md).
- Production deployment, configuration, traffic changes and fleet restarts
  require the specific approval described in [coordinator deployment](coordinator-deploy.md).
- Establish a comparable non-enrolled holdout and observation window. Compare
  qualified logical-request completion and first-content outcomes, donor
  capacity, local-work interference, churn and failures. Opt-in selection itself
  can bias comparisons; report cohort differences and denominators.

## Steps

1. Keep `EIGENINFERENCE_AUTOPILOT_ENABLED=true` and
   `EIGENINFERENCE_AUTOPILOT_OBSERVE_ONLY=true` (the defaults) for observation.
   Run `darkbloom start` and answer Yes to the experimental shadow-interest prompt
   to discover/verify all eligible downloaded active network models. There is no
   model picker or download, and saved model, preload, idle and other preferences
   remain unchanged. Empty eligible inventory fails before persistence or drain.
   Setup does not activate Autopilot, and unattended upgrades or missing settings
   do not enroll automatically.
2. Run `darkbloom autopilot status`. Confirm enrollment, the verified cached set and
   `shadow` (not activated) after a valid shadow lease. `waiting` means consent
   exists but no valid coordinator lease is acknowledged. In shadow, ordinary
   startup loading, cold loading and the configured idle policy remain in force.
   Cached inventory and hypothetical proposals are not proof of ready capacity.
   Freshness follows the configured heartbeat interval, so an intentionally
   slower daemon refresh does not appear as a missing live report.
3. Inspect authenticated `GET /v1/admin/autopilot`. It returns controller summary
   and up to 200 ledger events from the last 24 hours. In shadow verify
   `observe_only=true`, `issued=0`, and proposed rather than executed changes.
   Use the current summary for tick freshness: deduplicated unchanged decisions
   can age out of the recent events list ([ledger semantics](../architecture/storage.md#autopilot-operation-ledger)).
   Compare qualified demand and donor coverage with the holdout before requesting
   approval to promote. This does not establish causal production improvement.
4. After validation and explicit approval for the production configuration change
   and restart, set `EIGENINFERENCE_AUTOPILOT_OBSERVE_ONLY=false` using the
   [coordinator deployment procedure](coordinator-deploy.md). Verify
   `observe_only=false` in the controller summary and `active` only after a
   matching live lease acknowledgement. This startup setting applies to the
   eligible consenting population; it is not a per-provider mode command.
5. During live control, use `darkbloom autopilot pin MODEL_ID` or `unpin` to adjust
   selected-model protection. Use `pause` to retain ready models and stop new
   demand-based changes; `resume` resumes participation in the coordinator's
   current mode, never promotes shadow to live. Retired unadvertised models may
   still unload once unpinned and unused. `autopilot models` explicitly refreshes
   eligible downloaded network inventory through verification and safe drain/restart,
   without picker or downloads. Ordinary restarts retain the recorded set.
   Refresh/`enable` preserves an existing pause; use explicit `resume` to resume.
   An ordinary start fails before persistence/drain if any recorded build is
   missing, ineligible or cannot verify, including a transient manifest failure.
   Use an explicit inventory refresh only when pruning exclusions is intended.
6. Compare live intent and terminal residency with request outcomes, not just
   predicted benefit or issued counts. Provider status includes local resident
   models and the latest transition result.

The live planner chooses cached models for utilization; enrollment and rollout
are not an earnings guarantee. Newly downloaded catalog builds do not expand
consent until an explicit inventory refresh.

The action and operation bounds are in
[configuration](../reference/configuration.md#model-autopilot). Shadow control
leases report mode without granting residency ownership; shadow sends no
residency commands and creates no Autopilot routing reservations or fences.

## Verification

- Run `go test ./coordinator/...` and focused race tests for Autopilot and routing.
- Run `make provider-test` with the source-matched Metal library.
- Exercise expired/old-session commands, selection changes, opt-out during a
  transition, local/network work, protected donor floors, mixed shapes,
  optional-assistant fallback, partial failures and ledger unavailability.
- Verify shadow leases report `observe_only=true` and `active=false`, do not
  suppress the saved idle policy, and cannot authorize residency commands.
- Verify the exact released builds separately. Local tests and completed load
  commands do not establish production improvement.

## Rollback

1. Submit authenticated `POST /v1/admin/autopilot` with `{"paused":true}` to stop
   new reservations. Existing operations retain retries and reconciliation;
   pausing is not a reversal of already accepted work. Resume with
   `{"paused":false}`; this does not change observation/live mode.
2. To return the rollout to shadow, obtain approval to set
   `EIGENINFERENCE_AUTOPILOT_OBSERVE_ONLY=true` and restart through the deployment
   procedure. `EIGENINFERENCE_AUTOPILOT_ENABLED=false` disables the controller at
   startup instead. Neither startup setting is a runtime admin API mutation, nor
   proof that accepted work has reversed.
3. On a provider, run `darkbloom autopilot disable`. The daemon consumes the new
   revision at its next capacity poll, completes any accepted operation and
   restores its saved idle policy. Selected files remain downloaded.
4. Inspect actual resident sets and uncertain records. A failed operation may
   have released a model before failing to load another. Do not report rollback
   success until the resulting capacity is confirmed.

## Related

- [Autopilot architecture](../architecture/model-autopilot.md)
- [API contracts](../reference/api-contracts.md)
- [Provider release](provider-release.md)
- [Historical capacity evidence](../reports/2026-09-11-autopilot-capacity-evidence.md)
