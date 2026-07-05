package store

import (
	"testing"
	"time"
)

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
	tokenHash := hashKey(rawToken)

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
