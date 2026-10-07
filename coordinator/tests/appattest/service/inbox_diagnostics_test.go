package service_test

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestAppAttestShadowInboxStripsInvalidDeepDiagnosticsWithoutDropping(t *testing.T) {
	x := &inboxFixture{in: make(chan protocol.AppAttestShadowPayload, 3)}
	diagnosticBool := func(v bool) *bool { return &v }
	bad := -1
	x.offer(protocol.AppAttestShadowPayload{Action: "ready", Result: "ok", PreviousExit: "/Users/private", StartReason: "reboot", ProcessStartedAt: 1,
		Preflight: &protocol.AppAttestPreflight{BundlePathClass: "/Applications"}, KeyHistory: &protocol.AppAttestKeyHistory{GenerationsLast24h: &bad}})
	x.offer(protocol.AppAttestShadowPayload{Action: "assertion", Result: "apple_error", NativeErrorChain: make([]protocol.AppAttestNativeError, 5)})
	x.offer(protocol.AppAttestShadowPayload{Action: "assertion", Result: "ok", SIPEnabled: diagnosticBool(true), NativeErrorChain: []protocol.AppAttestNativeError{{Domain: "aks"}}})
	if len(x.in) != 3 || x.dropped.Load() != 0 {
		t.Fatalf("deep diagnostics dropped a frame: queued=%d dropped=%d", len(x.in), x.dropped.Load())
	}
	ready, oversized, misplaced := <-x.in, <-x.in, <-x.in
	if ready.PreviousExit != "" || ready.StartReason != "" || ready.ProcessStartedAt != 0 || ready.Preflight != nil || ready.KeyHistory != nil {
		t.Fatalf("invalid ready diagnostics admitted: %+v", ready)
	}
	if oversized.NativeErrorChain != nil || misplaced.NativeErrorChain != nil || misplaced.SIPEnabled != nil {
		t.Fatalf("invalid or misplaced diagnostics admitted: %+v %+v", oversized, misplaced)
	}
}
