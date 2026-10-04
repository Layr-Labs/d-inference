package service

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestSessionOfferQueuesValidFramesAndCountsRejectedOnes(t *testing.T) {
	x := &Session{in: make(chan protocol.AppAttestShadowPayload, 2)}
	x.Offer(protocol.AppAttestShadowPayload{Action: "ready", Session: "s", Result: "ok"})
	select {
	case got := <-x.in:
		if got.Action != "ready" || got.Session != "s" {
			t.Fatalf("queued %+v", got)
		}
	default:
		t.Fatal("valid frame not queued")
	}
	if x.dropped.Load() != 0 {
		t.Fatal("valid frame counted as dropped")
	}
	x.RejectOversized()
	if x.dropped.Load() != 1 {
		t.Fatal("oversized frame not counted as an evidence gap")
	}
	x.closed.Store(true)
	x.Offer(protocol.AppAttestShadowPayload{Action: "ready"})
	if x.dropped.Load() != 2 || len(x.in) != 0 {
		t.Fatal("frame offered after close was queued or not counted")
	}
}

func TestStatusReportsAuthorizationPath(t *testing.T) {
	s, p, record, state := newAuthorizationFixture(t)
	if got := s.Status(nil); got != nil {
		t.Fatalf("nil provider status %+v", got)
	}
	got := s.Status(p)
	if got == nil || got.Path != "none" || got.Reason != "app_attest_qualification_required" || got.SessionID != p.ID || !got.AppAttestAvailable || got.MachineID != "machine" {
		t.Fatalf("unauthorized status %+v", got)
	}
	if !s.authorizer.apply(p, record, state, time.Now()) {
		t.Fatal("grant")
	}
	got = s.Status(p)
	if got.Path != "app_attest" || got.Reason != "app_attest_verified" || !got.MDMRemovalReady || got.ExpiresAt == 0 || got.MachineID != "machine" {
		t.Fatalf("app attest status %+v", got)
	}
	s.authorizer.forget(p)
	makeLegacyAuthorized(p)
	if got = s.Status(p); got.Path != "legacy" || got.Reason != "legacy_verification_active" || got.MDMRemovalReady {
		t.Fatalf("legacy status %+v", got)
	}
	// A provider that is no longer the registered connection gets a denial.
	stale := newSessionProvider("endpoint", "se")
	if got = s.Status(stale); got.Path != "none" || got.Reason != "connection_replaced" {
		t.Fatalf("replaced connection status %+v", got)
	}
	s.config.ServingEnabled = false
	if s.Status(p) != nil {
		t.Fatal("status reported while serving is off")
	}
}

func TestTrustStatusAndMetricHooksAreOptional(t *testing.T) {
	s := &Service{}
	p := newSessionProvider("endpoint", "se")
	// Nil hooks must be harmless.
	s.sendTrustStatus(p, registry.TrustHardware, "online", "reason")
	s.ddIncr("a", nil)
	s.ddCount("a", 1, nil)
	s.ddGauge("a", 1, nil)
	s.ddHistogram("a", 1, nil)
	s.emit(map[string]any{"event": "x"})

	m := newMetricLog()
	var sent []string
	s = &Service{metrics: m.metrics(), trustStatus: func(got *registry.Provider, level registry.TrustLevel, status, reason string) {
		if got != p || level != registry.TrustHardware {
			t.Fatalf("trust status for %v at %v", got, level)
		}
		sent = append(sent, status+":"+reason)
	}}
	s.sendTrustStatus(p, registry.TrustHardware, "online", "reason")
	s.ddCount("count", 4, nil)
	s.ddGauge("gauge", 2.5, nil)
	s.ddHistogram("hist", 1, nil)
	if len(sent) != 1 || sent[0] != "online:reason" {
		t.Fatalf("trust status %v", sent)
	}
	if c := m.count("count"); len(c) != 1 || c[0] != 4 {
		t.Fatalf("count %v", c)
	}
	if g := m.gauge("gauge"); len(g) != 1 || g[0] != 2.5 {
		t.Fatalf("gauge %v", g)
	}
	if m.hist["hist"] != 1 {
		t.Fatalf("histogram %v", m.hist)
	}
}
