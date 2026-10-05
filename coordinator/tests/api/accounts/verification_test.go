package accounts_test

import (
	"testing"
	"time"

	fleetview "github.com/eigeninference/d-inference/coordinator/internal/api/accounts/fleetview"
)

func TestOwnerVerificationRemainsOfflineAndAccountScoped(t *testing.T) {
	s, p, _ := newAuthorizationFixture(t)
	mp := fleetview.Build(nil, p)
	fleetview.AttachAuthorization(s.registry, &mp, p, "other-account")
	if mp.Verification.Method() != "none" || mp.Verification.AppAttest.State != "offline" {
		t.Fatal("wrong owner obtained current evidence")
	}
	fleetview.AttachAuthorization(s.registry, &mp, p, "account")
	if mp.Verification.AppAttest.ExpiresAt <= time.Now().Unix() {
		t.Fatal("owner lost verified expiry")
	}
}
