package api

import (
	"log/slog"
	"os"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// newBreakerExemptionHarness builds a server with one registered provider that
// carries a stable identity (AccountID), so all three provider-fault breakers
// AND the stable-identity ejection breaker are armed for the test.
func newBreakerExemptionHarness(t *testing.T, name string) (*Server, *registry.Registry, *registry.Provider, *registry.PendingRequest) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	provider := reg.Register("provider-"+name, nil, &protocol.RegisterMessage{
		Type:     protocol.TypeRegister,
		Hardware: protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:   []protocol.ModelInfo{{ID: "test-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:  "mlx-swift",
	})
	provider.Mu().Lock()
	provider.AccountID = "acct-" + name
	provider.Mu().Unlock()
	provider.RebindStableFaultKey()
	pr := &registry.PendingRequest{
		RequestID: "req-" + name,
		Model:     "test-model",
	}
	return srv, reg, provider, pr
}

// assertBreakerStates asserts the open/closed state of the three
// provider-fault breakers the dispatch funnel feeds, one assert per breaker so
// a regression names the exact breaker that tripped.
func assertBreakerStates(t *testing.T, reg *registry.Registry, provider *registry.Provider, pr *registry.PendingRequest, wantOpen bool) {
	t.Helper()
	if got := reg.InferenceErrorCooldownActive(provider.ID, pr.Model, pr.Traits.CooldownShape()); got != wantOpen {
		t.Errorf("inference-error pair cooldown active = %v, want %v", got, wantOpen)
	}
	if got := reg.ProviderBreakerOpen(provider.ID); got != wantOpen {
		t.Errorf("node-health breaker open = %v, want %v", got, wantOpen)
	}
	sid := reg.GetProviderStableIdentity(provider.ID)
	if sid == "" {
		t.Fatal("test provider must carry a stable identity (AccountID) so the ejection breaker is armed")
	}
	if got := reg.HealthEjectionOpen(sid); got != wantOpen {
		t.Errorf("stable-identity ejection open = %v, want %v", got, wantOpen)
	}
}

// breakerStrikeRounds comfortably exceeds every trip threshold involved:
// inference-error cooldown (2 strikes in window), node-health breaker
// (5 consecutive faults), stable-identity ejection (8 consecutive faults).
const breakerStrikeRounds = 10
