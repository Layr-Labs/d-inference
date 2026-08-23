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

	fixture := newProviderWSFixture(t, ctx, ts.URL, reg, protocol.RegisterMessage{
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
	})
	defer fixture.Close(websocket.StatusNormalClosure, "done")

	if got := reg.ProviderCount(); got != 1 {
		t.Fatalf("provider count = %d, want 1", got)
	}

	// Send heartbeat.
	hbMsg := protocol.HeartbeatMessage{
		Type:   protocol.TypeHeartbeat,
		Status: "idle",
		Stats:  protocol.HeartbeatStats{RequestsServed: 1, TokensGenerated: 100},
	}
	fixture.WriteJSON(hbMsg)
	p := reg.GetProvider(fixture.providerID)
	awaitTestCondition(t, ctx, "heartbeat state", func() bool {
		p.Mu().Lock()
		defer p.Mu().Unlock()
		return p.Stats.RequestsServed == 1 && p.Stats.TokensGenerated == 100
	})
}

func TestProviderHeartbeatBeforeRegistrationIsRejected(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	reg := registry.New(logger)
	srv := NewServer(
		reg,
		store.NewMemory(store.Config{AdminKey: "test-key"}),
		ServerConfig{},
		logger,
	)

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

	heartbeat, err := json.Marshal(protocol.HeartbeatMessage{
		Type:   protocol.TypeHeartbeat,
		Status: "idle",
	})
	if err != nil {
		t.Fatalf("marshal heartbeat: %v", err)
	}
	if err := conn.Write(ctx, websocket.MessageText, heartbeat); err != nil {
		t.Fatalf("write heartbeat: %v", err)
	}

	_, _, err = conn.Read(ctx)
	if status := websocket.CloseStatus(err); status != websocket.StatusPolicyViolation {
		t.Fatalf("close status = %v, want %v; error=%v", status, websocket.StatusPolicyViolation, err)
	}
	if reg.ProviderCount() != 0 {
		t.Fatalf("provider count = %d, want 0", reg.ProviderCount())
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

	for range 2 {
		fixture := newTestProviderWS(t, ctx, ts.URL, reg,
			[]protocol.ModelInfo{{ID: "shared-model", ModelType: "chat", Quantization: "4bit"}},
			testPublicKeyB64())
		defer fixture.Close(websocket.StatusNormalClosure, "")
	}

	if got := reg.ProviderCount(); got != 2 {
		t.Fatalf("provider count = %d, want 2", got)
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

	pubKey := testPublicKeyB64()
	fixture := newTestProviderWS(t, ctx, ts.URL, reg,
		[]protocol.ModelInfo{{ID: "error-model", ModelType: "chat", Quantization: "4bit"}},
		pubKey)
	defer fixture.Close(websocket.StatusNormalClosure, "")
	reg.SetTrustLevel(fixture.providerID, registry.TrustHardware)
	reg.RecordChallengeSuccess(fixture.providerID)

	// Provider goroutine — handle challenges and always respond with error
	// for inference requests. Loops to handle retry attempts from the coordinator.
	go func() {
		for {
			_, data, err := fixture.Conn.Read(ctx)
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
				fixture.Conn.Write(ctx, websocket.MessageText, respData)
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
				fixture.Conn.Write(ctx, websocket.MessageText, errData)
			}
		}
	}()

	// Consumer request.
	chatBody := `{"model":"error-model","messages":[{"role":"user","content":"hi"}],"stream":false}`
	httpReq := newAuthRequest(t, ctx, ts.URL+"/v1/chat/completions", chatBody, "test-key")

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
	deliverError := func(requestID, errText string, status int, failureCode protocol.InferenceFailureCode) {
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
			Type:        protocol.TypeInferenceError,
			RequestID:   requestID,
			Error:       errText,
			StatusCode:  status,
			FailureCode: failureCode,
		})
	}

	// Capacity rejections must NOT be penalised:
	//   - 503 service unavailable (e.g. provider pre-accept reject)
	//   - 429 too many requests
	//   - token_budget_exhausted (carried in the error message, status 200)
	//   - "insufficient memory" message even on a 500 (case-insensitive)
	deliverError("req-503", "insufficient memory to load model 'cap-model'", http.StatusServiceUnavailable, protocol.FailureCodeCapacity)
	deliverError("req-429", "rate limited", http.StatusTooManyRequests, protocol.FailureCodeCapacity)
	deliverError("req-budget", "token_budget_exhausted", http.StatusOK, protocol.FailureCodeCapacity)
	deliverError("req-oom-500", "Insufficient memory (78.9 GB free, need 93.7 GB)", http.StatusInternalServerError, protocol.FailureCodeCapacity)

	if got := p.Reputation.FailedJobs; got != 0 {
		t.Fatalf("after capacity rejections: FailedJobs = %d, want 0 (no reputation penalty)", got)
	}
	if got := p.Reputation.TotalJobs; got != 0 {
		t.Fatalf("after capacity rejections: TotalJobs = %d, want 0", got)
	}

	// A genuine provider fault (500, no capacity keywords) still penalises.
	deliverError("req-fault-500", "model crashed during generation", http.StatusInternalServerError, protocol.FailureCodeGenerationFailure)

	if got := p.Reputation.FailedJobs; got != 1 {
		t.Fatalf("after genuine fault: FailedJobs = %d, want 1", got)
	}
	if got := p.Reputation.TotalJobs; got != 1 {
		t.Fatalf("after genuine fault: TotalJobs = %d, want 1", got)
	}
}

func TestHandleInferenceErrorPreservesModelLoadCategories(t *testing.T) {
	cases := []struct {
		name         string
		failureCode  protocol.InferenceFailureCode
		statusCode   int
		wantFailures int
	}{
		{"missing model", protocol.FailureCodeModelUnavailable, http.StatusNotFound, 0},
		{"transient load pressure", protocol.FailureCodeCapacity, http.StatusServiceUnavailable, 0},
		{"genuine provider load fault", protocol.FailureCodeInternalFailure, http.StatusInternalServerError, 1},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			logger := slog.New(slog.NewTextHandler(io.Discard, &slog.HandlerOptions{Level: slog.LevelError}))
			reg := registry.New(logger)
			srv := NewServer(reg, store.NewMemory(store.Config{AdminKey: "test-key"}), ServerConfig{}, logger)
			model := "load-category-model"
			provider := registerBuildsProvider(srv, "provider-"+tc.name, model)

			pending := &registry.PendingRequest{
				RequestID:          "req-load-category",
				Model:              model,
				RequestedMaxTokens: 128,
				ChunkCh:            make(chan string, 1),
				CompleteCh:         make(chan protocol.UsageInfo, 1),
				ErrorCh:            make(chan protocol.InferenceErrorMessage, 1),
			}
			selected, _ := reg.ReserveProviderEx(model, pending)
			if selected == nil || selected.ID != provider.ID {
				t.Fatal("routable provider fixture was not selected before the load failure")
			}

			srv.handleInferenceError(provider.ID, provider, &protocol.InferenceErrorMessage{
				Type:        protocol.TypeInferenceError,
				RequestID:   pending.RequestID,
				Error:       "UNTRUSTED_LOAD_DETAIL",
				StatusCode:  tc.statusCode,
				ErrorReason: errorReasonModelLoad,
				FailureCode: tc.failureCode,
			})

			select {
			case delivered := <-pending.ErrorCh:
				if delivered.FailureCode != tc.failureCode ||
					delivered.StatusCode != tc.statusCode ||
					delivered.ErrorReason != errorReasonModelLoad {
					t.Fatalf("delivered load failure = %+v, want code=%q status=%d reason=%q",
						delivered, tc.failureCode, tc.statusCode, errorReasonModelLoad)
				}
			default:
				t.Fatal("model-load terminal was not delivered")
			}
			if got := provider.Reputation.FailedJobs; got != tc.wantFailures {
				t.Fatalf("FailedJobs = %d, want %d", got, tc.wantFailures)
			}
			if got := provider.Reputation.TotalJobs; got != tc.wantFailures {
				t.Fatalf("TotalJobs = %d, want %d", got, tc.wantFailures)
			}

			coolingRequest := &registry.PendingRequest{
				RequestID: "req-load-category-cooling",
				Model:     model, RequestedMaxTokens: 128,
			}
			if selected, _ := reg.ReserveProviderEx(model, coolingRequest); selected != nil {
				t.Fatal("provider/model pair remained routable during its load-failure cooldown")
			}
			reg.ClearDispatchLoadCooldown(provider.ID, model)
			recoveredRequest := &registry.PendingRequest{
				RequestID: "req-load-category-recovered",
				Model:     model, RequestedMaxTokens: 128,
			}
			if selected, _ := reg.ReserveProviderEx(model, recoveredRequest); selected == nil {
				t.Fatal("provider did not become routable after clearing the load-failure cooldown")
			} else {
				selected.RemovePending(recoveredRequest.RequestID)
			}
		})
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
