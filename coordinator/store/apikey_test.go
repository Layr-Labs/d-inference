package store

import (
	"strings"
	"testing"
	"time"
)

func TestCreateAPIKeyAndAuthenticate(t *testing.T) {
	s := NewMemory(Config{})

	limit := int64(5_000_000) // $5
	raw, rec, err := s.CreateAPIKey("acct-1", APIKeyCreate{
		Name:          "prod",
		LimitMicroUSD: &limit,
		LimitReset:    KeyResetMonthly,
	})
	if err != nil {
		t.Fatalf("CreateAPIKey: %v", err)
	}
	if !strings.HasPrefix(raw, KeyPrefix) {
		t.Errorf("raw key %q missing prefix %q", raw, KeyPrefix)
	}
	if rec.ID == "" || !strings.HasPrefix(rec.ID, "key_") {
		t.Errorf("bad key id %q", rec.ID)
	}
	if rec.Label == raw {
		t.Errorf("label must be masked, got the raw key")
	}
	if rec.OwnerAccountID != "acct-1" || rec.Name != "prod" {
		t.Errorf("unexpected record: %+v", rec)
	}

	// Authenticate resolves the active record with limits intact.
	got, err := s.AuthenticateKey(raw)
	if err != nil {
		t.Fatalf("AuthenticateKey: %v", err)
	}
	if got.ID != rec.ID || got.LimitMicroUSD == nil || *got.LimitMicroUSD != limit {
		t.Errorf("authenticate mismatch: %+v", got)
	}

	// Unknown key fails.
	if _, err := s.AuthenticateKey("sk-db-nope"); err == nil {
		t.Error("expected error for unknown key")
	}
}

func TestAuthenticateKeyDisabledAndExpired(t *testing.T) {
	s := NewMemory(Config{})

	raw, rec, err := s.CreateAPIKey("acct-1", APIKeyCreate{Name: "k"})
	if err != nil {
		t.Fatalf("CreateAPIKey: %v", err)
	}

	// Disable it via update.
	mut := *rec
	mut.Disabled = true
	if _, err := s.UpdateAPIKey("acct-1", rec.ID, mut); err != nil {
		t.Fatalf("UpdateAPIKey: %v", err)
	}
	if _, err := s.AuthenticateKey(raw); err == nil {
		t.Error("expected error for disabled key")
	}

	// Re-enable + set past expiry.
	past := time.Now().Add(-time.Hour)
	mut.Disabled = false
	mut.ExpiresAt = &past
	if _, err := s.UpdateAPIKey("acct-1", rec.ID, mut); err != nil {
		t.Fatalf("UpdateAPIKey: %v", err)
	}
	if _, err := s.AuthenticateKey(raw); err == nil {
		t.Error("expected error for expired key")
	}
}

func TestListAndScopingByOwner(t *testing.T) {
	s := NewMemory(Config{})
	_, k1, _ := s.CreateAPIKey("acct-1", APIKeyCreate{Name: "a"})
	s.CreateAPIKey("acct-1", APIKeyCreate{Name: "b"})
	s.CreateAPIKey("acct-2", APIKeyCreate{Name: "c"})

	keys, err := s.ListAPIKeys("acct-1")
	if err != nil {
		t.Fatalf("ListAPIKeys: %v", err)
	}
	if len(keys) != 2 {
		t.Fatalf("len = %d, want 2", len(keys))
	}

	// A different account cannot fetch acct-1's key.
	if _, err := s.GetAPIKeyByID("acct-2", k1.ID); err == nil {
		t.Error("expected scoping error fetching another account's key")
	}
	// Owner can.
	if _, err := s.GetAPIKeyByID("acct-1", k1.ID); err != nil {
		t.Errorf("owner GetAPIKeyByID: %v", err)
	}
}

func TestRevokeAPIKeyByID(t *testing.T) {
	s := NewMemory(Config{})
	raw, rec, _ := s.CreateAPIKey("acct-1", APIKeyCreate{Name: "a"})

	// Wrong owner cannot delete.
	if err := s.RevokeAPIKeyByID("acct-2", rec.ID); err == nil {
		t.Error("expected scoping error on revoke")
	}
	if err := s.RevokeAPIKeyByID("acct-1", rec.ID); err != nil {
		t.Fatalf("RevokeAPIKeyByID: %v", err)
	}
	if _, err := s.AuthenticateKey(raw); err == nil {
		t.Error("revoked key should not authenticate")
	}
	if keys, _ := s.ListAPIKeys("acct-1"); len(keys) != 0 {
		t.Errorf("expected 0 keys after revoke, got %d", len(keys))
	}
}

func TestUpdateAPIKeyClearsLimits(t *testing.T) {
	s := NewMemory(Config{})
	limit := int64(1_000_000)
	rpm := int64(60)
	_, rec, _ := s.CreateAPIKey("acct-1", APIKeyCreate{
		Name: "a", LimitMicroUSD: &limit, RPMLimit: &rpm, LimitReset: KeyResetDaily,
	})

	// Clear the limits by passing a record with nil pointers.
	mut := *rec
	mut.LimitMicroUSD = nil
	mut.RPMLimit = nil
	mut.LimitReset = KeyResetNone
	updated, err := s.UpdateAPIKey("acct-1", rec.ID, mut)
	if err != nil {
		t.Fatalf("UpdateAPIKey: %v", err)
	}
	if updated.LimitMicroUSD != nil || updated.RPMLimit != nil {
		t.Errorf("limits not cleared: %+v", updated)
	}
	if updated.LimitReset != KeyResetNone {
		t.Errorf("reset = %q, want none", updated.LimitReset)
	}
}

func TestKeySpendSinceWindows(t *testing.T) {
	s := NewMemory(Config{})
	_, rec, _ := s.CreateAPIKey("acct-1", APIKeyCreate{Name: "a"})

	// Record usage attributed to this key.
	s.RecordUsageFull("prov", "acct-1", rec.ID, "model", "req-1", 10, 10, 2_000_000, nil)
	s.RecordUsageFull("prov", "acct-1", rec.ID, "model", "req-2", 5, 5, 500_000, nil)

	// Lifetime (zero since) sums everything.
	if got := s.KeySpendSince(rec.ID, time.Time{}); got != 2_500_000 {
		t.Errorf("lifetime spend = %d, want 2500000", got)
	}
	// Today's window includes both (recorded just now).
	since := KeySpendWindowStart(KeyResetDaily, time.Now())
	if got := s.KeySpendSince(rec.ID, since); got != 2_500_000 {
		t.Errorf("daily spend = %d, want 2500000", got)
	}
	// A future window start excludes them.
	future := time.Now().UTC().AddDate(0, 0, 1)
	if got := s.KeySpendSince(rec.ID, future); got != 0 {
		t.Errorf("future-window spend = %d, want 0", got)
	}
	// Unknown key has zero spend.
	if got := s.KeySpendSince("key_unknown", time.Time{}); got != 0 {
		t.Errorf("unknown key spend = %d, want 0", got)
	}
}

func TestKeySpendWindowStart(t *testing.T) {
	// 2026-05-29 is a Friday.
	now := time.Date(2026, 5, 29, 15, 30, 0, 0, time.UTC)

	if got := KeySpendWindowStart(KeyResetNone, now); !got.IsZero() {
		t.Errorf("none window = %v, want zero", got)
	}
	if got := KeySpendWindowStart(KeyResetDaily, now); !got.Equal(time.Date(2026, 5, 29, 0, 0, 0, 0, time.UTC)) {
		t.Errorf("daily window = %v", got)
	}
	// Monday of that week is 2026-05-25.
	if got := KeySpendWindowStart(KeyResetWeekly, now); !got.Equal(time.Date(2026, 5, 25, 0, 0, 0, 0, time.UTC)) {
		t.Errorf("weekly window = %v, want 2026-05-25", got)
	}
	if got := KeySpendWindowStart(KeyResetMonthly, now); !got.Equal(time.Date(2026, 5, 1, 0, 0, 0, 0, time.UTC)) {
		t.Errorf("monthly window = %v, want 2026-05-01", got)
	}
}

func TestRotateAPIKeyAtomic(t *testing.T) {
	s := NewMemory(Config{})
	limit := int64(7_000_000)
	oldRaw, old, _ := s.CreateAPIKey("acct-1", APIKeyCreate{
		Name: "prod", LimitMicroUSD: &limit, LimitReset: KeyResetWeekly, AllowedModels: []string{"m1"},
	})

	newRaw, rec, err := s.RotateAPIKey("acct-1", old.ID)
	if err != nil {
		t.Fatalf("RotateAPIKey: %v", err)
	}
	if newRaw == oldRaw {
		t.Error("rotate must mint a new secret")
	}
	if rec.ID == old.ID {
		t.Error("rotate must mint a new id")
	}
	// Old secret no longer authenticates; new one does.
	if _, err := s.AuthenticateKey(oldRaw); err == nil {
		t.Error("old secret must not authenticate after rotate")
	}
	if _, err := s.AuthenticateKey(newRaw); err != nil {
		t.Errorf("new secret must authenticate: %v", err)
	}
	// Limits carried over.
	if rec.LimitMicroUSD == nil || *rec.LimitMicroUSD != limit || rec.LimitReset != KeyResetWeekly || len(rec.AllowedModels) != 1 {
		t.Errorf("limits not carried over: %+v", rec)
	}
	// Exactly one key remains for the account.
	if keys, _ := s.ListAPIKeys("acct-1"); len(keys) != 1 {
		t.Errorf("expected 1 key after rotate, got %d", len(keys))
	}
	// Rotating the now-deleted old id fails (concurrent double-rotate safety).
	if _, _, err := s.RotateAPIKey("acct-1", old.ID); err == nil {
		t.Error("rotating an already-rotated id should fail")
	}
}

func TestRotateCarriesDisabledState(t *testing.T) {
	s := NewMemory(Config{})
	_, old, _ := s.CreateAPIKey("acct-1", APIKeyCreate{Name: "k"})
	mut := *old
	mut.Disabled = true
	s.UpdateAPIKey("acct-1", old.ID, mut)

	newRaw, rec, err := s.RotateAPIKey("acct-1", old.ID)
	if err != nil {
		t.Fatalf("RotateAPIKey: %v", err)
	}
	if !rec.Disabled {
		t.Error("rotated key should carry over the disabled state")
	}
	if _, err := s.AuthenticateKey(newRaw); err == nil {
		t.Error("a disabled rotated key must not authenticate")
	}
}

func TestRevokeKeySoftDisables(t *testing.T) {
	s := NewMemory(Config{})
	raw, rec, _ := s.CreateAPIKey("acct-1", APIKeyCreate{Name: "k"})

	if !s.RevokeKey(raw) {
		t.Fatal("first revoke should return true")
	}
	if s.ValidateKey(raw) {
		t.Error("revoked key should not validate")
	}
	if _, err := s.AuthenticateKey(raw); err == nil {
		t.Error("revoked key should not authenticate")
	}
	// Soft-disable: the key is still listed (as disabled), matching Postgres.
	keys, _ := s.ListAPIKeys("acct-1")
	if len(keys) != 1 || !keys[0].Disabled {
		t.Errorf("expected key still listed as disabled, got %+v", keys)
	}
	// Second revoke returns false (already inactive), matching Postgres
	// "WHERE active = TRUE" semantics.
	if s.RevokeKey(raw) {
		t.Error("second revoke should return false")
	}
	_ = rec
}

func TestValidateKeyEnforcesExpiry(t *testing.T) {
	s := NewMemory(Config{})
	past := time.Now().Add(-time.Hour)
	raw, _, _ := s.CreateAPIKey("acct-1", APIKeyCreate{Name: "k", ExpiresAt: &past})
	if s.ValidateKey(raw) {
		t.Error("expired key must not validate")
	}
	future := time.Now().Add(time.Hour)
	raw2, _, _ := s.CreateAPIKey("acct-1", APIKeyCreate{Name: "k2", ExpiresAt: &future})
	if !s.ValidateKey(raw2) {
		t.Error("non-expired key should validate")
	}
}

func TestLegacyAccountID(t *testing.T) {
	raw := "sk-db-secretsecretsecret"
	id := LegacyAccountID(raw)
	if !strings.HasPrefix(id, "legacy:") {
		t.Errorf("legacy id %q missing prefix", id)
	}
	if strings.Contains(id, raw) {
		t.Errorf("legacy id %q leaks the raw key", id)
	}
	// Deterministic and stable.
	if id != LegacyAccountID(raw) {
		t.Error("LegacyAccountID must be deterministic")
	}
	// Distinct keys yield distinct identities.
	if id == LegacyAccountID("sk-db-other") {
		t.Error("different keys must yield different legacy identities")
	}
	// Namespaced so it can never collide with a real account id.
	if LegacyAccountID("acct-123") == "acct-123" {
		t.Error("legacy id must be namespaced away from real account ids")
	}
}

func TestMigrateAccountBalance(t *testing.T) {
	s := NewMemory(Config{})
	from := "sk-db-rawtoken"
	to := LegacyAccountID(from)

	// Seed the old raw-token identity with a balance (mix of withdrawable).
	if err := s.Credit(from, 5_000_000, LedgerDeposit, "seed"); err != nil {
		t.Fatalf("Credit: %v", err)
	}
	if err := s.CreditWithdrawable(from, 2_000_000, LedgerAdminReward, "seed-wdr"); err != nil {
		t.Fatalf("CreditWithdrawable: %v", err)
	}
	totalBal, totalWdr := s.GetBalanceWithWithdrawable(from)

	moved, err := s.MigrateAccountBalance(from, to)
	if err != nil {
		t.Fatalf("MigrateAccountBalance: %v", err)
	}
	if !moved {
		t.Fatal("expected moved=true")
	}
	// Source drained, destination credited with the full balance + withdrawable.
	if b := s.GetBalance(from); b != 0 {
		t.Errorf("source balance = %d, want 0", b)
	}
	if b, w := s.GetBalanceWithWithdrawable(to); b != totalBal || w != totalWdr {
		t.Errorf("dest balance=%d/wdr=%d, want %d/%d", b, w, totalBal, totalWdr)
	}
	// Idempotent: a second migration is a no-op (source already empty).
	if moved, _ := s.MigrateAccountBalance(from, to); moved {
		t.Error("second migration should be a no-op")
	}
	// No-op for an account with no balance.
	if moved, _ := s.MigrateAccountBalance("empty-acct", "dest"); moved {
		t.Error("migrating an empty account should be a no-op")
	}
}

func TestKeyLabelMasking(t *testing.T) {
	raw := KeyPrefix + "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
	label := KeyLabel(raw)
	if !strings.HasPrefix(label, KeyPrefix) {
		t.Errorf("label %q missing prefix", label)
	}
	if !strings.Contains(label, "...") {
		t.Errorf("label %q not masked", label)
	}
	if !strings.HasSuffix(label, raw[len(raw)-4:]) {
		t.Errorf("label %q missing suffix", label)
	}
	if strings.Contains(label, raw[16:40]) {
		t.Errorf("label %q leaks key body", label)
	}
}
