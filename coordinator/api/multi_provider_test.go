package api

// Multi-provider integration tests for the Darkbloom coordinator.
//
// These tests verify correct behavior when multiple providers are connected
// simultaneously: load distribution, failover, model catalog enforcement
// across providers, concurrent provider registration, and provider churn
// during active inference.

import (
	"context"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

// ---------------------------------------------------------------------------
// Multiple providers, same model
// ---------------------------------------------------------------------------

func TestMultiProvider_TwoProvidersSameModel(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	srv.challengeInterval = 500 * time.Millisecond

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	model := "shared-model"
	pubKey1 := testPublicKeyB64()
	pubKey2 := testPublicKeyB64()

	models := []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}}

	provider1 := newTestProviderWS(t, ctx, ts.URL, reg, models, pubKey1)
	defer provider1.Close(websocket.StatusNormalClosure, "")
	provider2 := newTestProviderWS(t, ctx, ts.URL, reg, models, pubKey2)
	defer provider2.Close(websocket.StatusNormalClosure, "")
	reg.SetTrustLevel(provider1.providerID, registry.TrustHardware)
	reg.RecordChallengeSuccess(provider1.providerID)
	reg.SetTrustLevel(provider2.providerID, registry.TrustHardware)
	reg.RecordChallengeSuccess(provider2.providerID)

	if reg.ProviderCount() != 2 {
		t.Fatalf("expected 2 providers, got %d", reg.ProviderCount())
	}

	// Hold the first reservation busy so the next request must route to the
	// other provider; this proves both concrete connections are selectable.
	firstReq := &registry.PendingRequest{RequestID: "multi-first", Model: model, RequestedMaxTokens: 64}
	first, _ := reg.ReserveProviderEx(model, firstReq)
	if first == nil {
		t.Fatal("first provider reservation failed")
	}
	defer func() {
		first.RemovePending(firstReq.RequestID)
		reg.SetProviderIdle(first.ID)
	}()
	secondReq := &registry.PendingRequest{RequestID: "multi-second", Model: model, RequestedMaxTokens: 64}
	second, _ := reg.ReserveProviderEx(model, secondReq)
	if second == nil {
		t.Fatal("second provider reservation failed")
	}
	defer func() {
		second.RemovePending(secondReq.RequestID)
		reg.SetProviderIdle(second.ID)
	}()
	if first.ID == second.ID {
		t.Fatalf("two simultaneous reservations selected the same provider %q", first.ID)
	}
	gotIDs := map[string]bool{first.ID: true, second.ID: true}
	if !gotIDs[provider1.providerID] || !gotIDs[provider2.providerID] {
		t.Fatalf("reserved providers = %v, want %q and %q", gotIDs, provider1.providerID, provider2.providerID)
	}
}

func TestMultiProvider_BothProvidersServeSameModel(t *testing.T) {
	// Use the load test infrastructure which handles E2E encryption correctly.
	ts, reg, _ := setupLoadTestServer(t)
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	model := "multi-serve-model"
	pubKey1 := testPublicKeyB64()
	pubKey2 := testPublicKeyB64()

	provider1 := newTestProviderWS(t, ctx, ts.URL, reg,
		[]protocol.ModelInfo{{ID: model, ModelType: "test", Quantization: "4bit"}},
		pubKey1,
		func(msg *protocol.RegisterMessage) { msg.DecodeTPS = 50 })
	defer provider1.Close(websocket.StatusNormalClosure, "")
	provider2 := newTestProviderWS(t, ctx, ts.URL, reg,
		[]protocol.ModelInfo{{ID: model, ModelType: "test", Quantization: "4bit"}},
		pubKey2,
		func(msg *protocol.RegisterMessage) { msg.DecodeTPS = 50 })
	defer provider2.Close(websocket.StatusNormalClosure, "")
	for _, fixture := range []*providerWSFixture{provider1, provider2} {
		reg.SetTrustLevel(fixture.providerID, registry.TrustHardware)
		reg.RecordChallengeSuccess(fixture.providerID)
	}

	go runProviderLoop(ctx, t, provider1.Conn, pubKey1, "from-provider-1")
	go runProviderLoop(ctx, t, provider2.Conn, pubKey2, "from-provider-2")

	// Send a request — should succeed (at least one provider is available)
	code, body, err := sendRequest(ctx, ts.URL, "test-key", model)
	if err != nil {
		t.Fatalf("request failed: %v", err)
	}
	if code != http.StatusOK {
		t.Fatalf("request: status = %d, want 200, body = %s", code, body)
	}
	gotBody := string(body)
	fromFirst := strings.Contains(gotBody, "from-provider-1")
	fromSecond := strings.Contains(gotBody, "from-provider-2")
	if fromFirst == fromSecond {
		t.Fatalf("response must come from exactly one provider, body=%s", gotBody)
	}
}

// ---------------------------------------------------------------------------
// Multiple providers, different models
// ---------------------------------------------------------------------------

func TestMultiProvider_DifferentModels(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	pubKey1 := testPublicKeyB64()
	pubKey2 := testPublicKeyB64()

	provider1 := newTestProviderWS(t, ctx, ts.URL, reg,
		[]protocol.ModelInfo{{ID: "model-alpha", ModelType: "chat", Quantization: "4bit"}},
		pubKey1)
	defer provider1.Close(websocket.StatusNormalClosure, "")
	provider2 := newTestProviderWS(t, ctx, ts.URL, reg,
		[]protocol.ModelInfo{{ID: "model-beta", ModelType: "chat", Quantization: "8bit"}},
		pubKey2)
	defer provider2.Close(websocket.StatusNormalClosure, "")
	for _, fixture := range []*providerWSFixture{provider1, provider2} {
		reg.SetTrustLevel(fixture.providerID, registry.TrustHardware)
		reg.RecordChallengeSuccess(fixture.providerID)
	}

	// Find provider for each model
	pAlpha := findRoutableProvider(reg, "model-alpha")
	if pAlpha == nil {
		t.Error("no provider found for model-alpha")
	}

	pBeta := findRoutableProvider(reg, "model-beta")
	if pBeta == nil {
		t.Error("no provider found for model-beta")
	}

	if pAlpha.ID != provider1.providerID {
		t.Fatalf("model-alpha routed to %q, want %q", pAlpha.ID, provider1.providerID)
	}
	if pBeta.ID != provider2.providerID {
		t.Fatalf("model-beta routed to %q, want %q", pBeta.ID, provider2.providerID)
	}

	// Non-existent model should return nil
	pNone := findRoutableProvider(reg, "model-gamma")
	if pNone != nil {
		t.Error("should not find provider for non-existent model")
	}
}

// ---------------------------------------------------------------------------
// Provider churn (join/leave during operation)
// ---------------------------------------------------------------------------

func TestMultiProvider_ProviderLeavesOtherContinues(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	model := "churn-model"
	pubKey1 := testPublicKeyB64()
	pubKey2 := testPublicKeyB64()
	models := []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}}

	provider1 := newTestProviderWS(t, ctx, ts.URL, reg, models, pubKey1)
	provider2 := newTestProviderWS(t, ctx, ts.URL, reg, models, pubKey2)
	defer provider2.Close(websocket.StatusNormalClosure, "")
	for _, fixture := range []*providerWSFixture{provider1, provider2} {
		reg.SetTrustLevel(fixture.providerID, registry.TrustHardware)
		reg.RecordChallengeSuccess(fixture.providerID)
	}

	if reg.ProviderCount() != 2 {
		t.Fatalf("expected 2 providers, got %d", reg.ProviderCount())
	}

	provider1.Close(websocket.StatusNormalClosure, "leaving")
	if got := reg.ProviderCount(); got != 1 {
		t.Fatalf("after disconnect: providers = %d, want 1", got)
	}

	p := findRoutableProvider(reg, model)
	if p == nil {
		t.Fatal("remaining provider should still be findable")
	}
	if p.ID != provider2.providerID {
		t.Fatalf("routed to %q after leave, want remaining provider %q", p.ID, provider2.providerID)
	}
}

// ---------------------------------------------------------------------------
// Model catalog enforcement with multiple providers
// ---------------------------------------------------------------------------

func TestMultiProvider_CatalogFiltersDuringRegistration(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	// Set catalog before providers connect
	reg.SetModelCatalog([]registry.CatalogEntry{
		{ID: "whitelisted-model"},
	})

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	pubKey1 := testPublicKeyB64()
	pubKey2 := testPublicKeyB64()

	provider1 := newTestProviderWS(t, ctx, ts.URL, reg, []protocol.ModelInfo{
		{ID: "whitelisted-model", ModelType: "chat", Quantization: "4bit"},
		{ID: "blocked-model", ModelType: "chat", Quantization: "4bit"},
	}, pubKey1)
	defer provider1.Close(websocket.StatusNormalClosure, "")
	provider2 := newTestProviderWS(t, ctx, ts.URL, reg, []protocol.ModelInfo{
		{ID: "blocked-model", ModelType: "chat", Quantization: "4bit"},
		{ID: "another-blocked", ModelType: "chat", Quantization: "4bit"},
	}, pubKey2)
	defer provider2.Close(websocket.StatusNormalClosure, "")
	for _, fixture := range []*providerWSFixture{provider1, provider2} {
		reg.SetTrustLevel(fixture.providerID, registry.TrustHardware)
		reg.RecordChallengeSuccess(fixture.providerID)
	}

	// Should find a provider for the whitelisted model
	p := findRoutableProvider(reg, "whitelisted-model")
	if p == nil {
		t.Fatal("should find provider for whitelisted-model")
	}
	if p.ID != provider1.providerID {
		t.Fatalf("whitelisted model routed to %q, want %q", p.ID, provider1.providerID)
	}

	// Should NOT find a provider for blocked models (catalog check)
	if reg.IsModelInCatalog("blocked-model") {
		t.Error("blocked-model should not be in catalog")
	}
	if p := findRoutableProvider(reg, "blocked-model"); p != nil {
		t.Fatalf("blocked model routed to provider %q", p.ID)
	}
}

// ---------------------------------------------------------------------------
// Provider with multiple models
// ---------------------------------------------------------------------------

func TestMultiProvider_SingleProviderMultipleModels(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	pubKey := testPublicKeyB64()
	models := []protocol.ModelInfo{
		{ID: "text-model", ModelType: "text", Quantization: "4bit"},
		{ID: "code-model", ModelType: "text", Quantization: "8bit"},
		{ID: "chat-model", ModelType: "chat", Quantization: "4bit"},
	}

	provider := newTestProviderWS(t, ctx, ts.URL, reg, models, pubKey)
	defer provider.Close(websocket.StatusNormalClosure, "")
	reg.SetTrustLevel(provider.providerID, registry.TrustHardware)
	reg.RecordChallengeSuccess(provider.providerID)

	// Should find provider for each model
	for _, m := range models {
		p := findRoutableProvider(reg, m.ID)
		if p == nil {
			t.Fatalf("no provider found for model %q", m.ID)
		}
		if p.ID != provider.providerID {
			t.Fatalf("model %q routed to %q, want %q", m.ID, p.ID, provider.providerID)
		}
	}
}

// ---------------------------------------------------------------------------
// Trust level enforcement across multiple providers
// ---------------------------------------------------------------------------
