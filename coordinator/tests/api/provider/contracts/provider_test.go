package provider_test

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

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/testkit"
	"nhooyr.io/websocket"
)

func TestProviderWebSocketConnect(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := api.NewServer(reg, st, api.ServerConfig{}, logger)

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

func TestProviderWebSocketRejectsSecondRegisterAndAllowsReconnect(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	reg := registry.New(logger)
	srv := api.NewServer(
		reg,
		memory.NewMemory(store.Config{AdminKey: "test-key"}),
		api.ServerConfig{},
		logger,
	)
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatal(err)
	}

	first := protocol.RegisterMessage{
		Type:     protocol.TypeRegister,
		Hardware: protocol.Hardware{ChipFamily: "M4"},
		Models:   []protocol.ModelInfo{{ID: "ordinary-model"}},
		Backend:  "mlx-swift",
	}
	firstData, _ := json.Marshal(first)
	if err := conn.Write(ctx, websocket.MessageText, firstData); err != nil {
		t.Fatal(err)
	}
	time.Sleep(100 * time.Millisecond)
	ids := reg.ProviderIDs()
	if len(ids) != 1 {
		t.Fatalf("provider IDs after first register = %v", ids)
	}
	registered := reg.GetProvider(ids[0])
	if registered == nil {
		t.Fatal("first registration missing")
	}

	second := first
	second.Hardware.ChipFamily = "M5"
	second.Models = []protocol.ModelInfo{{ID: registry.Qwen38NAXModelID}}
	second.RuntimeCapabilities = []string{
		registry.ProviderCapabilityAppleM5,
		registry.ProviderCapabilityMLXNAX,
	}
	secondData, _ := json.Marshal(second)
	if err := conn.Write(ctx, websocket.MessageText, secondData); err != nil {
		t.Fatal(err)
	}
	readCtx, readCancel := context.WithTimeout(ctx, 2*time.Second)
	defer readCancel()
	for {
		_, _, err = conn.Read(readCtx)
		if err == nil {
			// Registration starts the attestation challenge loop. Drain any
			// already-enqueued challenge frame before observing the policy close.
			continue
		}
		if status := websocket.CloseStatus(err); status != websocket.StatusPolicyViolation {
			t.Fatalf("duplicate-register close status = %v, want policy violation; error=%v",
				status, err)
		}
		break
	}
	registered.Mu().Lock()
	if len(registered.Models) != 1 || registered.Models[0].ID != "ordinary-model" ||
		len(registered.ReportedRuntimeCapabilities) != 0 {
		t.Fatalf("duplicate register replaced state: models=%v capabilities=%v",
			registered.Models, registered.ReportedRuntimeCapabilities)
	}
	registered.Mu().Unlock()
	time.Sleep(100 * time.Millisecond)

	reconnect, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer reconnect.Close(websocket.StatusNormalClosure, "")
	reconnectMsg := first
	reconnectMsg.Models = []protocol.ModelInfo{{ID: "reconnected-model"}}
	reconnectData, _ := json.Marshal(reconnectMsg)
	if err := reconnect.Write(ctx, websocket.MessageText, reconnectData); err != nil {
		t.Fatal(err)
	}
	time.Sleep(100 * time.Millisecond)
	if reg.ProviderCount() != 1 {
		t.Fatalf("provider count after legitimate reconnect = %d, want 1",
			reg.ProviderCount())
	}
}

func TestProviderHeartbeatBeforeRegistrationIsRejected(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	reg := registry.New(logger)
	srv := api.NewServer(
		reg,
		memory.NewMemory(store.Config{AdminKey: "test-key"}),
		api.ServerConfig{},
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
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := api.NewServer(reg, st, api.ServerConfig{}, logger)

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

		pubKey := testkit.PublicKeyB64()
		regMsg := protocol.RegisterMessage{
			Type:                    protocol.TypeRegister,
			Hardware:                protocol.Hardware{ChipName: "M3 Max", MemoryGB: 64},
			Models:                  []protocol.ModelInfo{{ID: "shared-model", ModelType: "chat", Quantization: "4bit"}},
			Backend:                 "mlx-swift",
			PublicKey:               pubKey,
			EncryptedResponseChunks: true,
			PrivacyCapabilities:     testkit.PrivacyCaps(),
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
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := api.NewServer(reg, st, api.ServerConfig{}, logger)

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

	pubKey := testkit.PublicKeyB64()
	regMsg := protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{ChipName: "M3 Max", MemoryGB: 64},
		Models:                  []protocol.ModelInfo{{ID: "error-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:                 "mlx-swift",
		PublicKey:               pubKey,
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testkit.PrivacyCaps(),
	}
	regData, _ := json.Marshal(regMsg)
	conn.Write(ctx, websocket.MessageText, regData)
	time.Sleep(100 * time.Millisecond)

	// Upgrade provider to hardware trust for routing.
	p := testkit.FindProviderByModel(reg, "error-model")
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
				respData := testkit.MakeValidChallengeResponse(data, pubKey)
				conn.Write(ctx, websocket.MessageText, respData)
			case protocol.TypeInferenceRequest:
				reqID, _ := raw["request_id"].(string)
				// Assert a GENUINE provider fault (5xx) propagates to the consumer
				// unchanged. "model not loaded" is now a capacity-class cold miss
				// that reclassifies to 429, so use an unambiguous fault string to
				// exercise the fault-passthrough path.
				errMsg := protocol.InferenceErrorMessage{
					Type:        protocol.TypeInferenceError,
					RequestID:   reqID,
					Error:       "internal error",
					StatusCode:  500,
					FailureCode: protocol.FailureCodeGenerationFailure,
				}
				errData, _ := json.Marshal(errMsg)
				conn.Write(ctx, websocket.MessageText, errData)
			}
		}
	}()

	// Consumer request.
	chatBody := `{"model":"error-model","messages":[{"role":"user","content":"hi"}],"stream":false}`
	httpReq, _ := testkit.NewAuthRequest(t, ctx, ts.URL+"/v1/chat/completions", chatBody, "test-key")

	resp, err := ts.Client().Do(httpReq)
	if err != nil {
		t.Fatalf("http request: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusInternalServerError {
		t.Errorf("status = %d, want 500", resp.StatusCode)
	}
}
