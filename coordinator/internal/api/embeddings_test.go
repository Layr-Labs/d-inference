package api

import (
	"context"
	crand "crypto/rand"
	"encoding/base64"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/coordinator/internal/e2e"
	"github.com/eigeninference/coordinator/internal/protocol"
	"github.com/eigeninference/coordinator/internal/registry"
	"github.com/eigeninference/coordinator/internal/store"
	"golang.org/x/crypto/nacl/box"
	"nhooyr.io/websocket"
)

// TestEmbeddingsE2E walks the full embeddings flow:
//   - register a low-RAM (16 GB) provider with the embedding model in catalog
//   - issue POST /v1/embeddings
//   - the simulated provider decrypts the request, returns one vector
//   - the coordinator surfaces the OpenAI-shaped response
//
// This is the end-to-end proof that small Macs can earn revenue serving
// disaggregated compute jobs while the coordinator keeps prompts encrypted
// and the response uniform with OpenAI tooling.
func TestEmbeddingsE2E(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)
	srv.SyncModelCatalog()

	// Load embedding model into catalog as "embedding" type so routing
	// classifies it as disaggregated compute.
	st.SetSupportedModel(&store.SupportedModel{
		ID:        "test-embed",
		ModelType: "embedding",
		Active:    true,
	})
	srv.SyncModelCatalog()

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	// Provider key pair — the consumer-side request will be encrypted with
	// the public key, the provider goroutine decrypts with the private key.
	providerPub, providerPriv, err := box.GenerateKey(crand.Reader)
	if err != nil {
		t.Fatalf("generate provider keypair: %v", err)
	}
	providerPubB64 := base64.StdEncoding.EncodeToString(providerPub[:])

	// Connect a fake 16 GB provider serving the embedding model.
	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("dial provider ws: %v", err)
	}
	defer conn.Close(websocket.StatusNormalClosure, "")

	regMsg := protocol.RegisterMessage{
		Type: protocol.TypeRegister,
		Hardware: protocol.Hardware{
			MachineModel: "Mac15,12",
			ChipName:     "Apple M3",
			MemoryGB:     16,
		},
		Models: []protocol.ModelInfo{
			{ID: "test-embed", ModelType: "embedding", Quantization: "f16"},
		},
		Backend:   "test",
		PublicKey: providerPubB64,
	}
	regData, _ := json.Marshal(regMsg)
	if err := conn.Write(ctx, websocket.MessageText, regData); err != nil {
		t.Fatalf("write register: %v", err)
	}
	time.Sleep(150 * time.Millisecond)

	// Verify provider was classified as tiny tier (16 GB).
	var prov *registry.Provider
	for _, id := range reg.ProviderIDs() {
		prov = reg.GetProvider(id)
	}
	if prov == nil {
		t.Fatal("provider not registered")
	}
	if prov.Tier != protocol.ProviderTierTiny {
		t.Errorf("16 GB provider tier=%q, want tiny", prov.Tier)
	}

	// Mark the provider as trusted so it's eligible for routing.
	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
		reg.RecordChallengeSuccess(id)
	}

	// Provider goroutine: handle attestation challenge + embedding request.
	providerDone := make(chan struct{})
	go func() {
		defer close(providerDone)
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
					PublicKey: providerPubB64,
					Signature: "dummy",
				}
				respData, _ := json.Marshal(resp)
				conn.Write(ctx, websocket.MessageText, respData)
			case protocol.TypeEmbeddingRequest:
				// Decrypt the embedding request body.
				var msg protocol.EmbeddingRequestMessage
				if err := json.Unmarshal(data, &msg); err != nil {
					t.Errorf("unmarshal embedding request: %v", err)
					return
				}
				if msg.EncryptedBody == nil {
					t.Errorf("embedding request missing encrypted_body")
					return
				}
				payload := &e2e.EncryptedPayload{
					EphemeralPublicKey: msg.EncryptedBody.EphemeralPublicKey,
					Ciphertext:         msg.EncryptedBody.Ciphertext,
				}
				plain, err := e2e.DecryptWithPrivateKey(payload, *providerPriv)
				if err != nil {
					t.Errorf("decrypt embedding request: %v", err)
					return
				}
				var body protocol.EmbeddingRequestBody
				if err := json.Unmarshal(plain, &body); err != nil {
					t.Errorf("unmarshal decrypted body: %v", err)
					return
				}
				if body.Model != "test-embed" {
					t.Errorf("decrypted model=%q, want test-embed", body.Model)
				}

				complete := protocol.EmbeddingCompleteMessage{
					Type:      protocol.TypeEmbeddingComplete,
					RequestID: msg.RequestID,
					Model:     "test-embed",
					Data: []protocol.EmbeddingVector{
						{Index: 0, Embedding: []float64{0.1, 0.2, 0.3}},
					},
					Usage: protocol.EmbeddingUsage{
						PromptTokens: 5,
						TotalTokens:  5,
					},
					DurationSecs: 0.01,
				}
				cdata, _ := json.Marshal(complete)
				conn.Write(ctx, websocket.MessageText, cdata)
				return
			}
		}
	}()

	// Issue the consumer-side embedding request.
	body := `{"model":"test-embed","input":"hello"}`
	httpReq, _ := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+"/v1/embeddings", strings.NewReader(body))
	httpReq.Header.Set("Authorization", "Bearer test-key")

	resp, err := http.DefaultClient.Do(httpReq)
	if err != nil {
		t.Fatalf("http request: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		respBody, _ := io.ReadAll(resp.Body)
		t.Fatalf("status=%d body=%s", resp.StatusCode, respBody)
	}

	var result map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		t.Fatalf("decode: %v", err)
	}
	dataArr, ok := result["data"].([]any)
	if !ok || len(dataArr) != 1 {
		t.Fatalf("missing/short data: %#v", result)
	}
	first := dataArr[0].(map[string]any)
	if first["object"] != "embedding" {
		t.Errorf("data[0].object=%v, want embedding", first["object"])
	}
	emb, ok := first["embedding"].([]any)
	if !ok || len(emb) != 3 {
		t.Fatalf("embedding vector wrong shape: %#v", first)
	}
	usage, ok := result["usage"].(map[string]any)
	if !ok {
		t.Fatal("missing usage")
	}
	if usage["prompt_tokens"].(float64) != 5 {
		t.Errorf("prompt_tokens=%v, want 5", usage["prompt_tokens"])
	}

	<-providerDone

	// Verify usage was persisted.
	records := st.UsageRecords()
	if len(records) != 1 {
		t.Fatalf("usage records=%d, want 1", len(records))
	}
	if records[0].Model != "test-embed" {
		t.Errorf("recorded model=%q, want test-embed", records[0].Model)
	}
}

// TestEmbeddingsRejectsNonCatalogModel proves the catalog gate refuses
// requests for models the platform hasn't approved.
func TestEmbeddingsRejectsNonCatalogModel(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)

	st.SetSupportedModel(&store.SupportedModel{
		ID: "approved-embed", ModelType: "embedding", Active: true,
	})
	srv.SyncModelCatalog()

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	body := `{"model":"unknown-embed","input":"hello"}`
	req, _ := http.NewRequest(http.MethodPost, ts.URL+"/v1/embeddings", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer test-key")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("request: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		respBody, _ := io.ReadAll(resp.Body)
		t.Fatalf("status=%d (want 404), body=%s", resp.StatusCode, respBody)
	}
}

// TestRerankE2E is the rerank counterpart of TestEmbeddingsE2E.
func TestRerankE2E(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)
	st.SetSupportedModel(&store.SupportedModel{
		ID: "test-rerank", ModelType: "rerank", Active: true,
	})
	srv.SyncModelCatalog()

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	providerPub, providerPriv, err := box.GenerateKey(crand.Reader)
	if err != nil {
		t.Fatalf("generate keypair: %v", err)
	}
	providerPubB64 := base64.StdEncoding.EncodeToString(providerPub[:])

	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close(websocket.StatusNormalClosure, "")

	regMsg := protocol.RegisterMessage{
		Type: protocol.TypeRegister,
		Hardware: protocol.Hardware{
			MachineModel: "Mac15,12", ChipName: "Apple M3", MemoryGB: 16,
		},
		Models:    []protocol.ModelInfo{{ID: "test-rerank", ModelType: "rerank"}},
		Backend:   "test",
		PublicKey: providerPubB64,
	}
	regData, _ := json.Marshal(regMsg)
	conn.Write(ctx, websocket.MessageText, regData)
	time.Sleep(150 * time.Millisecond)

	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
		reg.RecordChallengeSuccess(id)
	}

	providerDone := make(chan struct{})
	go func() {
		defer close(providerDone)
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
					PublicKey: providerPubB64,
					Signature: "dummy",
				}
				respData, _ := json.Marshal(resp)
				conn.Write(ctx, websocket.MessageText, respData)
			case protocol.TypeRerankRequest:
				var msg protocol.RerankRequestMessage
				if err := json.Unmarshal(data, &msg); err != nil {
					t.Errorf("unmarshal rerank: %v", err)
					return
				}
				payload := &e2e.EncryptedPayload{
					EphemeralPublicKey: msg.EncryptedBody.EphemeralPublicKey,
					Ciphertext:         msg.EncryptedBody.Ciphertext,
				}
				plain, err := e2e.DecryptWithPrivateKey(payload, *providerPriv)
				if err != nil {
					t.Errorf("decrypt rerank: %v", err)
					return
				}
				var body protocol.RerankRequestBody
				if err := json.Unmarshal(plain, &body); err != nil {
					t.Errorf("unmarshal body: %v", err)
					return
				}
				if body.Query != "what is X?" {
					t.Errorf("query=%q, want 'what is X?'", body.Query)
				}
				complete := protocol.RerankCompleteMessage{
					Type:      protocol.TypeRerankComplete,
					RequestID: msg.RequestID,
					Model:     "test-rerank",
					Results: []protocol.RerankResult{
						{Index: 1, RelevanceScore: 0.97},
						{Index: 0, RelevanceScore: 0.42},
					},
					Usage: protocol.RerankUsage{
						PromptTokens: 30, TotalTokens: 30,
					},
					DurationSecs: 0.02,
				}
				cdata, _ := json.Marshal(complete)
				conn.Write(ctx, websocket.MessageText, cdata)
				return
			}
		}
	}()

	body := `{"model":"test-rerank","query":"what is X?","documents":["A","X is Y"],"top_n":1}`
	httpReq, _ := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+"/v1/rerank", strings.NewReader(body))
	httpReq.Header.Set("Authorization", "Bearer test-key")

	resp, err := http.DefaultClient.Do(httpReq)
	if err != nil {
		t.Fatalf("http: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		respBody, _ := io.ReadAll(resp.Body)
		t.Fatalf("status=%d body=%s", resp.StatusCode, respBody)
	}

	var result map[string]any
	json.NewDecoder(resp.Body).Decode(&result)
	results, ok := result["results"].([]any)
	if !ok {
		t.Fatalf("missing results: %#v", result)
	}
	// top_n=1 → coordinator should trim to one entry even though provider sent 2.
	if len(results) != 1 {
		t.Errorf("results len=%d, want 1 (top_n trim)", len(results))
	}
	first := results[0].(map[string]any)
	if first["index"].(float64) != 1 {
		t.Errorf("top result index=%v, want 1", first["index"])
	}

	<-providerDone
}
