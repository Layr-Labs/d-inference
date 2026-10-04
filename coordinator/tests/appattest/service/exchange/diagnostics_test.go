package exchange_test

import (
	"context"
	"io"
	"log/slog"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/appattest/exchange"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func diagnosticBool(v bool) *bool { return &v }

func TestDeepDiagnosticsNeverAuthorize(t *testing.T) {
	r := registry.New(slog.New(slog.NewTextHandler(io.Discard, nil)))
	p := r.Register("connection", nil, &protocol.RegisterMessage{})
	t.Cleanup(func() { r.Disconnect(p.ID) })
	deps := exchange.Dependencies{Commit: func(context.Context, store.AppAttestDecision) bool {
		t.Fatal("diagnostics reached cryptographic acceptance")
		return false
	}}
	x := exchange.Challenge{Expected: "ready"}
	ready := protocol.AppAttestShadowPayload{Action: "ready", Result: "unsupported", AvailabilityReason: "is_supported_false",
		ProcessStartedAt: time.Now().Unix(), PreviousExit: "clean", StartReason: "launchd", ConsoleUserActive: diagnosticBool(true),
		SIPEnabled: diagnosticBool(true), AuthenticatedRoot: diagnosticBool(true),
		Preflight:  &protocol.AppAttestPreflight{OptInEntitlement: diagnosticBool(true), EnvironmentEntitlement: "production", ProfilePresent: diagnosticBool(true), ProfileExpired: diagnosticBool(false), BundlePathClass: "applications"},
		KeyHistory: &protocol.AppAttestKeyHistory{CreatedBootMatches: diagnosticBool(true), CreatedAppVersion: "0.9.10"}}
	if next := exchange.Verify(context.Background(), deps, x, ready).Next; next != "stop" {
		t.Fatalf("unsupported ready continued: %s", next)
	}
	x.Expected = "assertion"
	exchange.Verify(context.Background(), deps, x, protocol.AppAttestShadowPayload{Action: "assertion", Result: "apple_error",
		NativeErrorChain: []protocol.AppAttestNativeError{{Domain: "devicecheck", Code: 0}}})
	if _, ok := r.ProviderServingAuthorization(p); ok {
		t.Fatal("deep diagnostics authorized a provider")
	}
}
