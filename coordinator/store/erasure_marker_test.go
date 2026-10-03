package store

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// The marker test puts a marker string in every personal column of every
// table in erasureRules for one account, runs plan, confirm and scrub, and
// then searches every text, JSON, array and bytea column of every table in
// the schema for the marker. A hit fails unless the column is in
// erasureMarkerAllowList. A second account carries keepMarker and must keep
// all of it.

const (
	piiMarker  = "PIIMARK"
	keepMarker = "KEEPMARK"
)

// erasureMarkerAllowList is the personal data that may stay after a scrub.
var erasureMarkerAllowList = map[string]string{
	// The outbox carries each Stripe ID until Stripe confirms the deletion;
	// the outbox worker then clears it.
	"erasure_outbox.external_id": "Stripe object IDs wait here for the Stripe deletion",
}

// erasureMarkerFixture inserts rows for account acct-A (markers) and
// acct-B (keep markers). Every statement must succeed.
var erasureMarkerFixture = []string{
	// Account A.
	`INSERT INTO users (account_id, privy_user_id, email, stripe_account_id, stripe_account_status, stripe_account_country, stripe_destination_type, stripe_destination_last4)
	 VALUES ('acct-A', 'did:privy:PIIMARK', 'PIIMARK@example.com', 'acct_PIIMARK', 'PIIMARK', 'PIIMARK', 'PIIMARK', 'PIIMARK')`,
	`INSERT INTO api_keys (key_hash, raw_prefix, owner_account_id, id, name) VALUES ('kh-A', 'sk-db-', 'acct-A', 'key-A', 'PIIMARK key name')`,
	`INSERT INTO provider_tokens (token_hash, account_id, label) VALUES ('th-A', 'acct-A', 'PIIMARK-hostname')`,
	`INSERT INTO device_codes (device_code, user_code, account_id, status, expires_at) VALUES ('dc-A', 'PIIMARK-UC', 'acct-A', 'approved', NOW() + interval '1 hour')`,
	`INSERT INTO providers (id, hardware, models, backend, location, attestation_result, se_public_key, serial_number, mda_cert_chain, account_id)
	 VALUES ('prov-A', '{}', '[]', 'mlx', '{"city": "PIIMARK"}', '{"serial_number": "PIIMARK-SERIAL"}', 'se-A', 'PIIMARK-SERIAL', '["PIIMARK-cert"]', 'acct-A')`,
	`INSERT INTO provider_sessions (session_id, serial_number, account_id) VALUES ('prov-A', 'PIIMARK-SERIAL', 'acct-A'), ('sess-A2', 'PIIMARK-SERIAL2', 'acct-A')`,
	`INSERT INTO provider_log_reports (serial_number, provider_id, account_id, log_data) VALUES ('PIIMARK-SERIAL', 'prov-A', 'acct-A', 'PIIMARK raw log'::bytea)`,
	`INSERT INTO provider_trust_reuse (se_pubkey, serial, mda_udid) VALUES ('se-A', 'PIIMARK-SERIAL', 'PIIMARK-UDID')`,
	`INSERT INTO provider_verification_jobs (se_pubkey, serial, udid, task_kind, task_state, priority) VALUES ('se-A', 'PIIMARK-SERIAL', 'PIIMARK-UDID', 'security_info', 'pending', 1)`,
	`INSERT INTO code_attestations (se_pubkey, apns_token) VALUES ('se-A', 'PIIMARK-apns')`,
	`INSERT INTO code_attest_push_budgets (se_pubkey, token_hash, next_push_at) VALUES ('se-A', 'PIIMARK-token', NOW())`,
	`INSERT INTO darkbloom_machines (id, assurance, first_seen, last_seen) VALUES ('m-A', 'mda', NOW(), NOW()), ('m-shared', 'mda', NOW(), NOW())`,
	`INSERT INTO darkbloom_machine_sessions (session_id, machine_id, original_machine_id, account_id, first_seen, last_seen, observation)
	 VALUES ('prov-A', 'm-A', 'm-A', 'acct-A', NOW(), NOW(), '{}'), ('sess-A2', 'm-shared', 'm-shared', 'acct-A', NOW(), NOW(), '{}')`,
	`INSERT INTO darkbloom_machine_aliases (kind, scope, digest, machine_id, verified_at) VALUES
	 ('app_attest', 'acct-A', 'PIIMARK-digest-1', 'm-A', NOW()),
	 ('legacy_se', 'acct-A', 'PIIMARK-digest-2', 'm-A', NOW()),
	 ('mda_serial', '', '` + mdaSerialDigest("PIIMARK-SERIAL") + `', 'm-A', NOW()),
	 ('mda_serial', '', '` + mdaSerialDigest("PIIMARK-SERIAL2") + `', 'm-shared', NOW())`,
	`INSERT INTO app_attest_evidence (id, session_id, key_id, received_at, action, sha256, context) VALUES ('ev-A', 'prov-A', 'kid-A', NOW(), 'attestation', 'abc', '{"boot_time": "PIIMARK"}')`,
	`INSERT INTO app_attest_evidence_blobs (evidence_id, proof_field, proof) VALUES ('ev-A', 'PIIMARK-proof-field', 'PIIMARK proof'::bytea)`,
	`INSERT INTO app_attest_receipts (id, key_id, evidence_id, parent_id, received_at, outcome, http_status, details, context, next_at, expires_at)
	 VALUES ('rc-A', 'kid-A', 'ev-A', '', NOW(), 'ok', 200, '{}', '{"note": "PIIMARK"}', NOW(), NOW())`,
	`INSERT INTO app_attest_receipt_blobs (receipt_id, body, response_body) VALUES ('rc-A', 'PIIMARK body'::bytea, 'PIIMARK response'::bytea)`,
	`INSERT INTO app_attest_receipt_jobs (key_id, receipt_id, next_at) VALUES ('kid-A', 'rc-A', NOW())`,
	`INSERT INTO usage (provider_id, consumer_key_hash, model, prompt_tokens, completion_tokens, request_location)
	 VALUES ('prov-X', '` + hashKey("acct-A") + `', 'm', 1, 1, '{"city": "PIIMARK"}')`,
	`INSERT INTO inference_routes (request_id, model, consumer_key_hash, consumer_region) VALUES ('req-A1', 'm', '` + hashKey("acct-A") + `', 'PIIMARK-region')`,
	`INSERT INTO inference_routes (request_id, model, provider_id, provider_region) VALUES ('req-A2', 'm', 'prov-A', 'PIIMARK-region')`,
	`INSERT INTO referrers (account_id, code) VALUES ('acct-A', 'PIIMARK-code')`,
	`INSERT INTO billing_sessions (id, account_id, payment_method, amount_micro_usd, external_id, status) VALUES ('bs-A', 'acct-A', 'stripe', 1, 'cs_PIIMARK1', 'completed')`,
	`INSERT INTO ledger_entries (account_id, entry_type, amount_micro_usd, balance_after, reference) VALUES
	 ('acct-A', 'stripe_deposit', 1, 1, 'stripe:cs_PIIMARK1'), ('acct-A', 'admin_credit', 1, 2, 'admin_credit:PIIMARK note')`,
	`INSERT INTO balances (account_id, balance_micro_usd, withdrawable_micro_usd) VALUES ('acct-A', 2, 0)`,
	`INSERT INTO global_payout_recipients (account_id, country, data)
	 VALUES ('acct-A', 'PIIMARK', '{"id": "g1", "account_id": "acct-A", "recipient_id": "acct_PIIMARKrecipient", "payout_method_id": "PIIMARK-pm", "last4": "PIIMARK"}')`,
	`INSERT INTO global_payout_withdrawals (id, account_id, status, submitted_at, checked_at, lease_until, expires_at, data)
	 VALUES ('gp-A', 'acct-A', 'failed', NOW(), NOW(), NOW(), NOW(), '{"recipient_id": "acct_PIIMARKrecipient", "payout_method_id": "PIIMARK-pm", "request": {"to": "PIIMARK"}}')`,
	`INSERT INTO stripe_withdrawals (id, account_id, stripe_account_id, amount_micro_usd, net_micro_usd, method, status) VALUES ('sw-A', 'acct-A', 'acct_PIIMARK', 1, 1, 'standard', 'paid')`,
	`INSERT INTO payments (consumer_address, provider_address, amount_usd, model, prompt_tokens, completion_tokens) VALUES
	 ('PIIMARK-wallet', '0xKEEPMARK', '1', 'm', 1, 1), ('0xKEEPMARK', 'PIIMARK-wallet', '1', 'm', 1, 1)`,
	`INSERT INTO provider_payouts (provider_address, amount_micro_usd) VALUES ('PIIMARK-wallet', 1), ('0xKEEPMARK', 1)`,

	// Account B shares machine m-shared, was referred by A and copied A's code.
	`INSERT INTO users (account_id, privy_user_id, email, stripe_account_id) VALUES ('acct-B', 'did:privy:KEEPMARK', 'KEEPMARK@example.com', 'acct_KEEPMARK')`,
	`INSERT INTO providers (id, hardware, models, backend, serial_number, se_public_key, account_id) VALUES ('prov-B', '{}', '[]', 'mlx', 'KEEPMARK-SERIAL', 'se-B', 'acct-B')`,
	`INSERT INTO provider_trust_reuse (se_pubkey, serial) VALUES ('se-B', 'KEEPMARK-SERIAL')`,
	`INSERT INTO darkbloom_machine_sessions (session_id, machine_id, original_machine_id, account_id, first_seen, last_seen, observation)
	 VALUES ('prov-B', 'm-shared', 'm-shared', 'acct-B', NOW(), NOW(), '{}')`,
	`INSERT INTO referrals (referred_account, referrer_code) VALUES ('acct-B', 'PIIMARK-code')`,
	`INSERT INTO billing_sessions (id, account_id, payment_method, amount_micro_usd, external_id, status, referral_code) VALUES ('bs-B', 'acct-B', 'stripe', 1, 'cs_KEEPMARK', 'completed', 'PIIMARK-code')`,
}

// markerHit is one column that still holds a marker.
type markerHit struct {
	Column string
	Rows   int64
}

// findMarker searches every text-like column of every public table.
func findMarker(t *testing.T, ctx context.Context, s *PostgresStore, marker string) []markerHit {
	t.Helper()
	rows, err := s.pool.Query(ctx, `
		SELECT c.table_name, c.column_name, c.data_type
		FROM information_schema.columns c
		JOIN information_schema.tables t ON t.table_schema = c.table_schema AND t.table_name = c.table_name
		WHERE c.table_schema = 'public' AND t.table_type = 'BASE TABLE'
		  AND c.data_type IN ('text', 'character varying', 'jsonb', 'json', 'ARRAY', 'bytea')
		ORDER BY c.table_name, c.column_name`)
	if err != nil {
		t.Fatal(err)
	}
	type column struct{ table, name, typ string }
	var columns []column
	for rows.Next() {
		var c column
		if err := rows.Scan(&c.table, &c.name, &c.typ); err != nil {
			t.Fatal(err)
		}
		columns = append(columns, c)
	}
	rows.Close()
	if len(columns) < 100 {
		t.Fatalf("found only %d text-like columns; the search query is wrong", len(columns))
	}
	var hits []markerHit
	for _, c := range columns {
		ident := pgx.Identifier{c.name}.Sanitize()
		predicate := ident + `::text LIKE '%' || $1 || '%'`
		if c.typ == "bytea" {
			predicate = `position(convert_to($1, 'UTF8') IN ` + ident + `) > 0`
		}
		var n int64
		if err := s.pool.QueryRow(ctx, `SELECT COUNT(*) FROM `+pgx.Identifier{c.table}.Sanitize()+` WHERE `+predicate, marker).Scan(&n); err != nil {
			t.Fatalf("search %s.%s: %v", c.table, c.name, err)
		}
		if n > 0 {
			hits = append(hits, markerHit{Column: c.table + "." + c.name, Rows: n})
		}
	}
	return hits
}

func TestErasureMarkerPostgres(t *testing.T) {
	ctx := context.Background()
	s, err := NewPostgres(ctx, Config{DatabaseURL: newThrowawayTestDatabase(t)})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	for _, stmt := range erasureMarkerFixture {
		if _, err := s.pool.Exec(ctx, stmt); err != nil {
			t.Fatalf("fixture %q: %v", stmt, err)
		}
	}
	keepBefore := findMarker(t, ctx, s, keepMarker)

	wallets := []string{"PIIMARK-wallet"}
	plan, err := s.PlanAccountErasure(ctx, "acct-A", wallets)
	if err != nil {
		t.Fatal(err)
	}
	// Every rule must see a fixture row, so the fixture covers the table.
	for _, r := range plan.Rows {
		if r.Rows == 0 {
			t.Errorf("rule %s (%s) has no fixture rows", r.Rule, r.Table)
		}
	}
	if len(plan.Retained) != 1 || plan.Retained[0].Rows != 1 {
		t.Fatalf("retained = %+v; want the shared mda_serial alias", plan.Retained)
	}
	now := time.Now().UTC()
	if _, err := s.SaveErasurePlan(ctx, "acct-A", "admin_key", plan.ErasureCounts, "token", now.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	req, err := s.RequestAccountErasure(ctx, ErasureConfirm{AccountID: "acct-A", ConfirmToken: "token", Email: "piimark@example.com", Actor: "admin_key", Reason: "ticket", WalletAddresses: wallets, Now: now})
	if err != nil {
		t.Fatal(err)
	}
	res, err := s.ScrubAccount(ctx, req.ID, now)
	if err != nil {
		t.Fatal(err)
	}
	for i, r := range res.Request.Summary.Applied.Rows {
		if r.Rows != plan.Rows[i].Rows {
			t.Errorf("rule %s applied %d rows, planned %d", r.Rule, r.Rows, plan.Rows[i].Rows)
		}
	}

	for _, hit := range findMarker(t, ctx, s, piiMarker) {
		if _, ok := erasureMarkerAllowList[hit.Column]; !ok {
			t.Errorf("personal data left in %s (%d rows)", hit.Column, hit.Rows)
		}
	}
	keepAfter := findMarker(t, ctx, s, keepMarker)
	if fmt.Sprint(keepAfter) != fmt.Sprint(keepBefore) {
		t.Errorf("the other account's data changed:\nbefore %v\nafter  %v", keepBefore, keepAfter)
	}

	// The unshared mda_serial alias is gone; the shared one stays.
	var aliases []string
	rows, err := s.pool.Query(ctx, `SELECT machine_id FROM darkbloom_machine_aliases WHERE kind = 'mda_serial' ORDER BY machine_id`)
	if err != nil {
		t.Fatal(err)
	}
	for rows.Next() {
		var m string
		if err := rows.Scan(&m); err != nil {
			t.Fatal(err)
		}
		aliases = append(aliases, m)
	}
	rows.Close()
	if strings.Join(aliases, ",") != "m-shared" {
		t.Fatalf("mda_serial aliases after scrub = %v; want [m-shared]", aliases)
	}

	// The referral follows the new code and the forfeit entry balances the ledger.
	var referral, copied string
	if err := s.pool.QueryRow(ctx, `SELECT r.referrer_code, b.referral_code FROM referrals r, billing_sessions b WHERE r.referred_account = 'acct-B' AND b.id = 'bs-B'`).Scan(&referral, &copied); err != nil {
		t.Fatal(err)
	}
	var code string
	if err := s.pool.QueryRow(ctx, `SELECT code FROM referrers WHERE account_id = 'acct-A'`).Scan(&code); err != nil {
		t.Fatal(err)
	}
	if referral != code || copied != code {
		t.Fatalf("referral %q, copied %q, referrer %q", referral, copied, code)
	}
	var sum, balance int64
	if err := s.pool.QueryRow(ctx, `SELECT COALESCE(SUM(amount_micro_usd), 0) FROM ledger_entries WHERE account_id = 'acct-A'`).Scan(&sum); err != nil {
		t.Fatal(err)
	}
	if err := s.pool.QueryRow(ctx, `SELECT balance_micro_usd FROM balances WHERE account_id = 'acct-A'`).Scan(&balance); err != nil {
		t.Fatal(err)
	}
	if sum != 0 || balance != 0 {
		t.Fatalf("ledger sum %d, balance %d; want 0, 0", sum, balance)
	}
	// One random value replaces the wallet in every row of both tables.
	var distinct int64
	if err := s.pool.QueryRow(ctx, `SELECT COUNT(DISTINCT a) FROM (
		SELECT consumer_address AS a FROM payments WHERE consumer_address LIKE 'erased-%'
		UNION ALL SELECT provider_address FROM payments WHERE provider_address LIKE 'erased-%'
		UNION ALL SELECT provider_address FROM provider_payouts WHERE provider_address LIKE 'erased-%') x`).Scan(&distinct); err != nil {
		t.Fatal(err)
	}
	if distinct != 1 {
		t.Fatalf("wallet replaced by %d distinct values; want 1", distinct)
	}
}

// TestErasureCountMismatchAborts makes one scrub statement change fewer rows
// than its count, with a trigger that skips the update, and checks that the
// scrub aborts and commits nothing.
func TestErasureCountMismatchAborts(t *testing.T) {
	ctx := context.Background()
	s, err := NewPostgres(ctx, Config{DatabaseURL: newThrowawayTestDatabase(t)})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	a := seedErasureAccount(t, s)
	now := time.Now().UTC()
	req := planAndConfirm(t, s, a, now, 0)
	for _, stmt := range []string{
		`CREATE FUNCTION skip_update() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NULL; END $$`,
		`CREATE TRIGGER skip_provider_token_update BEFORE UPDATE ON provider_tokens FOR EACH ROW EXECUTE FUNCTION skip_update()`,
	} {
		if _, err := s.pool.Exec(ctx, stmt); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := s.ScrubAccount(ctx, req.ID, now); err == nil || !strings.Contains(err.Error(), "provider_tokens counted 1, changed 0") {
		t.Fatalf("scrub error = %v; want a provider_tokens count mismatch", err)
	}
	var email, state string
	if err := s.pool.QueryRow(ctx, `SELECT email FROM users WHERE account_id = $1`, a.AccountID).Scan(&email); err != nil {
		t.Fatal(err)
	}
	if err := s.pool.QueryRow(ctx, `SELECT state FROM erasure_requests WHERE id = $1`, req.ID).Scan(&state); err != nil {
		t.Fatal(err)
	}
	if email != a.Email || state != string(ErasurePending) {
		t.Fatalf("after the aborted scrub: email %q, state %q", email, state)
	}
}
