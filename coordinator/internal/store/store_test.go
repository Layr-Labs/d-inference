package store

import (
	"strings"
	"testing"
	"time"
)

func TestNewWithAdminKey(t *testing.T) {
	s := NewMemory("test-admin-key")
	if !s.ValidateKey("test-admin-key") {
		t.Error("admin key should be valid")
	}
	if s.KeyCount() != 1 {
		t.Errorf("key count = %d, want 1", s.KeyCount())
	}
}

func TestNewWithoutAdminKey(t *testing.T) {
	s := NewMemory("")
	if s.KeyCount() != 0 {
		t.Errorf("key count = %d, want 0", s.KeyCount())
	}
}

func TestCreateKey(t *testing.T) {
	s := NewMemory("")

	key, err := s.CreateKey()
	if err != nil {
		t.Fatalf("CreateKey: %v", err)
	}

	if !strings.HasPrefix(key, "eigeninference-") {
		t.Errorf("key %q does not have eigeninference- prefix", key)
	}

	if !s.ValidateKey(key) {
		t.Error("created key should be valid")
	}

	if s.KeyCount() != 1 {
		t.Errorf("key count = %d, want 1", s.KeyCount())
	}
}

func TestCreateMultipleKeys(t *testing.T) {
	s := NewMemory("")

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
	s := NewMemory("admin-key")
	if s.ValidateKey("wrong-key") {
		t.Error("wrong key should not be valid")
	}
	if s.ValidateKey("") {
		t.Error("empty key should not be valid")
	}
}

func TestRevokeKey(t *testing.T) {
	s := NewMemory("admin-key")

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
	s := NewMemory("")
	if s.RevokeKey("nonexistent") {
		t.Error("RevokeKey should return false for nonexistent key")
	}
}

func TestRecordUsage(t *testing.T) {
	s := NewMemory("")

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

func TestUsageRecordsReturnsCopy(t *testing.T) {
	s := NewMemory("")
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
	s := NewMemory("")
	records := s.UsageRecords()
	if len(records) != 0 {
		t.Errorf("usage records = %d, want 0", len(records))
	}
}

func TestRecordPayment(t *testing.T) {
	s := NewMemory("")

	err := s.RecordPayment("0xabc123", "0xconsumer", "0xprovider", "0.05", "qwen3.5-9b", 50, 100, "test payment")
	if err != nil {
		t.Fatalf("RecordPayment: %v", err)
	}
}

func TestRecordPaymentDuplicateTxHash(t *testing.T) {
	s := NewMemory("")

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
	var _ Store = NewMemory("")
}

func TestSupportedModels(t *testing.T) {
	s := NewMemory("")

	// Initially empty
	models := s.ListSupportedModels()
	if len(models) != 0 {
		t.Fatalf("expected 0 models, got %d", len(models))
	}

	// Add models
	m1 := &SupportedModel{
		ID:           "mlx-community/Qwen2.5-0.5B-MLX-4bit",
		S3Name:       "Qwen2.5-0.5B-MLX-4bit",
		DisplayName:  "Qwen2.5 0.5B",
		ModelType:    "text",
		SizeGB:       0.5,
		Architecture: "0.5B dense",
		Description:  "Lightweight chat model",
		MinRAMGB:     8,
		Active:       true,
	}
	m2 := &SupportedModel{
		ID:           "mlx-community/Qwen3.5-9B-MLX-4bit",
		S3Name:       "Qwen3.5-9B-MLX-4bit",
		DisplayName:  "Qwen3.5 9B",
		ModelType:    "text",
		SizeGB:       6.0,
		Architecture: "9B dense",
		Description:  "Balanced",
		MinRAMGB:     16,
		Active:       true,
	}

	if err := s.SetSupportedModel(m1); err != nil {
		t.Fatalf("SetSupportedModel m1: %v", err)
	}
	if err := s.SetSupportedModel(m2); err != nil {
		t.Fatalf("SetSupportedModel m2: %v", err)
	}

	models = s.ListSupportedModels()
	if len(models) != 2 {
		t.Fatalf("expected 2 models, got %d", len(models))
	}
	// Should be sorted by MinRAMGB ascending
	if models[0].MinRAMGB > models[1].MinRAMGB {
		t.Error("models should be sorted by MinRAMGB ascending")
	}
	if models[0].ID != m1.ID {
		t.Errorf("first model = %q, want %q", models[0].ID, m1.ID)
	}

	// Update existing model
	m1Updated := &SupportedModel{
		ID:           m1.ID,
		S3Name:       m1.S3Name,
		DisplayName:  "Qwen2.5 0.5B (updated)",
		SizeGB:       0.5,
		Architecture: m1.Architecture,
		Description:  "Updated description",
		MinRAMGB:     8,
		Active:       false,
	}
	if err := s.SetSupportedModel(m1Updated); err != nil {
		t.Fatalf("SetSupportedModel update: %v", err)
	}
	models = s.ListSupportedModels()
	if len(models) != 2 {
		t.Fatalf("expected 2 models after update, got %d", len(models))
	}
	// Find the updated model
	for _, m := range models {
		if m.ID == m1.ID {
			if m.DisplayName != "Qwen2.5 0.5B (updated)" {
				t.Errorf("display_name = %q, want updated", m.DisplayName)
			}
			if m.Active {
				t.Error("model should be inactive after update")
			}
		}
	}

	// Delete model
	if err := s.DeleteSupportedModel(m1.ID); err != nil {
		t.Fatalf("DeleteSupportedModel: %v", err)
	}
	models = s.ListSupportedModels()
	if len(models) != 1 {
		t.Fatalf("expected 1 model after delete, got %d", len(models))
	}
	if models[0].ID != m2.ID {
		t.Errorf("remaining model = %q, want %q", models[0].ID, m2.ID)
	}

	// Delete nonexistent model
	if err := s.DeleteSupportedModel("nonexistent"); err == nil {
		t.Error("expected error deleting nonexistent model")
	}
}

func TestDeviceCodeFlow(t *testing.T) {
	s := NewMemory("")

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
	s := NewMemory("")

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
	s := NewMemory("")

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
	s := NewMemory("")

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
	s := NewMemory("")

	// Record earnings for two different nodes.
	for i := 0; i < 5; i++ {
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
	s := NewMemory("")

	// Record in chronological order.
	for i := 0; i < 5; i++ {
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
	for i := 0; i < len(earnings)-1; i++ {
		if earnings[i].ID < earnings[i+1].ID {
			t.Errorf("earnings not in newest-first order: ID %d before ID %d", earnings[i].ID, earnings[i+1].ID)
		}
	}
}

func TestProviderEarnings_LimitRespected(t *testing.T) {
	s := NewMemory("")

	// Record 10 earnings.
	for i := 0; i < 10; i++ {
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
	s := NewMemory("")

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
	s := NewMemory("")

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
	s := NewMemory("")

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
	s := NewMemory("")

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
	s := NewMemory("")

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
		Version:    "0.2.1",
		Platform:   "macos-arm64",
		BinaryHash: "ccc333",
		BundleHash: "ddd444",
		URL:        "https://r2.example.com/releases/v0.2.1/bundle.tar.gz",
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
	s := NewMemory("")

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
