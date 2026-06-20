package store

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func TestNewWithAdminKey(t *testing.T) {
	s := NewMemory(Config{AdminKey: "test-admin-key"})
	if !s.ValidateKey("test-admin-key") {
		t.Error("admin key should be valid")
	}
	if s.KeyCount() != 1 {
		t.Errorf("key count = %d, want 1", s.KeyCount())
	}
}

func TestNewWithoutAdminKey(t *testing.T) {
	s := NewMemory(Config{})
	if s.KeyCount() != 0 {
		t.Errorf("key count = %d, want 0", s.KeyCount())
	}
}

func TestCreateKey(t *testing.T) {
	s := NewMemory(Config{})

	key, err := s.CreateKey()
	if err != nil {
		t.Fatalf("CreateKey: %v", err)
	}

	if !strings.HasPrefix(key, KeyPrefix) {
		t.Errorf("key %q does not have %q prefix", key, KeyPrefix)
	}

	if !s.ValidateKey(key) {
		t.Error("created key should be valid")
	}

	if s.KeyCount() != 1 {
		t.Errorf("key count = %d, want 1", s.KeyCount())
	}
}

func TestCreateMultipleKeys(t *testing.T) {
	s := NewMemory(Config{})

	key1, _ := s.CreateKey()
	key2, _ := s.CreateKey()

	if key1 == key2 {
		t.Error("keys should be unique")
	}

	if s.KeyCount() != 2 {
		t.Errorf("key count = %d, want 2", s.KeyCount())
	}
}

func TestValidateKeyInvalid(t *testing.T) {
	s := NewMemory(Config{AdminKey: "admin-key"})
	if s.ValidateKey("wrong-key") {
		t.Error("wrong key should not be valid")
	}
	if s.ValidateKey("") {
		t.Error("empty key should not be valid")
	}
}

func TestRevokeKey(t *testing.T) {
	s := NewMemory(Config{AdminKey: "admin-key"})

	key, _ := s.CreateKey()
	if !s.ValidateKey(key) {
		t.Fatal("key should be valid before revoke")
	}

	if !s.RevokeKey(key) {
		t.Error("RevokeKey should return true for existing key")
	}
	if s.ValidateKey(key) {
		t.Error("key should be invalid after revoke")
	}
}

func TestRevokeKeyNonexistent(t *testing.T) {
	s := NewMemory(Config{})
	if s.RevokeKey("nonexistent") {
		t.Error("RevokeKey should return false for nonexistent key")
	}
}

func TestRecordUsage(t *testing.T) {
	s := NewMemory(Config{})

	s.RecordUsage("provider-1", "consumer-key", "qwen3.5-9b", 50, 100)
	s.RecordUsage("provider-2", "consumer-key", "llama-3", 30, 200)

	records := s.UsageRecords()
	if len(records) != 2 {
		t.Fatalf("usage records = %d, want 2", len(records))
	}

	r := records[0]
	if r.ProviderID != "provider-1" {
		t.Errorf("provider_id = %q", r.ProviderID)
	}
	if r.ConsumerKey != "consumer-key" {
		t.Errorf("consumer_key = %q", r.ConsumerKey)
	}
	if r.Model != "qwen3.5-9b" {
		t.Errorf("model = %q", r.Model)
	}
	if r.PromptTokens != 50 {
		t.Errorf("prompt_tokens = %d", r.PromptTokens)
	}
	if r.CompletionTokens != 100 {
		t.Errorf("completion_tokens = %d", r.CompletionTokens)
	}
	if r.Timestamp.IsZero() {
		t.Error("timestamp should not be zero")
	}
}

func TestRecordUsageFullWithPublicModel(t *testing.T) {
	s := NewMemory(Config{})

	s.RecordUsageFullWithPublicModel("provider-1", "consumer-key", "key-1", "build-v1", "public-alias", "req-1", 50, 100, 123, nil)

	records := s.UsageRecords()
	if len(records) != 1 {
		t.Fatalf("usage records = %d, want 1", len(records))
	}
	if records[0].Model != "build-v1" {
		t.Fatalf("model = %q, want concrete build", records[0].Model)
	}
	if records[0].PublicModel != "public-alias" {
		t.Fatalf("public_model = %q, want public alias", records[0].PublicModel)
	}
}

func TestUsageRecordsReturnsCopy(t *testing.T) {
	s := NewMemory(Config{})
	s.RecordUsage("p1", "k1", "m1", 10, 20)

	records := s.UsageRecords()
	records[0].PromptTokens = 999

	// Original should be unchanged.
	original := s.UsageRecords()
	if original[0].PromptTokens != 10 {
		t.Error("UsageRecords should return a copy")
	}
}

func TestUsageRecordsEmpty(t *testing.T) {
	s := NewMemory(Config{})
	records := s.UsageRecords()
	if len(records) != 0 {
		t.Errorf("usage records = %d, want 0", len(records))
	}
}

func TestRecordPayment(t *testing.T) {
	s := NewMemory(Config{})

	err := s.RecordPayment("0xabc123", "0xconsumer", "0xprovider", "0.05", "qwen3.5-9b", 50, 100, "test payment")
	if err != nil {
		t.Fatalf("RecordPayment: %v", err)
	}
}

func TestRecordPaymentDuplicateTxHash(t *testing.T) {
	s := NewMemory(Config{})

	err := s.RecordPayment("0xabc123", "0xconsumer", "0xprovider", "0.05", "qwen3.5-9b", 50, 100, "")
	if err != nil {
		t.Fatalf("first RecordPayment: %v", err)
	}

	err = s.RecordPayment("0xabc123", "0xconsumer", "0xprovider", "0.05", "qwen3.5-9b", 50, 100, "")
	if err == nil {
		t.Error("expected error for duplicate tx_hash")
	}
}

func TestMemoryStoreImplementsInterface(t *testing.T) {
	var _ Store = NewMemory(Config{})
}

func TestDeviceCodeFlow(t *testing.T) {
	s := NewMemory(Config{})

	dc := &DeviceCode{
		DeviceCode: "dev-code-123",
		UserCode:   "ABCD-1234",
		Status:     "pending",
		ExpiresAt:  time.Now().Add(15 * time.Minute),
	}

	// Create
	if err := s.CreateDeviceCode(dc); err != nil {
		t.Fatalf("CreateDeviceCode: %v", err)
	}

	// Duplicate user code should fail
	dc2 := &DeviceCode{DeviceCode: "dev-code-456", UserCode: "ABCD-1234", Status: "pending", ExpiresAt: time.Now().Add(15 * time.Minute)}
	if err := s.CreateDeviceCode(dc2); err == nil {
		t.Error("expected error for duplicate user code")
	}

	// Lookup by device code
	got, err := s.GetDeviceCode("dev-code-123")
	if err != nil {
		t.Fatalf("GetDeviceCode: %v", err)
	}
	if got.UserCode != "ABCD-1234" || got.Status != "pending" {
		t.Errorf("got user_code=%q status=%q", got.UserCode, got.Status)
	}

	// Lookup by user code
	got2, err := s.GetDeviceCodeByUserCode("ABCD-1234")
	if err != nil {
		t.Fatalf("GetDeviceCodeByUserCode: %v", err)
	}
	if got2.DeviceCode != "dev-code-123" {
		t.Errorf("got device_code=%q", got2.DeviceCode)
	}

	// Approve
	if err := s.ApproveDeviceCode("dev-code-123", "account-abc"); err != nil {
		t.Fatalf("ApproveDeviceCode: %v", err)
	}

	approved, _ := s.GetDeviceCode("dev-code-123")
	if approved.Status != "approved" || approved.AccountID != "account-abc" {
		t.Errorf("after approve: status=%q account=%q", approved.Status, approved.AccountID)
	}

	// Double approve should fail
	if err := s.ApproveDeviceCode("dev-code-123", "account-xyz"); err == nil {
		t.Error("expected error approving already-approved code")
	}
}

func TestDeviceCodeExpiry(t *testing.T) {
	s := NewMemory(Config{})

	dc := &DeviceCode{
		DeviceCode: "expired-code",
		UserCode:   "XXXX-0000",
		Status:     "pending",
		ExpiresAt:  time.Now().Add(-1 * time.Minute), // already expired
	}
	if err := s.CreateDeviceCode(dc); err != nil {
		t.Fatalf("CreateDeviceCode: %v", err)
	}

	// Approve expired code should fail
	if err := s.ApproveDeviceCode("expired-code", "account-abc"); err == nil {
		t.Error("expected error approving expired code")
	}

	// Cleanup should remove it
	if err := s.DeleteExpiredDeviceCodes(); err != nil {
		t.Fatalf("DeleteExpiredDeviceCodes: %v", err)
	}
	if _, err := s.GetDeviceCode("expired-code"); err == nil {
		t.Error("expected error after cleanup")
	}
}

func TestProviderToken(t *testing.T) {
	s := NewMemory(Config{})

	rawToken := "darkbloom-token-abc123"
	tokenHash := sha256Hex(rawToken)

	pt := &ProviderToken{
		TokenHash: tokenHash,
		AccountID: "account-abc",
		Label:     "my-macbook",
		Active:    true,
	}
	if err := s.CreateProviderToken(pt); err != nil {
		t.Fatalf("CreateProviderToken: %v", err)
	}

	// Validate with raw token
	got, err := s.GetProviderToken(rawToken)
	if err != nil {
		t.Fatalf("GetProviderToken: %v", err)
	}
	if got.AccountID != "account-abc" || got.Label != "my-macbook" {
		t.Errorf("got account=%q label=%q", got.AccountID, got.Label)
	}

	// Revoke
	if err := s.RevokeProviderToken(rawToken); err != nil {
		t.Fatalf("RevokeProviderToken: %v", err)
	}
	if _, err := s.GetProviderToken(rawToken); err == nil {
		t.Error("expected error for revoked token")
	}
}

func TestProviderEarnings_RecordAndGetByAccount(t *testing.T) {
	s := NewMemory(Config{})

	// Record three earnings for the same account, two different nodes.
	e1 := &ProviderEarning{
		AccountID: "acct-1", ProviderID: "prov-A", ProviderKey: "key-A",
		JobID: "job-1", Model: "qwen3.5-9b", AmountMicroUSD: 1000,
		PromptTokens: 10, CompletionTokens: 50,
		CreatedAt: time.Now().Add(-2 * time.Minute),
	}
	e2 := &ProviderEarning{
		AccountID: "acct-1", ProviderID: "prov-B", ProviderKey: "key-B",
		JobID: "job-2", Model: "llama-3", AmountMicroUSD: 2000,
		PromptTokens: 20, CompletionTokens: 100,
		CreatedAt: time.Now().Add(-1 * time.Minute),
	}
	e3 := &ProviderEarning{
		AccountID: "acct-1", ProviderID: "prov-A", ProviderKey: "key-A",
		JobID: "job-3", Model: "qwen3.5-9b", AmountMicroUSD: 1500,
		PromptTokens: 15, CompletionTokens: 75,
		CreatedAt: time.Now(),
	}

	for _, e := range []*ProviderEarning{e1, e2, e3} {
		if err := s.RecordProviderEarning(e); err != nil {
			t.Fatalf("RecordProviderEarning: %v", err)
		}
	}

	// GetAccountEarnings should return all three, newest first.
	earnings, err := s.GetAccountEarnings("acct-1", 50)
	if err != nil {
		t.Fatalf("GetAccountEarnings: %v", err)
	}
	if len(earnings) != 3 {
		t.Fatalf("expected 3 earnings, got %d", len(earnings))
	}
	// Newest first: e3 has ID 3, e2 has ID 2, e1 has ID 1
	if earnings[0].JobID != "job-3" {
		t.Errorf("first earning should be job-3, got %q", earnings[0].JobID)
	}
	if earnings[1].JobID != "job-2" {
		t.Errorf("second earning should be job-2, got %q", earnings[1].JobID)
	}
	if earnings[2].JobID != "job-1" {
		t.Errorf("third earning should be job-1, got %q", earnings[2].JobID)
	}

	// IDs should be auto-assigned.
	if earnings[0].ID != 3 || earnings[1].ID != 2 || earnings[2].ID != 1 {
		t.Errorf("IDs should be auto-assigned: got %d, %d, %d", earnings[0].ID, earnings[1].ID, earnings[2].ID)
	}
}

func TestProviderEarnings_GetByProviderKey(t *testing.T) {
	s := NewMemory(Config{})

	// Record earnings for two different nodes.
	for i := range 5 {
		key := "key-A"
		if i%2 == 0 {
			key = "key-B"
		}
		_ = s.RecordProviderEarning(&ProviderEarning{
			AccountID: "acct-1", ProviderID: "prov-X", ProviderKey: key,
			JobID: "job-" + string(rune('a'+i)), Model: "test-model",
			AmountMicroUSD: int64(1000 * (i + 1)),
			PromptTokens:   10, CompletionTokens: 50,
		})
	}

	// key-A should have 2 earnings (i=1, i=3)
	earningsA, err := s.GetProviderEarnings("key-A", 50)
	if err != nil {
		t.Fatalf("GetProviderEarnings key-A: %v", err)
	}
	if len(earningsA) != 2 {
		t.Errorf("expected 2 earnings for key-A, got %d", len(earningsA))
	}

	// key-B should have 3 earnings (i=0, i=2, i=4)
	earningsB, err := s.GetProviderEarnings("key-B", 50)
	if err != nil {
		t.Fatalf("GetProviderEarnings key-B: %v", err)
	}
	if len(earningsB) != 3 {
		t.Errorf("expected 3 earnings for key-B, got %d", len(earningsB))
	}

	// Nonexistent key should return empty slice.
	earningsC, err := s.GetProviderEarnings("key-C", 50)
	if err != nil {
		t.Fatalf("GetProviderEarnings key-C: %v", err)
	}
	if len(earningsC) != 0 {
		t.Errorf("expected 0 earnings for key-C, got %d", len(earningsC))
	}
}

func TestProviderEarnings_NewestFirst(t *testing.T) {
	s := NewMemory(Config{})

	// Record in chronological order.
	for i := range 5 {
		_ = s.RecordProviderEarning(&ProviderEarning{
			AccountID: "acct-1", ProviderID: "prov-1", ProviderKey: "key-1",
			JobID: string(rune('a' + i)), Model: "test-model",
			AmountMicroUSD: int64(i + 1),
		})
	}

	earnings, _ := s.GetProviderEarnings("key-1", 50)
	if len(earnings) != 5 {
		t.Fatalf("expected 5 earnings, got %d", len(earnings))
	}
	// Newest first means highest ID first.
	for i := range len(earnings) - 1 {
		if earnings[i].ID < earnings[i+1].ID {
			t.Errorf("earnings not in newest-first order: ID %d before ID %d", earnings[i].ID, earnings[i+1].ID)
		}
	}
}

func TestProviderEarnings_LimitRespected(t *testing.T) {
	s := NewMemory(Config{})

	// Record 10 earnings.
	for i := range 10 {
		_ = s.RecordProviderEarning(&ProviderEarning{
			AccountID: "acct-1", ProviderID: "prov-1", ProviderKey: "key-1",
			JobID: string(rune('a' + i)), Model: "test-model",
			AmountMicroUSD: int64(i + 1),
		})
	}

	// Limit to 3.
	earnings, err := s.GetProviderEarnings("key-1", 3)
	if err != nil {
		t.Fatalf("GetProviderEarnings: %v", err)
	}
	if len(earnings) != 3 {
		t.Errorf("expected 3 earnings with limit=3, got %d", len(earnings))
	}
	// Should be the 3 newest (IDs 10, 9, 8).
	if earnings[0].ID != 10 {
		t.Errorf("first earning ID = %d, want 10", earnings[0].ID)
	}

	// Limit also works for account earnings.
	acctEarnings, err := s.GetAccountEarnings("acct-1", 5)
	if err != nil {
		t.Fatalf("GetAccountEarnings: %v", err)
	}
	if len(acctEarnings) != 5 {
		t.Errorf("expected 5 account earnings with limit=5, got %d", len(acctEarnings))
	}
}

func TestProviderEarnings_DifferentAccounts(t *testing.T) {
	s := NewMemory(Config{})

	// Record earnings for two different accounts.
	_ = s.RecordProviderEarning(&ProviderEarning{
		AccountID: "acct-1", ProviderID: "prov-1", ProviderKey: "key-1",
		JobID: "job-1", Model: "test-model", AmountMicroUSD: 1000,
	})
	_ = s.RecordProviderEarning(&ProviderEarning{
		AccountID: "acct-2", ProviderID: "prov-2", ProviderKey: "key-2",
		JobID: "job-2", Model: "test-model", AmountMicroUSD: 2000,
	})

	// acct-1 should only see 1 earning.
	e1, _ := s.GetAccountEarnings("acct-1", 50)
	if len(e1) != 1 {
		t.Errorf("expected 1 earning for acct-1, got %d", len(e1))
	}
	if e1[0].AmountMicroUSD != 1000 {
		t.Errorf("expected amount 1000, got %d", e1[0].AmountMicroUSD)
	}

	// acct-2 should only see 1 earning.
	e2, _ := s.GetAccountEarnings("acct-2", 50)
	if len(e2) != 1 {
		t.Errorf("expected 1 earning for acct-2, got %d", len(e2))
	}
	if e2[0].AmountMicroUSD != 2000 {
		t.Errorf("expected amount 2000, got %d", e2[0].AmountMicroUSD)
	}
}

func TestProviderPayouts_RecordListAndSettle(t *testing.T) {
	s := NewMemory(Config{})

	p1 := &ProviderPayout{
		ProviderAddress: "0xProvider1",
		AmountMicroUSD:  900_000,
		Model:           "qwen3.5-9b",
		JobID:           "job-1",
	}
	p2 := &ProviderPayout{
		ProviderAddress: "0xProvider2",
		AmountMicroUSD:  450_000,
		Model:           "llama-3",
		JobID:           "job-2",
	}
	for _, payout := range []*ProviderPayout{p1, p2} {
		if err := s.RecordProviderPayout(payout); err != nil {
			t.Fatalf("RecordProviderPayout: %v", err)
		}
	}

	payouts, err := s.ListProviderPayouts()
	if err != nil {
		t.Fatalf("ListProviderPayouts: %v", err)
	}
	if len(payouts) != 2 {
		t.Fatalf("provider payouts = %d, want 2", len(payouts))
	}
	if payouts[0].ID != 1 || payouts[1].ID != 2 {
		t.Fatalf("provider payout IDs = %d, %d, want 1, 2", payouts[0].ID, payouts[1].ID)
	}
	if payouts[0].Settled {
		t.Fatal("first payout should start unsettled")
	}

	if err := s.SettleProviderPayout(payouts[0].ID); err != nil {
		t.Fatalf("SettleProviderPayout: %v", err)
	}

	payouts, err = s.ListProviderPayouts()
	if err != nil {
		t.Fatalf("ListProviderPayouts after settle: %v", err)
	}
	if !payouts[0].Settled {
		t.Fatal("first payout should be settled")
	}
	if payouts[1].Settled {
		t.Fatal("second payout should remain unsettled")
	}

	if err := s.SettleProviderPayout(payouts[0].ID); err == nil {
		t.Fatal("expected error settling same payout twice")
	}
}

func TestCreditProviderAccountAtomic(t *testing.T) {
	s := NewMemory(Config{})

	earning := &ProviderEarning{
		AccountID:        "acct-linked",
		ProviderID:       "prov-1",
		ProviderKey:      "key-1",
		JobID:            "job-atomic",
		Model:            "qwen3.5-9b",
		AmountMicroUSD:   123_000,
		PromptTokens:     10,
		CompletionTokens: 20,
	}
	if err := s.CreditProviderAccount(earning); err != nil {
		t.Fatalf("CreditProviderAccount: %v", err)
	}

	if bal := s.GetBalance("acct-linked"); bal != 123_000 {
		t.Fatalf("balance = %d, want 123000", bal)
	}

	history := s.LedgerHistory("acct-linked")
	if len(history) != 1 {
		t.Fatalf("ledger history = %d, want 1", len(history))
	}
	if history[0].Type != LedgerPayout {
		t.Fatalf("ledger entry type = %q, want payout", history[0].Type)
	}

	earnings, err := s.GetAccountEarnings("acct-linked", 10)
	if err != nil {
		t.Fatalf("GetAccountEarnings: %v", err)
	}
	if len(earnings) != 1 {
		t.Fatalf("earnings = %d, want 1", len(earnings))
	}
	if earnings[0].JobID != "job-atomic" {
		t.Fatalf("earning job_id = %q, want job-atomic", earnings[0].JobID)
	}
}

func TestCreditProviderWalletAtomic(t *testing.T) {
	s := NewMemory(Config{})

	payout := &ProviderPayout{
		ProviderAddress: "0xatomicwallet",
		AmountMicroUSD:  456_000,
		Model:           "llama-3",
		JobID:           "job-wallet",
	}
	if err := s.CreditProviderWallet(payout); err != nil {
		t.Fatalf("CreditProviderWallet: %v", err)
	}

	if bal := s.GetBalance("0xatomicwallet"); bal != 456_000 {
		t.Fatalf("wallet balance = %d, want 456000", bal)
	}

	history := s.LedgerHistory("0xatomicwallet")
	if len(history) != 1 {
		t.Fatalf("ledger history = %d, want 1", len(history))
	}
	if history[0].Type != LedgerPayout {
		t.Fatalf("ledger entry type = %q, want payout", history[0].Type)
	}

	payouts, err := s.ListProviderPayouts()
	if err != nil {
		t.Fatalf("ListProviderPayouts: %v", err)
	}
	if len(payouts) != 1 {
		t.Fatalf("provider payouts = %d, want 1", len(payouts))
	}
	if payouts[0].JobID != "job-wallet" {
		t.Fatalf("payout job_id = %q, want job-wallet", payouts[0].JobID)
	}
}

func TestReleases(t *testing.T) {
	s := NewMemory(Config{})

	// Empty initially.
	releases := s.ListReleases()
	if len(releases) != 0 {
		t.Fatalf("expected 0 releases, got %d", len(releases))
	}
	if r := s.GetLatestRelease("macos-arm64"); r != nil {
		t.Fatal("expected nil latest release")
	}

	// Add releases.
	r1 := &Release{
		Version:    "0.2.0",
		Platform:   "macos-arm64",
		BinaryHash: "aaa111",
		BundleHash: "bbb222",
		URL:        "https://r2.example.com/releases/v0.2.0/bundle.tar.gz",
	}
	r2 := &Release{
		Version:      "0.2.1",
		Platform:     "macos-arm64",
		Backend:      "mlx-swift",
		BinaryHash:   "ccc333",
		BundleHash:   "ddd444",
		MetallibHash: "eee555",
		URL:          "https://r2.example.com/releases/v0.2.1/bundle.tar.gz",
	}
	if err := s.SetRelease(r1); err != nil {
		t.Fatalf("SetRelease r1: %v", err)
	}
	// Small delay so r2 has a later timestamp.
	time.Sleep(time.Millisecond)
	if err := s.SetRelease(r2); err != nil {
		t.Fatalf("SetRelease r2: %v", err)
	}

	releases = s.ListReleases()
	if len(releases) != 2 {
		t.Fatalf("expected 2 releases, got %d", len(releases))
	}

	// Latest should be r2.
	latest := s.GetLatestRelease("macos-arm64")
	if latest == nil {
		t.Fatal("expected non-nil latest release")
	}
	if latest.Version != "0.2.1" {
		t.Errorf("expected latest version 0.2.1, got %s", latest.Version)
	}
	if latest.BinaryHash != "ccc333" {
		t.Errorf("expected binary_hash ccc333, got %s", latest.BinaryHash)
	}
	if latest.Backend != "mlx-swift" {
		t.Errorf("expected backend mlx-swift, got %s", latest.Backend)
	}
	if latest.MetallibHash != "eee555" {
		t.Errorf("expected metallib_hash eee555, got %s", latest.MetallibHash)
	}

	// Unknown platform returns nil.
	if r := s.GetLatestRelease("linux-amd64"); r != nil {
		t.Error("expected nil for unknown platform")
	}

	// Deactivate r2.
	if err := s.DeleteRelease("0.2.1", "macos-arm64"); err != nil {
		t.Fatalf("DeleteRelease: %v", err)
	}

	// Latest should now be r1.
	latest = s.GetLatestRelease("macos-arm64")
	if latest == nil {
		t.Fatal("expected non-nil latest after deactivation")
	}
	if latest.Version != "0.2.0" {
		t.Errorf("expected latest version 0.2.0 after deactivation, got %s", latest.Version)
	}

	// Deactivate nonexistent.
	if err := s.DeleteRelease("9.9.9", "macos-arm64"); err == nil {
		t.Error("expected error for nonexistent release")
	}

	// Validation: empty version.
	if err := s.SetRelease(&Release{Platform: "macos-arm64"}); err == nil {
		t.Error("expected error for empty version")
	}
}

func TestGetLatestReleasePrefersHigherSemverOverNewerTimestamp(t *testing.T) {
	s := NewMemory(Config{})

	if err := s.SetRelease(&Release{
		Version:    "0.3.9",
		Platform:   "macos-arm64",
		BinaryHash: "higher-semver",
		BundleHash: "bundle-higher-semver",
		URL:        "https://r2.example.com/releases/v0.3.9/bundle.tar.gz",
		CreatedAt:  time.Now().Add(-time.Hour),
	}); err != nil {
		t.Fatalf("SetRelease 0.3.9: %v", err)
	}

	if err := s.SetRelease(&Release{
		Version:    "0.3.8",
		Platform:   "macos-arm64",
		BinaryHash: "newer-timestamp",
		BundleHash: "bundle-newer-timestamp",
		URL:        "https://r2.example.com/releases/v0.3.8/bundle.tar.gz",
		CreatedAt:  time.Now(),
	}); err != nil {
		t.Fatalf("SetRelease 0.3.8: %v", err)
	}

	latest := s.GetLatestRelease("macos-arm64")
	if latest == nil {
		t.Fatal("expected non-nil latest release")
	}
	if latest.Version != "0.3.9" {
		t.Fatalf("latest version = %q, want %q", latest.Version, "0.3.9")
	}
}

func TestInferenceRoute_Memory(t *testing.T) {
	s := NewMemory(Config{})
	testInferenceRouteStore(t, s)
}

func TestInferenceRoute_Postgres(t *testing.T) {
	s := testPostgresStore(t)
	testInferenceRouteStore(t, s)
}

func testInferenceRouteStore(t *testing.T, s Store) {
	t.Helper()

	beforeRecord := time.Now().Add(-time.Minute)

	rec := &InferenceRouteRecord{
		RequestID:               "req-1",
		Attempt:                 1,
		ProviderID:              "prov-1",
		Model:                   "mlx-community/Qwen3.5-9B-MLX-4bit",
		PublicModel:             "qwen3.5-9b",
		ConsumerKeyHash:         "abc123hash",
		KeyID:                   "key_123",
		Outcome:                 "routed",
		CostMs:                  12.5,
		StateMs:                 3.0,
		QueueMs:                 1.5,
		PendingMs:               0.5,
		BacklogMs:               0.25,
		ThisReqMs:               2.0,
		HealthMs:                1.0,
		TTFTMs:                  50.0,
		BestTTFTMs:              40.0,
		EffectiveQueue:          2,
		CandidateCount:          4,
		CapacityRejections:      1,
		ModelTooLargeRejections: 0,
		VisionRejections:        0,
		TTFTRejections:          0,
		EffectiveTPS:            45.2,
		StaticTPS:               38.0,
		ProviderStatus:          "idle",
		ProviderTrustLevel:      "attested",
		ProviderVersion:         "0.5.0",
		HardwareChip:            "Apple M3 Max",
		HardwareChipFamily:      "M3",
		HardwareTier:            "high",
		MemoryGB:                128,
		GPUCores:                40,
		CPUCores:                16,
		SystemMemoryPressure:    0.2,
		SystemCPUUsage:          0.15,
		SystemThermalState:      "Nominal",
		GPUMemoryActiveGB:       8.5,
		GPUMemoryPeakGB:         12.0,
		GPUMemoryCacheGB:        2.0,
		SlotState:               "idle",
		BackendRunning:          1,
		BackendWaiting:          0,
		ActiveTokenBudgetUsed:   1000,
		ActiveTokenBudgetMax:    4096,
		QueuedTokenBudget:       0,
		EstimatedPromptTokens:   500,
		RequestedMaxTokens:      1024,
		RequiresVision:          true,
		HasTools:                false,
		SelfRouteOnly:           false,
		PreferOwner:             true,
		CacheAffinityKey:        "owner-123",
	}

	if err := s.RecordInferenceRoute(rec); err != nil {
		t.Fatalf("RecordInferenceRoute: %v", err)
	}

	// Lookup by request_id via zero-time since returns all records.
	all := s.InferenceRouteRecordsSince(time.Time{})
	if len(all) != 1 {
		t.Fatalf("InferenceRouteRecordsSince(zero) = %d records, want 1", len(all))
	}
	got := all[0]
	if got.RequestID != "req-1" || got.Attempt != 1 || got.ProviderID != "prov-1" {
		t.Errorf("record mismatch: got request_id=%q attempt=%d provider_id=%q", got.RequestID, got.Attempt, got.ProviderID)
	}
	if got.Model != rec.Model || got.PublicModel != rec.PublicModel {
		t.Errorf("model/public_model mismatch: got %q/%q want %q/%q", got.Model, got.PublicModel, rec.Model, rec.PublicModel)
	}
	if got.Outcome != "routed" {
		t.Errorf("outcome = %q, want routed", got.Outcome)
	}
	if got.CostMs != 12.5 {
		t.Errorf("cost_ms = %f, want 12.5", got.CostMs)
	}
	if got.CreatedAt.IsZero() || got.UpdatedAt.IsZero() {
		t.Error("created_at and updated_at should be set")
	}
	if !got.CreatedAt.After(beforeRecord) {
		t.Error("created_at should be after beforeRecord")
	}

	// RecordsSince filters out older records.
	old := s.InferenceRouteRecordsSince(time.Now().Add(time.Hour))
	if len(old) != 0 {
		t.Fatalf("InferenceRouteRecordsSince(future) = %d records, want 0", len(old))
	}

	// Update outcome.
	beforeUpdate := time.Now()
	outcome := &InferenceRouteOutcome{
		FinalStatus:            "success",
		ErrorCode:              0,
		ErrorClass:             "",
		ErrorReason:            "",
		PromptTokens:           50,
		CompletionTokens:       100,
		ReasoningTokens:        10,
		CostMicroUSD:           2500,
		ActualTTFTMs:           150.0,
		DispatchToFirstChunkMs: 180.0,
		TotalDurationMs:        1200.0,
		ParseMs:                1,
		ReserveMs:              2,
		RouteMs:                3,
		EncryptMs:              4,
		QueueWaitMs:            5,
		DispatchMs:             6,
		ActualDecodeTPS:        42,
		AdmittedButFailed:      true,
		UsedBackup:             true,
		BackupWon:              true,
	}
	if err := s.UpdateInferenceRouteOutcome("req-1", 1, outcome); err != nil {
		t.Fatalf("UpdateInferenceRouteOutcome: %v", err)
	}

	all = s.InferenceRouteRecordsSince(time.Time{})
	if len(all) != 1 {
		t.Fatalf("after update: expected 1 record, got %d", len(all))
	}
	if all[0].UpdatedAt.IsZero() {
		t.Error("updated_at should not be zero after update")
	}
	if !all[0].UpdatedAt.After(beforeUpdate) {
		// Allow a small amount of clock skew between process and DB for Postgres.
		if all[0].UpdatedAt.Sub(beforeUpdate) < -time.Second {
			t.Errorf("updated_at should be after beforeUpdate, got %v (beforeUpdate %v)", all[0].UpdatedAt, beforeUpdate)
		}
	}
	if all[0].FinalStatus != "success" || all[0].PromptTokens != 50 || all[0].CompletionTokens != 100 || all[0].ReasoningTokens != 10 {
		t.Errorf("outcome tokens/status not exposed on route record: %+v", all[0])
	}
	if all[0].CostMicroUSD != 2500 || all[0].ActualTTFTMs != 150 || all[0].DispatchToFirstChunkMs != 180 || all[0].TotalDurationMs != 1200 {
		t.Errorf("outcome cost/timing not exposed on route record: %+v", all[0])
	}
	if all[0].ParseMs != 1 || all[0].ReserveMs != 2 || all[0].RouteMs != 3 || all[0].EncryptMs != 4 || all[0].QueueWaitMs != 5 || all[0].DispatchMs != 6 {
		t.Errorf("latency decomposition not exposed on route record: %+v", all[0])
	}
	if all[0].ActualDecodeTPS != 42 || !all[0].AdmittedButFailed || !all[0].UsedBackup || !all[0].BackupWon {
		t.Errorf("decode/backup flags not exposed on route record: %+v", all[0])
	}

	if err := s.UpdateInferenceRouteOutcome("req-1", 1, &InferenceRouteOutcome{FinalStatus: "error", ErrorClass: "provider_error", ErrorCode: 500, ErrorReason: "jinja_template"}); err != nil {
		t.Fatalf("UpdateInferenceRouteOutcome error reason: %v", err)
	}
	all = s.InferenceRouteRecordsSince(time.Time{})
	if all[0].ErrorReason != "jinja_template" {
		t.Errorf("error_reason not exposed on route record: %+v", all[0])
	}

	// A later latency-only committed update must not erase the terminal status or
	// token/cost fields.
	if err := s.UpdateInferenceRouteOutcome("req-1", 1, &InferenceRouteOutcome{ActualTTFTMs: 175}); err != nil {
		t.Fatalf("UpdateInferenceRouteOutcome latency-only: %v", err)
	}
	all = s.InferenceRouteRecordsSince(time.Time{})
	if all[0].FinalStatus != "error" || all[0].PromptTokens != 50 || all[0].CostMicroUSD != 2500 || all[0].ActualTTFTMs != 175 || all[0].ErrorReason != "jinja_template" {
		t.Errorf("latency-only outcome update should merge, got %+v", all[0])
	}

	// Record a second attempt for the same request and verify lookup by request_id.
	rec2 := &InferenceRouteRecord{
		RequestID:  "req-1",
		Attempt:    2,
		ProviderID: "prov-2",
		Model:      rec.Model,
		Outcome:    "fallback",
	}
	if err := s.RecordInferenceRoute(rec2); err != nil {
		t.Fatalf("RecordInferenceRoute attempt 2: %v", err)
	}

	all = s.InferenceRouteRecordsSince(time.Time{})
	if len(all) != 2 {
		t.Fatalf("expected 2 records, got %d", len(all))
	}

	// Records should be newest-first (by created_at).
	if all[0].Attempt != 2 {
		t.Errorf("first record attempt = %d, want 2", all[0].Attempt)
	}
	if all[1].Attempt != 1 {
		t.Errorf("second record attempt = %d, want 1", all[1].Attempt)
	}

	queued := &InferenceRouteRecord{
		RequestID: "req-queued",
		Attempt:   0,
		Model:     rec.Model,
		Outcome:   "queued",
	}
	if err := s.RecordInferenceRoute(queued); err != nil {
		t.Fatalf("RecordInferenceRoute queued: %v", err)
	}
	queuedSelected := *queued
	queuedSelected.ProviderID = "prov-queued"
	queuedSelected.Outcome = "selected"
	queuedSelected.ProviderStatus = "serving"
	queuedSelected.HardwareChip = "Apple M4 Max"
	if err := s.RecordInferenceRoute(&queuedSelected); err != nil {
		t.Fatalf("RecordInferenceRoute queued selected refresh: %v", err)
	}
	all = s.InferenceRouteRecordsSince(time.Time{})
	var queuedGot *InferenceRouteRecord
	queuedCount := 0
	for i := range all {
		if all[i].RequestID == "req-queued" {
			queuedCount++
			queuedGot = &all[i]
		}
	}
	if queuedCount != 1 || queuedGot == nil {
		t.Fatalf("queued route rows = %d, want 1", queuedCount)
	}
	if queuedGot.ProviderID != "prov-queued" || queuedGot.Outcome != "selected" || queuedGot.HardwareChip != "Apple M4 Max" {
		t.Fatalf("queued route snapshot was not refreshed with serving provider: %+v", queuedGot)
	}

	// Updating a non-existent attempt is best-effort and returns no error.
	if err := s.UpdateInferenceRouteOutcome("req-missing", 99, outcome); err != nil {
		t.Errorf("UpdateInferenceRouteOutcome missing record: %v", err)
	}
}

func TestRejection_Memory(t *testing.T) {
	s := NewMemory(Config{})
	testRejectionStore(t, s)
}

func TestRejection_Postgres(t *testing.T) {
	s := testPostgresStore(t)
	testRejectionStore(t, s)
}

func testRejectionStore(t *testing.T, s Store) {
	t.Helper()

	beforeRecord := time.Now().Add(-time.Minute)

	rec := &RejectionRecord{
		RequestID:               "req-rej-1",
		Endpoint:                "/v1/chat/completions",
		Stage:                   "preflight_capacity",
		ReasonCode:              "machine_busy",
		HTTPStatus:              429,
		ConsumerKeyHash:         "abc123hash",
		KeyID:                   "key_123",
		ClientClass:             "openrouter",
		RequestedModel:          "mlx-community/Qwen3.5-9B-MLX-4bit",
		ResolvedModel:           "qwen3.5-9b",
		Stream:                  true,
		N:                       1,
		EstimatedPromptTokens:   500,
		RequestedMaxTokens:      1024,
		RequiresVision:          true,
		HasImage:                true,
		HasAudio:                false,
		HasTools:                false,
		ToolCount:               0,
		ResponseFormat:          "json_object",
		SelfRouteOnly:           false,
		PreferOwner:             true,
		Params:                  json.RawMessage(`{"temperature":0.7}`),
		RequestBodyBytes:        2048,
		RetryAfterMs:            1500,
		CouldHaveServed:         true,
		CandidateCount:          4,
		CapacityRejections:      3,
		ModelTooLargeRejections: 1,
		VisionRejections:        0,
		WarmProviderExisted:     true,
		BestTTFTMs:              42.5,
		ShortfallMicroUSD:       0,
		LimitKind:               "itpm",
		OverBy:                  120,
	}

	if err := s.RecordRejection(rec); err != nil {
		t.Fatalf("RecordRejection: %v", err)
	}

	// Zero-time since returns all records.
	all := s.RejectionRecordsSince(time.Time{})
	if len(all) != 1 {
		t.Fatalf("RejectionRecordsSince(zero) = %d records, want 1", len(all))
	}
	got := all[0]
	if got.Stage != "preflight_capacity" {
		t.Errorf("stage = %q, want preflight_capacity", got.Stage)
	}
	if got.ReasonCode != "machine_busy" {
		t.Errorf("reason_code = %q, want machine_busy", got.ReasonCode)
	}
	if got.HTTPStatus != 429 {
		t.Errorf("http_status = %d, want 429", got.HTTPStatus)
	}
	if got.RequestedModel != rec.RequestedModel {
		t.Errorf("requested_model = %q, want %q", got.RequestedModel, rec.RequestedModel)
	}
	if !got.CouldHaveServed {
		t.Error("could_have_served = false, want true")
	}
	if got.CandidateCount != 4 {
		t.Errorf("candidate_count = %d, want 4", got.CandidateCount)
	}
	if got.CreatedAt.IsZero() {
		t.Error("created_at should be set")
	}
	if !got.CreatedAt.After(beforeRecord) {
		t.Error("created_at should be after beforeRecord")
	}

	// RecordsSince filters out older records.
	old := s.RejectionRecordsSince(time.Now().Add(time.Hour))
	if len(old) != 0 {
		t.Fatalf("RejectionRecordsSince(future) = %d records, want 0", len(old))
	}

	// A second rejection at a different stage; records are newest-first.
	rec2 := &RejectionRecord{
		RequestID:      "req-rej-2",
		Endpoint:       "/v1/chat/completions",
		Stage:          "model_resolution",
		ReasonCode:     "model_not_found",
		HTTPStatus:     404,
		RequestedModel: "no-such-model",
	}
	if err := s.RecordRejection(rec2); err != nil {
		t.Fatalf("RecordRejection attempt 2: %v", err)
	}

	all = s.RejectionRecordsSince(time.Time{})
	if len(all) != 2 {
		t.Fatalf("expected 2 records, got %d", len(all))
	}
	if all[0].RequestID != "req-rej-2" {
		t.Errorf("first record request_id = %q, want req-rej-2 (newest-first)", all[0].RequestID)
	}
	if all[1].RequestID != "req-rej-1" {
		t.Errorf("second record request_id = %q, want req-rej-1", all[1].RequestID)
	}
}
