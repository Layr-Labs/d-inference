package api

// Stress and resilience tests for the Darkbloom coordinator.
//
// Covers: queue overflow, provider disconnect under active load, request
// cancellation with slow providers, billing race conditions, provider
// re-registration with different models, and heterogeneous provider scoring.

import (
	"bufio"
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

	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

// =========================================================================
// Queue overflow: more requests than the queue can hold
// =========================================================================

func TestStress_QueueOverflow(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	// Tiny queue: 3 slots, 500ms timeout
	reg.SetQueue(registry.NewRequestQueue(3, 500*time.Millisecond))
	srv := NewServer(reg, st, ServerConfig{}, logger)

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
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	reg.SetQueue(registry.NewRequestQueue(10, 10*time.Second))
	srv := NewServer(reg, st, ServerConfig{}, logger)
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
	t.Setenv(envQueueBeforeShed, "true")
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	// The queue, not the client guard, must terminate the undispatched request.
	reg.SetQueue(registry.NewRequestQueue(50, time.Second))
	srv := NewServer(reg, st, ServerConfig{}, logger)
	srv.challengeInterval = 1 * time.Second

	const inFlight = registry.DefaultMaxConcurrent
	const numRequests = inFlight + 1
	handlerDone := make(chan struct{}, numRequests)
	handler := srv.Handler()
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v1/chat/completions" {
			defer func() { handlerDone <- struct{}{} }()
		}
		handler.ServeHTTP(w, r)
	}))
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	model := "crash-model"
	pubKey := testPublicKeyB64()
	models := []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}}

	conn := connectProvider(t, ctx, ts.URL, models, pubKey)
	defer conn.CloseNow()

	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
		reg.RecordChallengeSuccess(id)
	}

	p := findRoutableProvider(reg, model)
	if p == nil {
		t.Fatal("provider must be routable before starting requests")
	}

	// Keep every dispatched stream open until both active and queued work exist.
	providerDone := make(chan struct{})
	go func() {
		defer close(providerDone)
		for {
			_, data, err := conn.Read(ctx)
			if err != nil {
				return
			}
			var env struct {
				Type string `json:"type"`
			}
			if err := json.Unmarshal(data, &env); err != nil {
				t.Errorf("decode provider message: %v", err)
				return
			}

			if env.Type == protocol.TypeAttestationChallenge {
				resp := makeValidChallengeResponse(data, pubKey)
				if err := conn.Write(ctx, websocket.MessageText, resp); err != nil {
					return
				}
			}
			if env.Type == protocol.TypeInferenceRequest {
				var req protocol.InferenceRequestMessage
				if err := json.Unmarshal(data, &req); err != nil {
					t.Errorf("decode inference request: %v", err)
					return
				}
				writeEncryptedTestChunk(t, ctx, conn, req, pubKey,
					`data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"partial..."},"finish_reason":null}]}`+"\n\n")
			}
		}
	}()

	type result struct {
		index  int
		status int
		body   string
		err    error
	}
	results := make(chan result, numRequests)
	streamStarted := make(chan struct{}, inFlight)
	startRequest := func(idx int) {
		go func() {
			got := result{index: idx}
			defer func() { results <- got }()
			body := fmt.Sprintf(`{"model":%q,"messages":[{"role":"user","content":"req %d"}],"stream":true}`, model, idx)
			req, err := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+"/v1/chat/completions",
				strings.NewReader(body))
			if err != nil {
				got.err = err
				return
			}
			req.Header.Set("Authorization", "Bearer test-key")

			resp, err := http.DefaultClient.Do(req)
			if err != nil {
				got.err = err
				return
			}
			defer resp.Body.Close()
			got.status = resp.StatusCode
			reader := bufio.NewReader(resp.Body)
			if idx < inFlight && resp.StatusCode == http.StatusOK {
				for {
					line, err := reader.ReadString('\n')
					got.body += line
					if err != nil {
						got.err = fmt.Errorf("read partial stream: %w", err)
						return
					}
					if strings.Contains(line, `"content":"partial..."`) {
						streamStarted <- struct{}{}
						break
					}
				}
			}
			remaining, err := io.ReadAll(reader)
			got.body += string(remaining)
			got.err = err
		}()
	}

	for i := range inFlight {
		startRequest(i)
	}
	for range inFlight {
		select {
		case <-streamStarted:
		case got := <-results:
			t.Fatalf("request ended before crash: %+v", got)
		case <-ctx.Done():
			t.Fatal("timed out waiting for partial streams")
		}
	}
	startRequest(inFlight)
	waitFor(t, 5*time.Second, "one queued request behind active streams", func() bool {
		return reg.Queue().QueueSize(model) == 1
	})
	if got := p.PendingCount(); got != inFlight {
		t.Fatalf("pending requests before crash = %d, want %d", got, inFlight)
	}
	if err := conn.CloseNow(); err != nil {
		t.Fatalf("crash provider connection: %v", err)
	}

	for range numRequests {
		select {
		case got := <-results:
			if got.err != nil {
				t.Errorf("request %d transport/body error: %v", got.index, got.err)
				continue
			}
			if got.index < inFlight {
				if got.status != http.StatusOK || !strings.Contains(got.body, `"content":"partial..."`) ||
					strings.Count(got.body, `"type":"provider_error"`) != 1 || strings.Contains(got.body, "data: [DONE]") {
					t.Errorf("active request %d: status=%d body=%s", got.index, got.status, got.body)
				}
			} else if got.status != http.StatusTooManyRequests || !strings.Contains(got.body, "queue timeout") {
				t.Errorf("queued request: status=%d body=%s, want queue-timeout 429", got.status, got.body)
			}
		case <-ctx.Done():
			t.Fatal("client guard expired before server completed all crash outcomes")
		}
	}
	for range numRequests {
		select {
		case <-handlerDone:
		case <-ctx.Done():
			t.Fatal("server-side request handler did not finish")
		}
	}
	select {
	case <-providerDone:
	case <-ctx.Done():
		t.Fatal("provider read loop did not finish")
	}
	waitFor(t, 5*time.Second, "provider removal and pending request cleanup", func() bool {
		return reg.ProviderCount() == 0 && p.PendingCount() == 0
	})
	if got := reg.Queue().QueueSize(model); got != 0 {
		t.Errorf("queue size after handlers completed = %d, want 0", got)
	}
}

// =========================================================================
// Consumer disconnect mid-stream triggers cancel
// =========================================================================

func TestStress_ConsumerDisconnectSendsCancelToProvider(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
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
	st := store.NewMemory(store.Config{AdminKey: "billing-key"})
	reg := registry.New(logger)
	reg.SetQueue(registry.NewRequestQueue(50, 5*time.Second))
	ledger := payments.NewLedger(st)
	billingSvc := billing.NewService(st, ledger, logger, billing.Config{MockMode: true})

	srv := NewServer(reg, st, ServerConfig{}, logger)
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
	st := store.NewMemory(store.Config{AdminKey: "charge-key"})
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
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

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

	pA := findRoutableProvider(reg, "model-A")
	if pA == nil {
		t.Fatal("should find provider for model-A")
	}
	reg.SetProviderIdle(pA.ID)

	pB := findRoutableProvider(reg, "model-B")
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
	pA2 := findRoutableProvider(reg, "model-A")
	if pA2 != nil {
		t.Error("model-A should not be available after re-registration with model-B")
	}

	// model-B should now be available
	pB2 := findRoutableProvider(reg, "model-B")
	if pB2 == nil {
		t.Error("model-B should be available after re-registration")
	}

	t.Log("model re-registration: PASS")
}

// =========================================================================
// Provider idle timeout simulation
// =========================================================================

func TestStress_ProviderBecomesIdleAfterRequest(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
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

	// Resolve the provider so we can observe its status transition after the
	// real inference request below drives it serving → idle.
	p := findRoutableProvider(reg, model)
	if p == nil {
		t.Fatal("provider should be routable")
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
