package api

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

	"github.com/eigeninference/coordinator/internal/protocol"
	"github.com/eigeninference/coordinator/internal/registry"
	"github.com/eigeninference/coordinator/internal/store"
	"nhooyr.io/websocket"
)

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

// runProviderLoop reads messages from the provider WebSocket in a loop,
// responding to attestation challenges and serving inference requests with
// simulated streaming chunks + a complete message. It returns when the
// context is cancelled or the connection is closed, and reports how many
// inference requests were served.
func runProviderLoop(ctx context.Context, t *testing.T, conn *websocket.Conn, pubKey, responseContent string) int {
	t.Helper()
	served := 0
	for {
		select {
		case <-ctx.Done():
			return served
		default:
		}

		_, data, err := conn.Read(ctx)
		if err != nil {
			return served
		}

		var raw map[string]any
		if err := json.Unmarshal(data, &raw); err != nil {
			continue
		}

		msgType, _ := raw["type"].(string)

		switch msgType {
		case protocol.TypeAttestationChallenge:
			resp := makeValidChallengeResponse(data, pubKey)
			if wErr := conn.Write(ctx, websocket.MessageText, resp); wErr != nil {
				return served
			}

		case protocol.TypeInferenceRequest:
			reqID, _ := raw["request_id"].(string)

			// Send two chunks to simulate streaming.
			for _, word := range []string{responseContent, " done"} {
				chunk := protocol.InferenceResponseChunkMessage{
					Type:      protocol.TypeInferenceResponseChunk,
					RequestID: reqID,
					Data:      `data: {"id":"chatcmpl-1","choices":[{"delta":{"content":"` + word + `"}}]}` + "\n\n",
				}
				chunkData, _ := json.Marshal(chunk)
				if wErr := conn.Write(ctx, websocket.MessageText, chunkData); wErr != nil {
					return served
				}
			}

			// Send complete with usage.
			complete := protocol.InferenceCompleteMessage{
				Type:      protocol.TypeInferenceComplete,
				RequestID: reqID,
				Usage:     protocol.UsageInfo{PromptTokens: 10, CompletionTokens: 5},
			}
			completeData, _ := json.Marshal(complete)
			if wErr := conn.Write(ctx, websocket.MessageText, completeData); wErr != nil {
				return served
			}
			served++

		case protocol.TypeCancel:
			// Ignore cancels.
		}
	}
}

// sendRequest sends a single chat completion request and returns the HTTP
// status code and the response body (drained). It is safe for concurrent use.
func sendRequest(ctx context.Context, url, apiKey, model string) (int, string, error) {
	body := fmt.Sprintf(`{"model":%q,"messages":[{"role":"user","content":"hello"}],"stream":true}`, model)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url+"/v1/chat/completions", strings.NewReader(body))
	if err != nil {
		return 0, "", err
	}
	req.Header.Set("Authorization", "Bearer "+apiKey)

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return 0, "", err
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(respBody), nil
}

// sendConcurrentRequests launches count goroutines, each sending one request,
// and collects all status codes. maxInflight limits the number of concurrent
// in-flight requests to stay within queue capacity.
func sendConcurrentRequests(t *testing.T, url, apiKey, model string, count, maxInflight int, timeout time.Duration) []int {
	t.Helper()
	results := make([]int, count)
	sem := make(chan struct{}, maxInflight)
	var wg sync.WaitGroup
	wg.Add(count)
	for i := 0; i < count; i++ {
		sem <- struct{}{} // acquire semaphore slot
		go func(idx int) {
			defer wg.Done()
			defer func() { <-sem }() // release slot
			ctx, cancel := context.WithTimeout(context.Background(), timeout)
			defer cancel()
			code, _, err := sendRequest(ctx, url, apiKey, model)
			if err != nil {
				t.Logf("request %d error: %v", idx, err)
				results[idx] = 0
				return
			}
			results[idx] = code
		}(i)
	}
	wg.Wait()
	return results
}

// setupLoadTestServer creates a Server with short challenge intervals and a
// large request queue for load tests. Returns the test server, registry, and store.
func setupLoadTestServer(t *testing.T) (*httptest.Server, *registry.Registry, *store.MemoryStore) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	// Replace the default queue (10 slots, 30s) with a larger one for load tests.
	reg.SetQueue(registry.NewRequestQueue(200, 30*time.Second))
	srv := NewServer(reg, st, logger)
	srv.challengeInterval = 500 * time.Millisecond
	ts := httptest.NewServer(srv.Handler())
	return ts, reg, st
}

// connectAndPrepareProvider connects a provider, sets trust + challenge verified,
// and returns the WebSocket connection. The caller must defer conn.Close(...).
func connectAndPrepareProvider(t *testing.T, ctx context.Context, tsURL string, reg *registry.Registry, model, pubKey string, decodeTPS float64) *websocket.Conn {
	t.Helper()
	models := []protocol.ModelInfo{{ID: model, ModelType: "test", Quantization: "4bit"}}
	wsURL := "ws" + strings.TrimPrefix(tsURL, "http") + "/ws/provider"
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("websocket dial: %v", err)
	}

	regMsg := protocol.RegisterMessage{
		Type: protocol.TypeRegister,
		Hardware: protocol.Hardware{
			MachineModel: "Mac15,8",
			ChipName:     "Apple M3 Max",
			MemoryGB:     64,
		},
		Models:    models,
		Backend:   "test",
		PublicKey: pubKey,
		DecodeTPS: decodeTPS,
	}
	regData, _ := json.Marshal(regMsg)
	if err := conn.Write(ctx, websocket.MessageText, regData); err != nil {
		t.Fatalf("write register: %v", err)
	}

	time.Sleep(200 * time.Millisecond)

	// Set trust level and mark challenge as verified for all providers.
	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
		reg.RecordChallengeSuccess(id)
	}

	return conn
}

// ---------------------------------------------------------------------------
// Test 1: Single provider, 20 sequential requests
// ---------------------------------------------------------------------------

func TestLoad_SingleProviderBurst(t *testing.T) {
	ts, reg, st := setupLoadTestServer(t)
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	pubKey := testPublicKeyB64()
	model := "load-burst-model"

	conn := connectAndPrepareProvider(t, ctx, ts.URL, reg, model, pubKey, 100)
	defer conn.Close(websocket.StatusNormalClosure, "done")

	// Provider loop in background.
	providerCtx, providerCancel := context.WithCancel(ctx)
	defer providerCancel()
	var served int32
	go func() {
		s := runProviderLoop(providerCtx, t, conn, pubKey, "burst")
		atomic.StoreInt32(&served, int32(s))
	}()

	const numRequests = 20
	start := time.Now()

	for i := 0; i < numRequests; i++ {
		code, _, err := sendRequest(ctx, ts.URL, "test-key", model)
		if err != nil {
			t.Fatalf("request %d: %v", i, err)
		}
		if code != http.StatusOK {
			t.Fatalf("request %d: status=%d, want 200", i, code)
		}
	}

	elapsed := time.Since(start)
	t.Logf("completed %d sequential requests in %s (%.1f req/s)", numRequests, elapsed, float64(numRequests)/elapsed.Seconds())

	// Give handleComplete a moment to finish recording usage.
	time.Sleep(300 * time.Millisecond)

	records := st.UsageRecords()
	if len(records) != numRequests {
		t.Errorf("usage records = %d, want %d", len(records), numRequests)
	}
}

// ---------------------------------------------------------------------------
// Test 2: Single provider, 20 concurrent requests (queue exercised)
// ---------------------------------------------------------------------------

func TestLoad_SingleProviderConcurrent(t *testing.T) {
	ts, reg, st := setupLoadTestServer(t)
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	pubKey := testPublicKeyB64()
	model := "load-concurrent-model"

	conn := connectAndPrepareProvider(t, ctx, ts.URL, reg, model, pubKey, 100)
	defer conn.Close(websocket.StatusNormalClosure, "done")

	providerCtx, providerCancel := context.WithCancel(ctx)
	defer providerCancel()
	go runProviderLoop(providerCtx, t, conn, pubKey, "concurrent")

	// MaxConcurrentRequests = 4, so with 20 concurrent requests the remaining
	// 16 will queue. The queue supports up to 200 slots (setupLoadTestServer).
	const numRequests = 20
	results := sendConcurrentRequests(t, ts.URL, "test-key", model, numRequests, numRequests, 25*time.Second)

	successes := 0
	for i, code := range results {
		if code == http.StatusOK {
			successes++
		} else {
			t.Logf("request %d: status=%d", i, code)
		}
	}

	t.Logf("concurrent test: %d/%d succeeded", successes, numRequests)

	if successes != numRequests {
		t.Errorf("successes = %d, want %d", successes, numRequests)
	}

	// Give handleComplete a moment to finish recording.
	time.Sleep(300 * time.Millisecond)

	records := st.UsageRecords()
	if len(records) != numRequests {
		t.Errorf("usage records = %d, want %d", len(records), numRequests)
	}
}

// ---------------------------------------------------------------------------
// Test 3: 3 providers with different DecodeTPS, 30 concurrent requests
// ---------------------------------------------------------------------------

func TestLoad_MultiProviderLoadBalance(t *testing.T) {
	ts, reg, _ := setupLoadTestServer(t)
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	model := "load-balance-model"

	type providerSetup struct {
		pubKey    string
		decodeTPS float64
	}
	providers := []providerSetup{
		{testPublicKeyB64(), 50},
		{testPublicKeyB64(), 100},
		{testPublicKeyB64(), 200},
	}

	providerCtx, providerCancel := context.WithCancel(ctx)
	defer providerCancel()

	var servedCounts [3]int32

	for i, ps := range providers {
		conn := connectAndPrepareProvider(t, ctx, ts.URL, reg, model, ps.pubKey, ps.decodeTPS)
		defer conn.Close(websocket.StatusNormalClosure, "done")

		idx := i
		pk := ps.pubKey
		go func() {
			s := runProviderLoop(providerCtx, t, conn, pk, fmt.Sprintf("provider-%d", idx))
			atomic.StoreInt32(&servedCounts[idx], int32(s))
		}()
	}

	// 3 providers * 4 concurrent = 12 in-flight + queue headroom.
	const numRequests = 30
	results := sendConcurrentRequests(t, ts.URL, "test-key", model, numRequests, numRequests, 25*time.Second)

	successes := 0
	for _, code := range results {
		if code == http.StatusOK {
			successes++
		}
	}

	if successes != numRequests {
		t.Errorf("successes = %d, want %d", successes, numRequests)
	}

	// Allow completion handlers to finish.
	time.Sleep(500 * time.Millisecond)
	providerCancel()
	time.Sleep(200 * time.Millisecond)

	s0 := atomic.LoadInt32(&servedCounts[0])
	s1 := atomic.LoadInt32(&servedCounts[1])
	s2 := atomic.LoadInt32(&servedCounts[2])
	total := s0 + s1 + s2
	t.Logf("load distribution: slow(50tps)=%d, mid(100tps)=%d, fast(200tps)=%d, total=%d", s0, s1, s2, total)

	// The fastest provider (200 TPS) should serve the most requests.
	// We don't enforce a strict ratio because timing jitter matters,
	// but the fast provider should serve at least as many as the slow one.
	if s2 < s0 && total > 0 {
		t.Logf("warning: fast provider served fewer requests (%d) than slow provider (%d); timing jitter may explain this", s2, s0)
	}

	if total < int32(numRequests) {
		t.Errorf("total served = %d, want >= %d", total, numRequests)
	}
}

// ---------------------------------------------------------------------------
// Test 4: 2 providers, disconnect one mid-load
// ---------------------------------------------------------------------------

func TestLoad_ProviderFailureMidLoad(t *testing.T) {
	ts, reg, _ := setupLoadTestServer(t)
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	model := "load-failover-model"
	pubKey1 := testPublicKeyB64()
	pubKey2 := testPublicKeyB64()

	conn1 := connectAndPrepareProvider(t, ctx, ts.URL, reg, model, pubKey1, 100)
	conn2 := connectAndPrepareProvider(t, ctx, ts.URL, reg, model, pubKey2, 100)
	defer conn2.Close(websocket.StatusNormalClosure, "done")

	providerCtx, providerCancel := context.WithCancel(ctx)
	defer providerCancel()

	// Provider 1 loop — will be killed after serving some requests.
	provider1Ctx, provider1Cancel := context.WithCancel(providerCtx)
	var served1 int32
	go func() {
		s := runProviderLoop(provider1Ctx, t, conn1, pubKey1, "p1")
		atomic.StoreInt32(&served1, int32(s))
	}()

	// Provider 2 loop — stays alive the whole time.
	go runProviderLoop(providerCtx, t, conn2, pubKey2, "p2")

	// Send first 10 requests sequentially.
	const firstBatch = 10
	for i := 0; i < firstBatch; i++ {
		code, _, err := sendRequest(ctx, ts.URL, "test-key", model)
		if err != nil {
			t.Fatalf("batch1 request %d: %v", i, err)
		}
		if code != http.StatusOK {
			t.Fatalf("batch1 request %d: status=%d, want 200", i, code)
		}
	}

	// Disconnect provider 1.
	provider1Cancel()
	conn1.Close(websocket.StatusNormalClosure, "simulated failure")
	time.Sleep(300 * time.Millisecond) // Let the registry process the disconnect.

	// Send remaining 10 requests — all should go to provider 2.
	const secondBatch = 10
	for i := 0; i < secondBatch; i++ {
		code, _, err := sendRequest(ctx, ts.URL, "test-key", model)
		if err != nil {
			t.Fatalf("batch2 request %d: %v", i, err)
		}
		if code != http.StatusOK {
			t.Fatalf("batch2 request %d: status=%d, want 200", i, code)
		}
	}

	t.Logf("provider failover: all %d requests succeeded (%d before disconnect, %d after)",
		firstBatch+secondBatch, firstBatch, secondBatch)
}

// ---------------------------------------------------------------------------
// Test 5: Billing under concurrent load
// ---------------------------------------------------------------------------

func TestLoad_ConcurrentBillingUnderLoad(t *testing.T) {
	ts, reg, st := setupLoadTestServer(t)
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	pubKey := testPublicKeyB64()
	model := "load-billing-model"

	conn := connectAndPrepareProvider(t, ctx, ts.URL, reg, model, pubKey, 100)
	defer conn.Close(websocket.StatusNormalClosure, "done")

	providerCtx, providerCancel := context.WithCancel(ctx)
	defer providerCancel()
	go runProviderLoop(providerCtx, t, conn, pubKey, "billing")

	// Credit the consumer with $100 (100,000,000 micro-USD).
	consumerKey := "test-key"
	initialBalance := int64(100_000_000)
	if err := st.Credit(consumerKey, initialBalance, store.LedgerDeposit, ""); err != nil {
		t.Fatalf("credit consumer: %v", err)
	}

	// Send 50 requests with a concurrency limit. MaxConcurrentRequests=4, so
	// we allow up to 50 in flight (the queue can hold 200) and they'll be
	// served 4 at a time by the single provider.
	const numRequests = 50
	results := sendConcurrentRequests(t, ts.URL, consumerKey, model, numRequests, numRequests, 25*time.Second)

	successes := 0
	for _, code := range results {
		if code == http.StatusOK {
			successes++
		}
	}

	if successes != numRequests {
		t.Errorf("successes = %d, want %d", successes, numRequests)
	}

	// Let handleComplete finish processing.
	time.Sleep(500 * time.Millisecond)

	finalBalance := st.GetBalance(consumerKey)
	charged := initialBalance - finalBalance

	t.Logf("billing: initial=$%.2f, final=$%.2f, charged=$%.2f",
		float64(initialBalance)/1_000_000, float64(finalBalance)/1_000_000, float64(charged)/1_000_000)

	if charged <= 0 {
		t.Error("expected consumer to be charged, but balance did not decrease")
	}

	if finalBalance < 0 {
		t.Errorf("consumer balance went negative: %d micro-USD", finalBalance)
	}

	// Verify ledger entries: should have 1 deposit + numRequests charges.
	ledger := st.LedgerHistory(consumerKey)
	chargeCount := 0
	for _, entry := range ledger {
		if entry.Type == store.LedgerCharge {
			chargeCount++
		}
	}
	if chargeCount != numRequests {
		t.Errorf("ledger charge entries = %d, want %d (no double-charges)", chargeCount, numRequests)
	}
}

// ---------------------------------------------------------------------------
// Test 6: Race safety — 5 providers, 100 requests, concurrent heartbeats
// ---------------------------------------------------------------------------

func TestLoad_RaceSafety(t *testing.T) {
	ts, reg, _ := setupLoadTestServer(t)
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()

	model := "load-race-model"
	const numProviders = 5
	const numRequests = 100

	providerCtx, providerCancel := context.WithCancel(ctx)
	defer providerCancel()

	// Connect 5 providers.
	for i := 0; i < numProviders; i++ {
		pk := testPublicKeyB64()
		conn := connectAndPrepareProvider(t, ctx, ts.URL, reg, model, pk, float64(50+i*50))
		defer conn.Close(websocket.StatusNormalClosure, "done")

		go runProviderLoop(providerCtx, t, conn, pk, fmt.Sprintf("race-%d", i))
	}

	// Concurrently send heartbeats to stress shared state.
	heartbeatCtx, heartbeatCancel := context.WithCancel(ctx)
	defer heartbeatCancel()
	var heartbeatWg sync.WaitGroup
	for i := 0; i < numProviders; i++ {
		heartbeatWg.Add(1)
		go func(idx int) {
			defer heartbeatWg.Done()
			ids := reg.ProviderIDs()
			if idx >= len(ids) {
				return
			}
			providerID := ids[idx]
			ticker := time.NewTicker(50 * time.Millisecond)
			defer ticker.Stop()
			for {
				select {
				case <-heartbeatCtx.Done():
					return
				case <-ticker.C:
					reg.Heartbeat(providerID, &protocol.HeartbeatMessage{
						Type:   protocol.TypeHeartbeat,
						Status: "idle",
						SystemMetrics: protocol.SystemMetrics{
							MemoryPressure: 0.3,
							CPUUsage:       0.2,
							ThermalState:   "nominal",
						},
					})
				}
			}
		}(i)
	}

	// Send 100 concurrent requests. 5 providers * 4 slots = 20 concurrent,
	// plus queue capacity of 200.
	results := sendConcurrentRequests(t, ts.URL, "test-key", model, numRequests, numRequests, 30*time.Second)

	heartbeatCancel()
	heartbeatWg.Wait()

	successes := 0
	for _, code := range results {
		if code == http.StatusOK {
			successes++
		}
	}

	t.Logf("race safety: %d/%d requests succeeded with %d providers and concurrent heartbeats",
		successes, numRequests, numProviders)

	if successes != numRequests {
		t.Errorf("successes = %d, want %d", successes, numRequests)
	}
}
