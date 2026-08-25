package store

import (
	"context"
	"encoding/json"
	"testing"
	"time"
)

func TestPostgresLegacyProviderIdentityBackfillAndFallback(t *testing.T) {
	s := testPostgresStore(t)
	ctx := context.Background()
	accountID := uniqueID("identity-backfill-account")
	otherAccountID := uniqueID("identity-backfill-other")
	sessionID := uniqueID("identity-backfill-session")
	legacyOnlySessionID := uniqueID("identity-backfill-session-only")
	guardSessionID := uniqueID("identity-backfill-guard")
	mismatchSessionID := uniqueID("identity-backfill-mismatch")
	providerKey := uniqueID("identity-backfill-key")

	for _, record := range []ProviderRecord{
		{
			ID:           sessionID,
			Hardware:     json.RawMessage(`{}`),
			Models:       json.RawMessage(`[]`),
			Backend:      "mlx_swift",
			AccountID:    accountID,
			PublicKey:    providerKey,
			SerialNumber: "SERIAL-BACKFILL",
			RegisteredAt: time.Now(),
			LastSeen:     time.Now(),
		},
		{
			ID:           guardSessionID,
			Hardware:     json.RawMessage(`{}`),
			Models:       json.RawMessage(`[]`),
			Backend:      "mlx_swift",
			AccountID:    otherAccountID,
			PublicKey:    uniqueID("identity-guard-key"),
			SerialNumber: "SERIAL-GUARD",
			RegisteredAt: time.Now(),
			LastSeen:     time.Now(),
		},
		{
			ID:           mismatchSessionID,
			Hardware:     json.RawMessage(`{}`),
			Models:       json.RawMessage(`[]`),
			Backend:      "mlx_swift",
			AccountID:    accountID,
			PublicKey:    uniqueID("identity-mismatch-key"),
			SerialNumber: "SERIAL-PROVIDER-DIFFERENT",
			RegisteredAt: time.Now(),
			LastSeen:     time.Now(),
		},
	} {
		if err := s.UpsertProvider(ctx, record); err != nil {
			t.Fatalf("upsert provider %q: %v", record.ID, err)
		}
	}

	for _, session := range []struct {
		id      string
		serial  string
		account string
	}{
		{sessionID, "SERIAL-BACKFILL", accountID},
		{legacyOnlySessionID, "SERIAL-SESSION-ONLY", accountID},
		{guardSessionID, "SERIAL-GUARD", otherAccountID},
		{mismatchSessionID, "SERIAL-SESSION-DIFFERENT", accountID},
	} {
		if err := s.OpenProviderSession(ctx, session.id, session.serial, session.account); err != nil {
			t.Fatalf("open session %q: %v", session.id, err)
		}
	}

	for _, earning := range []ProviderEarning{
		{
			AccountID:        accountID,
			ProviderID:       sessionID,
			JobID:            uniqueID("identity-backfill-job"),
			Model:            "qwen3.5-9b",
			AmountMicroUSD:   123,
			PromptTokens:     4,
			CompletionTokens: 5,
		},
		{
			AccountID:      accountID,
			ProviderID:     guardSessionID,
			JobID:          uniqueID("identity-guard-job"),
			Model:          "qwen3.5-9b",
			AmountMicroUSD: 50,
		},
		{
			AccountID:      accountID,
			ProviderID:     mismatchSessionID,
			JobID:          uniqueID("identity-mismatch-job"),
			Model:          "qwen3.5-9b",
			AmountMicroUSD: 60,
		},
	} {
		if err := s.RecordProviderEarning(&earning); err != nil {
			t.Fatalf("record earning for %q: %v", earning.ProviderID, err)
		}
	}

	if _, err := s.pool.Exec(ctx, `
		DELETE FROM schema_migrations
		WHERE id = 'backfill_provider_earning_identity_v1'`); err != nil {
		t.Fatal(err)
	}
	if _, err := s.pool.Exec(ctx, providerIdentityBackfillMigration); err != nil {
		t.Fatalf("run identity backfill: %v", err)
	}

	var sessionKey, earningKey string
	if err := s.pool.QueryRow(ctx, `
		SELECT provider_key FROM provider_sessions WHERE session_id = $1`,
		sessionID,
	).Scan(&sessionKey); err != nil {
		t.Fatal(err)
	}
	if err := s.pool.QueryRow(ctx, `
		SELECT provider_key FROM provider_earnings WHERE provider_id = $1`,
		sessionID,
	).Scan(&earningKey); err != nil {
		t.Fatal(err)
	}
	if sessionKey != providerKey || earningKey != providerKey {
		t.Fatalf("recovered keys = session:%q earning:%q, want %q", sessionKey, earningKey, providerKey)
	}

	for _, providerID := range []string{guardSessionID, mismatchSessionID} {
		var key string
		if err := s.pool.QueryRow(ctx, `
			SELECT provider_key
			  FROM provider_earnings
			 WHERE account_id = $1 AND provider_id = $2`,
			accountID, providerID,
		).Scan(&key); err != nil {
			t.Fatal(err)
		}
		if key != "" {
			t.Fatalf("unsafe relationship for %q was backfilled as %q", providerID, key)
		}
	}

	summary, err := s.GetProviderEarningsSummary(providerKey)
	if err != nil {
		t.Fatalf("read recovered provider summary: %v", err)
	}
	if summary.Count != 1 ||
		summary.TotalMicroUSD != 123 ||
		summary.PromptTokens != 4 ||
		summary.CompletionTokens != 5 {
		t.Fatalf("recovered summary = %+v", summary)
	}

	// The mutable provider row can later be removed; the account-scoped session
	// relationship remains sufficient for both key-backed and ID-only history.
	if _, err := s.pool.Exec(ctx, `DELETE FROM providers WHERE id = $1`, sessionID); err != nil {
		t.Fatal(err)
	}
	identities, err := s.ListProviderSessionIdentities(ctx, accountID, []ProviderEarningIdentityRef{
		{ProviderID: sessionID, ProviderKey: providerKey},
		{ProviderID: legacyOnlySessionID},
		{ProviderID: guardSessionID},
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(identities) != 2 {
		t.Fatalf("identities = %+v, want recovered and ID-only sessions", identities)
	}
	byID := make(map[string]ProviderSessionIdentity, len(identities))
	for _, identity := range identities {
		byID[identity.SessionID] = identity
	}
	if got := byID[sessionID]; got.ProviderKey != providerKey || got.SerialNumber != "SERIAL-BACKFILL" {
		t.Fatalf("recovered identity = %+v", got)
	}
	if got := byID[legacyOnlySessionID]; got.ProviderKey != "" || got.SerialNumber != "SERIAL-SESSION-ONLY" {
		t.Fatalf("ID-only legacy identity = %+v", got)
	}
	if _, leaked := byID[guardSessionID]; leaked {
		t.Fatalf("other account identity leaked: %+v", identities)
	}
}
