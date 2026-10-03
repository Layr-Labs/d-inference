package store

import (
	"testing"
	"time"
)

// TestDeviceCodeFlowBackends runs the device authorization flow on both
// backends. device_auth_test.go covers the memory store's details.
func TestDeviceCodeFlowBackends(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			live := &DeviceCode{
				DeviceCode: uniqueID("dev"),
				UserCode:   uniqueID("USER"),
				Status:     "pending",
				ExpiresAt:  time.Now().Add(15 * time.Minute),
			}
			if err := s.CreateDeviceCode(live); err != nil {
				t.Fatalf("CreateDeviceCode: %v", err)
			}
			clash := &DeviceCode{DeviceCode: uniqueID("dev"), UserCode: live.UserCode, Status: "pending", ExpiresAt: live.ExpiresAt}
			if err := s.CreateDeviceCode(clash); err == nil {
				t.Fatal("duplicate user code accepted")
			}

			if got, err := s.GetDeviceCode(live.DeviceCode); err != nil || got.UserCode != live.UserCode || got.Status != "pending" {
				t.Fatalf("GetDeviceCode = %+v, %v", got, err)
			}
			if got, err := s.GetDeviceCodeByUserCode(live.UserCode); err != nil || got.DeviceCode != live.DeviceCode {
				t.Fatalf("GetDeviceCodeByUserCode = %+v, %v", got, err)
			}
			if _, err := s.GetDeviceCode(uniqueID("dev-missing")); err == nil {
				t.Fatal("unknown device code returned")
			}
			if _, err := s.GetDeviceCodeByUserCode(uniqueID("USER-missing")); err == nil {
				t.Fatal("unknown user code returned")
			}

			account := uniqueID("acct")
			if err := s.ApproveDeviceCode(live.DeviceCode, account); err != nil {
				t.Fatalf("ApproveDeviceCode: %v", err)
			}
			if got, _ := s.GetDeviceCode(live.DeviceCode); got == nil || got.Status != "approved" || got.AccountID != account {
				t.Fatalf("after approval = %+v", got)
			}
			if err := s.ApproveDeviceCode(live.DeviceCode, uniqueID("acct")); err == nil {
				t.Fatal("approved code approved again")
			}

			expired := &DeviceCode{
				DeviceCode: uniqueID("dev-expired"),
				UserCode:   uniqueID("USER"),
				Status:     "pending",
				ExpiresAt:  time.Now().Add(-time.Minute),
			}
			if err := s.CreateDeviceCode(expired); err != nil {
				t.Fatal(err)
			}
			if err := s.ApproveDeviceCode(expired.DeviceCode, account); err == nil {
				t.Fatal("expired code approved")
			}
			if err := s.DeleteExpiredDeviceCodes(); err != nil {
				t.Fatalf("DeleteExpiredDeviceCodes: %v", err)
			}
			if _, err := s.GetDeviceCode(expired.DeviceCode); err == nil {
				t.Fatal("expired code survived cleanup")
			}
			if _, err := s.GetDeviceCode(live.DeviceCode); err != nil {
				t.Fatalf("cleanup removed a live code: %v", err)
			}
		})
	}
}

func TestProviderTokenLifecycleBackends(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			raw := uniqueID("provider-token")
			account := uniqueID("acct")
			if err := s.CreateProviderToken(&ProviderToken{TokenHash: hashKey(raw), AccountID: account, Label: "test-machine", Active: true}); err != nil {
				t.Fatalf("CreateProviderToken: %v", err)
			}
			if err := s.CreateProviderToken(&ProviderToken{TokenHash: hashKey(raw), AccountID: account, Active: true}); err == nil {
				t.Fatal("duplicate provider token accepted")
			}

			got, err := s.GetProviderToken(raw)
			if err != nil || got.AccountID != account || got.Label != "test-machine" || !got.Active {
				t.Fatalf("GetProviderToken = %+v, %v", got, err)
			}
			if _, err := s.GetProviderToken(hashKey(raw)); err == nil {
				t.Fatal("lookup by the stored hash, not the raw token, succeeded")
			}

			if err := s.RevokeProviderToken(raw); err != nil {
				t.Fatalf("RevokeProviderToken: %v", err)
			}
			if _, err := s.GetProviderToken(raw); err == nil {
				t.Fatal("revoked provider token still valid")
			}
			if err := s.RevokeProviderToken(uniqueID("provider-token-missing")); err == nil {
				t.Fatal("unknown provider token revoked")
			}
		})
	}
}
