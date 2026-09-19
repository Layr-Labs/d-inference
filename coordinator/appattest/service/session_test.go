package service

import (
	"context"
	"io"
	"log/slog"
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
	s := New(ctx, Config{}, Dependencies{Registry: reg, Store: st, Logger: logger})
	p := newSessionProvider("key", "se")
	if x := s.startAppAttestShadow(context.Background(), p, &protocol.RegisterMessage{AppAttestProtocol: 1}); x != nil {
		t.Fatal("off mode started shadow")
	}
	s.config = Config{Enabled: true, AppID: "TEST.app", Environment: "production"}
	if x := s.startAppAttestShadow(context.Background(), p, &protocol.RegisterMessage{}); x != nil {
		t.Fatal("sent unknown frames to legacy client")
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

func TestAppAttestShadowLateProofCannotWinTimerRace(t *testing.T) {
	p := newSessionProvider("key", "se")
	x := &Session{s: &Service{}, provider: p, expected: "assertion", started: time.Now().Add(-shadowResponseTimeout - time.Second)}
	if got := x.handle(context.Background(), protocol.AppAttestShadowPayload{Result: "ok"}); got != "stop" {
		t.Fatalf("late proof handled: %s", got)
	}
}
