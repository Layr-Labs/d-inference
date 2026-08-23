package store

import (
	"testing"
	"time"
)

func TestDeviceAuthStoreContract(t *testing.T) {
	for name, st := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			testDeviceAuthStoreContract(t, st)
		})
	}
}

func testDeviceAuthStoreContract(t *testing.T, st Store) {
	t.Helper()

	deviceCode := uniqueID("device")
	userCode := uniqueID("user-code")
	accountID := uniqueID("account")
	dc := &DeviceCode{
		DeviceCode: deviceCode,
		UserCode:   userCode,
		Status:     "pending",
		ExpiresAt:  time.Now().UTC().Add(15 * time.Minute),
	}
	if err := st.CreateDeviceCode(dc); err != nil {
		t.Fatalf("create device code: %v", err)
	}
	if err := st.CreateDeviceCode(&DeviceCode{
		DeviceCode: uniqueID("duplicate-device"),
		UserCode:   userCode,
		Status:     "pending",
		ExpiresAt:  dc.ExpiresAt,
	}); err == nil {
		t.Fatal("duplicate user code succeeded")
	}

	got, err := st.GetDeviceCode(deviceCode)
	if err != nil {
		t.Fatalf("get by device code: %v", err)
	}
	if got.UserCode != userCode || got.Status != "pending" {
		t.Fatalf("device round-trip mismatch: %+v", got)
	}
	byUserCode, err := st.GetDeviceCodeByUserCode(userCode)
	if err != nil {
		t.Fatalf("get by user code: %v", err)
	}
	if byUserCode.DeviceCode != deviceCode {
		t.Fatalf("device code = %q, want %q", byUserCode.DeviceCode, deviceCode)
	}
	if err := st.ApproveDeviceCode(deviceCode, accountID); err != nil {
		t.Fatalf("approve: %v", err)
	}
	approved, err := st.GetDeviceCode(deviceCode)
	if err != nil {
		t.Fatalf("get approved: %v", err)
	}
	if approved.Status != "approved" || approved.AccountID != accountID {
		t.Fatalf("approved mismatch: %+v", approved)
	}
	if err := st.ApproveDeviceCode(deviceCode, uniqueID("other-account")); err == nil {
		t.Fatal("double approve succeeded")
	}

	expiredCode := uniqueID("expired-device")
	if err := st.CreateDeviceCode(&DeviceCode{
		DeviceCode: expiredCode,
		UserCode:   uniqueID("expired-user-code"),
		Status:     "pending",
		ExpiresAt:  time.Now().UTC().Add(-time.Minute),
	}); err != nil {
		t.Fatalf("create expired code: %v", err)
	}
	if err := st.ApproveDeviceCode(expiredCode, accountID); err == nil {
		t.Fatal("approve expired code succeeded")
	}
	if err := st.DeleteExpiredDeviceCodes(); err != nil {
		t.Fatalf("delete expired codes: %v", err)
	}
	if _, err := st.GetDeviceCode(expiredCode); err == nil {
		t.Fatal("expired code remained after cleanup")
	}
	if _, err := st.GetDeviceCode(deviceCode); err != nil {
		t.Fatalf("cleanup deleted unexpired code: %v", err)
	}

	rawToken := uniqueID("provider-token")
	token := &ProviderToken{
		TokenHash: hashKey(rawToken),
		AccountID: accountID,
		Label:     "my-macbook",
		Active:    true,
	}
	if err := st.CreateProviderToken(token); err != nil {
		t.Fatalf("create provider token: %v", err)
	}
	gotToken, err := st.GetProviderToken(rawToken)
	if err != nil {
		t.Fatalf("get provider token: %v", err)
	}
	if gotToken.AccountID != accountID || gotToken.Label != token.Label {
		t.Fatalf("provider token mismatch: %+v", gotToken)
	}
	if err := st.RevokeProviderToken(rawToken); err != nil {
		t.Fatalf("revoke provider token: %v", err)
	}
	if _, err := st.GetProviderToken(rawToken); err == nil {
		t.Fatal("revoked provider token authenticated")
	}
}
