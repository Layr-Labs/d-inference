package api

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/coordinator/internal/protocol"
	"github.com/eigeninference/coordinator/internal/registry"
	"github.com/eigeninference/coordinator/internal/store"
	"nhooyr.io/websocket"
)

// privacyPOCTestServer creates a server with an in-memory log sink so the test
// can prove whether provider-supplied plaintext reaches coordinator logs.
func privacyPOCTestServer(t *testing.T) (*Server, *store.MemoryStore, *bytes.Buffer) {
	t.Helper()
	var logs bytes.Buffer
	logger := slog.New(slog.NewTextHandler(&logs, &slog.HandlerOptions{Level: slog.LevelDebug}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)
	return srv, st, &logs
}

func registerPrivacyPOCProvider(t *testing.T, srv *Server, ctx context.Context, ts *httptest.Server, modelID, modelType string) *websocket.Conn {
	t.Helper()

	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("websocket dial: %v", err)
	}

	regMsg := protocol.RegisterMessage{
		Type:      protocol.TypeRegister,
		Hardware:  protocol.Hardware{ChipName: "M3 Max", MemoryGB: 64},
		Models:    []protocol.ModelInfo{{ID: modelID, ModelType: modelType, Quantization: "4bit"}},
		Backend:   "test",
		PublicKey: "fX6XYH7p2hmM3ogeXaAsY+p8M6UKD1df/LJUN9Nj9Nw=",
	}
	regData, _ := json.Marshal(regMsg)
	if err := conn.Write(ctx, websocket.MessageText, regData); err != nil {
		t.Fatalf("write register: %v", err)
	}
	time.Sleep(100 * time.Millisecond)

	p := findProviderByModel(srv.registry, modelID)
	if p == nil {
		t.Fatal("provider not registered")
	}
	srv.registry.SetTrustLevel(p.ID, registry.TrustHardware)
	srv.registry.RecordChallengeSuccess(p.ID)

	return conn
}

func TestPrivacyPOC_ProviderErrorPlaintextLeaksToClientAndLogs(t *testing.T) {
	srv, _, logs := privacyPOCTestServer(t)
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	conn := registerPrivacyPOCProvider(t, srv, ctx, ts, "privacy-poc-model", "test")
	defer conn.Close(websocket.StatusNormalClosure, "")

	secret := "backend leaked prompt: ssn=123-45-6789"

	go func() {
		for {
			_, data, err := conn.Read(ctx)
			if err != nil {
				return
			}
			var raw map[string]any
			if err := json.Unmarshal(data, &raw); err != nil {
				continue
			}
			switch raw["type"] {
			case protocol.TypeAttestationChallenge:
				resp := protocol.AttestationResponseMessage{
					Type:      protocol.TypeAttestationResponse,
					Nonce:     raw["nonce"].(string),
					PublicKey: "dummy",
					Signature: "dummy",
				}
				respData, _ := json.Marshal(resp)
				_ = conn.Write(ctx, websocket.MessageText, respData)
			case protocol.TypeInferenceRequest:
				reqID, _ := raw["request_id"].(string)
				errMsg := protocol.InferenceErrorMessage{
					Type:       protocol.TypeInferenceError,
					RequestID:  reqID,
					Error:      secret,
					StatusCode: http.StatusBadGateway,
				}
				errData, _ := json.Marshal(errMsg)
				_ = conn.Write(ctx, websocket.MessageText, errData)
			}
		}
	}()

	req, err := newAuthRequest(t, ctx, ts.URL+"/v1/chat/completions", `{"model":"privacy-poc-model","messages":[{"role":"user","content":"hi"}],"stream":false}`, "test-key")
	if err != nil {
		t.Fatalf("new request: %v", err)
	}

	resp, err := ts.Client().Do(req)
	if err != nil {
		t.Fatalf("http request: %v", err)
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusBadGateway {
		t.Fatalf("status = %d, want %d", resp.StatusCode, http.StatusBadGateway)
	}
	if !strings.Contains(string(body), secret) {
		t.Fatalf("consumer body did not include provider plaintext error: %s", string(body))
	}
	if !strings.Contains(logs.String(), secret) {
		t.Fatalf("coordinator logs did not include provider plaintext error: %s", logs.String())
	}
}

func TestPrivacyPOC_TranscriptionProviderErrorPlaintextLeaksToClient(t *testing.T) {
	srv, _, _ := privacyPOCTestServer(t)
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	conn := registerPrivacyPOCProvider(t, srv, ctx, ts, "privacy-poc-stt-model", "transcription")
	defer conn.Close(websocket.StatusNormalClosure, "")

	secret := "transcription backend leaked prompt-adjacent text"

	go func() {
		for {
			_, data, err := conn.Read(ctx)
			if err != nil {
				return
			}
			var raw map[string]any
			if err := json.Unmarshal(data, &raw); err != nil {
				continue
			}
			switch raw["type"] {
			case protocol.TypeAttestationChallenge:
				resp := protocol.AttestationResponseMessage{
					Type:      protocol.TypeAttestationResponse,
					Nonce:     raw["nonce"].(string),
					PublicKey: "dummy",
					Signature: "dummy",
				}
				respData, _ := json.Marshal(resp)
				_ = conn.Write(ctx, websocket.MessageText, respData)
			case protocol.TypeTranscriptionRequest:
				reqID, _ := raw["request_id"].(string)
				errMsg := protocol.InferenceErrorMessage{
					Type:       protocol.TypeInferenceError,
					RequestID:  reqID,
					Error:      secret,
					StatusCode: http.StatusBadGateway,
				}
				errData, _ := json.Marshal(errMsg)
				_ = conn.Write(ctx, websocket.MessageText, errData)
			}
		}
	}()

	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	if err := writer.WriteField("model", "privacy-poc-stt-model"); err != nil {
		t.Fatalf("write model field: %v", err)
	}
	part, err := writer.CreateFormFile("file", "clip.wav")
	if err != nil {
		t.Fatalf("create form file: %v", err)
	}
	if _, err := part.Write([]byte("fake wav bytes")); err != nil {
		t.Fatalf("write form file: %v", err)
	}
	if err := writer.Close(); err != nil {
		t.Fatalf("close multipart writer: %v", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+"/v1/audio/transcriptions", &body)
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	req.Header.Set("Authorization", "Bearer test-key")
	req.Header.Set("Content-Type", writer.FormDataContentType())

	resp, err := ts.Client().Do(req)
	if err != nil {
		t.Fatalf("http request: %v", err)
	}
	defer resp.Body.Close()

	respBody, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusBadGateway {
		t.Fatalf("status = %d, want %d", resp.StatusCode, http.StatusBadGateway)
	}
	if !strings.Contains(string(respBody), secret) {
		t.Fatalf("transcription response did not include provider plaintext error: %s", string(respBody))
	}
}

func TestPrivacyPOC_ImageProviderErrorPlaintextLeaksToClient(t *testing.T) {
	srv, _, _ := privacyPOCTestServer(t)
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	conn := registerPrivacyPOCProvider(t, srv, ctx, ts, "privacy-poc-image-model", "image")
	defer conn.Close(websocket.StatusNormalClosure, "")

	secret := "image backend leaked sensitive generation details"

	go func() {
		for {
			_, data, err := conn.Read(ctx)
			if err != nil {
				return
			}
			var raw map[string]any
			if err := json.Unmarshal(data, &raw); err != nil {
				continue
			}
			switch raw["type"] {
			case protocol.TypeAttestationChallenge:
				resp := protocol.AttestationResponseMessage{
					Type:      protocol.TypeAttestationResponse,
					Nonce:     raw["nonce"].(string),
					PublicKey: "dummy",
					Signature: "dummy",
				}
				respData, _ := json.Marshal(resp)
				_ = conn.Write(ctx, websocket.MessageText, respData)
			case protocol.TypeImageGenerationRequest:
				reqID, _ := raw["request_id"].(string)
				errMsg := protocol.InferenceErrorMessage{
					Type:       protocol.TypeInferenceError,
					RequestID:  reqID,
					Error:      secret,
					StatusCode: http.StatusBadGateway,
				}
				errData, _ := json.Marshal(errMsg)
				_ = conn.Write(ctx, websocket.MessageText, errData)
			}
		}
	}()

	req, err := newAuthRequest(t, ctx, ts.URL+"/v1/images/generations", `{"model":"privacy-poc-image-model","prompt":"draw a cat","n":1,"size":"512x512"}`, "test-key")
	if err != nil {
		t.Fatalf("new request: %v", err)
	}

	resp, err := ts.Client().Do(req)
	if err != nil {
		t.Fatalf("http request: %v", err)
	}
	defer resp.Body.Close()

	respBody, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusBadGateway {
		t.Fatalf("status = %d, want %d", resp.StatusCode, http.StatusBadGateway)
	}
	if !strings.Contains(string(respBody), secret) {
		t.Fatalf("image response did not include provider plaintext error: %s", string(respBody))
	}
}

func TestPrivacyPOC_ValidSelfSignedAttestationMakesProviderImmediatelyRoutableAtSelfSignedFloor(t *testing.T) {
	srv, _, _ := privacyPOCTestServer(t)
	srv.registry.MinTrustLevel = registry.TrustSelfSigned
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("websocket dial: %v", err)
	}
	defer conn.Close(websocket.StatusNormalClosure, "")

	attestationJSON := createTestAttestationJSON(t, "")
	regMsg := protocol.RegisterMessage{
		Type:        protocol.TypeRegister,
		Hardware:    protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:      []protocol.ModelInfo{{ID: "selfsigned-floor-model", ModelType: "test", Quantization: "4bit"}},
		Backend:     "test",
		Attestation: attestationJSON,
	}
	regData, _ := json.Marshal(regMsg)
	if err := conn.Write(ctx, websocket.MessageText, regData); err != nil {
		t.Fatalf("write register: %v", err)
	}
	time.Sleep(200 * time.Millisecond)

	p := findProviderByModel(srv.registry, "selfsigned-floor-model")
	if p == nil {
		t.Fatal("provider not registered")
	}
	if got := srv.registry.FindProvider("selfsigned-floor-model"); got == nil {
		t.Fatal("expected self-signed provider to be immediately routable after valid attestation")
	}
}

func TestPrivacyPOC_StoredHardwareTrustRestoresThroughRealRegistrationPath(t *testing.T) {
	srv, _, _ := privacyPOCTestServer(t)
	srv.registry.MinTrustLevel = registry.TrustHardware

	attestationJSON := createTestAttestationJSON(t, "")
	var signed struct {
		Attestation json.RawMessage `json:"attestation"`
	}
	if err := json.Unmarshal(attestationJSON, &signed); err != nil {
		t.Fatalf("unmarshal signed attestation: %v", err)
	}
	var blob struct {
		PublicKey string `json:"publicKey"`
	}
	if err := json.Unmarshal(signed.Attestation, &blob); err != nil {
		t.Fatalf("unmarshal attestation blob: %v", err)
	}

	now := time.Now()
	srv.storedProviders = map[string]*store.ProviderRecord{
		"sekey:" + blob.PublicKey: {
			ID:                    "stored-provider-record",
			TrustLevel:            string(registry.TrustHardware),
			Attested:              true,
			MDAVerified:           true,
			ACMEVerified:          true,
			RuntimeVerified:       true,
			LastChallengeVerified: &now,
		},
	}

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("websocket dial: %v", err)
	}
	defer conn.Close(websocket.StatusNormalClosure, "")

	regMsg := protocol.RegisterMessage{
		Type:        protocol.TypeRegister,
		Hardware:    protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:      []protocol.ModelInfo{{ID: "restored-hardware-model", ModelType: "test", Quantization: "4bit"}},
		Backend:     "test",
		Attestation: attestationJSON,
	}
	regData, _ := json.Marshal(regMsg)
	if err := conn.Write(ctx, websocket.MessageText, regData); err != nil {
		t.Fatalf("write register: %v", err)
	}
	time.Sleep(200 * time.Millisecond)

	if got := srv.registry.FindProvider("restored-hardware-model"); got == nil {
		t.Fatal("expected stored hardware-trust provider to be routable immediately after registration restore")
	}
}

func TestPrivacyPOC_HandleChunkCopiesPlaintextIntoCoordinatorChannel(t *testing.T) {
	srv, _, _ := privacyPOCTestServer(t)

	regMsg := protocol.RegisterMessage{
		Type:     protocol.TypeRegister,
		Hardware: protocol.Hardware{ChipName: "M3 Max", MemoryGB: 64},
		Models:   []protocol.ModelInfo{{ID: "chunk-model", ModelType: "test", Quantization: "4bit"}},
		Backend:  "test",
	}
	p := srv.registry.Register("provider-1", nil, &regMsg)

	pr := &registry.PendingRequest{
		RequestID:  "req-chunk-1",
		Model:      "chunk-model",
		ChunkCh:    make(chan string, 1),
		CompleteCh: make(chan protocol.UsageInfo, 1),
		ErrorCh:    make(chan protocol.InferenceErrorMessage, 1),
	}
	p.AddPending(pr)

	plaintextChunk := "data: {\"choices\":[{\"delta\":{\"content\":\"secret assistant output\"}}]}\n\n"
	srv.handleChunk(p.ID, p, &protocol.InferenceResponseChunkMessage{
		Type:      protocol.TypeInferenceResponseChunk,
		RequestID: pr.RequestID,
		Data:      plaintextChunk,
	})

	select {
	case got := <-pr.ChunkCh:
		if got != plaintextChunk {
			t.Fatalf("chunk = %q, want %q", got, plaintextChunk)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for plaintext chunk on coordinator channel")
	}
}
