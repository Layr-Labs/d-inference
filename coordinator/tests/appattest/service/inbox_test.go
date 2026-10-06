package service_test

import (
	"sync/atomic"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/appattest/input"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

type inboxFixture struct {
	admission input.Admission
	in        chan protocol.AppAttestShadowPayload
	dropped   atomic.Uint64
}

func (x *inboxFixture) offer(p protocol.AppAttestShadowPayload) {
	x.admission.Offer(p, x.in, func() { x.dropped.Add(1) })
}

func TestAppAttestShadowInboxBounded(t *testing.T) {
	x := &inboxFixture{in: make(chan protocol.AppAttestShadowPayload, 2)}
	for i := 0; i < 10000; i++ {
		x.offer(protocol.AppAttestShadowPayload{Action: "assertion"})
	}
	if len(x.in) != 2 {
		t.Fatal("unbounded inbox")
	}
}

func TestAppAttestShadowInboxRejectsUnboundedClientDiagnostics(t *testing.T) {
	x := &inboxFixture{in: make(chan protocol.AppAttestShadowPayload, 2)}
	x.offer(protocol.AppAttestShadowPayload{Action: "ready", Result: "unsupported", AvailabilityReason: "is_supported_false"})
	x.offer(protocol.AppAttestShadowPayload{Action: "ready", Result: "unsupported", AvailabilityReason: "private path or entitlement"})
	x.offer(protocol.AppAttestShadowPayload{Action: "assertion", Result: "apple_error", AppleErrorSource: "private native description"})
	if len(x.in) != 1 || x.dropped.Load() != 2 {
		t.Fatalf("unbounded diagnostics reached inbox: queued=%d dropped=%d", len(x.in), x.dropped.Load())
	}
}

func TestAppAttestShadowInboxStripsInvalidRuntimeDiagnosticsWithoutDropping(t *testing.T) {
	x := &inboxFixture{in: make(chan protocol.AppAttestShadowPayload, 2)}
	x.offer(protocol.AppAttestShadowPayload{Action: "ready", Result: "busy", LaunchSession: "private label", BootTime: -1, OperationStalledSeconds: 90000})
	x.offer(protocol.AppAttestShadowPayload{Action: "ready", Result: "busy", LaunchSession: "background", BootTime: 1_700_000_000, OperationStalledSeconds: 42})
	if len(x.in) != 2 || x.dropped.Load() != 0 {
		t.Fatalf("runtime diagnostics dropped a frame: queued=%d dropped=%d", len(x.in), x.dropped.Load())
	}
	stripped, kept := <-x.in, <-x.in
	if stripped.LaunchSession != "" || stripped.BootTime != 0 || stripped.OperationStalledSeconds != 0 {
		t.Fatalf("invalid values admitted: %+v", stripped)
	}
	if kept.LaunchSession != "background" || kept.BootTime != 1_700_000_000 || kept.OperationStalledSeconds != 42 {
		t.Fatalf("valid values lost: %+v", kept)
	}
}
