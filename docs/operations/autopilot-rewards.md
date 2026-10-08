# Autopilot reward funding and recovery

> Last updated: 2026-10-08

Operate the separately funded daily inference-earnings floor for machines with
saved Autopilot consent. Use this runbook to inspect enrollment, approve an
absolute pool cap, repair missing baseline history and stop payments safely.

## When to use

Use after deploying a coordinator that implements `AutopilotRewardsStore` and
the [reward admin API](../reference/api-contracts.md#autopilot-reward-administration).
The [pricing reference](../reference/pricing-model.md#autopilot-rewards) is the
canonical policy; [billing](../architecture/billing.md#autopilot-rewards) explains
first-ever history limits. This is not an all-machine program or a live-controller
rollout. Ordinary base rewards remain independent.

## Prerequisites

- Explicit human approval for each production mutation: coordinator deployment,
  payment-flag change/restart, exact cap change and each historical baseline
  import. This runbook grants none of those approvals.
- A durable PostgreSQL coordinator and verified migrations 31 and 32, using the
  [schema migration procedure](schema-migration.md). Preserve all four new
  [financial tables](../architecture/storage.md#autopilot-reward-persistence) in
  database backups; existing accounting archive coverage cannot restore them.
  Migration 32 preserves frozen baselines and receipts; older declarations
  remain unqualified rather than gaining invented historical eligibility.
- The approved `COORDINATOR_URL` and an admin bearer credential in `ADMIN_TOKEN`;
  never place credentials or evidence in public logs, PRs or tickets.
- Separately released compatible providers reporting saved `consent_enabled`.
  The optional field does not upgrade installed providers. No provider version
  bump, publication, fleet restart or live-cohort activation is implied here.
- Passed isolated [reward tests](../developer/test.md#autopilot-rewards) for the
  exact candidate; no production accounts, credentials or database in tests.

## Steps

### 1. Inspect without funding

```bash
curl --fail-with-body \
  "$COORDINATOR_URL/v1/admin/autopilot/rewards?limit=100" \
  --header "Authorization: Bearer $ADMIN_TOKEN"
```

Follow `next_after` as `after` until absent. Confirm `enabled`, pool cap/spending
and `tracking_started_at`. For each machine, inspect `baseline_known`, `baseline_source`,
`history_conflict`, `first_opt_in_at`, `first_observed_at`, `opted_in`,
`observed_at` and `next_day`.
This list includes eligible durable offline enrollments; it is not the connected
inventory report. Listing may materialize a previously journaled declaration
once its session has a verified machine binding, but moves no money.

For `baseline_source="cohort"`, verify the cohort key, peer count, fingerprint,
anchor window and statistic in `baseline_evidence` under the
[cohort contract](../reference/api-contracts.md#autopilot-reward-administration).
It is the frozen fallback for a machine with shorter personal history, not a
baseline to replace once that machine matures. An empty comparable cohort keeps
the baseline unknown.

An absent row can mean no supported positive declaration or unresolved identity.
Do not use the current live `enabled`/`active` flags as historical consent proof.
The new pool starts at zero and the payment flag defaults off, as defined in
[configuration](../reference/configuration.md#billing-stripe-and-base-rewards).

### 2. Resolve missing first-ever history

For each `baseline_known=false` machine, obtain independent evidence of the true
first-ever opt-in instant and the attributed inference payout total for the exact
preceding window in the [policy](../reference/pricing-model.md#autopilot-rewards).
Include sponsored/promotional inference payouts; exclude base rewards and other
reward/referral income. Verify canonical machine and account ownership, original
time, interval boundaries and completeness of the earnings source.

First distinguish missing opt-in history from missing comparable earnings
evidence. A machine with a proven first-ever opt-in but shorter personal history
can receive an automatic cohort baseline under the
[cohort policy](../reference/pricing-model.md#autopilot-rewards). Unknown hardware
or no comparable mature peers does not authorize a zero baseline. Preserve the
original anchor while investigating; do not toggle consent to create a new one.

Old software never recorded the opt-in date. Deployment, reconnect, first-seen
time, current consent or an earnings export alone cannot prove it. An unbound old
session that never gained trusted machine identity cannot safely be attributed
to a reconnect. Leave the baseline unknown if either required source is missing;
do not invent zero, a common cutoff or a replacement enrollment date.

After a journal outage, establish which raw declarations actually committed.
The bounded retry queue is not durable: connection or process loss can discard
uncommitted declarations if storage never recovers. A receive timestamp or
pending-write log is not proof of preserved consent; follow the
[capture failure boundary](../architecture/billing.md#capture-failure-boundary).

If `history_conflict=true`, stop this baseline-import procedure for that machine.
Linked history contradicts the frozen anchor or invalidates an automatic baseline's
[history proof](../reference/pricing-model.md#autopilot-rewards), even though
`baseline_known=true`. Preserve the baseline, evidence, receipts and cursor, and
escalate for separately approved reconciliation. The ordinary baseline endpoint
still returns 409; neither another import, more funding nor toggling consent
resolves the hold. There is no automatic correction or clawback.

After specific approval, prepare `BASELINE_JSON` with exactly these fields:

```json
{
  "first_opt_in_at": "<verified RFC3339 instant>",
  "seven_day_earnings_micro_usd": 70000000,
  "evidence": "<restricted evidence references for both the instant and earnings total>"
}
```

The displayed amount is illustrative, not an approved baseline. Evidence must be
nonblank and at most 1024 UTF-8 bytes. Use concise, durable references rather than
personal data, prompts, credentials or raw proof payloads: this is retained
financial evidence. The server trusts the authorized import; it does not verify
the referenced documents for the operator.

```bash
curl --fail-with-body --request POST \
  "$COORDINATOR_URL/v1/admin/autopilot/rewards/machines/$MACHINE_ID/baseline" \
  --header "Authorization: Bearer $ADMIN_TOKEN" \
  --header 'Content-Type: application/json' \
  --data "$BASELINE_JSON"
```

Read back the frozen baseline and evidence. `first_observed_at` and the accrual
start must not move backward: import repairs the baseline, not old consent or
days before the first positive observation under this tracker. A frozen baseline
rejects all replacements, even an exact repeated import. After an uncertain
response, inspect the existing value before attempting anything else.

### 3. Fund or refill the independent allowance

Record the current cap/spending and the approved new **absolute cumulative cap**.
`APPROVED_CAP_MICRO_USD` must be a nonnegative int64 at least equal to spending;
it is not a refill delta. Remaining allowance is cap minus spent. Setting the cap
is an internal spending authorization, not a Stripe deposit or wallet credit.

```bash
curl --fail-with-body --request PATCH \
  "$COORDINATOR_URL/v1/admin/autopilot/rewards/pool" \
  --header "Authorization: Bearer $ADMIN_TOKEN" \
  --header 'Content-Type: application/json' \
  --data "{\"cap_micro_usd\":$APPROVED_CAP_MICRO_USD}"
```

Verify the returned cap matches the approved value. The cap update does not
change spending, but concurrent settlements may have increased it since the
initial inspection. Repeating the same absolute cap does not add funding twice.
There is no automatic reset/refill or link to the ordinary base-reward budget.
A pending `pool_exhausted` day is retried without partial payment; its actual
inference earnings are recomputed before payment.

### 4. Enable payments only when approved

If the worker is not enabled, obtain approval for
`EIGENINFERENCE_AUTOPILOT_REWARDS=true` and restart through
[coordinator deployment](coordinator-deploy.md). This setting changes payments
only: do not modify ordinary base-reward settings, Autopilot global shadow,
machine desired modes or provider consent as a side effect.

The worker catches up on startup and follows the bounded
[UTC schedule](../reference/pricing-model.md#autopilot-rewards). No manual
settlement endpoint is provided. Consent tracking continues while payments are
disabled, so enabling can process previously closed tracked days.
The [shared final eligible day](../reference/pricing-model.md#autopilot-rewards)
does not move with enrollment or a restart. Keep the worker and any approved
funding available to settle earlier pending days afterward; the cutoff already
prevents new accrual and does not disable Autopilot or ordinary base rewards.

## Verification

- Read back the pool and enrollment pages through the admin API. The pool and
  list are separate snapshots; use restricted database inspection for financial
  reconciliation, not a cross-page equality assertion during active payments.
- Inspect `autopilot_reward_settlements` for the canonical machine and all retained
  aliases, using the [persistence contract](../architecture/storage.md#autopilot-reward-persistence).
  Confirm one finalized logical machine/day result, matching baseline and daily
  inference sum. There is no receipt-list HTTP endpoint in this interface.
- For a paid receipt, match its amount and job/reference identity against one
  `autopilot_floor_topup` ledger entry and one `base_reward` earning; confirm the
  same amount raised wallet, withdrawable balance and pool spending atomically.
  Earnings summaries count it once with no inference count/tokens.
- Distinguish `pool_exhausted` and `history_required` pending states from final
  `paid`, `zero`, `opted_out` and `ineligible` results. Pending days keep `next_day`; a funded
  retry recalculates actuals. Finalized receipts are not reopened for later
  backdated earnings. For unknown or conflicted baselines, inspect enrollment and
  `history_pending` even if no receipt exists: the worker can defer that machine
  before creating a receipt while continuing to process others.
- Check aggregate worker logs for `processed_days`, `pool_pending`,
  `history_pending`, `failed` and `store_error`. They intentionally omit machine
  IDs, accounts, evidence and raw store errors; do not add those to logs to debug.
- Verify first-partial-day and day-end consent against the exact
  [policy](../reference/pricing-model.md#autopilot-rewards), not live availability
  at payout time. A later strong day must not erase an earlier weak day's top-up.
- For `ineligible`, inspect the day-close captured qualification and union of
  canonical-machine session uptime for that UTC day. A current OS upgrade,
  inventory refresh, reconnect or lease granted after the recorded receive time
  does not manufacture earlier qualification.
  Duplicate sessions cannot multiply uptime, and short first enrollment days
  still use the full-day denominator. Confirm no wallet credit or pool spending.

For 400/404/409/429/503 handling, use the
[HTTP contract](../reference/api-contracts.md#autopilot-reward-administration).
History/ownership conflicts require evidence or identity resolution, not a
fresh enrollment. A store failure is not proof that an earlier write rolled back.

## Rollback

1. For an approved payment stop, set `EIGENINFERENCE_AUTOPILOT_REWARDS=false`
   and restart through the deployment procedure. Read back `enabled=false`.
   Leave ordinary base rewards, provider consent and the live controller alone.
2. If only removing unspent allowance is approved, set the absolute cap to the
   observed spent amount. A concurrent settlement can make that value too low
   and return 409; inspect again rather than lowering below committed spending.
   Stopping the worker is the payment kill switch, not controller pause/shadow.
3. Preserve pool spending, baselines, consent journals and all pending/final
   receipts. Do not delete tables, reset cursors or credit manual duplicates.
   Re-enabling resumes from durable days; it does not create a new baseline.
4. Before rolling back coordinator code, confirm it preserves this tracker and
   all existing financial/erasure compatibility. An older writer that cannot
   capture saved-consent and qualification history creates a gap; do not later claim uninterrupted
   history or substitute reconnect time. Preserve database backups containing
   all new tables, not just the [partial archive evidence](../architecture/storage.md#retention-and-archive-boundary).

No rollback action claws back finalized payments or changes the historical
baseline. Provider publication/rollback and live-cohort operation remain separate
approved procedures.

## Related

- [Reward policy, formulas and statuses](../reference/pricing-model.md#autopilot-rewards)
- [Billing and historical consent mechanism](../architecture/billing.md#autopilot-rewards)
- [Persistence and archive boundary](../architecture/storage.md#autopilot-reward-persistence)
- [Controller operation and recovery](model-autopilot.md)
- [Provider release](provider-release.md)
