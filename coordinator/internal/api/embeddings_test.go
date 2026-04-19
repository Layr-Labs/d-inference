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

// TestEmbeddingsRejectsBase64EncodingFormat documents that we don't support
// the base64 encoding format yet — better to 400 than silently return float.
func TestEmbeddingsRejectsBase64EncodingFormat(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)
	st.SetSupportedModel(&store.SupportedModel{
		ID: "bge-m3", ModelType: "embedding", Active: true,
	})
	srv.SyncModelCatalog()
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	body := `{"model":"bge-m3","input":"hi","encoding_format":"base64"}`
	req, _ := http.NewRequest(http.MethodPost, ts.URL+"/v1/embeddings", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer test-key")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("request: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		respBody, _ := io.ReadAll(resp.Body)
		t.Fatalf("status=%d (want 400), body=%s", resp.StatusCode, respBody)
	}
}

// TestEmbeddingsNoFreeCreditWhenBillingDisabled is a regression test for a
// bug caught in PR review: when s.billing was nil the handler still computed
// a non-zero reservation and the refund path called store.Credit() on early
// errors, minting unlimited free balance for the consumer.
//
// With billing disabled the handler must never write to the consumer's
// ledger — neither charge nor refund. This test asserts that no
// LedgerRefund entries appear after triggering an error path.
func TestEmbeddingsNoFreeCreditWhenBillingDisabled(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger) // s.billing is nil here
	st.SetSupportedModel(&store.SupportedModel{
		ID: "bge-m3", ModelType: "embedding", Active: true,
	})
	srv.SyncModelCatalog()
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	balanceBefore := st.GetBalance("test-key")

	// No provider is registered → ReserveProvider returns nil → handler
	// will exit through the "no provider" error path, calling refund().
	// If the bug is present, refund() will mint free credit because we
	// never charged. With the fix, refund() is a no-op when billing is off.
	body := `{"model":"bge-m3","input":"hi"}`
	req, _ := http.NewRequest(http.MethodPost, ts.URL+"/v1/embeddings", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer test-key")
	resp, _ := http.DefaultClient.Do(req)
	if resp != nil {
		resp.Body.Close()
	}

	balanceAfter := st.GetBalance("test-key")
	if balanceAfter != balanceBefore {
		t.Errorf("ledger balance changed when billing is disabled: before=%d after=%d (free-credit bug)",
			balanceBefore, balanceAfter)
	}

	// Also assert: no refund-type ledger entries for this consumer.
	for _, entry := range st.LedgerHistory("test-key") {
		if entry.Type == store.LedgerRefund {
			t.Errorf("found LedgerRefund entry when billing was disabled: %+v", entry)
		}
	}
}

// TestEmbeddingsRetriesAcrossProviders is a regression test for a gap caught
// in PR review: the handler should retry on a different provider when the
// first one fails, mirroring the chat path. We register two providers that
// both fail and assert the handler hit *both* before giving up — proving the
// retry loop excludes a failed provider rather than re-trying the same one.
func TestEmbeddingsRetriesAcrossProviders(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)
	st.SetSupportedModel(&store.SupportedModel{
		ID: "bge-m3", ModelType: "embedding", Active: true,
	})
	srv.SyncModelCatalog()
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	// Two providers: the first will return an InferenceError, the second
	// will succeed. The consumer should see the success — total invisible
	// retry, just like the chat path.
	type prov struct {
		conn        *websocket.Conn
		pubB64      string
		priv        *[32]byte
		shouldFail  bool
		handledChan chan struct{}
	}

	makeProv := func(id string, shouldFail bool) *prov {
		pub, priv, err := box.GenerateKey(crand.Reader)
		if err != nil {
			t.Fatalf("keypair: %v", err)
		}
		pubB64 := base64.StdEncoding.EncodeToString(pub[:])
		wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"
		conn, _, err := websocket.Dial(ctx, wsURL, nil)
		if err != nil {
			t.Fatalf("dial: %v", err)
		}
		regMsg := protocol.RegisterMessage{
			Type: protocol.TypeRegister,
			Hardware: protocol.Hardware{
				MachineModel: "Mac15,12",
				ChipName:     "Apple M3",
				MemoryGB:     16,
			},
			Models:    []protocol.ModelInfo{{ID: "bge-m3", ModelType: "embedding"}},
			Backend:   "test",
			PublicKey: pubB64,
		}
		regData, _ := json.Marshal(regMsg)
		conn.Write(ctx, websocket.MessageText, regData)
		_ = id
		return &prov{
			conn:        conn,
			pubB64:      pubB64,
			priv:        priv,
			shouldFail:  shouldFail,
			handledChan: make(chan struct{}, 1),
		}
	}

	provA := makeProv("A", true) // both fail — we want to prove both are tried
	defer provA.conn.Close(websocket.StatusNormalClosure, "")
	provB := makeProv("B", true)
	defer provB.conn.Close(websocket.StatusNormalClosure, "")
	time.Sleep(150 * time.Millisecond)

	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
		reg.RecordChallengeSuccess(id)
	}

	runProvider := func(p *prov) {
		go func() {
			for {
				_, data, err := p.conn.Read(ctx)
				if err != nil {
					return
				}
				var raw map[string]any
				if json.Unmarshal(data, &raw) != nil {
					continue
				}
				switch raw["type"] {
				case protocol.TypeAttestationChallenge:
					resp := protocol.AttestationResponseMessage{
						Type:      protocol.TypeAttestationResponse,
						Nonce:     raw["nonce"].(string),
						PublicKey: p.pubB64,
						Signature: "dummy",
					}
					respData, _ := json.Marshal(resp)
					p.conn.Write(ctx, websocket.MessageText, respData)
				case protocol.TypeEmbeddingRequest:
					var msg protocol.EmbeddingRequestMessage
					json.Unmarshal(data, &msg)
					p.handledChan <- struct{}{}
					if p.shouldFail {
						errMsg := protocol.InferenceErrorMessage{
							Type:       protocol.TypeInferenceError,
							RequestID:  msg.RequestID,
							Error:      "simulated failure",
							StatusCode: 500,
						}
						errData, _ := json.Marshal(errMsg)
						p.conn.Write(ctx, websocket.MessageText, errData)
						return
					}
					complete := protocol.EmbeddingCompleteMessage{
						Type:      protocol.TypeEmbeddingComplete,
						RequestID: msg.RequestID,
						Model:     "bge-m3",
						Data: []protocol.EmbeddingVector{
							{Index: 0, Embedding: []float64{0.5, 0.5}},
						},
						Usage:        protocol.EmbeddingUsage{PromptTokens: 1, TotalTokens: 1},
						DurationSecs: 0.01,
					}
					cdata, _ := json.Marshal(complete)
					p.conn.Write(ctx, websocket.MessageText, cdata)
					return
				}
			}
		}()
	}
	runProvider(provA)
	runProvider(provB)

	body := `{"model":"bge-m3","input":"hi"}`
	httpReq, _ := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+"/v1/embeddings", strings.NewReader(body))
	httpReq.Header.Set("Authorization", "Bearer test-key")
	resp, err := http.DefaultClient.Do(httpReq)
	if err != nil {
		t.Fatalf("request: %v", err)
	}
	defer resp.Body.Close()
	// Both providers fail → the consumer eventually sees an error, but
	// only after both providers have been attempted (proving the retry
	// excluded the first failed provider).
	if resp.StatusCode == http.StatusOK {
		t.Fatal("both providers fail; expected error, got 200")
	}

	hits := 0
	for _, p := range []*prov{provA, provB} {
		select {
		case <-p.handledChan:
			hits++
		case <-time.After(2 * time.Second):
		}
	}
	if hits < 2 {
		t.Errorf("retry should attempt both providers; got %d hits (single-provider fail-fast bug)", hits)
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
