-- Account erasure: requests, outbox, key collection and the scrub statements
-- that erasure_rules.go lists. Every scrub statement has a count query with
-- the same predicate; the scrub compares the two in one transaction.

-- name: GetErasureRequest :one
SELECT * FROM erasure_requests WHERE id = $1;

-- name: GetErasureRequestForUpdate :one
SELECT * FROM erasure_requests WHERE id = $1 FOR UPDATE;

-- name: GetLatestErasureRequest :one
SELECT * FROM erasure_requests WHERE account_id = $1 ORDER BY created_at DESC LIMIT 1;

-- name: GetOpenErasureRequestForUpdate :one
SELECT * FROM erasure_requests
WHERE account_id = $1 AND state IN ('planned', 'pending')
FOR UPDATE;

-- name: InsertErasurePlan :exec
INSERT INTO erasure_requests (id, account_id, actor, state, plan, confirm_token_hash, confirm_expires_at, wallet_hash)
VALUES ($1, $2, $3, 'planned', $4, $5, $6, $7);

-- name: UpdateErasurePlan :exec
UPDATE erasure_requests
SET actor = $2, plan = $3, confirm_token_hash = $4, confirm_expires_at = $5, wallet_hash = $6
WHERE id = $1 AND state = 'planned';

-- name: MarkErasurePending :exec
UPDATE erasure_requests
SET state = 'pending', actor = $2, reason = $3, wallet_addresses = $4,
    requested_at = $5, scrub_after = $6, confirm_token_hash = '', confirm_expires_at = NULL
WHERE id = $1;

-- name: MarkErasureCanceled :exec
UPDATE erasure_requests
SET state = 'canceled', canceled_by = $2, canceled_at = $3, wallet_addresses = '{}', lease_until = NULL
WHERE id = $1;

-- name: MarkErasureErased :exec
UPDATE erasure_requests
SET state = 'erased', erased_at = $2, plan = $3, wallet_addresses = '{}', lease_until = NULL, last_error = ''
WHERE id = $1;

-- name: RecordErasureFailure :exec
UPDATE erasure_requests SET last_error = $2 WHERE id = $1 AND state = 'pending';

-- name: LeaseDueErasureRequests :many
UPDATE erasure_requests SET lease_until = sqlc.arg('lease_until')::timestamptz
WHERE id IN (
    SELECT r.id FROM erasure_requests r
    WHERE r.state = 'pending' AND r.scrub_after <= sqlc.arg('now')::timestamptz
      AND (r.lease_until IS NULL OR r.lease_until <= sqlc.arg('now')::timestamptz)
    ORDER BY r.scrub_after
    LIMIT sqlc.arg('max_rows')::int
    FOR UPDATE SKIP LOCKED
)
RETURNING id;

-- name: InsertErasureOutbox :exec
INSERT INTO erasure_outbox (id, request_id, target, external_id, next_at)
VALUES ($1, $2, $3, $4, $5);

-- name: ListErasureOutbox :many
SELECT * FROM erasure_outbox WHERE request_id = $1 ORDER BY created_at, id;

-- name: CountUsersPendingErasureByPrivyID :one
SELECT COUNT(*) FROM users WHERE privy_user_id = $1 AND deleted_at IS NOT NULL;

-- Soft delete and cancel.

-- name: LockLiveUserForErasure :one
SELECT account_id, email FROM users WHERE account_id = $1 AND deleted_at IS NULL FOR UPDATE;

-- name: LockUserForErasure :one
SELECT account_id, privy_user_id, email, stripe_account_id, deleted_at
FROM users WHERE account_id = $1 FOR UPDATE;

-- name: GetUserForErasurePlan :one
SELECT account_id, privy_user_id, email, stripe_account_id, deleted_at
FROM users WHERE account_id = $1;

-- name: SoftDeleteUser :execrows
UPDATE users SET deleted_at = $2 WHERE account_id = $1 AND deleted_at IS NULL;

-- name: SoftDeleteProviders :execrows
UPDATE providers SET deleted_at = $2 WHERE account_id = $1 AND deleted_at IS NULL;

-- name: SoftDeleteAPIKeys :execrows
UPDATE api_keys SET active = FALSE, deleted_at = $2 WHERE owner_account_id = $1 AND deleted_at IS NULL;

-- name: SoftDeleteProviderTokens :execrows
UPDATE provider_tokens SET active = FALSE, deleted_at = $2 WHERE account_id = $1 AND deleted_at IS NULL;

-- name: RestoreUser :execrows
UPDATE users SET deleted_at = NULL WHERE account_id = $1 AND deleted_at IS NOT NULL;

-- name: RestoreProviders :execrows
UPDATE providers SET deleted_at = NULL WHERE account_id = $1 AND deleted_at IS NOT NULL;

-- Money that is still moving blocks erasure.

-- name: CountOpenStripeWithdrawals :one
SELECT COUNT(*) FROM stripe_withdrawals
WHERE account_id = sqlc.arg('account_id') AND (
    status IN ('pending', 'transferred')
    OR (status = 'paid' AND updated_at > sqlc.arg('paid_after')::timestamptz)
    OR (status = 'failed' AND NOT refunded AND transfer_id = '' AND payout_id = ''
        AND sweep_payout_id = '' AND amount_micro_usd > 0
        AND starts_with(failure_reason, sqlc.arg('refund_prefix')::text)));

-- name: CountOpenGlobalPayouts :one
SELECT COUNT(*) FROM global_payout_withdrawals
WHERE account_id = sqlc.arg('account_id') AND (
    status IN ('pending', 'processing')
    OR (status = 'posted' AND submitted_at > sqlc.arg('posted_after')::timestamptz));

-- name: LockBalance :one
SELECT balance_micro_usd, withdrawable_micro_usd FROM balances WHERE account_id = $1 FOR UPDATE;

-- name: GetBalanceForErasure :one
SELECT balance_micro_usd, withdrawable_micro_usd FROM balances WHERE account_id = $1;

-- name: ZeroBalance :execrows
UPDATE balances SET balance_micro_usd = 0, withdrawable_micro_usd = 0, updated_at = NOW()
WHERE account_id = $1;

-- name: InsertErasureLedgerEntry :exec
INSERT INTO ledger_entries (account_id, entry_type, amount_micro_usd, balance_after, reference)
VALUES ($1, $2, $3, 0, $4);

-- Key collection. Each list is bounded by an indexed account link.

-- name: ListAccountProviderKeys :many
SELECT id, se_public_key, serial_number FROM providers WHERE account_id = $1;

-- name: ListAccountSessionSerials :many
SELECT DISTINCT serial_number FROM provider_sessions WHERE account_id = $1 AND serial_number <> '';

-- name: ListAccountLogReportSerials :many
SELECT DISTINCT serial_number FROM provider_log_reports WHERE account_id = $1 AND serial_number <> '';

-- name: ListAppAttestKeysForSessions :many
SELECT DISTINCT key_id FROM app_attest_evidence WHERE session_id = ANY(sqlc.arg('session_ids')::text[]) AND key_id <> '';

-- name: ListSharedSEKeys :many
SELECT DISTINCT se_public_key FROM providers
WHERE se_public_key = ANY(sqlc.arg('se_keys')::text[]) AND account_id <> sqlc.arg('account_id');

-- name: ListSharedAppAttestKeys :many
SELECT DISTINCT key_id FROM app_attest_evidence
WHERE key_id = ANY(sqlc.arg('key_ids')::text[]) AND NOT (session_id = ANY(sqlc.arg('session_ids')::text[]));

-- name: ListAccountStripeAccountIDs :many
SELECT DISTINCT stripe_account_id FROM stripe_withdrawals WHERE account_id = $1 AND stripe_account_id <> '';

-- name: ListAccountRecipientIDs :many
SELECT DISTINCT (data->>'recipient_id')::text AS recipient_id FROM global_payout_withdrawals
WHERE account_id = $1 AND COALESCE(data->>'recipient_id', '') <> '';

-- name: LockAccountBillingSessions :many
SELECT id FROM billing_sessions WHERE account_id = $1 ORDER BY id FOR UPDATE;

-- name: IsAccountErased :one
SELECT EXISTS (SELECT 1 FROM erasure_requests WHERE account_id = $1 AND state = 'erased');

-- name: ListErasureRefusedCredits :many
SELECT * FROM erasure_refused_credits WHERE account_id = $1 ORDER BY created_at, id LIMIT 500;

-- name: GetReferrerCodeForErasure :one
SELECT code FROM referrers WHERE account_id = $1;

-- name: ListAccountCheckoutSessionIDs :many
SELECT external_id FROM billing_sessions
WHERE account_id = $1 AND payment_method = 'stripe' AND external_id <> ''
ORDER BY created_at, id;

-- name: GetGlobalRecipientDataForErasure :one
SELECT data FROM global_payout_recipients WHERE account_id = $1;

-- name: ListMDASerialAliasesForErasure :many
SELECT a.digest, EXISTS (
    SELECT 1 FROM darkbloom_machine_sessions s
    WHERE s.machine_id = a.machine_id AND s.account_id <> sqlc.arg('account_id')
) AS shared
FROM darkbloom_machine_aliases a
WHERE a.kind = 'mda_serial' AND a.scope = '' AND a.digest = ANY(sqlc.arg('digests')::text[]);

-- Scrub statements, in erasure_rules.go order.

-- name: CountUsersRow :one
SELECT COUNT(*) FROM users WHERE account_id = $1;

-- name: ScrubUsersRow :execrows
UPDATE users SET email = '', privy_user_id = sqlc.arg('privy_user_id'), stripe_account_id = '',
    stripe_account_status = '', stripe_account_country = '', stripe_destination_type = '',
    stripe_destination_last4 = '', stripe_instant_eligible = FALSE
WHERE account_id = sqlc.arg('account_id');

-- name: CountAPIKeysRows :one
SELECT COUNT(*) FROM api_keys WHERE owner_account_id = $1;

-- name: ScrubAPIKeysRows :execrows
UPDATE api_keys SET name = '' WHERE owner_account_id = $1;

-- name: CountProviderTokensRows :one
SELECT COUNT(*) FROM provider_tokens WHERE account_id = $1;

-- name: ScrubProviderTokensRows :execrows
UPDATE provider_tokens SET label = '' WHERE account_id = $1;

-- name: CountDeviceCodesRows :one
SELECT COUNT(*) FROM device_codes WHERE account_id = $1;

-- name: DeleteDeviceCodesRows :execrows
DELETE FROM device_codes WHERE account_id = $1;

-- name: CountProvidersRows :one
SELECT COUNT(*) FROM providers WHERE account_id = $1;

-- name: ScrubProvidersRows :execrows
UPDATE providers SET serial_number = '', location = NULL, attestation_result = NULL, mda_cert_chain = NULL
WHERE account_id = $1;

-- name: CountProviderSessionsRows :one
SELECT COUNT(*) FROM provider_sessions WHERE account_id = $1;

-- name: ScrubProviderSessionsRows :execrows
UPDATE provider_sessions SET serial_number = '', disconnected_at = COALESCE(disconnected_at, NOW())
WHERE account_id = $1;

-- name: CountProviderLogReportsRows :one
SELECT COUNT(*) FROM provider_log_reports WHERE account_id = $1;

-- name: DeleteProviderLogReportsRows :execrows
DELETE FROM provider_log_reports WHERE account_id = $1;

-- name: CountProviderTrustReuseRows :one
SELECT COUNT(*) FROM provider_trust_reuse WHERE se_pubkey = ANY(sqlc.arg('se_keys')::text[]);

-- name: DeleteProviderTrustReuseRows :execrows
DELETE FROM provider_trust_reuse WHERE se_pubkey = ANY(sqlc.arg('se_keys')::text[]);

-- name: CountProviderVerificationJobsRows :one
SELECT COUNT(*) FROM provider_verification_jobs WHERE se_pubkey = ANY(sqlc.arg('se_keys')::text[]);

-- name: DeleteProviderVerificationJobsRows :execrows
DELETE FROM provider_verification_jobs WHERE se_pubkey = ANY(sqlc.arg('se_keys')::text[]);

-- name: CountCodeAttestationsRows :one
SELECT COUNT(*) FROM code_attestations WHERE se_pubkey = ANY(sqlc.arg('se_keys')::text[]);

-- name: DeleteCodeAttestationsRows :execrows
DELETE FROM code_attestations WHERE se_pubkey = ANY(sqlc.arg('se_keys')::text[]);

-- name: CountCodeAttestPushBudgetsRows :one
SELECT COUNT(*) FROM code_attest_push_budgets WHERE se_pubkey = ANY(sqlc.arg('se_keys')::text[]);

-- name: DeleteCodeAttestPushBudgetsRows :execrows
DELETE FROM code_attest_push_budgets WHERE se_pubkey = ANY(sqlc.arg('se_keys')::text[]);

-- name: CountAccountMachineAliasesRows :one
SELECT COUNT(*) FROM darkbloom_machine_aliases WHERE kind IN ('app_attest', 'legacy_se') AND scope = $1;

-- name: DeleteAccountMachineAliasesRows :execrows
DELETE FROM darkbloom_machine_aliases WHERE kind IN ('app_attest', 'legacy_se') AND scope = $1;

-- name: CountMDASerialAliasesRows :one
SELECT COUNT(*) FROM darkbloom_machine_aliases
WHERE kind = 'mda_serial' AND scope = '' AND digest = ANY(sqlc.arg('digests')::text[]);

-- name: DeleteMDASerialAliasesRows :execrows
DELETE FROM darkbloom_machine_aliases
WHERE kind = 'mda_serial' AND scope = '' AND digest = ANY(sqlc.arg('digests')::text[]);

-- name: CountAppAttestEvidenceBlobsRows :one
SELECT COUNT(*) FROM app_attest_evidence_blobs
WHERE evidence_id IN (SELECT id FROM app_attest_evidence WHERE session_id = ANY(sqlc.arg('session_ids')::text[]));

-- name: DeleteAppAttestEvidenceBlobsRows :execrows
DELETE FROM app_attest_evidence_blobs
WHERE evidence_id IN (SELECT id FROM app_attest_evidence WHERE session_id = ANY(sqlc.arg('session_ids')::text[]));

-- name: CountAppAttestEvidenceRows :one
SELECT COUNT(*) FROM app_attest_evidence WHERE session_id = ANY(sqlc.arg('session_ids')::text[]);

-- name: ScrubAppAttestEvidenceRows :execrows
UPDATE app_attest_evidence SET context = '{}' WHERE session_id = ANY(sqlc.arg('session_ids')::text[]);

-- name: CountAppAttestReceiptJobsRows :one
SELECT COUNT(*) FROM app_attest_receipt_jobs WHERE key_id = ANY(sqlc.arg('key_ids')::text[]);

-- name: DeleteAppAttestReceiptJobsRows :execrows
DELETE FROM app_attest_receipt_jobs WHERE key_id = ANY(sqlc.arg('key_ids')::text[]);

-- name: CountAppAttestReceiptBlobsRows :one
SELECT COUNT(*) FROM app_attest_receipt_blobs
WHERE receipt_id IN (SELECT id FROM app_attest_receipts WHERE key_id = ANY(sqlc.arg('key_ids')::text[]));

-- name: DeleteAppAttestReceiptBlobsRows :execrows
DELETE FROM app_attest_receipt_blobs
WHERE receipt_id IN (SELECT id FROM app_attest_receipts WHERE key_id = ANY(sqlc.arg('key_ids')::text[]));

-- name: CountAppAttestReceiptsRows :one
SELECT COUNT(*) FROM app_attest_receipts WHERE key_id = ANY(sqlc.arg('key_ids')::text[]);

-- name: ScrubAppAttestReceiptsRows :execrows
UPDATE app_attest_receipts SET context = '{}' WHERE key_id = ANY(sqlc.arg('key_ids')::text[]);

-- name: CountUsageLocationRows :one
SELECT COUNT(*) FROM usage WHERE consumer_key_hash = $1 AND request_location IS NOT NULL;

-- name: ScrubUsageLocationRows :execrows
UPDATE usage SET request_location = NULL WHERE consumer_key_hash = $1 AND request_location IS NOT NULL;

-- name: CountConsumerRegionRows :one
SELECT COUNT(*) FROM inference_routes WHERE consumer_key_hash = $1 AND consumer_region IS NOT NULL;

-- name: ScrubConsumerRegionRows :execrows
UPDATE inference_routes SET consumer_region = NULL WHERE consumer_key_hash = $1 AND consumer_region IS NOT NULL;

-- name: CountProviderRegionRows :one
SELECT COUNT(*) FROM inference_routes
WHERE provider_id = ANY(sqlc.arg('provider_ids')::text[]) AND provider_region IS NOT NULL;

-- name: ScrubProviderRegionRows :execrows
UPDATE inference_routes SET provider_region = NULL
WHERE provider_id = ANY(sqlc.arg('provider_ids')::text[]) AND provider_region IS NOT NULL;

-- name: CountReferrersRow :one
SELECT COUNT(*) FROM referrers WHERE account_id = $1;

-- name: ScrubReferrersRow :execrows
UPDATE referrers SET code = sqlc.arg('code') WHERE account_id = sqlc.arg('account_id');

-- name: CountReferralCodeCopies :one
SELECT COUNT(*) FROM billing_sessions WHERE referral_code = $1;

-- name: ScrubReferralCodeCopies :execrows
UPDATE billing_sessions SET referral_code = sqlc.arg('new_code') WHERE referral_code = sqlc.arg('old_code');

-- name: CountBillingSessionsRows :one
SELECT COUNT(*) FROM billing_sessions WHERE account_id = $1;

-- name: ScrubBillingSessionsRows :execrows
UPDATE billing_sessions
SET external_id = '', status = CASE WHEN status = 'pending' THEN 'erased' ELSE status END
WHERE account_id = $1;

-- name: CountStripeLedgerReferences :one
SELECT COUNT(*) FROM ledger_entries WHERE account_id = $1 AND reference LIKE 'stripe:%';

-- name: ScrubStripeLedgerReferences :execrows
UPDATE ledger_entries SET reference = 'stripe:erased' WHERE account_id = $1 AND reference LIKE 'stripe:%';

-- name: CountAdminNoteLedgerReferences :one
SELECT COUNT(*) FROM ledger_entries
WHERE account_id = $1 AND entry_type IN ('admin_credit', 'admin_reward') AND reference <> entry_type;

-- name: ScrubAdminNoteLedgerReferences :execrows
UPDATE ledger_entries SET reference = entry_type
WHERE account_id = $1 AND entry_type IN ('admin_credit', 'admin_reward') AND reference <> entry_type;

-- name: CountGlobalRecipientRow :one
SELECT COUNT(*) FROM global_payout_recipients WHERE account_id = $1;

-- name: TombstoneGlobalRecipientRow :execrows
UPDATE global_payout_recipients SET country = '', data = sqlc.arg('data') WHERE account_id = sqlc.arg('account_id');

-- name: CountGlobalPayoutRows :one
SELECT COUNT(*) FROM global_payout_withdrawals WHERE account_id = $1;

-- name: ScrubGlobalPayoutRows :execrows
UPDATE global_payout_withdrawals
SET data = data || '{"recipient_id": "", "payout_method_id": "", "request": {}}'::jsonb
WHERE account_id = $1;

-- name: CountStripeWithdrawalRows :one
SELECT COUNT(*) FROM stripe_withdrawals WHERE account_id = $1;

-- name: ScrubStripeWithdrawalRows :execrows
UPDATE stripe_withdrawals SET stripe_account_id = '' WHERE account_id = $1;

-- name: CountPaymentConsumerAddress :one
SELECT COUNT(*) FROM payments WHERE consumer_address = $1;

-- name: ScrubPaymentConsumerAddress :execrows
UPDATE payments SET consumer_address = sqlc.arg('replacement') WHERE consumer_address = sqlc.arg('address');

-- name: CountPaymentProviderAddress :one
SELECT COUNT(*) FROM payments WHERE provider_address = $1;

-- name: ScrubPaymentProviderAddress :execrows
UPDATE payments SET provider_address = sqlc.arg('replacement') WHERE provider_address = sqlc.arg('address');

-- name: CountProviderPayoutAddress :one
SELECT COUNT(*) FROM provider_payouts WHERE provider_address = $1;

-- name: ScrubProviderPayoutAddress :execrows
UPDATE provider_payouts SET provider_address = sqlc.arg('replacement') WHERE provider_address = sqlc.arg('address');
