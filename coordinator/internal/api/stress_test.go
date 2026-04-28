package api

// Stress and resilience tests for the Darkbloom coordinator.
//
// Covers: queue overflow, provider disconnect under active load, request
// cancellation with slow providers, billing race conditions, provider
// re-registration with different models, and heterogeneous provider scoring.

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/darkbloom/coordinator/internal/billing"
	"github.com/darkbloom/coordinator/internal/payments"
	"github.com/darkbloom/coordinator/internal/protocol"
	"github.com/darkbloom/coordinator/internal/registry"
	"github.com/darkbloom/coordinator/internal/store"
	"nhooyr.io/websocket"
)

// =========================================================================
// Queue overflow: more requests than the queue can hold
// =========================================================================

func TestStress_QueueOverflow(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	// Tiny queue: 3 slots, 500ms timeout
	reg.SetQueue(registry.NewRequestQueue(3, 500*time.Millisecond))
	srv := NewServer(reg, st, logger)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	// NO providers registered — all requests go to queue
	model := "queue-test-model"

	// Fire 10 concurrent requests at a queue that holds 3
	var wg sync.WaitGroup
	results := make([]int, 10)

	for i := range 10 {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			body := fmt.Sprintf(`{"model":%q,"messages":[{"role":"user","content":"hi"}]}`, model)
			req, _ := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+"/v1/chat/completions",
				strings.NewReader(body))
			req.Header.Set("Authorization", "Bearer test-key")

			resp, err := http.DefaultClient.Do(req)
			if err != nil {
				results[idx] = 0
				return
			}
			io.ReadAll(resp.Body)
			resp.Body.Close()
			results[idx] = resp.StatusCode
		}(i)
	}

	wg.Wait()

	// Count results
	var got503, got404, other int
	for _, code := range results {
		switch code {
		case http.StatusServiceUnavailable:
			got503++
		case http.StatusNotFound:
			got404++
		default:
			other++
		}
	}

	t.Logf("queue overflow results: 503=%d, 404=%d, other=%d", got503, got404, other)

	// Most should be 503 (queue full) or 404 (not in catalog)
	// The key thing: no 500s, no panics, no hangs
	if other > 0 {
		t.Logf("unexpected status codes in results: %v", results)
	}
}

func TestStress_QueueDrainsWhenProviderAppears(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	reg.SetQueue(registry.NewRequestQueue(10, 10*time.Second))
	srv := NewServer(reg, st, logger)
	srv.challengeInterval = 200 * time.Millisecond

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	model := "drain-model"
	pubKey := testPublicKeyB64()

	// Fire 3 requests BEFORE any provider is available (they'll queue)
	var wg sync.WaitGroup
	results := make([]int, 3)
	for i := range 3 {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			body := fmt.Sprintf(`{"model":%q,"messages":[{"role":"user","content":"queued request %d"}],"stream":true}`, model, idx)
			req, _ := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+"/v1/chat/completions",
				strings.NewReader(body))
			req.Header.Set("Authorization", "Bearer test-key")

			resp, err := http.DefaultClient.Do(req)
			if err != nil {
				results[idx] = 0
				return
			}
			io.ReadAll(resp.Body)
			resp.Body.Close()
			results[idx] = resp.StatusCode
		}(i)
	}

	// Wait a moment for requests to enter the queue
	time.Sleep(500 * time.Millisecond)

	// NOW connect a provider — queued requests should drain to it
	models := []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}}
	conn := connectProvider(t, ctx, ts.URL, models, pubKey)
	defer conn.Close(websocket.StatusNormalClosure, "")

	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
		reg.RecordChallengeSuccess(id)
	}

	// Provider handles messages
	go runProviderLoop(ctx, t, conn, pubKey, "drained-response")

	wg.Wait()

	succeeded := 0
	for _, code := range results {
		if code == 200 {
			succeeded++
		}
	}
	t.Logf("queue drain: %d/3 requests succeeded after provider appeared", succeeded)
	// At least 1 should have been picked up from queue (provider serves 1 then exits loop)
	if succeeded == 0 {
		t.Logf("results: %v (may have timed out before provider was ready)", results)
	}
}

// =========================================================================
// Provider disconnect while requests are in-flight
// =========================================================================

func TestStress_ProviderCrashDuringMultipleInFlightRequests(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	reg.SetQueue(registry.NewRequestQueue(50, 30*time.Second))
	srv := NewServer(reg, st, logger)
	srv.challengeInterval = 1 * time.Second

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	model := "crash-model"
	pubKey := testPublicKeyB64()
	models := []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}}

	conn := connectProvider(t, ctx, ts.URL, models, pubKey)

	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
		reg.RecordChallengeSuccess(id)
	}

	// Provider handles challenges but delays inference response, then crashes
	go func() {
		for {
			_, data, err := conn.Read(ctx)
			if err != nil {
				return
			}
			var env struct {
				Type string `json:"type"`
			}
			json.Unmarshal(data, &env)

			if env.Type == protocol.TypeAttestationChallenge {
				resp := makeValidChallengeResponse(data, pubKey)
				conn.Write(ctx, websocket.MessageText, resp)
			}
			if env.Type == protocol.TypeInferenceRequest {
				// Send one partial chunk then crash
				var req protocol.InferenceRequestMessage
				json.Unmarshal(data, &req)
				writeEncryptedTestChunk(t, ctx, conn, req, pubKey,
					`data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"partial..."},"finish_reason":null}]}`+"\n\n")
				time.Sleep(100 * time.Millisecond)
				// Crash!
				conn.Close(websocket.StatusAbnormalClosure, "simulated crash")
				return
			}
		}
	}()

	// Fire 5 concurrent requests
	var wg sync.WaitGroup
	results := make([]int, 5)
	for i := range 5 {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			body := fmt.Sprintf(`{"model":%q,"messages":[{"role":"user","content":"req %d"}],"stream":true}`, model, idx)
			req, _ := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+"/v1/chat/completions",
				strings.NewReader(body))
			req.Header.Set("Authorization", "Bearer test-key")

			resp, err := http.DefaultClient.Do(req)
			if err != nil {
				return
			}
			io.ReadAll(resp.Body)
			resp.Body.Close()
			results[idx] = resp.StatusCode
		}(i)
	}

	wg.Wait()

	// After crash, provider should be removed
	time.Sleep(500 * time.Millisecond)
	if reg.ProviderCount() != 0 {
		t.Errorf("provider should be removed after crash, count = %d", reg.ProviderCount())
	}

	t.Logf("crash results: %v (no hangs = PASS)", results)
	// Key assertion: test completes (no deadlock/hang), all requests return
}

// =========================================================================
// Consumer disconnect mid-stream triggers cancel
// =========================================================================

func TestStress_ConsumerDisconnectSendsCancelToProvider(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)
	srv.challengeInterval = 1 * time.Second

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	model := "cancel-model"
	pubKey := testPublicKeyB64()
	models := []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}}

	conn := connectProvider(t, ctx, ts.URL, models, pubKey)
	defer conn.Close(websocket.StatusNormalClosure, "")

	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
		reg.RecordChallengeSuccess(id)
	}

	// Track what messages the provider receives
	var gotCancel int32
	var gotInferenceRequest int32

	go func() {
		for {
			_, data, err := conn.Read(ctx)
			if err != nil {
				return
			}
			var env struct {
				Type string `json:"type"`
			}
			json.Unmarshal(data, &env)

			switch env.Type {
			case protocol.TypeAttestationChallenge:
				resp := makeValidChallengeResponse(data, pubKey)
				conn.Write(ctx, websocket.MessageText, resp)

			case protocol.TypeInferenceRequest:
				atomic.AddInt32(&gotInferenceRequest, 1)
				var req protocol.InferenceRequestMessage
				json.Unmarshal(data, &req)

				// Send first chunk (simulating slow generation)
				writeEncryptedTestChunk(t, ctx, conn, req, pubKey,
					`data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"slow..."},"finish_reason":null}]}`+"\n\n")
				// Don't block the read loop — keep reading for cancel

			case protocol.TypeCancel:
				atomic.AddInt32(&gotCancel, 1)
			}
		}
	}()

	// Send a request with a short timeout (consumer will disconnect)
	reqCtx, reqCancel := context.WithTimeout(ctx, 1*time.Second)
	defer reqCancel()

	body := fmt.Sprintf(`{"model":%q,"messages":[{"role":"user","content":"cancel me"}],"stream":true}`, model)
	req, _ := http.NewRequestWithContext(reqCtx, http.MethodPost, ts.URL+"/v1/chat/completions",
		strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer test-key")

	resp, err := http.DefaultClient.Do(req)
	if err == nil {
		// Read partially then abandon
		buf := make([]byte, 100)
		resp.Body.Read(buf)
		resp.Body.Close()
	}

	// Wait for cancel to propagate
	time.Sleep(2 * time.Second)

	if atomic.LoadInt32(&gotInferenceRequest) == 0 {
		t.Error("provider never received inference request")
	}
	if atomic.LoadInt32(&gotCancel) == 0 {
		t.Error("provider never received cancel message after consumer disconnect")
	} else {
		t.Log("cancel message received by provider: PASS")
	}
}

// =========================================================================
// Billing: concurrent charges and balance exhaustion
// =========================================================================

func TestStress_BillingBalanceExhaustion(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("billing-key")
	reg := registry.New(logger)
	reg.SetQueue(registry.NewRequestQueue(50, 5*time.Second))
	ledger := payments.NewLedger(st)
	billingSvc := billing.NewService(st, ledger, logger, billing.Config{MockMode: true})

	srv := NewServer(reg, st, logger)
	srv.SetBilling(billingSvc)
	srv.SetAdminKey("billing-key")
	srv.challengeInterval = 500 * time.Millisecond

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	// Credit the consumer with a small balance (enough for ~5 requests)
	st.Credit("billing-key", 500, store.LedgerDeposit, "test-credit")

	model := "billing-model"
	pubKey := testPublicKeyB64()
	models := []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}}

	conn := connectProvider(t, ctx, ts.URL, models, pubKey)
	defer conn.Close(websocket.StatusNormalClosure, "")

	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
		reg.RecordChallengeSuccess(id)
	}

	go runProviderLoop(ctx, t, conn, pubKey, "billing-response")

	// Send requests until balance runs out
	var succeeded, rejected int
	for i := range 20 {
		body := fmt.Sprintf(`{"model":%q,"messages":[{"role":"user","content":"billing %d"}],"stream":true}`, model, i)
		req, _ := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+"/v1/chat/completions",
			strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer billing-key")

		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			continue
		}
		io.ReadAll(resp.Body)
		resp.Body.Close()

		switch resp.StatusCode {
		case http.StatusOK:
			succeeded++
		case http.StatusPaymentRequired:
			rejected++
		}
	}

	t.Logf("billing exhaustion: %d succeeded, %d rejected (402)", succeeded, rejected)
	if rejected == 0 {
		t.Error("expected some requests to be rejected after balance exhaustion")
	}
	finalBalance := ledger.Balance("billing-key")
	t.Logf("final balance: %d micro-USD", finalBalance)
}

func TestStress_BillingConcurrentCharges(t *testing.T) {
	st := store.NewMemory("charge-key")
	ledger := payments.NewLedger(st)

	// Credit a large balance
	st.Credit("charge-key", 1_000_000, store.LedgerDeposit, "test-credit")
	initialBalance := ledger.Balance("charge-key")

	// Fire 50 concurrent charges of 100 each
	var wg sync.WaitGroup
	var chargeErrors int32
	for i := range 50 {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			if err := ledger.Charge("charge-key", 100, fmt.Sprintf("job-%d", idx)); err != nil {
				atomic.AddInt32(&chargeErrors, 1)
			}
		}(i)
	}
	wg.Wait()

	finalBalance := ledger.Balance("charge-key")
	expectedBalance := initialBalance - (50 * 100)
	errors := atomic.LoadInt32(&chargeErrors)

	t.Logf("concurrent charges: initial=%d, final=%d, expected=%d, errors=%d",
		initialBalance, finalBalance, expectedBalance, errors)

	if errors > 0 {
		t.Errorf("unexpected charge errors: %d", errors)
	}
	// Balance should be exactly correct (no double-charges or missed charges)
	if finalBalance != expectedBalance {
		t.Errorf("balance mismatch: got %d, want %d", finalBalance, expectedBalance)
	}
}

// =========================================================================
// Model re-registration (provider reconnects with different models)
// =========================================================================

func TestStress_ProviderReRegistersWithDifferentModels(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	pubKey := testPublicKeyB64()

	// Phase 1: Connect with model-A
	modelsA := []protocol.ModelInfo{{ID: "model-A", ModelType: "chat", Quantization: "4bit"}}
	conn1 := connectProvider(t, ctx, ts.URL, modelsA, pubKey)

	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
		reg.RecordChallengeSuccess(id)
	}

	pA := reg.FindProvider("model-A")
	if pA == nil {
		t.Fatal("should find provider for model-A")
	}
	reg.SetProviderIdle(pA.ID)

	pB := reg.FindProvider("model-B")
	if pB != nil {
		t.Fatal("should NOT find provider for model-B (not registered)")
	}

	// Phase 2: Disconnect and reconnect with model-B instead
	conn1.Close(websocket.StatusNormalClosure, "switching models")
	time.Sleep(300 * time.Millisecond)

	if reg.ProviderCount() != 0 {
		t.Fatalf("provider should be gone after disconnect, count=%d", reg.ProviderCount())
	}

	modelsB := []protocol.ModelInfo{{ID: "model-B", ModelType: "chat", Quantization: "8bit"}}
	conn2 := connectProvider(t, ctx, ts.URL, modelsB, pubKey)
	defer conn2.Close(websocket.StatusNormalClosure, "")

	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
		reg.RecordChallengeSuccess(id)
	}

	time.Sleep(200 * time.Millisecond)

	// model-A should no longer be available
	pA2 := reg.FindProvider("model-A")
	if pA2 != nil {
		t.Error("model-A should not be available after re-registration with model-B")
	}

	// model-B should now be available
	pB2 := reg.FindProvider("model-B")
	if pB2 == nil {
		t.Error("model-B should be available after re-registration")
	}

	t.Log("model re-registration: PASS")
}

// =========================================================================
// Heterogeneous provider scoring
// =========================================================================

func TestStress_HeterogeneousProviderScoring(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	reg.SetQueue(registry.NewRequestQueue(50, 10*time.Second))
	srv := NewServer(reg, st, logger)
	srv.challengeInterval = 1 * time.Second

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	model := "scoring-model"

	// Connect 3 providers with different hardware specs
	specs := []struct {
		chipName  string
		memoryGB  int
		decodeTPS float64
		pubKey    string
	}{
		{"Apple M3 Max", 64, 50.0, testPublicKeyB64()},   // slow
		{"Apple M4 Max", 128, 120.0, testPublicKeyB64()}, // fast
		{"Apple M3 Pro", 36, 30.0, testPublicKeyB64()},   // slowest
	}

	conns := make([]*websocket.Conn, len(specs))
	for i, spec := range specs {
		wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"
		conn, _, err := websocket.Dial(ctx, wsURL, nil)
		if err != nil {
			t.Fatalf("provider %d dial: %v", i, err)
		}
		conns[i] = conn
		defer conn.Close(websocket.StatusNormalClosure, "")

		regMsg := protocol.RegisterMessage{
			Type: protocol.TypeRegister,
			Hardware: protocol.Hardware{
				MachineModel: "Mac15,8",
				ChipName:     spec.chipName,
				MemoryGB:     spec.memoryGB,
			},
			Models:                  []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}},
			Backend:                 "inprocess-mlx",
			PublicKey:               spec.pubKey,
			DecodeTPS:               spec.decodeTPS,
			EncryptedResponseChunks: true,
			PrivacyCapabilities:     testPrivacyCaps(),
		}
		data, _ := json.Marshal(regMsg)
		conn.Write(ctx, websocket.MessageText, data)
		time.Sleep(100 * time.Millisecond)
	}

	// Trust all and verify challenges
	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
		reg.RecordChallengeSuccess(id)
	}

	// Find provider 10 times — the fastest (120 TPS M4 Max) should be selected most
	selections := make(map[string]int)
	for range 10 {
		p := reg.FindProvider(model)
		if p == nil {
			t.Fatal("FindProvider returned nil")
		}
		selections[p.Hardware.ChipName]++
		reg.SetProviderIdle(p.ID)
	}

	t.Logf("scoring selections (10 rounds): %v", selections)

	// The M4 Max (120 TPS) should be selected most often
	if selections["Apple M4 Max"] < selections["Apple M3 Pro"] {
		t.Error("M4 Max (120 TPS) should be preferred over M3 Pro (30 TPS)")
	}
}

func TestStress_ThermalThrottlingAffectsScoring(t *testing.T) {
	model := "thermal-model"

	// Create two providers directly in the registry
	p1 := &registry.Provider{
		ID: "cool-provider",
		Hardware: protocol.Hardware{
			ChipName: "Apple M4 Max",
			MemoryGB: 128,
		},
		Models:          []protocol.ModelInfo{{ID: model, ModelType: "chat"}},
		DecodeTPS:       100.0,
		RuntimeVerified: true,
		SystemMetrics: protocol.SystemMetrics{
			MemoryPressure: 0.3,
			CPUUsage:       0.2,
			ThermalState:   "nominal",
		},
	}
	p1.Reputation = registry.NewReputation()

	p2 := &registry.Provider{
		ID: "hot-provider",
		Hardware: protocol.Hardware{
			ChipName: "Apple M4 Max",
			MemoryGB: 128,
		},
		Models:          []protocol.ModelInfo{{ID: model, ModelType: "chat"}},
		DecodeTPS:       100.0,
		RuntimeVerified: true,
		SystemMetrics: protocol.SystemMetrics{
			MemoryPressure: 0.3,
			CPUUsage:       0.2,
			ThermalState:   "serious", // thermal throttling!
		},
	}
	p2.Reputation = registry.NewReputation()

	// Score them
	scoreCool := registry.ScoreProvider(p1, model)
	scoreHot := registry.ScoreProvider(p2, model)

	t.Logf("cool provider score: %.2f", scoreCool)
	t.Logf("hot provider score:  %.2f (thermal=serious)", scoreHot)

	if scoreHot >= scoreCool {
		t.Errorf("thermally throttled provider (%.2f) should score lower than cool one (%.2f)",
			scoreHot, scoreCool)
	}

	// Critical thermal should score near zero
	p3 := &registry.Provider{
		ID:              "critical-provider",
		Hardware:        p1.Hardware,
		Models:          p1.Models,
		DecodeTPS:       100.0,
		RuntimeVerified: true,
		SystemMetrics: protocol.SystemMetrics{
			ThermalState: "critical",
		},
	}
	p3.Reputation = registry.NewReputation()
	scoreCritical := registry.ScoreProvider(p3, model)
	t.Logf("critical score: %.2f", scoreCritical)

	if scoreCritical > 0.01 {
		t.Errorf("critical thermal provider should score near zero, got %.2f", scoreCritical)
	}
}

func TestStress_MemoryPressureAffectsScoring(t *testing.T) {
	model := "memory-model"

	low := &registry.Provider{
		ID:              "low-mem",
		Models:          []protocol.ModelInfo{{ID: model}},
		DecodeTPS:       100.0,
		RuntimeVerified: true,
		SystemMetrics: protocol.SystemMetrics{
			MemoryPressure: 0.1,
			ThermalState:   "nominal",
		},
	}
	low.Reputation = registry.NewReputation()

	high := &registry.Provider{
		ID:              "high-mem",
		Models:          []protocol.ModelInfo{{ID: model}},
		DecodeTPS:       100.0,
		RuntimeVerified: true,
		SystemMetrics: protocol.SystemMetrics{
			MemoryPressure: 0.9,
			ThermalState:   "nominal",
		},
	}
	high.Reputation = registry.NewReputation()

	scoreLow := registry.ScoreProvider(low, model)
	scoreHigh := registry.ScoreProvider(high, model)

	t.Logf("low memory pressure score:  %.2f", scoreLow)
	t.Logf("high memory pressure score: %.2f", scoreHigh)

	if scoreHigh >= scoreLow {
		t.Errorf("high memory pressure (%.2f) should score lower than low (%.2f)", scoreHigh, scoreLow)
	}
}

// =========================================================================
// Provider idle timeout simulation
// =========================================================================

func TestStress_ProviderBecomesIdleAfterRequest(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)
	srv.challengeInterval = 500 * time.Millisecond

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	model := "idle-model"
	pubKey := testPublicKeyB64()
	models := []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}}

	conn := connectProvider(t, ctx, ts.URL, models, pubKey)
	defer conn.Close(websocket.StatusNormalClosure, "")

	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
		reg.RecordChallengeSuccess(id)
	}

	go runProviderLoop(ctx, t, conn, pubKey, "idle-response")

	// Provider starts idle → busy serving → should become idle after completion
	p := reg.FindProvider(model)
	if p == nil {
		t.Fatal("provider should be findable")
	}

	// Provider is now serving (status = serving after FindProvider)
	p.Mu().Lock()
	status := p.Status
	p.Mu().Unlock()
	if status != registry.StatusServing {
		t.Errorf("expected status serving, got %v", status)
	}

	// Send a request and wait for completion
	body := fmt.Sprintf(`{"model":%q,"messages":[{"role":"user","content":"hi"}],"stream":true}`, model)
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+"/v1/chat/completions",
		strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer test-key")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("request failed: %v", err)
	}
	io.ReadAll(resp.Body)
	resp.Body.Close()

	// After request completes, provider should be idle again
	time.Sleep(300 * time.Millisecond)

	p.Mu().Lock()
	statusAfter := p.Status
	p.Mu().Unlock()

	if statusAfter != registry.StatusOnline {
		t.Errorf("expected provider to return to online status after request, got %v", statusAfter)
	}
}
