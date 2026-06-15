package api

import (
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// registerOnlineProviderWithHardware registers a live provider with the given
// hardware and promotes it to attested hardware trust so it renders as online
// in handleStats.
func registerOnlineProviderWithHardware(t *testing.T, reg *registry.Registry, id string, hw protocol.Hardware) {
	t.Helper()
	p := reg.Register(id, nil, &protocol.RegisterMessage{
		Hardware: hw,
		Models:   []protocol.ModelInfo{{ID: "gemma-4-26b"}},
	})
	p.Mu().Lock()
	p.TrustLevel = registry.TrustHardware
	p.Attested = true
	p.Mu().Unlock()
}

// TestStatsActiveNetworkPower verifies that /v1/stats reports active_power_watts
// as the sum of EstimateMachineWatts over the online (non-private) providers.
func TestStatsActiveNetworkPower(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	reg := registry.New(logger)
	st := store.NewMemory(store.Config{})
	srv := NewServer(reg, st, ServerConfig{}, logger)

	m1Max := protocol.Hardware{ChipName: "Apple M1 Max", ChipFamily: "M1", ChipTier: "Max", GPUCores: 32, MemoryGB: 64}
	m4Pro := protocol.Hardware{ChipName: "Apple M4 Pro", ChipFamily: "M4", ChipTier: "Pro", GPUCores: 20, MemoryGB: 48}

	registerOnlineProviderWithHardware(t, reg, "online-m1max", m1Max)
	registerOnlineProviderWithHardware(t, reg, "online-m4pro", m4Pro)
	wantWatts := registry.EstimateMachineWatts(m1Max.ChipFamily, m1Max.ChipTier, m1Max.GPUCores) +
		registry.EstimateMachineWatts(m4Pro.ChipFamily, m4Pro.ChipTier, m4Pro.GPUCores)

	rr := httptest.NewRecorder()
	srv.handleStats(rr, httptest.NewRequest(http.MethodGet, "/v1/stats", nil))
	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", rr.Code, rr.Body.String())
	}

	var body struct {
		ActiveProviders  int     `json:"active_providers"`
		ActivePowerWatts float64 `json:"active_power_watts"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}

	if body.ActiveProviders != 2 {
		t.Fatalf("active_providers = %d, want 2", body.ActiveProviders)
	}
	if body.ActivePowerWatts != wantWatts {
		t.Fatalf("active_power_watts = %v, want %v", body.ActivePowerWatts, wantWatts)
	}
}

// TestStatsActivePowerExcludesPrivate verifies private-only providers are left
// out of active_power_watts (they are not part of the public fleet).
func TestStatsActivePowerExcludesPrivate(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	reg := registry.New(logger)
	st := store.NewMemory(store.Config{})
	srv := NewServer(reg, st, ServerConfig{}, logger)

	m4Pro := protocol.Hardware{ChipName: "Apple M4 Pro", ChipFamily: "M4", ChipTier: "Pro", GPUCores: 20, MemoryGB: 48}

	registerOnlineProviderWithHardware(t, reg, "pub-1", m4Pro)
	priv := reg.Register("priv-1", nil, &protocol.RegisterMessage{
		Hardware: m4Pro,
		Models:   []protocol.ModelInfo{{ID: "gemma-4-26b"}},
	})
	priv.Mu().Lock()
	priv.TrustLevel = registry.TrustHardware
	priv.Attested = true
	priv.PrivateOnly = true
	priv.Mu().Unlock()

	rr := httptest.NewRecorder()
	srv.handleStats(rr, httptest.NewRequest(http.MethodGet, "/v1/stats", nil))
	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", rr.Code, rr.Body.String())
	}

	var body struct {
		ActiveProviders  int     `json:"active_providers"`
		ActivePowerWatts float64 `json:"active_power_watts"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}

	oneBox := registry.EstimateMachineWatts(m4Pro.ChipFamily, m4Pro.ChipTier, m4Pro.GPUCores)
	if body.ActiveProviders != 1 {
		t.Fatalf("active_providers = %d, want 1 (private excluded)", body.ActiveProviders)
	}
	if body.ActivePowerWatts != oneBox {
		t.Fatalf("active_power_watts = %v, want %v (private excluded)", body.ActivePowerWatts, oneBox)
	}
}
