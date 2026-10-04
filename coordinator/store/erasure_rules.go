package store

import (
	"context"

	"github.com/eigeninference/d-inference/coordinator/store/storedb"
)

// This file is the PII rule table of account erasure: for every table that
// holds personal data of an account, how its rows link to the account and
// what the scrub does to them. PostgresStore.ScrubAccount runs these rules in
// order; MemoryStore.ScrubAccount applies the same rules to its maps. The
// marker test (erasure_marker_test.go) seeds every table listed here, plus a
// second account, with marker strings, then searches every text, JSON, array
// and bytea column of every table for the marker. It proves the rules for the
// seeded rows; a new table or column that holds personal data needs a rule
// here and a row in the test's fixture, or the test cannot see it.
//
// IDs are not personal data and stay: account IDs, provider and machine IDs,
// request IDs, key IDs and public keys. What is kept and why is listed in
// (*erasureKeys).retained and in docs/operations/account-erasure.md.

// piiAction is what a rule does to a column or a row.
type piiAction string

const (
	piiSetEmpty     piiAction = "set_empty"         // '' for text
	piiSetNull      piiAction = "set_null"          // NULL for JSON or text
	piiSetEmptyJSON piiAction = "set_empty_json"    // '{}' for a NOT NULL JSON column
	piiSetRandom    piiAction = "set_unique_random" // a fresh random value, unique per account or address
	piiRewrite      piiAction = "rewrite"           // a fixed value that drops the personal part
	piiTombstone    piiAction = "tombstone"         // row kept with every personal field cleared
	piiDeleteRow    piiAction = "delete_row"
)

// piiColumn is one personal column and its action.
type piiColumn struct {
	Name   string
	Action piiAction
}

// piiStatement is one scrub statement and the count query with the same
// predicate. The scrub runs count, then apply, in one transaction and
// aborts when the two differ.
type piiStatement struct {
	count func(context.Context, *storedb.Queries) (int64, error)
	apply func(context.Context, *storedb.Queries) (int64, error)
}

// piiRule is one row of the rule table.
type piiRule struct {
	Name    string
	Table   string
	Link    string      // how rows link to the account
	Columns []piiColumn // nil for piiDeleteRow rules
	Delete  bool        // the rule deletes the linked rows
	// statements returns the statements for the collected keys; none when
	// the account has no linked keys of that kind.
	statements func(k *erasureKeys) []piiStatement
}

func (r piiRule) action() string {
	if r.Delete {
		return string(piiDeleteRow)
	}
	return "update"
}

func (r piiRule) columnNames() []string {
	names := make([]string, 0, len(r.Columns))
	for _, c := range r.Columns {
		names = append(names, c.Name)
	}
	return names
}

// rowCount is the report row of the rule for rows changed (or counted).
func (r piiRule) rowCount(rows int64) ErasureRowCount {
	return ErasureRowCount{Rule: r.Name, Table: r.Table, Columns: r.columnNames(), Action: r.action(), Rows: rows}
}

// one wraps a single statement.
func one(count, apply func(context.Context, *storedb.Queries) (int64, error)) []piiStatement {
	return []piiStatement{{count: count, apply: apply}}
}

// byKey is one statement whose count and apply queries take the same key.
func byKey(key string, count, apply func(*storedb.Queries, context.Context, string) (int64, error)) []piiStatement {
	return one(
		func(ctx context.Context, q *storedb.Queries) (int64, error) { return count(q, ctx, key) },
		func(ctx context.Context, q *storedb.Queries) (int64, error) { return apply(q, ctx, key) })
}

// byKeys is one statement whose count and apply queries take the same key
// list; none when the list is empty.
func byKeys(keys []string, count, apply func(*storedb.Queries, context.Context, []string) (int64, error)) []piiStatement {
	if len(keys) == 0 {
		return nil
	}
	return one(
		func(ctx context.Context, q *storedb.Queries) (int64, error) { return count(q, ctx, keys) },
		func(ctx context.Context, q *storedb.Queries) (int64, error) { return apply(q, ctx, keys) })
}

// erasureRules is the rule table, in scrub order.
var erasureRules = []piiRule{
	{
		Name: "users", Table: "users", Link: "account_id",
		Columns: []piiColumn{
			{"email", piiSetEmpty}, {"privy_user_id", piiSetRandom}, {"stripe_account_id", piiSetEmpty},
			{"stripe_account_status", piiSetEmpty}, {"stripe_account_country", piiSetEmpty},
			{"stripe_destination_type", piiSetEmpty}, {"stripe_destination_last4", piiSetEmpty},
		},
		statements: func(k *erasureKeys) []piiStatement {
			return one(
				func(ctx context.Context, q *storedb.Queries) (int64, error) { return q.CountUsersRow(ctx, k.AccountID) },
				func(ctx context.Context, q *storedb.Queries) (int64, error) {
					return q.ScrubUsersRow(ctx, storedb.ScrubUsersRowParams{AccountID: k.AccountID, PrivyUserID: k.PrivyReplacement})
				})
		},
	},
	{
		Name: "api_keys", Table: "api_keys", Link: "owner_account_id",
		Columns: []piiColumn{{"name", piiSetEmpty}},
		statements: func(k *erasureKeys) []piiStatement {
			return byKey(k.AccountID, (*storedb.Queries).CountAPIKeysRows, (*storedb.Queries).ScrubAPIKeysRows)
		},
	},
	{
		Name: "provider_tokens", Table: "provider_tokens", Link: "account_id",
		Columns: []piiColumn{{"label", piiSetEmpty}},
		statements: func(k *erasureKeys) []piiStatement {
			return byKey(k.AccountID, (*storedb.Queries).CountProviderTokensRows, (*storedb.Queries).ScrubProviderTokensRows)
		},
	},
	{
		Name: "device_codes", Table: "device_codes", Link: "account_id", Delete: true,
		statements: func(k *erasureKeys) []piiStatement {
			return byKey(k.AccountID, (*storedb.Queries).CountDeviceCodesRows, (*storedb.Queries).DeleteDeviceCodesRows)
		},
	},
	{
		Name: "providers", Table: "providers", Link: "account_id",
		Columns: []piiColumn{
			{"serial_number", piiSetEmpty}, {"location", piiSetNull},
			{"attestation_result", piiSetNull}, {"mda_cert_chain", piiSetNull},
		},
		statements: func(k *erasureKeys) []piiStatement {
			return byKey(k.AccountID, (*storedb.Queries).CountProvidersRows, (*storedb.Queries).ScrubProvidersRows)
		},
	},
	{
		// Open sessions are closed so a late TouchProviderSession cannot
		// backfill the serial again.
		Name: "provider_sessions", Table: "provider_sessions", Link: "account_id",
		Columns: []piiColumn{{"serial_number", piiSetEmpty}},
		statements: func(k *erasureKeys) []piiStatement {
			return byKey(k.AccountID, (*storedb.Queries).CountProviderSessionsRows, (*storedb.Queries).ScrubProviderSessionsRows)
		},
	},
	{
		Name: "provider_log_reports", Table: "provider_log_reports", Link: "account_id", Delete: true,
		statements: func(k *erasureKeys) []piiStatement {
			return byKey(k.AccountID, (*storedb.Queries).CountProviderLogReportsRows, (*storedb.Queries).DeleteProviderLogReportsRows)
		},
	},
	{
		Name: "provider_trust_reuse", Table: "provider_trust_reuse", Link: "se_pubkey of the account's providers", Delete: true,
		statements: func(k *erasureKeys) []piiStatement {
			return byKeys(k.SEKeys, (*storedb.Queries).CountProviderTrustReuseRows, (*storedb.Queries).DeleteProviderTrustReuseRows)
		},
	},
	{
		Name: "provider_verification_jobs", Table: "provider_verification_jobs", Link: "se_pubkey of the account's providers", Delete: true,
		statements: func(k *erasureKeys) []piiStatement {
			return byKeys(k.SEKeys, (*storedb.Queries).CountProviderVerificationJobsRows, (*storedb.Queries).DeleteProviderVerificationJobsRows)
		},
	},
	{
		// apns_token is a device push token.
		Name: "code_attestations", Table: "code_attestations", Link: "se_pubkey of the account's providers", Delete: true,
		statements: func(k *erasureKeys) []piiStatement {
			return byKeys(k.SEKeys, (*storedb.Queries).CountCodeAttestationsRows, (*storedb.Queries).DeleteCodeAttestationsRows)
		},
	},
	{
		Name: "code_attest_push_budgets", Table: "code_attest_push_budgets", Link: "se_pubkey of the account's providers", Delete: true,
		statements: func(k *erasureKeys) []piiStatement {
			return byKeys(k.SEKeys, (*storedb.Queries).CountCodeAttestPushBudgetsRows, (*storedb.Queries).DeleteCodeAttestPushBudgetsRows)
		},
	},
	{
		// app_attest and legacy_se aliases are digests of keys, scoped to the
		// account.
		Name: "machine_aliases_account", Table: "darkbloom_machine_aliases", Link: "scope = account_id, kind app_attest or legacy_se", Delete: true,
		statements: func(k *erasureKeys) []piiStatement {
			return byKey(k.AccountID, (*storedb.Queries).CountAccountMachineAliasesRows, (*storedb.Queries).DeleteAccountMachineAliasesRows)
		},
	},
	{
		// mda_serial aliases are digests of a serial number with no account
		// scope. One is deleted only when no other account has a session on
		// its machine; a shared one is kept and reported (retainedSharedMDAAlias).
		Name: "machine_aliases_mda_serial", Table: "darkbloom_machine_aliases", Link: "digest of the account's serial numbers, machine not shared", Delete: true,
		statements: func(k *erasureKeys) []piiStatement {
			return byKeys(k.MDADigestsToDelete, (*storedb.Queries).CountMDASerialAliasesRows, (*storedb.Queries).DeleteMDASerialAliasesRows)
		},
	},
	{
		// Raw App Attest proofs from the account's provider sessions.
		Name: "app_attest_evidence_blobs", Table: "app_attest_evidence_blobs", Link: "evidence of the account's provider sessions", Delete: true,
		statements: func(k *erasureKeys) []piiStatement {
			return byKeys(k.ProviderIDs, (*storedb.Queries).CountAppAttestEvidenceBlobsRows, (*storedb.Queries).DeleteAppAttestEvidenceBlobsRows)
		},
	},
	{
		// The context holds the client transcript and runtime diagnostics
		// (boot time, launch session). Outcome, action and hashes stay.
		Name: "app_attest_evidence", Table: "app_attest_evidence", Link: "session_id in the account's provider IDs",
		Columns: []piiColumn{{"context", piiSetEmptyJSON}},
		statements: func(k *erasureKeys) []piiStatement {
			return byKeys(k.ProviderIDs, (*storedb.Queries).CountAppAttestEvidenceRows, (*storedb.Queries).ScrubAppAttestEvidenceRows)
		},
	},
	{
		// No more Apple receipt refreshes for the erased account's keys.
		Name: "app_attest_receipt_jobs", Table: "app_attest_receipt_jobs", Link: "key_id of the account's App Attest keys", Delete: true,
		statements: func(k *erasureKeys) []piiStatement {
			return byKeys(k.AppAttestKeyIDs, (*storedb.Queries).CountAppAttestReceiptJobsRows, (*storedb.Queries).DeleteAppAttestReceiptJobsRows)
		},
	},
	{
		// Raw Apple receipts and HTTP responses for the account's keys.
		Name: "app_attest_receipt_blobs", Table: "app_attest_receipt_blobs", Link: "receipts of the account's App Attest keys", Delete: true,
		statements: func(k *erasureKeys) []piiStatement {
			return byKeys(k.AppAttestKeyIDs, (*storedb.Queries).CountAppAttestReceiptBlobsRows, (*storedb.Queries).DeleteAppAttestReceiptBlobsRows)
		},
	},
	{
		Name: "app_attest_receipts", Table: "app_attest_receipts", Link: "key_id of the account's App Attest keys",
		Columns: []piiColumn{{"context", piiSetEmptyJSON}},
		statements: func(k *erasureKeys) []piiStatement {
			return byKeys(k.AppAttestKeyIDs, (*storedb.Queries).CountAppAttestReceiptsRows, (*storedb.Queries).ScrubAppAttestReceiptsRows)
		},
	},
	{
		// IP-derived location of the account's requests as a consumer.
		Name: "usage_request_location", Table: "usage", Link: "consumer_key_hash = sha256(account_id)",
		Columns: []piiColumn{{"request_location", piiSetNull}},
		statements: func(k *erasureKeys) []piiStatement {
			return byKey(k.ConsumerKeyHash, (*storedb.Queries).CountUsageLocationRows, (*storedb.Queries).ScrubUsageLocationRows)
		},
	},
	{
		Name: "inference_routes_consumer_region", Table: "inference_routes", Link: "consumer_key_hash = sha256(account_id)",
		Columns: []piiColumn{{"consumer_region", piiSetNull}},
		statements: func(k *erasureKeys) []piiStatement {
			return byKey(k.ConsumerKeyHash, (*storedb.Queries).CountConsumerRegionRows, (*storedb.Queries).ScrubConsumerRegionRows)
		},
	},
	{
		Name: "inference_routes_provider_region", Table: "inference_routes", Link: "provider_id in the account's provider IDs",
		Columns: []piiColumn{{"provider_region", piiSetNull}},
		statements: func(k *erasureKeys) []piiStatement {
			return byKeys(k.ProviderIDs, (*storedb.Queries).CountProviderRegionRows, (*storedb.Queries).ScrubProviderRegionRows)
		},
	},
	{
		// A referrer code is chosen by the user. referrals.referrer_code
		// follows through ON UPDATE CASCADE.
		Name: "referrers", Table: "referrers", Link: "account_id",
		Columns: []piiColumn{{"code", piiSetRandom}},
		statements: func(k *erasureKeys) []piiStatement {
			return one(
				func(ctx context.Context, q *storedb.Queries) (int64, error) {
					return q.CountReferrersRow(ctx, k.AccountID)
				},
				func(ctx context.Context, q *storedb.Queries) (int64, error) {
					return q.ScrubReferrersRow(ctx, storedb.ScrubReferrersRowParams{AccountID: k.AccountID, Code: k.ReferrerReplacement})
				})
		},
	},
	{
		// Billing sessions of any account that copied the referrer code.
		Name: "billing_sessions_referral_code", Table: "billing_sessions", Link: "referral_code = the account's referrer code",
		Columns: []piiColumn{{"referral_code", piiSetRandom}},
		statements: func(k *erasureKeys) []piiStatement {
			if k.ReferrerCode == "" {
				return nil
			}
			return one(
				func(ctx context.Context, q *storedb.Queries) (int64, error) {
					return q.CountReferralCodeCopies(ctx, k.ReferrerCode)
				},
				func(ctx context.Context, q *storedb.Queries) (int64, error) {
					return q.ScrubReferralCodeCopies(ctx, storedb.ScrubReferralCodeCopiesParams{OldCode: k.ReferrerCode, NewCode: k.ReferrerReplacement})
				})
		},
	},
	{
		// Checkout Session IDs move to the outbox for Stripe redaction. A
		// pending session becomes 'erased' so a late webhook is acknowledged.
		Name: "billing_sessions", Table: "billing_sessions", Link: "account_id",
		Columns: []piiColumn{{"external_id", piiSetEmpty}},
		statements: func(k *erasureKeys) []piiStatement {
			return byKey(k.AccountID, (*storedb.Queries).CountBillingSessionsRows, (*storedb.Queries).ScrubBillingSessionsRows)
		},
	},
	{
		// "stripe:<checkout session id>" becomes "stripe:erased".
		Name: "ledger_entries_stripe_reference", Table: "ledger_entries", Link: "account_id, reference stripe:*",
		Columns: []piiColumn{{"reference", piiRewrite}},
		statements: func(k *erasureKeys) []piiStatement {
			return byKey(k.AccountID, (*storedb.Queries).CountStripeLedgerReferences, (*storedb.Queries).ScrubStripeLedgerReferences)
		},
	},
	{
		// An admin credit or reward reference can carry a free-text note.
		Name: "ledger_entries_admin_note", Table: "ledger_entries", Link: "account_id, admin_credit or admin_reward",
		Columns: []piiColumn{{"reference", piiRewrite}},
		statements: func(k *erasureKeys) []piiStatement {
			return byKey(k.AccountID, (*storedb.Queries).CountAdminNoteLedgerReferences, (*storedb.Queries).ScrubAdminNoteLedgerReferences)
		},
	},
	{
		// The same tombstone as RemoveGlobalRecipient: a new onboarding
		// generation and no recipient, payout method, last4 or country.
		Name: "global_payout_recipients", Table: "global_payout_recipients", Link: "account_id",
		Columns: []piiColumn{{"country", piiSetEmpty}, {"data", piiTombstone}},
		statements: func(k *erasureKeys) []piiStatement {
			return one(
				func(ctx context.Context, q *storedb.Queries) (int64, error) {
					return q.CountGlobalRecipientRow(ctx, k.AccountID)
				},
				func(ctx context.Context, q *storedb.Queries) (int64, error) {
					return q.TombstoneGlobalRecipientRow(ctx, storedb.TombstoneGlobalRecipientRowParams{AccountID: k.AccountID, Data: k.GlobalRecipientTombstone})
				})
		},
	},
	{
		// Amounts, status, country and the payment ID stay as the financial
		// record; the Stripe recipient and payout method and the request go.
		Name: "global_payout_withdrawals", Table: "global_payout_withdrawals", Link: "account_id",
		Columns: []piiColumn{{"data.recipient_id", piiSetEmpty}, {"data.payout_method_id", piiSetEmpty}, {"data.request", piiSetEmptyJSON}},
		statements: func(k *erasureKeys) []piiStatement {
			return byKey(k.AccountID, (*storedb.Queries).CountGlobalPayoutRows, (*storedb.Queries).ScrubGlobalPayoutRows)
		},
	},
	{
		// Transfer and payout IDs and amounts stay as the financial record.
		Name: "stripe_withdrawals", Table: "stripe_withdrawals", Link: "account_id",
		Columns: []piiColumn{{"stripe_account_id", piiSetEmpty}},
		statements: func(k *erasureKeys) []piiStatement {
			return byKey(k.AccountID, (*storedb.Queries).CountStripeWithdrawalRows, (*storedb.Queries).ScrubStripeWithdrawalRows)
		},
	},
	{
		// payments and provider_payouts have no account column and no reader
		// since #1208. The admin request names the wallet addresses; each
		// address gets one random value for all its rows in both tables.
		Name: "payments_consumer_address", Table: "payments", Link: "consumer_address in the request's wallet addresses",
		Columns: []piiColumn{{"consumer_address", piiSetRandom}},
		statements: func(k *erasureKeys) []piiStatement {
			return walletStatements(k, (*storedb.Queries).CountPaymentConsumerAddress,
				func(q *storedb.Queries, ctx context.Context, w walletReplacement) (int64, error) {
					return q.ScrubPaymentConsumerAddress(ctx, storedb.ScrubPaymentConsumerAddressParams{Address: w.Address, Replacement: w.Replacement})
				})
		},
	},
	{
		Name: "payments_provider_address", Table: "payments", Link: "provider_address in the request's wallet addresses",
		Columns: []piiColumn{{"provider_address", piiSetRandom}},
		statements: func(k *erasureKeys) []piiStatement {
			return walletStatements(k, (*storedb.Queries).CountPaymentProviderAddress,
				func(q *storedb.Queries, ctx context.Context, w walletReplacement) (int64, error) {
					return q.ScrubPaymentProviderAddress(ctx, storedb.ScrubPaymentProviderAddressParams{Address: w.Address, Replacement: w.Replacement})
				})
		},
	},
	{
		Name: "provider_payouts_address", Table: "provider_payouts", Link: "provider_address in the request's wallet addresses",
		Columns: []piiColumn{{"provider_address", piiSetRandom}},
		statements: func(k *erasureKeys) []piiStatement {
			return walletStatements(k, (*storedb.Queries).CountProviderPayoutAddress,
				func(q *storedb.Queries, ctx context.Context, w walletReplacement) (int64, error) {
					return q.ScrubProviderPayoutAddress(ctx, storedb.ScrubProviderPayoutAddressParams{Address: w.Address, Replacement: w.Replacement})
				})
		},
	},
}

// walletStatements returns one statement per wallet address.
func walletStatements(k *erasureKeys,
	count func(*storedb.Queries, context.Context, string) (int64, error),
	apply func(*storedb.Queries, context.Context, walletReplacement) (int64, error),
) []piiStatement {
	out := make([]piiStatement, 0, len(k.Wallets))
	for _, w := range k.Wallets {
		out = append(out, piiStatement{
			count: func(ctx context.Context, q *storedb.Queries) (int64, error) { return count(q, ctx, w.Address) },
			apply: func(ctx context.Context, q *storedb.Queries) (int64, error) { return apply(q, ctx, w) },
		})
	}
	return out
}

// These reasons explain the personal-looking data the scrub keeps.
// (*erasureKeys).retained reports how many rows each one has for the account.
const (
	retainedSharedMDAAlias     = "mda_serial alias of a machine that another account also used; deleting it would break that account's machine identity"
	retainedSharedSEKey        = "Secure Enclave key that another account's provider also uses; its trust, verification and code-attestation rows belong to that account too"
	retainedSharedAppAttestKey = "App Attest key that another account's sessions also used; its receipts belong to that account too"
)
