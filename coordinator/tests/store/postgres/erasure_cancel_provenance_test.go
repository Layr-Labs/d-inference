package postgres_test

import (
	"context"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/erasurefixture"
)

// confirmLikeBase applies the confirm of the build before migration 34
// (base 586f7e12, queries/erasure.sql): every credential of the account gets
// active = false and the same deleted_at, the request gets no
// credential_provenance, and nothing lists which credentials were live.
func confirmLikeBase(t *testing.T, s *postgresFixture, a erasurefixture.Account, now time.Time, grace time.Duration) string {
	t.Helper()
	ctx := context.Background()
	plan, err := s.PlanAccountErasure(ctx, a.AccountID, nil)
	if err != nil {
		t.Fatal(err)
	}
	req, err := s.SaveErasurePlan(ctx, a.AccountID, "admin_key", plan.ErasureCounts, nil, "token", now.Add(15*time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.pool.Exec(ctx, `
		WITH u AS (UPDATE users SET deleted_at = $2 WHERE account_id = $1 AND deleted_at IS NULL RETURNING 1),
		     p AS (UPDATE providers SET deleted_at = $2 WHERE account_id = $1 AND deleted_at IS NULL RETURNING 1),
		     k AS (UPDATE api_keys SET active = FALSE, deleted_at = $2 WHERE owner_account_id = $1 AND deleted_at IS NULL RETURNING 1),
		     t AS (UPDATE provider_tokens SET active = FALSE, deleted_at = $2 WHERE account_id = $1 AND deleted_at IS NULL RETURNING 1)
		UPDATE erasure_requests
		SET state = 'pending', actor = 'admin_key', reason = 'ticket 1', wallet_addresses = '{}',
		    requested_at = $2, scrub_after = $3, confirm_token_hash = '', confirm_expires_at = NULL
		WHERE id = $4`, a.AccountID, now, now.Add(grace), req.ID); err != nil {
		t.Fatal(err)
	}
	return req.ID
}

// An erasure confirmed by the build before migration 34 and canceled by this
// build restores no API key and no provider token: nothing records which of
// them were live at the confirm, and a revoked credential can be one that
// leaked. The account and its providers are restored.
func TestErasureCancelOfConfirmBeforeProvenanceRestoresNoCredential(t *testing.T) {
	ctx := context.Background()
	s := testPostgresStore(t)
	a := erasurefixture.SeedAccount(t, s)
	oldKey, oldToken := revokedCredentialsBeforeErasure(t, s, a)
	now := time.Now().UTC()
	confirmLikeBase(t, s, a, now, time.Hour)

	if _, err := s.CancelAccountErasure(ctx, a.AccountID, "admin_key", now.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct{ name, raw string }{{"API key revoked before the erasure", oldKey}, {"API key live at the confirm", a.RawKey}} {
		if k, err := s.AuthenticateKey(c.raw); err == nil {
			t.Errorf("%s authenticates after cancel: %s", c.name, k.ID)
		}
	}
	for _, c := range []struct{ name, raw string }{{"provider token revoked before the erasure", oldToken}, {"provider token live at the confirm", a.ProviderToken}} {
		if _, err := s.GetProviderToken(c.raw); err == nil {
			t.Errorf("%s is valid after cancel", c.name)
		}
	}
	if _, err := s.GetUserByAccountID(a.AccountID); err != nil {
		t.Fatalf("user after cancel: %v", err)
	}
	var providerDeleted bool
	if err := s.pool.QueryRow(ctx, `SELECT deleted_at IS NOT NULL FROM providers WHERE id = $1`, a.ProviderID).Scan(&providerDeleted); err != nil || providerDeleted {
		t.Fatalf("provider deleted after cancel = %v (%v); want restored", providerDeleted, err)
	}
}

// The confirm lists each credential it revoked, and the scrub deletes the
// list: a scrubbed request cannot be canceled.
func TestErasureScrubDeletesRevokedCredentialList(t *testing.T) {
	ctx := context.Background()
	s := testPostgresStore(t)
	a := erasurefixture.SeedAccount(t, s)
	revokedCredentialsBeforeErasure(t, s, a)
	now := time.Now().UTC()
	req := erasurefixture.PlanAndConfirm(t, s, a, now, 0)
	listed := func() map[string]string {
		t.Helper()
		rows, err := s.pool.Query(ctx, `SELECT kind, credential_id FROM erasure_revoked_credentials WHERE request_id = $1`, req.ID)
		if err != nil {
			t.Fatal(err)
		}
		defer rows.Close()
		out := map[string]string{}
		for rows.Next() {
			var kind, id string
			if err := rows.Scan(&kind, &id); err != nil {
				t.Fatal(err)
			}
			out[kind] = id
		}
		return out
	}
	want := map[string]string{"api_key": store.HashKey(a.RawKey), "provider_token": store.HashKey(a.ProviderToken)}
	if got := listed(); len(got) != len(want) || got["api_key"] != want["api_key"] || got["provider_token"] != want["provider_token"] {
		t.Fatalf("listed after confirm = %v; want only the live key and token %v", got, want)
	}
	var provenance int16
	if err := s.pool.QueryRow(ctx, `SELECT credential_provenance FROM erasure_requests WHERE id = $1`, req.ID).Scan(&provenance); err != nil || provenance != 1 {
		t.Fatalf("credential_provenance = %d (%v); want 1", provenance, err)
	}
	if _, err := s.ScrubAccount(ctx, req.ID, now); err != nil {
		t.Fatal(err)
	}
	if got := listed(); len(got) != 0 {
		t.Fatalf("listed after scrub = %v; want none", got)
	}
}

// revokedCredentialsBeforeErasure creates an API key and a provider token of a
// and revokes both. It returns the raw key and the raw token.
func revokedCredentialsBeforeErasure(t *testing.T, s *postgresFixture, a erasurefixture.Account) (string, string) {
	t.Helper()
	key, _, err := s.CreateAPIKey(a.AccountID, store.APIKeyCreate{Name: "old key"})
	if err != nil {
		t.Fatal(err)
	}
	if !s.RevokeKey(key) {
		t.Fatal("revoke the old key")
	}
	token := erasurefixture.UniqueID("ptok-old")
	if err := s.CreateProviderToken(&store.ProviderToken{TokenHash: store.HashKey(token), AccountID: a.AccountID, Label: "old mac", Active: true}); err != nil {
		t.Fatal(err)
	}
	if err := s.RevokeProviderToken(token); err != nil {
		t.Fatal(err)
	}
	return key, token
}
