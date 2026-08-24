package store

import (
	"errors"
	"fmt"
	"sync"
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

func exerciseDeviceGrantConcurrency(t *testing.T, s Store) {
	t.Helper()

	deviceCode := uniqueID("device")
	userCode := uniqueID("user")
	if err := s.CreateDeviceCode(&DeviceCode{
		DeviceCode: deviceCode,
		UserCode:   userCode,
		Status:     "pending",
		ExpiresAt:  time.Now().Add(15 * time.Minute),
	}); err != nil {
		t.Fatalf("CreateDeviceCode: %v", err)
	}
	if err := s.ApproveDeviceCode(deviceCode, "account-concurrent"); err != nil {
		t.Fatalf("ApproveDeviceCode: %v", err)
	}

	const polls = 16
	rawTokens := make([]string, polls)
	results := make([]*ProviderToken, polls)
	errs := make([]error, polls)
	start := make(chan struct{})
	var wg sync.WaitGroup
	for i := range polls {
		rawTokens[i] = fmt.Sprintf("concurrent-provider-token-%d-%s", i, deviceCode)
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			<-start
			results[i], errs[i] = s.ConsumeDeviceGrant(deviceCode, hashKey(rawTokens[i]))
		}(i)
	}
	close(start)
	wg.Wait()

	successes := 0
	validTokens := 0
	for i := range polls {
		switch {
		case errs[i] == nil:
			successes++
			if results[i] == nil || results[i].AccountID != "account-concurrent" {
				t.Errorf("successful exchange result = %+v", results[i])
			}
		case !errors.Is(errs[i], ErrDeviceGrantConsumed):
			t.Errorf("exchange %d error = %v, want ErrDeviceGrantConsumed", i, errs[i])
		}
		if token, err := s.GetProviderToken(rawTokens[i]); err == nil {
			validTokens++
			if token.AccountID != "account-concurrent" {
				t.Errorf("issued token account = %q", token.AccountID)
			}
		}
	}
	if successes != 1 {
		t.Fatalf("successful exchanges = %d, want 1", successes)
	}
	if validTokens != 1 {
		t.Fatalf("valid provider tokens = %d, want 1", validTokens)
	}

	dc, err := s.GetDeviceCode(deviceCode)
	if err != nil {
		t.Fatalf("GetDeviceCode: %v", err)
	}
	if dc.Status != "consumed" {
		t.Fatalf("device code status = %q, want consumed", dc.Status)
	}
	if _, err := s.ConsumeDeviceGrant(deviceCode, hashKey("replay-token")); !errors.Is(err, ErrDeviceGrantConsumed) {
		t.Fatalf("replay error = %v, want ErrDeviceGrantConsumed", err)
	}
}

func TestMemoryConsumeDeviceGrantConcurrentSingleIssue(t *testing.T) {
	exerciseDeviceGrantConcurrency(t, NewMemory(Config{}))
}

func TestPostgresConsumeDeviceGrantConcurrentSingleIssue(t *testing.T) {
	exerciseDeviceGrantConcurrency(t, testPostgresStore(t))
}

func TestConsumeDeviceGrantPreservesGrantWhenTokenInsertFails(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			deviceCode := uniqueID("device-rollback")
			userCode := uniqueID("user-rollback")
			const duplicateRawToken = "already-issued-provider-token"
			duplicateHash := hashKey(duplicateRawToken)

			if err := s.CreateProviderToken(&ProviderToken{
				TokenHash: duplicateHash,
				AccountID: "existing-account",
				Active:    true,
			}); err != nil {
				t.Fatalf("CreateProviderToken: %v", err)
			}
			if err := s.CreateDeviceCode(&DeviceCode{
				DeviceCode: deviceCode,
				UserCode:   userCode,
				Status:     "pending",
				ExpiresAt:  time.Now().Add(15 * time.Minute),
			}); err != nil {
				t.Fatalf("CreateDeviceCode: %v", err)
			}
			if err := s.ApproveDeviceCode(deviceCode, "account-retry"); err != nil {
				t.Fatalf("ApproveDeviceCode: %v", err)
			}

			if _, err := s.ConsumeDeviceGrant(deviceCode, duplicateHash); err == nil {
				t.Fatal("expected duplicate token insert to fail")
			}
			dc, err := s.GetDeviceCode(deviceCode)
			if err != nil {
				t.Fatalf("GetDeviceCode: %v", err)
			}
			if dc.Status != "approved" {
				t.Fatalf("status after failed issuance = %q, want approved", dc.Status)
			}

			freshRawToken := "fresh-" + deviceCode
			if _, err := s.ConsumeDeviceGrant(deviceCode, hashKey(freshRawToken)); err != nil {
				t.Fatalf("retry exchange: %v", err)
			}
			if _, err := s.GetProviderToken(freshRawToken); err != nil {
				t.Fatalf("fresh token was not issued: %v", err)
			}
		})
	}
}

func TestConsumeDeviceGrantStateErrors(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			pendingCode := uniqueID("device-pending")
			if err := s.CreateDeviceCode(&DeviceCode{
				DeviceCode: pendingCode,
				UserCode:   uniqueID("user-pending"),
				Status:     "pending",
				ExpiresAt:  time.Now().Add(time.Minute),
			}); err != nil {
				t.Fatal(err)
			}
			if _, err := s.ConsumeDeviceGrant(pendingCode, hashKey("pending-token")); !errors.Is(err, ErrDeviceAuthorizationPending) {
				t.Fatalf("pending error = %v, want ErrDeviceAuthorizationPending", err)
			}

			expiredCode := uniqueID("device-expired")
			if err := s.CreateDeviceCode(&DeviceCode{
				DeviceCode: expiredCode,
				UserCode:   uniqueID("user-expired"),
				Status:     "approved",
				AccountID:  "account-expired",
				ExpiresAt:  time.Now().Add(-time.Minute),
			}); err != nil {
				t.Fatal(err)
			}
			if _, err := s.ConsumeDeviceGrant(expiredCode, hashKey("expired-token")); !errors.Is(err, ErrDeviceCodeExpired) {
				t.Fatalf("expired error = %v, want ErrDeviceCodeExpired", err)
			}

			if _, err := s.ConsumeDeviceGrant("missing-device-code", hashKey("missing-token")); !errors.Is(err, ErrNotFound) {
				t.Fatalf("missing error = %v, want ErrNotFound", err)
			}
		})
	}
}
