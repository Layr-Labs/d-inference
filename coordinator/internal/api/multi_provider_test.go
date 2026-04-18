package api

// Multi-provider integration tests for the Darkbloom coordinator.
//
// These tests verify correct behavior when multiple providers are connected
// simultaneously: load distribution, failover, model catalog enforcement
// across providers, concurrent provider registration, and provider churn
// during active inference.

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/coordinator/internal/protocol"
	"github.com/eigeninference/coordinator/internal/registry"
	"github.com/eigeninference/coordinator/internal/store"
	"github.com/coder/websocket"
)

// ---------------------------------------------------------------------------
// Multiple providers, same model
// ---------------------------------------------------------------------------

func TestMultiProvider_TwoProvidersSameModel(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)
	srv.challengeInterval = 500 * time.Millisecond

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	model := "shared-model"
	pubKey1 := testPublicKeyB64()
	pubKey2 := testPublicKeyB64()

	models := []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}}

	// Connect two providers
	conn1 := connectProvider(t, ctx, ts.URL, models, pubKey1)
	defer conn1.Close(websocket.StatusNormalClosure, "")
	conn2 := connectProvider(t, ctx, ts.URL, models, pubKey2)
	defer conn2.Close(websocket.StatusNormalClosure, "")

	// Trust both and mark challenges verified
	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
		reg.RecordChallengeSuccess(id)
	}

	if reg.ProviderCount() != 2 {
		t.Fatalf("expected 2 providers, got %d", reg.ProviderCount())
	}

	// Both should be findable for the same model
	p1 := reg.FindProvider(model)
	if p1 == nil {
		t.Fatal("should find a provider for shared-model")
	}

	// Second FindProvider also returns a provider (both are available)
	p2 := reg.FindProvider(model)
	if p2 == nil {
		t.Fatal("should find provider on second call")
	}

	// Both providers are registered and routable
	if reg.ProviderCount() != 2 {
		t.Errorf("expected 2 providers registered, got %d", reg.ProviderCount())
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

	conn1 := connectAndPrepareProvider(t, ctx, ts.URL, reg, model, pubKey1, 50.0)
	defer conn1.Close(websocket.StatusNormalClosure, "")
	conn2 := connectAndPrepareProvider(t, ctx, ts.URL, reg, model, pubKey2, 50.0)
	defer conn2.Close(websocket.StatusNormalClosure, "")

	if reg.ProviderCount() != 2 {
		t.Fatalf("expected 2 providers, got %d", reg.ProviderCount())
	}

	// Both providers serve requests
	go runProviderLoop(ctx, t, conn1, pubKey1, "from-provider-1")
	go runProviderLoop(ctx, t, conn2, pubKey2, "from-provider-2")

	// Wait for challenge handling
	time.Sleep(500 * time.Millisecond)

	// Send a request — should succeed (at least one provider is available)
	code, body, err := sendRequest(ctx, ts.URL, "test-key", model)
	if err != nil {
		t.Fatalf("request failed: %v", err)
	}
	if code != http.StatusOK {
		t.Errorf("request: status = %d, want 200, body = %s", code, body)
	}
}

// ---------------------------------------------------------------------------
// Multiple providers, different models
// ---------------------------------------------------------------------------

func TestMultiProvider_DifferentModels(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	pubKey1 := testPublicKeyB64()
	pubKey2 := testPublicKeyB64()

	conn1 := connectProvider(t, ctx, ts.URL, []protocol.ModelInfo{
		{ID: "model-alpha", ModelType: "chat", Quantization: "4bit"},
	}, pubKey1)
	defer conn1.Close(websocket.StatusNormalClosure, "")

	conn2 := connectProvider(t, ctx, ts.URL, []protocol.ModelInfo{
		{ID: "model-beta", ModelType: "chat", Quantization: "8bit"},
	}, pubKey2)
	defer conn2.Close(websocket.StatusNormalClosure, "")

	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
		reg.RecordChallengeSuccess(id)
	}

	// Find provider for each model
	pAlpha := reg.FindProvider("model-alpha")
	if pAlpha == nil {
		t.Error("no provider found for model-alpha")
	}

	pBeta := reg.FindProvider("model-beta")
	if pBeta == nil {
		t.Error("no provider found for model-beta")
	}

	// They should be different providers
	if pAlpha != nil && pBeta != nil && pAlpha.ID == pBeta.ID {
		t.Error("different models should map to different providers")
	}

	// Non-existent model should return nil
	pNone := reg.FindProvider("model-gamma")
	if pNone != nil {
		t.Error("should not find provider for non-existent model")
	}
}

// ---------------------------------------------------------------------------
// Provider churn (join/leave during operation)
// ---------------------------------------------------------------------------

func TestMultiProvider_ProviderLeavesOtherContinues(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	model := "churn-model"
	pubKey1 := testPublicKeyB64()
	pubKey2 := testPublicKeyB64()
	models := []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}}

	conn1 := connectProvider(t, ctx, ts.URL, models, pubKey1)
	conn2 := connectProvider(t, ctx, ts.URL, models, pubKey2)
	defer conn2.Close(websocket.StatusNormalClosure, "")

	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
		reg.RecordChallengeSuccess(id)
	}

	if reg.ProviderCount() != 2 {
		t.Fatalf("expected 2 providers, got %d", reg.ProviderCount())
	}

	// Disconnect provider 1
	conn1.Close(websocket.StatusNormalClosure, "leaving")
	time.Sleep(300 * time.Millisecond)

	if reg.ProviderCount() != 1 {
		t.Errorf("after disconnect: expected 1 provider, got %d", reg.ProviderCount())
	}

	// Provider 2 should still be findable
	p := reg.FindProvider(model)
	if p == nil {
		t.Error("remaining provider should still be findable")
	}
}

func TestMultiProvider_ProviderJoinsLate(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)
	srv.challengeInterval = 200 * time.Millisecond

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	model := "late-join-model"
	pubKey1 := testPublicKeyB64()
	pubKey2 := testPublicKeyB64()
	models := []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}}

	// Only provider 1 initially
	conn1 := connectProvider(t, ctx, ts.URL, models, pubKey1)
	defer conn1.Close(websocket.StatusNormalClosure, "")

	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
		reg.RecordChallengeSuccess(id)
	}

	if reg.ProviderCount() != 1 {
		t.Fatalf("expected 1 provider initially, got %d", reg.ProviderCount())
	}

	// Provider 2 joins later
	time.Sleep(200 * time.Millisecond)
	conn2 := connectProvider(t, ctx, ts.URL, models, pubKey2)
	defer conn2.Close(websocket.StatusNormalClosure, "")

	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
		reg.RecordChallengeSuccess(id)
	}

	time.Sleep(200 * time.Millisecond)

	if reg.ProviderCount() != 2 {
		t.Errorf("expected 2 providers after late join, got %d", reg.ProviderCount())
	}
}

// ---------------------------------------------------------------------------
// Model catalog enforcement with multiple providers
// ---------------------------------------------------------------------------

func TestMultiProvider_CatalogFiltersDuringRegistration(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)

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

	// Provider 1 has the whitelisted model
	conn1 := connectProvider(t, ctx, ts.URL, []protocol.ModelInfo{
		{ID: "whitelisted-model", ModelType: "chat", Quantization: "4bit"},
		{ID: "blocked-model", ModelType: "chat", Quantization: "4bit"},
	}, pubKey1)
	defer conn1.Close(websocket.StatusNormalClosure, "")

	// Provider 2 only has non-whitelisted models
	conn2 := connectProvider(t, ctx, ts.URL, []protocol.ModelInfo{
		{ID: "blocked-model", ModelType: "chat", Quantization: "4bit"},
		{ID: "another-blocked", ModelType: "chat", Quantization: "4bit"},
	}, pubKey2)
	defer conn2.Close(websocket.StatusNormalClosure, "")

	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
		reg.RecordChallengeSuccess(id)
	}

	time.Sleep(200 * time.Millisecond)

	// Should find a provider for the whitelisted model
	p := reg.FindProvider("whitelisted-model")
	if p == nil {
		t.Error("should find provider for whitelisted-model")
	}

	// Should NOT find a provider for blocked models (catalog check)
	if reg.IsModelInCatalog("blocked-model") {
		t.Error("blocked-model should not be in catalog")
	}
}

// ---------------------------------------------------------------------------
// Provider count and capacity
// ---------------------------------------------------------------------------

func TestMultiProvider_ManyProviders(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	model := "scale-model"
	models := []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}}
	const numProviders = 10

	conns := make([]*websocket.Conn, numProviders)
	for i := 0; i < numProviders; i++ {
		pk := testPublicKeyB64()
		conns[i] = connectProvider(t, ctx, ts.URL, models, pk)
		defer conns[i].Close(websocket.StatusNormalClosure, "")
	}

	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
		reg.RecordChallengeSuccess(id)
	}

	if reg.ProviderCount() != numProviders {
		t.Errorf("expected %d providers, got %d", numProviders, reg.ProviderCount())
	}

	// Should be able to find providers for the model
	for i := 0; i < numProviders; i++ {
		p := reg.FindProvider(model)
		if p == nil {
			t.Errorf("FindProvider returned nil on attempt %d", i)
			break
		}
	}
}

// ---------------------------------------------------------------------------
// Concurrent provider registration
// ---------------------------------------------------------------------------

func TestMultiProvider_ConcurrentRegistration(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	model := "concurrent-reg-model"
	models := []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}}
	const numProviders = 5

	var wg sync.WaitGroup
	conns := make([]*websocket.Conn, numProviders)
	errors := make([]error, numProviders)

	// Register all providers concurrently
	for i := 0; i < numProviders; i++ {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			pk := testPublicKeyB64()
			wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"
			conn, _, err := websocket.Dial(ctx, wsURL, nil)
			if err != nil {
				errors[idx] = err
				return
			}
			conns[idx] = conn

			regMsg := protocol.RegisterMessage{
				Type: protocol.TypeRegister,
				Hardware: protocol.Hardware{
					MachineModel: "Mac15,8",
					ChipName:     "Apple M3 Max",
					MemoryGB:     64,
				},
				Models:    models,
				Backend:   "test",
				PublicKey: pk,
			}
			regData, _ := json.Marshal(regMsg)
			if err := conn.Write(ctx, websocket.MessageText, regData); err != nil {
				errors[idx] = err
			}
		}(i)
	}

	wg.Wait()

	// Cleanup
	for _, c := range conns {
		if c != nil {
			defer c.Close(websocket.StatusNormalClosure, "")
		}
	}

	// Check for errors
	for i, err := range errors {
		if err != nil {
			t.Errorf("provider %d registration failed: %v", i, err)
		}
	}

	time.Sleep(500 * time.Millisecond)

	// All providers should be registered
	count := reg.ProviderCount()
	if count != numProviders {
		t.Errorf("expected %d providers after concurrent registration, got %d", numProviders, count)
	}
}

// ---------------------------------------------------------------------------
// Provider with multiple models
// ---------------------------------------------------------------------------

func TestMultiProvider_SingleProviderMultipleModels(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)

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

	conn := connectProvider(t, ctx, ts.URL, models, pubKey)
	defer conn.Close(websocket.StatusNormalClosure, "")

	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
		reg.RecordChallengeSuccess(id)
	}

	// Should find provider for each model
	for _, m := range models {
		p := reg.FindProvider(m.ID)
		if p == nil {
			t.Errorf("no provider found for model %q", m.ID)
		} else {
			// Set back to idle for next find
			reg.SetProviderIdle(p.ID)
		}
	}
}

// ---------------------------------------------------------------------------
// Trust level enforcement across multiple providers
// ---------------------------------------------------------------------------

func TestMultiProvider_TrustLevelFiltering(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	model := "trust-model"
	pubKeyTrusted := testPublicKeyB64()
	pubKeyUntrusted := testPublicKeyB64()
	models := []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}}

	connTrusted := connectProvider(t, ctx, ts.URL, models, pubKeyTrusted)
	defer connTrusted.Close(websocket.StatusNormalClosure, "")
	connUntrusted := connectProvider(t, ctx, ts.URL, models, pubKeyUntrusted)
	defer connUntrusted.Close(websocket.StatusNormalClosure, "")

	ids := reg.ProviderIDs()
	if len(ids) != 2 {
		t.Fatalf("expected 2 providers, got %d", len(ids))
	}

	// Give different trust levels
	reg.SetTrustLevel(ids[0], registry.TrustHardware)
	reg.RecordChallengeSuccess(ids[0])
	reg.SetTrustLevel(ids[1], registry.TrustSelfSigned)
	reg.RecordChallengeSuccess(ids[1])

	// FindProviderWithTrust for hardware should only return the hardware-trusted one
	p := reg.FindProviderWithTrust(model, registry.TrustHardware)
	if p == nil {
		t.Fatal("should find hardware-trusted provider")
	}
	if p.ID != ids[0] {
		t.Error("should return the hardware-trusted provider")
	}

	// Reset the first provider to idle
	reg.SetProviderIdle(ids[0])

	// FindProviderWithTrust for self_signed should return either (both meet minimum)
	p2 := reg.FindProviderWithTrust(model, registry.TrustSelfSigned)
	if p2 == nil {
		t.Fatal("should find provider with self_signed trust minimum")
	}
}
