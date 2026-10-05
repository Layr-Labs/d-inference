package authorization_test

import (
	"context"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/appattest/service"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestStatusReportsAuthorizationPath(t *testing.T) {
	f, p, record, state := newAuthorizationFixture(t, true)
	if got := f.service.Status(nil); got != nil {
		t.Fatalf("nil provider status %+v", got)
	}
	got := f.service.Status(p)
	if got == nil || got.Path != "none" || got.Reason != "app_attest_qualification_required" || got.SessionID != p.ID || !got.AppAttestAvailable || got.MachineID != "machine" {
		t.Fatalf("unauthorized status %+v", got)
	}
	if !f.controller.Apply(p, record, state, time.Now()) {
		t.Fatal("grant")
	}
	got = f.service.Status(p)
	if got.Path != "app_attest" || got.Reason != "app_attest_verified" || !got.MDMRemovalReady || got.ExpiresAt == 0 || got.MachineID != "machine" {
		t.Fatalf("app attest status %+v", got)
	}
	f.controller.Forget(p)
	makeLegacyAuthorized(p)
	if got = f.service.Status(p); got.Path != "legacy" || got.Reason != "legacy_verification_active" || got.MDMRemovalReady {
		t.Fatalf("legacy status %+v", got)
	}
	// A provider that is no longer the registered connection gets a denial.
	stale := &registry.Provider{ID: p.ID}
	if got = f.service.Status(stale); got.Path != "none" || got.Reason != "connection_replaced" {
		t.Fatalf("replaced connection status %+v", got)
	}
	off := service.New(context.Background(), service.Config{Environment: "production"}, service.Dependencies{Store: f.store, Registry: f.registry})
	if off.Status(p) != nil {
		t.Fatal("status reported while serving is off")
	}
}
