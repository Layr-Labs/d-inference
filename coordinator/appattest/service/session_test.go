package service

import (
	"context"
	"encoding/base64"
	"io"
	"log/slog"
	"slices"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestAppAttestShadowOldProvidersAndOffMode(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	st := store.NewMemory(store.Config{})
	reg := registry.New(logger)
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	var events [][]string
	s := New(ctx, Config{}, Dependencies{Registry: reg, Store: st, Logger: logger,
		Metrics: Metrics{Incr: func(name string, tags []string) {
			if name == "app_attest.shadow.events" {
				events = append(events, tags)
			}
		}}})
	p := newSessionProvider("key", "se")
	if x := s.startAppAttestShadow(context.Background(), p, &protocol.RegisterMessage{AppAttestProtocol: 3}); x != nil {
		t.Fatal("off mode started shadow")
	}
	s.config = Config{Enabled: true, AppID: "TEST.app", Environment: "production"}
	if x := s.startAppAttestShadow(context.Background(), p, &protocol.RegisterMessage{}); x != nil {
		t.Fatal("sent unknown frames to legacy client")
	}
	// Protocol 3 is the only one served: the released 0.9.3 announced
	// protocol 2 and protocol 1 was never released. Both get no frames and
	// are counted as stragglers to upgrade; a provider that announces no
	// protocol is not.
	current := newSessionProvider(base64.StdEncoding.EncodeToString(make([]byte, 32)), "se")
	for _, old := range []int{0, 1, 2} {
		events = nil
		if x := s.startAppAttestShadow(context.Background(), current, &protocol.RegisterMessage{AppAttestProtocol: old, Version: "0.9.3"}); x != nil {
			t.Fatalf("protocol %d started shadow", old)
		}
		if old == 0 {
			if len(events) != 0 {
				t.Fatalf("a provider without App Attest was counted: %v", events)
			}
			continue
		}
		if len(events) != 1 || !slices.Contains(events[0], "outcome:provider_upgrade_required") || !slices.Contains(events[0], "stage:rollout") {
			t.Fatalf("protocol %d straggler not counted: %v", old, events)
		}
	}
	if got := shadowClientResult("provider-controlled secret"); got != "client_error" {
		t.Fatal("raw error escaped allowlist")
	}
}

func TestAppAttestShadowInboxBounded(t *testing.T) {
	x := &Session{in: make(chan protocol.AppAttestShadowPayload, 2)}
	for i := 0; i < 10000; i++ {
		x.offer(protocol.AppAttestShadowPayload{Action: "assertion"})
	}
	if len(x.in) != 2 {
		t.Fatal("unbounded inbox")
	}
}

func TestAppAttestShadowInboxRejectsUnboundedClientDiagnostics(t *testing.T) {
	x := &Session{in: make(chan protocol.AppAttestShadowPayload, 2)}
	x.offer(protocol.AppAttestShadowPayload{Action: "ready", Result: "unsupported", AvailabilityReason: "is_supported_false"})
	x.offer(protocol.AppAttestShadowPayload{Action: "ready", Result: "unsupported", AvailabilityReason: "private path or entitlement"})
	x.offer(protocol.AppAttestShadowPayload{Action: "assertion", Result: "apple_error", AppleErrorSource: "private native description"})
	if len(x.in) != 1 || x.dropped.Load() != 2 {
		t.Fatalf("unbounded diagnostics reached inbox: queued=%d dropped=%d", len(x.in), x.dropped.Load())
	}
}

func TestAppAttestShadowInboxStripsInvalidRuntimeDiagnosticsWithoutDropping(t *testing.T) {
	x := &Session{in: make(chan protocol.AppAttestShadowPayload, 2)}
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

func TestAppAttestShadowLateProofCannotWinTimerRace(t *testing.T) {
	p := newSessionProvider("key", "se")
	x := &Session{s: &Service{}, provider: p, expected: "assertion", started: time.Now().Add(-shadowResponseTimeout - time.Second)}
	if got := x.handle(context.Background(), protocol.AppAttestShadowPayload{Result: "ok"}); got != "stop" {
		t.Fatalf("late proof handled: %s", got)
	}
}
