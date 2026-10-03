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
  `pending` or `transferred`, none waiting for a confirmed-rejection refund,
  and no Global Payout in `pending`, `processing`, or `posted` within 90 days.
  The plan shows `open_withdrawals`; the confirm call refuses with 409
  `open_withdrawal`.

## Steps

1. Run the plan (a dry run; it changes no account data):

   ```bash
   curl -sS -X POST "$COORD/v1/admin/accounts/$ACCOUNT/erasure/plan" \
     -H "Authorization: Bearer $ADMIN_KEY" \
     -d '{"wallet_addresses": ["0x..."]}'
   ```

   Read `email`, the per-rule `rows`, `stripe_objects`, `balance_micro_usd`,
   `withdrawable_micro_usd`, `open_withdrawals` and `retained`. Check that the
   email matches the verified requester. Each wallet address must show rows in
   `payments_*` or `provider_payouts_address`; zero rows means the address is
   wrong. Keep `confirm_token`; it expires after 15 minutes
   (`erasureConfirmTTL`).

2. Confirm the erasure. Repeat the token and the email from the plan:

   ```bash
   curl -sS -X POST "$COORD/v1/admin/accounts/$ACCOUNT/erasure" \
     -H "Authorization: Bearer $ADMIN_KEY" \
     -d '{"confirm_token": "...", "email": "...", "reason": "ticket 1234", "wallet_addresses": ["0x..."]}'
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
   Stripe object (`stripe_account`, `global_recipient`, `checkout_sessions`)
   and one `erasure_log` row. Until the outbox worker ships, each row stays
   `pending`: delete the Express account, close the Global Payouts recipient
   and redact the Checkout Sessions in the Stripe dashboard by hand. The
   Stripe IDs are in `erasure_outbox.external_id`; read them with SQL, as the
   API does not return them.

## Cancel

During the grace period only (`state` `pending` and before `scrub_after`):

```bash
curl -sS -X POST "$COORD/v1/admin/accounts/$ACCOUNT/erasure/cancel" -H "Authorization: Bearer $ADMIN_KEY"
```

The user and its provider rows are live again. API keys and provider tokens
stay revoked: the user makes new keys and links the machines again. After the
scrub there is no cancel.

## What is kept, and why

| Data | Why it is kept |
|---|---|
| IDs: account, provider, machine, request, key and session IDs, Secure Enclave and App Attest public keys | Not personal data alone; ledger, earnings and audit rows need them. |
| Ledger entries, balances, provider earnings, floor draws, usage token counts | Financial records. The forfeit is an `erasure_forfeit` ledger entry, so the ledger still sums to the zero balance. |
| Stripe transfer and payout IDs and amounts on `stripe_withdrawals`; amount, country and payment ID on `global_payout_withdrawals` | Financial records of the platform's own payments. The connected account, recipient and payout method are cleared. |
| `darkbloom_machine_sessions` and observations | Chip, OS version and IDs only; no serial or key. |
| App Attest shadow keys, enrollments, revocations and rotations | Key IDs, public keys and owner hashes keep a revoked or used key from being accepted again. Raw proofs, receipts and evidence context are deleted. |
| An `mda_serial` machine alias that another account also used | Deleting it would break that account's machine identity. The plan lists it under `retained`. |
| `erasure_requests` (state, actor, reason, row counts) | The record that the erasure happened. It holds no email, token or wallet address after the scrub. |
| `erasure_outbox.external_id` | The Stripe ID waits here until Stripe confirms the deletion. |

## Backups and logs

- Postgres backups and point-in-time recovery keep the erased data until
  their retention ends. After a restore, a request that was `pending` at the
  backup time is scrubbed again by the loop. An erasure confirmed after the
  backup time is not in the restored database: plan and confirm it again,
  with `force`, for each account in the list of completed erasures. That list
  is the `erasure_log` record of each erasure (request ID, account ID,
  `erased_at`), written by the outbox worker; it survives a restore only in a
  Datadog log archive. Until the worker ships, keep the request ID and
  account ID of each completed erasure in the support ticket.
- Datadog logs written before the erasure keep any data they hold until
  their retention ends. The coordinator does not delete log events.
- Stripe keeps its own data until the outbox (or the manual step 5) deletes
  or redacts it.

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
