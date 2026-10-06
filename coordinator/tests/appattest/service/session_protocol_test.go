package service_test

import (
	"context"
	"encoding/base64"
	"io"
	"log/slog"
	"slices"
	"testing"

	service "github.com/eigeninference/d-inference/coordinator/appattest/service"

	recovery "github.com/eigeninference/d-inference/coordinator/internal/appattest/recovery"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"

	memorystore "github.com/eigeninference/d-inference/coordinator/store/memory"
)

func TestAppAttestShadowOldProvidersAndOffMode(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	st := memorystore.NewMemory(store.Config{})
	reg := registry.New(logger)
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	var events [][]string
	deps := service.Dependencies{Registry: reg, Store: st, Logger: logger,
		Metrics: service.Metrics{Incr: func(name string, tags []string) {
			if name == "app_attest.shadow.events" {
				events = append(events, tags)
			}
		}}}
	s := service.New(ctx, service.Config{}, deps)
	p := newSessionProvider("key", "se")
	if x := s.StartSession(context.Background(), p, &protocol.RegisterMessage{AppAttestProtocol: 3}, ""); x != nil {
		t.Fatal("off mode started shadow")
	}
	s = service.New(ctx, service.Config{Enabled: true, AppID: "TEST.app", Environment: "production"}, deps)
	if x := s.StartSession(context.Background(), p, &protocol.RegisterMessage{}, ""); x != nil {
		t.Fatal("sent unknown frames to legacy client")
	}
	// Protocol 3 is the only one served: the released 0.9.3 announced
	// protocol 2 and protocol 1 was never released. Both get no frames and
	// are counted as stragglers to upgrade; a provider that announces no
	// protocol is not.
	current := newSessionProvider(base64.StdEncoding.EncodeToString(make([]byte, 32)), "se")
	for _, old := range []int{0, 1, 2} {
		events = nil
		if x := s.StartSession(context.Background(), current, &protocol.RegisterMessage{AppAttestProtocol: old, Version: "0.9.3"}, ""); x != nil {
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
	if got := recovery.ClientResult("provider-controlled secret"); got != "client_error" {
		t.Fatal("raw error escaped allowlist")
	}
}
