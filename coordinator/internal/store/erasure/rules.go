package erasure

import "github.com/eigeninference/d-inference/coordinator/store"

// The rule table lists, for every table that holds personal data of an
// account, how its rows link to the account and what the scrub does to them.
// The marker test (coordinator/tests/store/postgres/erasure_marker_test.go)
// seeds every table listed here, plus a second account, with marker strings,
// then searches every text, JSON, array and bytea column of every table for
// the marker. It proves the rules for the seeded rows; a new table or column
// that holds personal data needs a rule here and a row in the test's
// fixture, or the test cannot see it.
//
// IDs are not personal data and stay: account IDs, provider and machine IDs,
// request IDs, key IDs and public keys. What is kept and why is listed in
// (*Keys).Retained and in docs/operations/account-erasure.md.

// Action is what a rule does to a column or a row.
type Action string

const (
	SetEmpty     Action = "set_empty"         // '' for text
	SetNull      Action = "set_null"          // NULL for JSON or text
	SetEmptyJSON Action = "set_empty_json"    // '{}' for a NOT NULL JSON column
	SetRandom    Action = "set_unique_random" // a fresh random value, unique per account or address
	Rewrite      Action = "rewrite"           // a fixed value that drops the personal part
	Tombstone    Action = "tombstone"         // row kept with every personal field cleared
	DeleteRow    Action = "delete_row"
)

// Column is one personal column and its action.
type Column struct {
	Name   string
	Action Action
}

// Rule is one row of the rule table.
type Rule struct {
	Name    string
	Table   string
	Link    string   // how rows link to the account
	Columns []Column // nil for DeleteRow rules
	Delete  bool     // the rule deletes the linked rows
}

func (r Rule) action() string {
	if r.Delete {
		return string(DeleteRow)
	}
	return "update"
}

func (r Rule) columnNames() []string {
	names := make([]string, 0, len(r.Columns))
	for _, c := range r.Columns {
		names = append(names, c.Name)
	}
	return names
}

// RowCount is the report row of the rule for rows changed (or counted).
func (r Rule) RowCount(rows int64) store.ErasureRowCount {
	return store.ErasureRowCount{Rule: r.Name, Table: r.Table, Columns: r.columnNames(), Action: r.action(), Rows: rows}
}

// Rules is the rule table, in scrub order.
var Rules = []Rule{
	{
		Name: "users", Table: "users", Link: "account_id",
		Columns: []Column{
			{"email", SetEmpty}, {"privy_user_id", SetRandom}, {"stripe_account_id", SetEmpty},
			{"stripe_account_status", SetEmpty}, {"stripe_account_country", SetEmpty},
			{"stripe_destination_type", SetEmpty}, {"stripe_destination_last4", SetEmpty},
		},
	},
	{
		Name: "api_keys", Table: "api_keys", Link: "owner_account_id",
		Columns: []Column{{"name", SetEmpty}},
	},
	{
		Name: "provider_tokens", Table: "provider_tokens", Link: "account_id",
		Columns: []Column{{"label", SetEmpty}},
	},
	{
		Name: "device_codes", Table: "device_codes", Link: "account_id", Delete: true,
	},
	{
		Name: "providers", Table: "providers", Link: "account_id",
		Columns: []Column{
			{"serial_number", SetEmpty}, {"location", SetNull},
			{"attestation_result", SetNull}, {"mda_cert_chain", SetNull},
		},
	},
	{
		// Open sessions are closed so a late TouchProviderSession cannot
		// backfill the serial again.
		Name: "provider_sessions", Table: "provider_sessions", Link: "account_id",
		Columns: []Column{{"serial_number", SetEmpty}},
	},
	{
		Name: "provider_log_reports", Table: "provider_log_reports", Link: "account_id", Delete: true,
	},
	{
		Name: "provider_trust_reuse", Table: "provider_trust_reuse", Link: "se_pubkey of the account's providers", Delete: true,
	},
	{
		Name: "provider_verification_jobs", Table: "provider_verification_jobs", Link: "se_pubkey of the account's providers", Delete: true,
	},
	{
		// apns_token is a device push token.
		Name: "code_attestations", Table: "code_attestations", Link: "se_pubkey of the account's providers", Delete: true,
	},
	{
		Name: "code_attest_push_budgets", Table: "code_attest_push_budgets", Link: "se_pubkey of the account's providers", Delete: true,
	},
	{
		// app_attest and legacy_se aliases are digests of keys, scoped to the
		// account.
		Name: "machine_aliases_account", Table: "darkbloom_machine_aliases", Link: "scope = account_id, kind app_attest or legacy_se", Delete: true,
	},
	{
		// mda_serial aliases are digests of a serial number with no account
		// scope. One is deleted only when no other account has a session on
		// its machine; a shared one is kept and reported (retainedSharedMDAAlias).
		Name: "machine_aliases_mda_serial", Table: "darkbloom_machine_aliases", Link: "digest of the account's serial numbers, machine not shared", Delete: true,
	},
	{
		// Raw App Attest proofs from the account's provider sessions.
		Name: "app_attest_evidence_blobs", Table: "app_attest_evidence_blobs", Link: "evidence of the account's provider sessions", Delete: true,
	},
	{
		// The context holds the client transcript and runtime diagnostics
		// (boot time, launch session). Outcome, action and hashes stay.
		Name: "app_attest_evidence", Table: "app_attest_evidence", Link: "session_id in the account's provider IDs",
		Columns: []Column{{"context", SetEmptyJSON}},
	},
	{
		// No more Apple receipt refreshes for the erased account's keys.
		Name: "app_attest_receipt_jobs", Table: "app_attest_receipt_jobs", Link: "key_id of the account's App Attest keys", Delete: true,
	},
	{
		// Raw Apple receipts and HTTP responses for the account's keys.
		Name: "app_attest_receipt_blobs", Table: "app_attest_receipt_blobs", Link: "receipts of the account's App Attest keys", Delete: true,
	},
	{
		Name: "app_attest_receipts", Table: "app_attest_receipts", Link: "key_id of the account's App Attest keys",
		Columns: []Column{{"context", SetEmptyJSON}},
	},
	{
		// IP-derived location of the account's requests as a consumer.
		Name: "usage_request_location", Table: "usage", Link: "consumer_key_hash = sha256(account_id)",
		Columns: []Column{{"request_location", SetNull}},
	},
	{
		Name: "inference_routes_consumer_region", Table: "inference_routes", Link: "consumer_key_hash = sha256(account_id)",
		Columns: []Column{{"consumer_region", SetNull}},
	},
	{
		Name: "inference_routes_provider_region", Table: "inference_routes", Link: "provider_id in the account's provider IDs",
		Columns: []Column{{"provider_region", SetNull}},
	},
	{
		// A referrer code is chosen by the user. referrals.referrer_code
		// follows through ON UPDATE CASCADE.
		Name: "referrers", Table: "referrers", Link: "account_id",
		Columns: []Column{{"code", SetRandom}},
	},
	{
		// Billing sessions of any account that copied the referrer code.
		Name: "billing_sessions_referral_code", Table: "billing_sessions", Link: "referral_code = the account's referrer code",
		Columns: []Column{{"referral_code", SetRandom}},
	},
	{
		// Checkout Session IDs move to the outbox for Stripe redaction. A
		// pending session becomes 'erased' so a late webhook is acknowledged.
		Name: "billing_sessions", Table: "billing_sessions", Link: "account_id",
		Columns: []Column{{"external_id", SetEmpty}},
	},
	{
		// "stripe:<checkout session id>" becomes "stripe:erased".
		Name: "ledger_entries_stripe_reference", Table: "ledger_entries", Link: "account_id, reference stripe:*",
		Columns: []Column{{"reference", Rewrite}},
	},
	{
		// An admin credit or reward reference can carry a free-text note.
		Name: "ledger_entries_admin_note", Table: "ledger_entries", Link: "account_id, admin_credit or admin_reward",
		Columns: []Column{{"reference", Rewrite}},
	},
	{
		// The same tombstone as RemoveGlobalRecipient: a new onboarding
		// generation and no recipient, payout method, last4 or country.
		Name: "global_payout_recipients", Table: "global_payout_recipients", Link: "account_id",
		Columns: []Column{{"country", SetEmpty}, {"data", Tombstone}},
	},
	{
		// Amounts, status, country and the payment ID stay as the financial
		// record; the Stripe recipient and payout method and the request go.
		Name: "global_payout_withdrawals", Table: "global_payout_withdrawals", Link: "account_id",
		Columns: []Column{{"data.recipient_id", SetEmpty}, {"data.payout_method_id", SetEmpty}, {"data.request", SetEmptyJSON}},
	},
	{
		// Transfer and payout IDs and amounts stay as the financial record.
		Name: "stripe_withdrawals", Table: "stripe_withdrawals", Link: "account_id",
		Columns: []Column{{"stripe_account_id", SetEmpty}},
	},
	{
		// payments and provider_payouts have no account column and no reader
		// since #1208. The admin request names the wallet addresses; each
		// address gets one random value for all its rows in both tables.
		Name: "payments_consumer_address", Table: "payments", Link: "consumer_address in the request's wallet addresses",
		Columns: []Column{{"consumer_address", SetRandom}},
	},
	{
		Name: "payments_provider_address", Table: "payments", Link: "provider_address in the request's wallet addresses",
		Columns: []Column{{"provider_address", SetRandom}},
	},
	{
		Name: "provider_payouts_address", Table: "provider_payouts", Link: "provider_address in the request's wallet addresses",
		Columns: []Column{{"provider_address", SetRandom}},
	},
}

// These reasons explain the personal-looking data the scrub keeps.
// (*Keys).Retained reports how many rows each one has for the account.
const (
	retainedSharedMDAAlias     = "mda_serial alias of a machine that another account also used; deleting it would break that account's machine identity"
	retainedSharedSEKey        = "Secure Enclave key that another account's provider also uses; its trust, verification and code-attestation rows belong to that account too"
	retainedSharedAppAttestKey = "App Attest key that another account's sessions also used; its receipts belong to that account too"
)
