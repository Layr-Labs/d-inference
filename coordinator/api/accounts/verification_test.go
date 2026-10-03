package accounts

import (
	"testing"
	"time"
)

func TestOwnerVerificationRemainsOfflineAndAccountScoped(t *testing.T) {
	s, p, _ := newAuthorizationFixture(t)
	mp := buildMyProvider(nil, p)
	s.attachMyProviderAuthorization(&mp, p, "other-account")
	if mp.Verification.Method() != "none" || mp.Verification.AppAttest.State != "offline" {
		t.Fatal("wrong owner obtained current evidence")
	}
	s.attachMyProviderAuthorization(&mp, p, "account")
	if mp.Verification.AppAttest.ExpiresAt <= time.Now().Unix() {
		t.Fatal("owner lost verified expiry")
	}
}
