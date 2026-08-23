package store

import (
	"strings"
	"testing"
	"time"
)

func TestAPIKeyStoreContract(t *testing.T) {
	for name, st := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			testAPIKeyStoreContract(t, st)
		})
	}
}

func testAPIKeyStoreContract(t *testing.T, st Store) {
	t.Helper()

	legacyRaw, err := st.CreateKey()
	if err != nil || !strings.HasPrefix(legacyRaw, KeyPrefix) || !st.ValidateKey(legacyRaw) {
		t.Fatalf("create legacy key = %q err=%v", legacyRaw, err)
	}
	if owner := st.GetKeyAccount(legacyRaw); owner != "" {
		t.Fatalf("unlinked legacy key owner = %q, want empty", owner)
	}
	linkedAccountID := uniqueID("legacy-key-account")
	linkedRaw, err := st.CreateKeyForAccount(linkedAccountID)
	if err != nil || !st.ValidateKey(linkedRaw) || st.GetKeyAccount(linkedRaw) != linkedAccountID {
		t.Fatalf("create linked legacy key = %q owner=%q err=%v", linkedRaw, st.GetKeyAccount(linkedRaw), err)
	}
	if linkedRaw == legacyRaw {
		t.Fatal("legacy key creation returned a duplicate secret")
	}
	if count := st.KeyCount(); count != 2 {
		t.Fatalf("legacy key count = %d, want 2", count)
	}
	if st.ValidateKey("") || st.ValidateKey(uniqueID("wrong-key")) {
		t.Fatal("unknown legacy key validated")
	}
	if !st.RevokeKey(legacyRaw) || st.ValidateKey(legacyRaw) {
		t.Fatal("legacy key revoke failed")
	}
	if count := st.KeyCount(); count != 1 {
		t.Fatalf("legacy key count after revoke = %d, want 1", count)
	}
	if st.RevokeKey(legacyRaw) || st.RevokeKey(uniqueID("missing-key")) {
		t.Fatal("nonexistent legacy key revoke returned true")
	}

	accountID := uniqueID("api-account")
	otherAccountID := uniqueID("api-other-account")
	limit := int64(5_000_000)
	rpm := int64(60)
	raw, rec, err := st.CreateAPIKey(accountID, APIKeyCreate{
		Name:          "prod",
		LimitMicroUSD: &limit,
		LimitReset:    KeyResetMonthly,
		RPMLimit:      &rpm,
		AllowedModels: []string{"model-a"},
		SelfRouteOnly: true,
	})
	if err != nil {
		t.Fatalf("create API key: %v", err)
	}
	if !strings.HasPrefix(raw, KeyPrefix) ||
		rec.ID == "" ||
		!strings.HasPrefix(rec.ID, "key_") ||
		rec.Label == raw ||
		rec.OwnerAccountID != accountID ||
		rec.Name != "prod" {
		t.Fatalf("created API key mismatch: raw=%q rec=%+v", raw, rec)
	}
	authenticated, err := st.AuthenticateKey(raw)
	if err != nil {
		t.Fatalf("authenticate: %v", err)
	}
	if authenticated.ID != rec.ID ||
		authenticated.LimitMicroUSD == nil ||
		*authenticated.LimitMicroUSD != limit ||
		!authenticated.SelfRouteOnly {
		t.Fatalf("authenticated key mismatch: %+v", authenticated)
	}
	if active, owner, err := st.ValidateKeyFull(raw); err != nil || !active || owner != accountID {
		t.Fatalf("validate full = active %v owner %q err %v", active, owner, err)
	}
	if !st.ValidateKey(raw) || st.GetKeyAccount(raw) != accountID {
		t.Fatalf("legacy validation/account lookup failed")
	}
	if _, err := st.AuthenticateKey(uniqueID("unknown-key")); err == nil {
		t.Fatal("unknown key authenticated")
	}

	if _, _, err := st.CreateAPIKey(accountID, APIKeyCreate{Name: "second"}); err != nil {
		t.Fatalf("create second key: %v", err)
	}
	if _, _, err := st.CreateAPIKey(otherAccountID, APIKeyCreate{Name: "other"}); err != nil {
		t.Fatalf("create other-account key: %v", err)
	}
	keys, err := st.ListAPIKeys(accountID)
	if err != nil || len(keys) != 2 {
		t.Fatalf("list account keys = %+v err=%v", keys, err)
	}
	if _, err := st.GetAPIKeyByID(otherAccountID, rec.ID); err == nil {
		t.Fatal("other owner fetched key")
	}
	if got, err := st.GetAPIKeyByID(accountID, rec.ID); err != nil || got.ID != rec.ID {
		t.Fatalf("owner get key = %+v err=%v", got, err)
	}

	touchedAt := time.Date(2026, time.August, 22, 12, 0, 0, 0, time.UTC)
	st.TouchAPIKey(rec.ID, touchedAt)
	touched, err := st.GetAPIKeyByID(accountID, rec.ID)
	if err != nil ||
		touched.LastUsedAt == nil ||
		!touched.LastUsedAt.Equal(touchedAt) {
		t.Fatalf("touch result = %+v err=%v", touched, err)
	}

	mutable := *touched
	mutable.Name = "updated"
	mutable.LimitMicroUSD = nil
	mutable.RPMLimit = nil
	mutable.LimitReset = KeyResetNone
	mutable.SelfRouteOnly = false
	updated, err := st.UpdateAPIKey(accountID, rec.ID, mutable)
	if err != nil {
		t.Fatalf("update key: %v", err)
	}
	if updated.Name != "updated" ||
		updated.LimitMicroUSD != nil ||
		updated.RPMLimit != nil ||
		updated.LimitReset != KeyResetNone ||
		updated.SelfRouteOnly {
		t.Fatalf("updated key mismatch: %+v", updated)
	}

	st.RecordUsageFull("provider", accountID, rec.ID, "model-a", uniqueID("request"), 10, 10, 2_000_000, nil)
	st.RecordUsageFull("provider", accountID, rec.ID, "model-a", uniqueID("request"), 5, 5, 500_000, nil)
	if got := st.KeySpendSince(rec.ID, time.Time{}); got != 2_500_000 {
		t.Fatalf("lifetime spend = %d, want 2500000", got)
	}
	if got := st.KeySpendSince(rec.ID, time.Now().UTC().AddDate(0, 0, 1)); got != 0 {
		t.Fatalf("future-window spend = %d, want 0", got)
	}
	if got := st.KeySpendSince(uniqueID("unknown-key-id"), time.Time{}); got != 0 {
		t.Fatalf("unknown-key spend = %d, want 0", got)
	}

	rotatedRaw, rotated, err := st.RotateAPIKey(accountID, rec.ID)
	if err != nil {
		t.Fatalf("rotate key: %v", err)
	}
	if rotatedRaw == raw || rotated.ID == rec.ID || rotated.Name != updated.Name {
		t.Fatalf("rotated key mismatch: raw=%q rec=%+v", rotatedRaw, rotated)
	}
	if _, err := st.AuthenticateKey(raw); err == nil {
		t.Fatal("old key authenticated after rotation")
	}
	if _, err := st.AuthenticateKey(rotatedRaw); err != nil {
		t.Fatalf("rotated key did not authenticate: %v", err)
	}
	if _, _, err := st.RotateAPIKey(accountID, rec.ID); err == nil {
		t.Fatal("rotating deleted key succeeded")
	}

	if !st.RevokeKey(rotatedRaw) {
		t.Fatal("first legacy revoke returned false")
	}
	if st.ValidateKey(rotatedRaw) {
		t.Fatal("soft-revoked key validated")
	}
	if st.RevokeKey(rotatedRaw) {
		t.Fatal("second legacy revoke returned true")
	}
	keys, err = st.ListAPIKeys(accountID)
	if err != nil {
		t.Fatalf("list after soft revoke: %v", err)
	}
	var softRevoked *APIKey
	for i := range keys {
		if keys[i].ID == rotated.ID {
			softRevoked = &keys[i]
		}
	}
	if softRevoked == nil || !softRevoked.Disabled {
		t.Fatalf("soft-revoked key missing or enabled: %+v", keys)
	}

	revokeRaw, revokeRec, err := st.CreateAPIKey(accountID, APIKeyCreate{Name: "hard-revoke"})
	if err != nil {
		t.Fatalf("create hard-revoke key: %v", err)
	}
	if err := st.RevokeAPIKeyByID(otherAccountID, revokeRec.ID); err == nil {
		t.Fatal("other owner hard-revoked key")
	}
	if err := st.RevokeAPIKeyByID(accountID, revokeRec.ID); err != nil {
		t.Fatalf("hard revoke: %v", err)
	}
	if _, err := st.AuthenticateKey(revokeRaw); err == nil {
		t.Fatal("hard-revoked key authenticated")
	}

	past := time.Now().UTC().Add(-time.Hour)
	expiredRaw, _, err := st.CreateAPIKey(accountID, APIKeyCreate{Name: "expired", ExpiresAt: &past})
	if err != nil {
		t.Fatalf("create expired key: %v", err)
	}
	if st.ValidateKey(expiredRaw) {
		t.Fatal("expired key validated")
	}

	selfRaw, selfKey, err := st.CreateAPIKey(accountID, APIKeyCreate{Name: "self-route", SelfRouteOnly: true})
	if err != nil {
		t.Fatalf("create self-route key: %v", err)
	}
	if authenticated, err := st.AuthenticateKey(selfRaw); err != nil || !authenticated.SelfRouteOnly {
		t.Fatalf("authenticate self-route key = %+v err=%v", authenticated, err)
	}
	selfMutable := *selfKey
	selfMutable.SelfRouteOnly = false
	selfKey, err = st.UpdateAPIKey(accountID, selfKey.ID, selfMutable)
	if err != nil || selfKey.SelfRouteOnly {
		t.Fatalf("disable self-route = %+v err=%v", selfKey, err)
	}
	selfMutable = *selfKey
	selfMutable.SelfRouteOnly = true
	selfKey, err = st.UpdateAPIKey(accountID, selfKey.ID, selfMutable)
	if err != nil || !selfKey.SelfRouteOnly {
		t.Fatalf("restore self-route = %+v err=%v", selfKey, err)
	}
	_, rotatedSelf, err := st.RotateAPIKey(accountID, selfKey.ID)
	if err != nil || !rotatedSelf.SelfRouteOnly {
		t.Fatalf("rotate self-route key = %+v err=%v", rotatedSelf, err)
	}
	_, plain, err := st.CreateAPIKey(accountID, APIKeyCreate{Name: "plain"})
	if err != nil || plain.SelfRouteOnly {
		t.Fatalf("plain key = %+v err=%v", plain, err)
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
