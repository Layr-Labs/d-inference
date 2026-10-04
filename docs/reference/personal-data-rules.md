# Personal-data rules

> Last updated: 2026-10-04

Reference for account erasure: every personal column the scrub changes and
how, the data it keeps and why, the erasure tables, and the constants. How the
scrub works is in [account erasure](../architecture/account-erasure.md); the
procedure is the [runbook](../operations/account-erasure.md).

## Rule actions

The closed set of actions a rule applies (`piiAction`,
`coordinator/store/erasure_rules.go`). The plan and the summary show `update`
or `delete_row` per rule (`piiRule.action`).

| Action | Name in the table below | What the scrub writes |
|---|---|---|
| `set_empty` | empty | `''` |
| `set_null` | NULL | `NULL` |
| `set_empty_json` | `{}` | `'{}'` in a `NOT NULL` JSON column or key |
| `set_unique_random` | unique random | A new value per account: `erased:<uuid>` (Privy ID) or `erased-<uuid>` (referrer code) (`erasedValue`) |
| `set_unique_random` on a wallet rule | random per wallet | One `erased-<uuid>` per wallet address, the same in every row and table that holds it (`walletReplacement`) |
| `rewrite` | fixed value | A constant that drops the personal part |
| `tombstone` | tombstone | The row stays with every personal field cleared |
| `delete_row` | delete row | `DELETE` |

## Rule table

`erasureRules` in scrub order. Every statement is a sqlc query in
`coordinator/store/queries/erasure.sql`; the count query has the same
predicate as the apply query. "Unshared" means no other account uses the key
([shared keys](../architecture/account-erasure.md#shared-machines-and-shared-keys)).

| # | Rule (`Name`) | Table | Column: rule | Link to the account | Count / apply query |
|---|---|---|---|---|---|
| 1 | `users` | `users` | `email`: empty; `privy_user_id`: unique random; `stripe_account_id`, `stripe_account_status`, `stripe_account_country`, `stripe_destination_type`, `stripe_destination_last4`: empty; `stripe_instant_eligible`: `FALSE` (not listed in the rule's columns) | `account_id` | `CountUsersRow` / `ScrubUsersRow` |
| 2 | `api_keys` | `api_keys` | `name`: empty | `owner_account_id` | `CountAPIKeysRows` / `ScrubAPIKeysRows` |
| 3 | `provider_tokens` | `provider_tokens` | `label` (host name): empty | `account_id` | `CountProviderTokensRows` / `ScrubProviderTokensRows` |
| 4 | `device_codes` | `device_codes` | delete row | `account_id` | `CountDeviceCodesRows` / `DeleteDeviceCodesRows` |
| 5 | `providers` | `providers` | `serial_number`: empty; `location`, `attestation_result`, `mda_cert_chain`: NULL | `account_id` | `CountProvidersRows` / `ScrubProvidersRows` |
| 6 | `provider_sessions` | `provider_sessions` | `serial_number`: empty; an open session gets `disconnected_at = NOW()` | `account_id` | `CountProviderSessionsRows` / `ScrubProviderSessionsRows` |
| 7 | `provider_log_reports` | `provider_log_reports` | delete row | `account_id` | `CountProviderLogReportsRows` / `DeleteProviderLogReportsRows` |
| 8 | `provider_trust_reuse` | `provider_trust_reuse` | delete row | `se_pubkey` in the unshared Secure Enclave keys of the account's providers | `CountProviderTrustReuseRows` / `DeleteProviderTrustReuseRows` |
| 9 | `provider_verification_jobs` | `provider_verification_jobs` | delete row | same as 8 | `CountProviderVerificationJobsRows` / `DeleteProviderVerificationJobsRows` |
| 10 | `code_attestations` | `code_attestations` | delete row (`apns_token` is a device push token) | same as 8 | `CountCodeAttestationsRows` / `DeleteCodeAttestationsRows` |
| 11 | `code_attest_push_budgets` | `code_attest_push_budgets` | delete row | same as 8 | `CountCodeAttestPushBudgetsRows` / `DeleteCodeAttestPushBudgetsRows` |
| 12 | `machine_aliases_account` | `darkbloom_machine_aliases` | delete row | `kind` `app_attest` or `legacy_se`, `scope` = account ID | `CountAccountMachineAliasesRows` / `DeleteAccountMachineAliasesRows` |
| 13 | `machine_aliases_mda_serial` | `darkbloom_machine_aliases` | delete row | `kind` `mda_serial`, `scope` `''`, `digest` = SHA-256 of `mda_serial\x00<serial>` for the account's serials (`mdaSerialDigest`), machine not used by another account | `CountMDASerialAliasesRows` / `DeleteMDASerialAliasesRows` |
| 14 | `app_attest_evidence_blobs` | `app_attest_evidence_blobs` | delete row | `evidence_id` of evidence whose `session_id` is one of the account's provider IDs | `CountAppAttestEvidenceBlobsRows` / `DeleteAppAttestEvidenceBlobsRows` |
| 15 | `app_attest_evidence` | `app_attest_evidence` | `context`: `{}` | `session_id` in the account's provider IDs | `CountAppAttestEvidenceRows` / `ScrubAppAttestEvidenceRows` |
| 16 | `app_attest_receipt_jobs` | `app_attest_receipt_jobs` | delete row | `key_id` in the account's unshared App Attest key IDs | `CountAppAttestReceiptJobsRows` / `DeleteAppAttestReceiptJobsRows` |
| 17 | `app_attest_receipt_blobs` | `app_attest_receipt_blobs` | delete row | `receipt_id` of receipts with those key IDs | `CountAppAttestReceiptBlobsRows` / `DeleteAppAttestReceiptBlobsRows` |
| 18 | `app_attest_receipts` | `app_attest_receipts` | `context`: `{}` | `key_id` in those key IDs | `CountAppAttestReceiptsRows` / `ScrubAppAttestReceiptsRows` |
| 19 | `usage_request_location` | `usage` | `request_location`: NULL | `consumer_key_hash` = SHA-256 hex of the account ID (`hashKey`), rows with a location | `CountUsageLocationRows` / `ScrubUsageLocationRows` |
| 20 | `inference_routes_consumer_region` | `inference_routes` | `consumer_region`: NULL | `consumer_key_hash`, as 19 | `CountConsumerRegionRows` / `ScrubConsumerRegionRows` |
| 21 | `inference_routes_provider_region` | `inference_routes` | `provider_region`: NULL | `provider_id` in the account's provider IDs | `CountProviderRegionRows` / `ScrubProviderRegionRows` |
| 22 | `referrers` | `referrers` | `code`: unique random; `referrals.referrer_code` follows through `ON UPDATE CASCADE` | `account_id` | `CountReferrersRow` / `ScrubReferrersRow` |
| 23 | `billing_sessions_referral_code` | `billing_sessions` | `referral_code`: the new code from 22 | `referral_code` = the account's old code, in any account's sessions | `CountReferralCodeCopies` / `ScrubReferralCodeCopies` |
| 24 | `billing_sessions` | `billing_sessions` | `external_id` (Checkout Session ID): empty; `status` `pending` becomes `erased` | `account_id` | `CountBillingSessionsRows` / `ScrubBillingSessionsRows` |
| 25 | `ledger_entries_stripe_reference` | `ledger_entries` | `reference` `stripe:<session>`: fixed value `stripe:erased` | `account_id`, `reference LIKE 'stripe:%'` | `CountStripeLedgerReferences` / `ScrubStripeLedgerReferences` |
| 26 | `ledger_entries_admin_note` | `ledger_entries` | `reference`: fixed value, the entry type (drops the admin note) | `account_id`, `entry_type` `admin_credit` or `admin_reward` | `CountAdminNoteLedgerReferences` / `ScrubAdminNoteLedgerReferences` |
| 27 | `global_payout_recipients` | `global_payout_recipients` | `country`: empty; `data`: tombstone (a new `GlobalRecipient` with only `id` and `account_id`, as `RemoveGlobalRecipient`) | `account_id` | `CountGlobalRecipientRow` / `TombstoneGlobalRecipientRow` |
| 28 | `global_payout_withdrawals` | `global_payout_withdrawals` | `data.recipient_id`, `data.payout_method_id`: empty; `data.request`: `{}` | `account_id` | `CountGlobalPayoutRows` / `ScrubGlobalPayoutRows` |
| 29 | `stripe_withdrawals` | `stripe_withdrawals` | `stripe_account_id`: empty | `account_id` | `CountStripeWithdrawalRows` / `ScrubStripeWithdrawalRows` |
| 30 | `payments_consumer_address` | `payments` | `consumer_address`: random per wallet | `consumer_address` = a wallet address named in the request | `CountPaymentConsumerAddress` / `ScrubPaymentConsumerAddress` |
| 31 | `payments_provider_address` | `payments` | `provider_address`: random per wallet | `provider_address` = a named wallet address | `CountPaymentProviderAddress` / `ScrubPaymentProviderAddress` |
| 32 | `provider_payouts_address` | `provider_payouts` | `provider_address`: random per wallet | `provider_address` = a named wallet address | `CountProviderPayoutAddress` / `ScrubProviderPayoutAddress` |

Notes:

- Rules 8 to 11, 13 to 18 and 21 run only when the account has keys of
  that kind (`byKeys`); rule 23 runs only when the account has a referrer
  code. A rule with no statement reports 0 rows.
- Rules 30 to 32 run one statement per wallet address (`walletStatements`).
  `payments` and `provider_payouts` have no account column, so the admin names
  the addresses in the plan and confirm calls.
- `MemoryStore` maps every rule name to a function in `memoryErasureRules`
  (`coordinator/store/erasure_memory_rules.go`). It has no `payments` or
  `provider_payouts` tables, so rules 30 to 32 are `memoryNoTable` there.
- Before the rules, `forfeitBalance` sets `balances.balance_micro_usd` and
  `withdrawable_micro_usd` to 0 and writes one `erasure_forfeit` ledger entry
  (`coordinator/store/erasure_postgres.go`).

## Retained data

The scrub keeps these on purpose. The marker tests allow only
`erasure_outbox.external_id` to hold a seeded marker after a scrub
(`erasureMarkerAllowList`, `coordinator/store/erasure_marker_test.go`).

| Data | Reason | Code |
|---|---|---|
| IDs: account, provider, machine, request, key and session IDs; Secure Enclave and App Attest public keys | Not personal data alone; ledger, earnings and audit rows need them | `coordinator/store/erasure_rules.go` (file comment) |
| Ledger entries, balances, provider earnings, floor draws, usage token counts | Financial records. The forfeit is an `erasure_forfeit` entry, so the ledger sums to the zero balance | `forfeitBalance` |
| `stripe_withdrawals` transfer and payout IDs and amounts; `global_payout_withdrawals` amount, status, country and payment ID | Financial records of the platform's own payments; the connected account, recipient, payout method and request are cleared | rules 28, 29 |
| `darkbloom_machine_sessions` and machine observations | Chip, OS version and IDs; no serial or key. The marker test searches them | `TestErasureMarkerPostgres` |
| App Attest shadow keys, enrollments, revocations and rotations | Key IDs, public keys and owner hashes keep a used or revoked key from being accepted again; proofs, receipts and evidence context are removed | rules 14 to 18 |
| An `mda_serial` alias of a machine another account also used | Deleting it would break that account's machine identity | `retainedSharedMDAAlias` |
| Trust-reuse, verification, code-attestation and push-budget rows of a Secure Enclave key another account's provider has; their trust-reuse cache entries and MDM jobs | They belong to the other account too | `retainedSharedSEKey` |
| App Attest receipts, receipt blobs and receipt jobs of a key another account's session used | They belong to the other account too | `retainedSharedAppAttestKey` |
| `erasure_requests`: state, actor, reason, row counts, times | The record that the erasure happened; no email, token or wallet address after the scrub | `MarkErasureErased` |
| `erasure_refused_credits` | Credits refused after the erasure, kept for review; IDs, amounts and cleaned references only | `00021_erasure_refuse_credits.sql` |
| `erasure_outbox.external_id` | The Stripe ID waits here until the worker confirms the deletion; a `manual_action` row keeps it until an operator clears it | `erasureMarkerAllowList`; `SaveErasureOutboxResult` |
| The Datadog `erasure_log` record | Request ID, account ID and `erased_at`: the list to replay after a restore | `writeErasureLog` |

The plan and the applied summary list the three shared kinds in `retained`
(`ErasureRetained`: `table`, `rows`, `reason`), with the reason strings
`retainedSharedMDAAlias`, `retainedSharedSEKey` and
`retainedSharedAppAttestKey`.

## Outbox targets

`ErasureTarget` (`coordinator/store/erasure.go`). The scrub writes the rows
(`erasureKeys.outboxRows`, `coordinator/store/erasure_keys.go`) with `state`
`pending` and `next_at` = the scrub time; the worker in
`coordinator/api/erasure_outbox.go` delivers them
([outbox delivery](../architecture/account-erasure.md#outbox-delivery)).

| `target` | One row per | `external_id` holds | Calls (key) |
|---|---|---|---|
| `stripe_account` | Express account in `users.stripe_account_id` or any `stripe_withdrawals.stripe_account_id` of the account | `acct_…` | `DELETE /v1/accounts/{id}` (Connect key; `StripeConnect.DeleteAccount`) |
| `global_recipient` | Global Payouts recipient in `global_payout_recipients.data` or any `global_payout_withdrawals.data.recipient_id` | the recipient account ID | `POST /v2/core/accounts/{id}/close`, body `{"applied_configurations": ["recipient"]}`, `Stripe-Version: 2026-08-26.preview` (Global Payouts key; `globalpayouts.Client.CloseRecipient`) |
| `checkout_sessions` | Batch of up to `ErasureCheckoutBatch` (10) Checkout Session IDs from `billing_sessions.external_id` (`payment_method = 'stripe'`) | comma-separated `cs_…` IDs | `POST /v1/privacy/redaction_jobs` (`validation_behavior=fix`, `objects[checkout_sessions][]`, `Idempotency-Key: erasure-redaction-<row id>-<generation>`); `GET /v1/privacy/redaction_jobs/{id}`; `POST /v1/privacy/redaction_jobs/{id}/run`; `GET /v1/privacy/redaction_jobs/{id}/validation_errors?limit=100`; `GET /v1/checkout/sessions/{id}` when a batch must be split (Checkout key; `coordinator/billing/stripe_redaction.go`) |
| `erasure_log` | Erasure (always one) | `''` | Datadog Logs API, one unbatched event (`DD_API_KEY`; `datadog.Client.SendLog`) |

A split adds a `checkout_sessions` row in `manual_action` with the sessions
Stripe cannot find (`InsertManualErasureOutbox`, `attempts` 1).

`ErasureOutboxState` is closed: `pending`, `done`, `manual_action`.

## Erasure tables

### `erasure_requests`

`coordinator/store/schema/migrations/00018_erasure_tables.sql`.

| Column | Type | Meaning |
|---|---|---|
| `id` | `TEXT` PK | Request ID (UUID) |
| `account_id` | `TEXT NOT NULL` | The account |
| `actor` | `TEXT` | `admin_key` or `account:<id>` of the admin who planned or confirmed (`adminActor`) |
| `canceled_by` | `TEXT` | Actor of the cancel |
| `reason` | `TEXT` | Free text from the confirm call; kept |
| `state` | `TEXT` | `planned`, `pending`, `erased`, `canceled` (`CHECK`) |
| `plan` | `JSONB` | `ErasureSummary`: `planned` and `applied` counts |
| `confirm_token_hash` | `TEXT` | SHA-256 of `erasure-confirm-v1:<token>`; cleared at confirm |
| `confirm_expires_at` | `TIMESTAMPTZ` | Token expiry; cleared at confirm |
| `wallet_hash` | `TEXT` | SHA-256 of the normalized wallet list (`erasureWalletHash`) |
| `wallet_addresses` | `TEXT[]` | The wallet list, stored at confirm, cleared by the scrub or a cancel |
| `requested_at`, `scrub_after`, `erased_at`, `canceled_at` | `TIMESTAMPTZ` | Step times |
| `lease_until` | `TIMESTAMPTZ` | Grace-loop lease |
| `last_error` | `TEXT` | Last scrub failure; cleared when erased |
| `created_at` | `TIMESTAMPTZ` | Insert time |

Indexes: `erasure_requests_open` (unique `account_id` where `state` is
`planned` or `pending`), `erasure_requests_account` (`account_id`,
`created_at DESC`), `erasure_requests_due` (`scrub_after` where `pending`),
`erasure_requests_erased` (`account_id` where `erased`, read by the
triggers).

### `erasure_outbox`

| Column | Type | Meaning |
|---|---|---|
| `id` | `TEXT` PK | Row ID (UUID) |
| `request_id` | `TEXT` FK `erasure_requests(id)` | The request |
| `target` | `TEXT` | [Outbox target](#outbox-targets) (`CHECK`) |
| `external_id` | `TEXT` | Stripe IDs, see [outbox targets](#outbox-targets) |
| `state` | `TEXT` | `pending`, `done`, `manual_action` (`CHECK`, default `pending`) |
| `attempts` | `INTEGER` | Delivery attempts |
| `next_at` | `TIMESTAMPTZ` | When the row is due |
| `lease_until` | `TIMESTAMPTZ` | Delivery lease |
| `last_error` | `TEXT` | Last delivery error |
| `done_at` | `TIMESTAMPTZ` | When it ended `done` |
| `created_at` | `TIMESTAMPTZ` | Insert time; the 105-day redaction deadline counts from it |
| `stripe_job_id` | `TEXT` | Redaction job of a `checkout_sessions` row (`prj_…`); cleared when done |
| `stripe_job_status` | `TEXT` | Last job status the worker read |
| `stripe_job_status_since` | `TIMESTAMPTZ` | Since when the job has had that status (the stuck-job clock) |
| `stripe_job_generation` | `INTEGER` | Part of the job's idempotency key; goes up when a new job must be made |

The last four columns come from
`coordinator/store/schema/migrations/00022_erasure_outbox_stripe_job.sql`.

Indexes: `erasure_outbox_request` (`request_id`), `erasure_outbox_due`
(`next_at` where `pending`).

### `erasure_refused_credits`

`coordinator/store/schema/migrations/00021_erasure_refuse_credits.sql`.

| Column | Type | Meaning |
|---|---|---|
| `id` | `BIGSERIAL` PK | Row ID |
| `account_id` | `TEXT NOT NULL` | The erased account |
| `entry_type` | `TEXT NOT NULL` | The refused ledger entry type, for example `refund`, `payout`, `referral_reward` |
| `amount_micro_usd` | `BIGINT NOT NULL` | The refused amount |
| `reference` | `TEXT` | The ledger reference; the entry type for `admin_credit` and `admin_reward`, `stripe:erased` for a `stripe:` reference |
| `created_at` | `TIMESTAMPTZ` | When the credit was refused |

Index: `erasure_refused_credits_account` (`account_id`, `created_at DESC`).
`ListErasureRefusedCredits` returns at most 500 rows per account, oldest
first.

| Function or trigger | Fires | Effect |
|---|---|---|
| `erasure_account_erased(account)` | — | `true` when the account has an `erased` request |
| `erasure_keep_balance_insert` | `BEFORE INSERT ON balances` | A positive balance of an erased account becomes 0 |
| `erasure_keep_balance_update` | `BEFORE UPDATE ON balances` | An increase is capped at the old value |
| `erasure_refuse_ledger_credit` | `BEFORE INSERT ON ledger_entries`, `WHEN (NEW.amount_micro_usd > 0)` | Inserts the `erasure_refused_credits` row and drops the ledger row |

### Indexes from Go migrations

`coordinator/store/postgres_migration_indexes.go` (`indexMigrations`), built
`CONCURRENTLY`.

| Version | Index | Used by |
|---|---|---|
| 19 | `idx_billing_sessions_referral_code` on `billing_sessions (referral_code) WHERE referral_code <> ''` | Rule 23 |
| 20 | `idx_users_privy_deleted` on `users (privy_user_id) WHERE deleted_at IS NOT NULL` | `PrivyUserPendingErasure` |

## Configuration and constants

| Name | Value | Code | Effect |
|---|---|---|---|
| `EIGENINFERENCE_ERASURE_GRACE` | Go duration ≥ 0; default `720h` (`defaultErasureGrace = 30 * 24 * time.Hour`) | `coordinator/api/erasure_loop.go` (`erasureGraceFromEnv`) | Time from the soft delete to `scrub_after`. An invalid or negative value logs a warning and uses the default. Listed in [configuration](configuration.md) |
| `erasureConfirmTTL` | `15 * time.Minute` | `coordinator/api/erasure_handlers.go` | Life of a plan's confirm token |
| `stripePayoutBounceWindow` | `30 * 24 * time.Hour` | `coordinator/store/erasure.go` | A Stripe withdrawal `paid` within this window still counts as open (the bounce window) |
| `globalPayoutReconcileWindow` | `90 * 24 * time.Hour` | `coordinator/store/erasure.go` | A Global Payout `posted` within this window still counts as open |
| `erasureScrubInterval` | `time.Hour` | `coordinator/api/erasure_loop.go` | Grace-loop period; the loop also runs once at start |
| `erasureScrubLease` | `time.Hour` | `coordinator/api/erasure_loop.go` | Lease on a due request; a failed scrub runs again after it |
| `erasureScrubBatch` | `20` | `coordinator/api/erasure_loop.go` | Requests per loop pass |
| `erasureTimeout` | `2 * time.Minute` | `coordinator/store/erasure_postgres.go` | Bound on one erasure transaction |
| `ErasureCheckoutBatch` | `10` | `coordinator/store/erasure.go` | Checkout Session IDs per `checkout_sessions` row (`MaxRedactionObjects` is also 10) |
| `erasureOutboxInterval` | `time.Minute` | `coordinator/api/erasure_outbox.go` | Outbox worker period; it also runs once at start |
| `erasureOutboxLease` | `10 * time.Minute` | `coordinator/api/erasure_outbox.go` | Lease on a due outbox row |
| `erasureOutboxBatch` | `20` | `coordinator/api/erasure_outbox.go` | Outbox rows per pass |
| `erasureOutboxMaxAttempts` | `8` | `coordinator/api/erasure_outbox.go` | The eighth failed delivery moves the row to `manual_action` |
| `erasureOutboxBaseBackoff` | `time.Minute` | `coordinator/api/erasure_outbox.go` | First retry delay; doubles each attempt (1, 2, 4 … 64 minutes) |
| `erasureOutboxMaxBackoff` | `6 * time.Hour` | `coordinator/api/erasure_outbox.go` | Retry delay cap; not reached with 8 attempts |
| `erasureRedactionPoll` | `5 * time.Minute` | `coordinator/api/erasure_outbox.go` | How often a running redaction job is read |
| `erasureRedactionWait` | `7 * 24 * time.Hour` | `coordinator/api/erasure_outbox.go` | Wait after a job failed because its transactions are under 90 days old (the 90-day rule) |
| `erasureRedactionDeadline` | `105 * 24 * time.Hour` | `coordinator/api/erasure_outbox.go` | End of those waits, counted from the row's `created_at` |
| `erasureRedactionStuck` | `31 * 24 * time.Hour` | `coordinator/api/erasure_outbox.go` | A job in one non-terminal status longer than this goes to `manual_action` (the 31-day rule; Stripe says a job can take up to 30 days) |
| `erasureLogTag` | `"erasure_log:true"` | `coordinator/api/erasure_outbox.go` | Datadog tag of the erasure record |

Open withdrawals (`CountOpenStripeWithdrawals`, `CountOpenGlobalPayouts`):
a Stripe withdrawal in `pending` or `transferred`, `paid` within the bounce
window, or `failed` and waiting for a confirmed-rejection refund
(`StripeConfirmedRejectionPrefix`); a Global Payout in `pending` or
`processing`, or `posted` within `globalPayoutReconcileWindow`.

## Related

- [Account erasure](../architecture/account-erasure.md): how the scrub uses these rules
- [Add personal data safely](../developer/personal-data.md): add a rule for a new column
- [API contracts: account erasure](api-contracts.md#account-erasure)
- [Account erasure runbook](../operations/account-erasure.md)
