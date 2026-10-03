# Erase an account (GDPR)

> Last updated: 2026-10-03

This runbook erases the personal data of one provider or consumer account:
plan, confirm, grace period, scrub, and the external Stripe deletions. It also
says how to cancel and what is kept. The admin API is in
[API contracts](../reference/api-contracts.md#account-erasure); the storage
rules are in [storage](../architecture/storage.md#account-erasure).

## When to use

- A user asks for the erasure of their account and the request is verified.
- An admin closes an account and its personal data must go.

Do not use it to disable an account for abuse; revoke its keys instead. An
erasure forfeits the balance and cannot be undone after the scrub.

## Prerequisites

- Explicit human approval for this specific erasure. It changes production
  data.
- The admin key (`EIGENINFERENCE_ADMIN_KEY`) or a Privy session of an admin
  email. The API records which admin acted (`admin_key` or `account:<id>`),
  never an email.
- The account ID. Find it from the support ticket or the admin console.
- The wallet addresses of the account, if it ever used the retired on-chain
  payments. `payments` and `provider_payouts` have no account column, so the
  admin names the addresses. Give each one exactly as stored.
- No withdrawal of the account may be in flight: no Stripe withdrawal in
  `pending` or `transferred`, none `paid` within the last 30 days (a bank can
  still return it; `stripePayoutBounceWindow`), none waiting for a
  confirmed-rejection refund, and no Global Payout in `pending`,
  `processing`, or `posted` within 90 days.
  The plan shows `open_withdrawals`; the confirm call refuses with 409
  `open_withdrawal`.

## Steps

1. Run the plan (a dry run; it changes no account data):

   ```bash
   curl -sS -X POST "$COORD/v1/admin/accounts/$ACCOUNT/erasure/plan" \
     -H "Authorization: Bearer $ADMIN_KEY" \
     -d '{"wallet_addresses": ["0x..."]}'
   ```

   Read `email`, the per-rule `rows`, `stripe_objects` (every Express account
   and Global Payouts recipient the account ever used, and its Checkout
   Sessions), `wallets`, `balance_micro_usd`, `withdrawable_micro_usd`,
   `open_withdrawals` and `retained`. Check that the email matches the
   verified requester. Each entry in `wallets` shows the rows that hold that
   address in `payments` and `provider_payouts`; zero rows means the address
   is wrong. `retained` lists rows that are kept because another account
   shares them (a machine alias, a Secure Enclave key, an App Attest key).
   Keep `confirm_token`; it expires after 15 minutes (`erasureConfirmTTL`).
   The token is bound to this wallet list: to change the list, plan again.

2. Confirm the erasure. Repeat the account ID, the token, the email (when the
   account has one) and the same wallet list as the plan:

   ```bash
   curl -sS -X POST "$COORD/v1/admin/accounts/$ACCOUNT/erasure" \
     -H "Authorization: Bearer $ADMIN_KEY" \
     -d '{"account_id": "'"$ACCOUNT"'", "confirm_token": "...", "email": "...", "reason": "ticket 1234", "wallet_addresses": ["0x..."]}'
   ```

   The coordinator soft deletes the account: the user and its provider rows
   get `deleted_at`, API keys and provider tokens are revoked, and the
   account's connected providers are disconnected. A provider that reconnects
   comes back unlinked. A Privy login of the account gets 403
   `account_pending_deletion`. Do not write personal data in `reason`; it is
   kept.

3. Wait for the grace period. The default is 30 days
   (`EIGENINFERENCE_ERASURE_GRACE`, a Go duration such as `720h`). The
   response shows `scrub_after`. An hourly loop scrubs each request after its
   `scrub_after`. To scrub at once, send `"force": true` in step 2.

4. Check the scrub:

   ```bash
   curl -sS "$COORD/v1/admin/accounts/$ACCOUNT/erasure" -H "Authorization: Bearer $ADMIN_KEY"
   ```

   `request.state` is `erased` and `request.summary.applied` has the rows
   changed. If the state is still `pending` after `scrub_after`, read
   `request.last_error`. An open withdrawal blocks the scrub until it ends;
   the loop retries every hour.

5. Follow the outbox. The scrub writes one `erasure_outbox` row for each
   Stripe object and one `erasure_log` row; a worker (`StartErasureOutboxLoop`,
   every minute) delivers them. `GET …/erasure` shows each row's `state`:

   | Target | What the worker does | Done when |
   |---|---|---|
   | `stripe_account` | `DELETE /v1/accounts/{id}` with the Connect key | deleted, or Stripe says the account does not exist |
   | `global_recipient` | `POST /v2/core/accounts/{id}/close` with `applied_configurations: ["recipient"]` | closed, or not found |
   | `checkout_sessions` | a Stripe redaction job for up to 10 sessions (`validation_behavior=fix`): create, wait for `ready`, run, wait for `succeeded`; the job ID is kept on the row (`has_stripe_job`) | the job succeeded. A session Stripe cannot find is not done: it moves to its own `manual_action` row (see step 6), and the others continue in a new job |
   | `erasure_log` | one Datadog log with tag `erasure_log:true`, or a `slog` line without Datadog | written |

   A transient error (network, 5xx, 429) is retried with backoff from 1 min
   up to 6 h; after 8 attempts the row moves to `manual_action`. A definitive
   Stripe refusal moves it to `manual_action` at once with the error in
   `last_error`: for example a live Express account whose balances are not
   zero, a recipient with a cash balance, or "Redaction Jobs is not enabled
   for this account" (the feature is in public preview and needs Stripe to
   grant access). Most transactions can be redacted only 90 days after they
   were created; when every validation error of a job says so, the row waits
   7 days (`erasureRedactionWait`) and a new job is made, without counting an
   attempt. Those waits end 105 days after the scrub
   (`erasureRedactionDeadline`): the row then moves to `manual_action`. A job
   that stays in one non-terminal status (for example `validating`) for more
   than 31 days (`erasureRedactionStuck`; Stripe says a job can take up to 30
   days) also moves to `manual_action`. When a job disappears at Stripe, the
   next one is created with a new idempotency key. When the coordinator runs
   in billing mock mode, Stripe rows end done without a call.

6. Resolve `manual_action` rows by hand. A done row no longer holds its
   Stripe ID; a `manual_action` row keeps it in `erasure_outbox.external_id`
   (the API does not return it):

   ```sql
   SELECT id, target, external_id, attempts, last_error
   FROM erasure_outbox WHERE state = 'manual_action';
   ```

   Fix the cause in Stripe (pay out or reverse the remaining balance, request
   Redaction Jobs access, cancel a conflicting job), finish the deletion in
   the Stripe dashboard, then clear the ID:
   `UPDATE erasure_outbox SET external_id = '', last_error = 'resolved by hand' WHERE id = '<id>';`.
   To let the worker try again instead, set `state = 'pending'`,
   `attempts = 0` and `next_at = NOW()`.

## Cancel

During the grace period only (`state` `pending` and before `scrub_after`):

```bash
curl -sS -X POST "$COORD/v1/admin/accounts/$ACCOUNT/erasure/cancel" -H "Authorization: Bearer $ADMIN_KEY"
```

The user and its provider rows are live again. API keys and provider tokens
stay revoked: the user makes new keys and links the machines again. After the
scrub there is no cancel.

## Credits after the erasure

After the scrub the account's balance stays zero. Any later credit (a bank
returns a paid payout, a Global Payout comes back after the reconcile window,
a settlement or referral reward lands late) is refused by database triggers
(`00021_erasure_refuse_credits.sql`) and recorded in
`erasure_refused_credits` (amount, ledger type, reference). The caller sees
success, so Stripe does not redeliver its webhook. `GET …/erasure` lists them
as `refused_credits`. Review each one: the money is still with the platform
(or Stripe) and may need a refund or a transfer to the person by another
channel. Credits during the grace period still apply, because the erasure
can be canceled.

## What is kept, and why

| Data | Why it is kept |
|---|---|
| IDs: account, provider, machine, request, key and session IDs, Secure Enclave and App Attest public keys | Not personal data alone; ledger, earnings and audit rows need them. |
| Ledger entries, balances, provider earnings, floor draws, usage token counts | Financial records. The forfeit is an `erasure_forfeit` ledger entry, so the ledger still sums to the zero balance. |
| Stripe transfer and payout IDs and amounts on `stripe_withdrawals`; amount, country and payment ID on `global_payout_withdrawals` | Financial records of the platform's own payments. The connected account, recipient and payout method are cleared. |
| `darkbloom_machine_sessions` and observations | Chip, OS version and IDs only; no serial or key. |
| App Attest shadow keys, enrollments, revocations and rotations | Key IDs, public keys and owner hashes keep a revoked or used key from being accepted again. Raw proofs, receipts and evidence context are deleted. |
| An `mda_serial` machine alias that another account also used | Deleting it would break that account's machine identity. The plan lists it under `retained`. |
| Trust-reuse, verification, code-attestation and push-budget rows of a Secure Enclave key that another account's provider also has; App Attest receipts of a key another account's session used | They belong to the other account too. The in-memory trust cache and MDM jobs of those keys also stay. The plan lists them under `retained`. |
| `erasure_refused_credits` | Credits refused after the erasure, for manual review; IDs and amounts only. |
| `erasure_requests` (state, actor, reason, row counts) | The record that the erasure happened. It holds no email, token or wallet address after the scrub. |
| `erasure_outbox.external_id` | The Stripe ID waits here until Stripe confirms the deletion; a `manual_action` row keeps it until an operator clears it. |

## Backups and logs

- Postgres backups and point-in-time recovery keep the erased data until
  their retention ends. After a restore, a request that was `pending` at the
  backup time is scrubbed again by the loop. An erasure confirmed after the
  backup time is not in the restored database: plan and confirm it again,
  with `force`, for each account in the list of completed erasures. That list
  is the `erasure_log` record of each erasure (request ID, account ID,
  `erased_at`), written by the outbox worker with the Datadog tag
  `erasure_log:true`; it survives a restore only in a Datadog log archive.
  Without Datadog the record is only a process log line. Set up a Datadog log archive (an
  archive with the query `erasure_log:true`) that keeps these records longer
  than the database backups.
- Datadog logs written before the erasure keep any data they hold until
  their retention ends. The coordinator does not delete log events.
- Stripe keeps its own data until the outbox deletes or redacts it. A
  redacted Checkout transaction can no longer be refunded or disputed.
  Checkout Sessions made on the earlier Stripe account (before the
  [Stripe migration](stripe-migration.md)) are not reachable with the current
  key. The worker looks up each session of a batch that Stripe refused as not
  found, keeps the found ones in the batch, and moves the missing ones to a
  `manual_action` row whose `last_error` says so. Redact those sessions in the
  old account's dashboard, then clear the row as in step 6.

## Verification

- `GET /v1/admin/accounts/{account_id}/erasure` shows `state: erased`.
- A Privy login with the old identity creates a new, empty account.
- `SELECT email, privy_user_id FROM users WHERE account_id = '<id>'` returns
  an empty email and an `erased:` Privy ID.

## Rollback

Before the scrub, cancel. After the scrub, the data is gone from the live
database; it cannot be brought back, by design. Do not restore a backup to
undo an erasure.

## Related

- [Storage](../architecture/storage.md#account-erasure) — rule table, soft delete, scrub transaction
- [API contracts](../reference/api-contracts.md#account-erasure) — routes, bodies, errors
- [Configuration](../reference/configuration.md) — `EIGENINFERENCE_ERASURE_GRACE`
