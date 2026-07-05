package api

import (
	"context"
	"encoding/json"
	"io"
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

func TestProviderWebSocketConnect(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("websocket dial: %v", err)
	}
	defer conn.Close(websocket.StatusNormalClosure, "")

	// Send register.
	regMsg := protocol.RegisterMessage{
		Type: protocol.TypeRegister,
		Hardware: protocol.Hardware{
			MachineModel: "Mac15,8",
			ChipName:     "Apple M3 Max",
			MemoryGB:     64,
		},
		Models: []protocol.ModelInfo{
			{ID: "test-model", SizeBytes: 1000, ModelType: "chat", Quantization: "4bit"},
		},
		Backend: "mlx-swift",
	}
	regData, _ := json.Marshal(regMsg)
	if err := conn.Write(ctx, websocket.MessageText, regData); err != nil {
		t.Fatalf("write register: %v", err)
	}

	// Wait for registration.
	time.Sleep(100 * time.Millisecond)

	if reg.ProviderCount() != 1 {
		t.Errorf("provider count = %d, want 1", reg.ProviderCount())
	}

	// Send heartbeat.
	hbMsg := protocol.HeartbeatMessage{
		Type:   protocol.TypeHeartbeat,
		Status: "idle",
		Stats:  protocol.HeartbeatStats{RequestsServed: 1, TokensGenerated: 100},
	}
	hbData, _ := json.Marshal(hbMsg)
	if err := conn.Write(ctx, websocket.MessageText, hbData); err != nil {
		t.Fatalf("write heartbeat: %v", err)
	}

	time.Sleep(100 * time.Millisecond)

	// Close connection and verify disconnect.
	conn.Close(websocket.StatusNormalClosure, "done")
	time.Sleep(200 * time.Millisecond)

	if reg.ProviderCount() != 0 {
		t.Errorf("provider count after disconnect = %d, want 0", reg.ProviderCount())
	}
}

func TestProviderWebSocketMultiple(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"

	// Connect two providers.
	for i := range 2 {
		conn, _, err := websocket.Dial(ctx, wsURL, nil)
		if err != nil {
			t.Fatalf("websocket dial %d: %v", i, err)
		}
		defer conn.Close(websocket.StatusNormalClosure, "")

		pubKey := testPublicKeyB64()
		regMsg := protocol.RegisterMessage{
			Type:                    protocol.TypeRegister,
			Hardware:                protocol.Hardware{ChipName: "M3 Max", MemoryGB: 64},
			Models:                  []protocol.ModelInfo{{ID: "shared-model", ModelType: "chat", Quantization: "4bit"}},
			Backend:                 "mlx-swift",
			PublicKey:               pubKey,
			EncryptedResponseChunks: true,
			PrivacyCapabilities:     testPrivacyCaps(),
		}
		regData, _ := json.Marshal(regMsg)
		conn.Write(ctx, websocket.MessageText, regData)
	}

	time.Sleep(200 * time.Millisecond)

	if reg.ProviderCount() != 2 {
		t.Errorf("provider count = %d, want 2", reg.ProviderCount())
	}

	// Upgrade both providers to hardware trust for routing eligibility.
	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
		reg.RecordChallengeSuccess(id)
	}

	models := reg.ListModels()
	if len(models) != 1 {
		t.Fatalf("models = %d, want 1 (deduplicated)", len(models))
	}
	if models[0].Providers != 2 {
		t.Errorf("providers for model = %d, want 2", models[0].Providers)
	}
}

func TestProviderInferenceError(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("websocket dial: %v", err)
	}
	defer conn.Close(websocket.StatusNormalClosure, "")

	pubKey := testPublicKeyB64()
	regMsg := protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{ChipName: "M3 Max", MemoryGB: 64},
		Models:                  []protocol.ModelInfo{{ID: "error-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:                 "mlx-swift",
		PublicKey:               pubKey,
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
	}
	regData, _ := json.Marshal(regMsg)
	conn.Write(ctx, websocket.MessageText, regData)
	time.Sleep(100 * time.Millisecond)

	// Upgrade provider to hardware trust for routing.
	p := findProviderByModel(reg, "error-model")
	if p != nil {
		reg.SetTrustLevel(p.ID, registry.TrustHardware)
		reg.RecordChallengeSuccess(p.ID)
	}

	// Provider goroutine — handle challenges and always respond with error
	// for inference requests. Loops to handle retry attempts from the coordinator.
	go func() {
		for {
			_, data, err := conn.Read(ctx)
			if err != nil {
				return
			}
			var raw map[string]interface{}
			if err := json.Unmarshal(data, &raw); err != nil {
				continue
			}
			switch raw["type"] {
			case protocol.TypeAttestationChallenge:
				respData := makeValidChallengeResponse(data, pubKey)
				conn.Write(ctx, websocket.MessageText, respData)
			case protocol.TypeInferenceRequest:
				reqID, _ := raw["request_id"].(string)
				// Assert a GENUINE provider fault (5xx) propagates to the consumer
				// unchanged. "model not loaded" is now a capacity-class cold miss
				// that reclassifies to 429, so use an unambiguous fault string to
				// exercise the fault-passthrough path.
				errMsg := protocol.InferenceErrorMessage{
					Type:       protocol.TypeInferenceError,
					RequestID:  reqID,
					Error:      "internal error",
					StatusCode: 500,
				}
				errData, _ := json.Marshal(errMsg)
				conn.Write(ctx, websocket.MessageText, errData)
			}
		}
	}()

	// Consumer request.
	chatBody := `{"model":"error-model","messages":[{"role":"user","content":"hi"}],"stream":false}`
	httpReq, _ := newAuthRequest(t, ctx, ts.URL+"/v1/chat/completions", chatBody, "test-key")

	resp, err := ts.Client().Do(httpReq)
	if err != nil {
		t.Fatalf("http request: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusInternalServerError {
		t.Errorf("status = %d, want 500", resp.StatusCode)
	}
}

// TestHandleInferenceErrorReputationCarveout verifies that capacity rejections
// (HTTP 503/429, token-budget exhaustion, out-of-memory load rejects) do NOT
// count against a provider's reputation, while a genuine provider fault (HTTP
// 500) still records a job failure. It drives handleInferenceError directly so
// the carve-out is asserted deterministically without the HTTP/WebSocket flow.
// A registry without a store keeps reputation reads race-free (no async
// persistence goroutine).
func TestHandleInferenceErrorReputationCarveout(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, &slog.HandlerOptions{Level: slog.LevelError}))
	reg := registry.New(logger)
	srv := &Server{registry: reg, logger: logger}

	regMsg := &protocol.RegisterMessage{
		Type:     protocol.TypeRegister,
		Hardware: protocol.Hardware{ChipName: "M3 Max", MemoryGB: 64},
		Models:   []protocol.ModelInfo{{ID: "cap-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:  "mlx-swift",
	}
	p := reg.Register("prov-reputation", nil, regMsg)
	if p == nil {
		t.Fatal("Register returned nil provider")
	}

	// deliverError registers a fresh pending request and routes a single
	// inference error through handleInferenceError. Channels are buffered so
	// the synchronous delivery never blocks.
	deliverError := func(requestID, errText string, status int) {
		pr := &registry.PendingRequest{
			RequestID:  requestID,
			ProviderID: p.ID,
			Model:      "cap-model",
			ChunkCh:    make(chan string, 1),
			CompleteCh: make(chan protocol.UsageInfo, 1),
			ErrorCh:    make(chan protocol.InferenceErrorMessage, 1),
		}
		p.AddPending(pr)
		srv.handleInferenceError(p.ID, p, &protocol.InferenceErrorMessage{
			Type:       protocol.TypeInferenceError,
			RequestID:  requestID,
			Error:      errText,
			StatusCode: status,
		})
	}

	// Capacity rejections must NOT be penalised:
	//   - 503 service unavailable (e.g. provider pre-accept reject)
	//   - 429 too many requests
	//   - token_budget_exhausted (carried in the error message, status 200)
	//   - "insufficient memory" message even on a 500 (case-insensitive)
	deliverError("req-503", "insufficient memory to load model 'cap-model'", http.StatusServiceUnavailable)
	deliverError("req-429", "rate limited", http.StatusTooManyRequests)
	deliverError("req-budget", "token_budget_exhausted", http.StatusOK)
	deliverError("req-oom-500", "Insufficient memory (78.9 GB free, need 93.7 GB)", http.StatusInternalServerError)

	if got := p.Reputation.FailedJobs; got != 0 {
		t.Fatalf("after capacity rejections: FailedJobs = %d, want 0 (no reputation penalty)", got)
	}
	if got := p.Reputation.TotalJobs; got != 0 {
		t.Fatalf("after capacity rejections: TotalJobs = %d, want 0", got)
	}

	// A genuine provider fault (500, no capacity keywords) still penalises.
	deliverError("req-fault-500", "model crashed during generation", http.StatusInternalServerError)

	if got := p.Reputation.FailedJobs; got != 1 {
		t.Fatalf("after genuine fault: FailedJobs = %d, want 1", got)
	}
	if got := p.Reputation.TotalJobs; got != 1 {
		t.Fatalf("after genuine fault: TotalJobs = %d, want 1", got)
	}
}

// findProviderByModel returns the first provider offering the given model.
func findProviderByModel(reg *registry.Registry, model string) *registry.Provider {
	for _, id := range reg.ProviderIDs() {
		p := reg.GetProvider(id)
		if p == nil {
			continue
		}
		for _, m := range p.Models {
			if m.ID == model {
				return p
			}
		}
	}
	return nil
}
