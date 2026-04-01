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

	if !strings.HasPrefix(key, "dginf-") {
		t.Errorf("key %q does not have dginf- prefix", key)
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
		ID:           "CohereLabs/cohere-transcribe-03-2026",
		S3Name:       "cohere-transcribe-03-2026",
		DisplayName:  "Cohere Transcribe",
		ModelType:    "transcription",
		SizeGB:       4.2,
		Architecture: "2B conformer",
		Description:  "Best-in-class STT",
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

	rawToken := "dginf-provider-token-abc123"
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
