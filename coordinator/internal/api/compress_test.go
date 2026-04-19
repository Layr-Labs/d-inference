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

// TestCompressE2E walks the full smart-prefill compression flow:
//   - register a 16 GB tiny-tier provider serving a "compressor" model
//   - POST /v1/compress with a long prompt
//   - simulated provider decrypts, returns a shorter prompt
//   - coordinator surfaces the OpenAI-style response with usage stats
func TestCompressE2E(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)

	st.SetSupportedModel(&store.SupportedModel{
		ID: "test-compressor", ModelType: "compressor", Active: true,
	})
	srv.SyncModelCatalog()

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	providerPub, providerPriv, err := box.GenerateKey(crand.Reader)
	if err != nil {
		t.Fatalf("keypair: %v", err)
	}
	providerPubB64 := base64.StdEncoding.EncodeToString(providerPub[:])

	// Register a 16 GB (tiny-tier) compressor provider.
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
		Models:    []protocol.ModelInfo{{ID: "test-compressor", ModelType: "compressor"}},
		Backend:   "test",
		PublicKey: providerPubB64,
	}
	regData, _ := json.Marshal(regMsg)
	conn.Write(ctx, websocket.MessageText, regData)
	time.Sleep(150 * time.Millisecond)

	// Confirm the registry classified it as tiny.
	for _, id := range reg.ProviderIDs() {
		p := reg.GetProvider(id)
		if p.Tier != protocol.ProviderTierTiny {
			t.Errorf("16 GB compressor tier=%q, want tiny", p.Tier)
		}
		reg.SetTrustLevel(id, registry.TrustHardware)
		reg.RecordChallengeSuccess(id)
	}

	// Provider goroutine: handle attestation challenge + compression request.
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
			case protocol.TypePromptCompressionRequest:
				var msg protocol.PromptCompressionRequestMessage
				if err := json.Unmarshal(data, &msg); err != nil {
					t.Errorf("unmarshal: %v", err)
					return
				}
				if msg.EncryptedBody == nil {
					t.Errorf("missing encrypted_body")
					return
				}
				payload := &e2e.EncryptedPayload{
					EphemeralPublicKey: msg.EncryptedBody.EphemeralPublicKey,
					Ciphertext:         msg.EncryptedBody.Ciphertext,
				}
				plain, err := e2e.DecryptWithPrivateKey(payload, *providerPriv)
				if err != nil {
					t.Errorf("decrypt: %v", err)
					return
				}
				var body protocol.PromptCompressionRequestBody
				if err := json.Unmarshal(plain, &body); err != nil {
					t.Errorf("body: %v", err)
					return
				}
				// Drop every other word as a deterministic stand-in for
				// real attention-based selection.
				words := strings.Fields(body.Prompt)
				kept := make([]string, 0, len(words)/2+1)
				for i, w := range words {
					if i%2 == 0 {
						kept = append(kept, w)
					}
				}
				compressed := strings.Join(kept, " ")
				complete := protocol.PromptCompressionCompleteMessage{
					Type:             protocol.TypePromptCompressionComplete,
					RequestID:        msg.RequestID,
					CompressorModel:  body.CompressorModel,
					CompressedPrompt: compressed,
					Usage: protocol.PromptCompressionUsage{
						OriginalTokens:   len(words),
						CompressedTokens: len(kept),
						TotalTokens:      len(words),
					},
					DurationSecs: 0.05,
				}
				cdata, _ := json.Marshal(complete)
				conn.Write(ctx, websocket.MessageText, cdata)
				return
			}
		}
	}()

	// Build a long-ish prompt so the result is interesting.
	prompt := strings.Repeat("the quick brown fox jumps over the lazy dog ", 40)
	body, _ := json.Marshal(map[string]any{
		"compressor_model": "test-compressor",
		"prompt":           prompt,
		"target_ratio":     0.5,
	})
	httpReq, _ := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+"/v1/compress", strings.NewReader(string(body)))
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
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		t.Fatalf("decode: %v", err)
	}
	cp, _ := result["compressed_prompt"].(string)
	if cp == "" {
		t.Fatalf("missing compressed_prompt: %#v", result)
	}
	if !strings.Contains(cp, "the") || !strings.Contains(cp, "fox") {
		t.Errorf("compressed prompt looks empty/malformed: %q", cp)
	}
	if len(cp) >= len(prompt) {
		t.Errorf("compressed prompt should be shorter; got len %d vs original %d", len(cp), len(prompt))
	}
	usage, ok := result["usage"].(map[string]any)
	if !ok {
		t.Fatal("missing usage")
	}
	if usage["compressed_tokens"].(float64) >= usage["original_tokens"].(float64) {
		t.Errorf("compressed >= original: %#v", usage)
	}

	<-providerDone

	// Usage was persisted.
	records := st.UsageRecords()
	if len(records) != 1 {
		t.Fatalf("usage records=%d, want 1", len(records))
	}
}

// TestCompressNoFreeCreditWhenBillingDisabled — same regression test we
// have for embeddings. With billing off, the refund-on-error path must
// not credit the consumer.
func TestCompressNoFreeCreditWhenBillingDisabled(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger) // s.billing == nil
	st.SetSupportedModel(&store.SupportedModel{
		ID: "test-compressor", ModelType: "compressor", Active: true,
	})
	srv.SyncModelCatalog()
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	balanceBefore := st.GetBalance("test-key")
	body := `{"compressor_model":"test-compressor","prompt":"hi"}`
	req, _ := http.NewRequest(http.MethodPost, ts.URL+"/v1/compress", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer test-key")
	resp, _ := http.DefaultClient.Do(req)
	if resp != nil {
		resp.Body.Close()
	}
	if st.GetBalance("test-key") != balanceBefore {
		t.Errorf("balance changed when billing was disabled (free-credit bug)")
	}
	for _, e := range st.LedgerHistory("test-key") {
		if e.Type == store.LedgerRefund {
			t.Errorf("found refund entry when billing was disabled: %+v", e)
		}
	}
}

// TestCompressInvalidRatio — target_ratio outside (0, 1] is rejected.
func TestCompressInvalidRatio(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)
	st.SetSupportedModel(&store.SupportedModel{
		ID: "test-compressor", ModelType: "compressor", Active: true,
	})
	srv.SyncModelCatalog()
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	for _, ratio := range []float64{0, -0.1, 1.5, 2.0} {
		body, _ := json.Marshal(map[string]any{
			"compressor_model": "test-compressor",
			"prompt":           "x",
			"target_ratio":     ratio,
		})
		req, _ := http.NewRequest(http.MethodPost, ts.URL+"/v1/compress", strings.NewReader(string(body)))
		req.Header.Set("Authorization", "Bearer test-key")
		resp, _ := http.DefaultClient.Do(req)
		// ratio=0 hits the "use default" path (it's valid syntactically),
		// only out-of-range values should 400.
		if ratio == 0 {
			continue
		}
		if resp.StatusCode != http.StatusBadRequest {
			t.Errorf("ratio=%v: status=%d, want 400", ratio, resp.StatusCode)
		}
		resp.Body.Close()
	}
}

// TestSmartPrefillMiddlewareSwapsLongestMessage exercises the
// /v1/chat/completions middleware path: a request with smart_prefill=true
// and a long user message should hit the compressor first, then route
// to the chat model with the shorter prompt. We register two providers
// (one tiny compressor, one standard chat model) and assert the chat
// model receives the *compressed* prompt.
func TestSmartPrefillMiddlewareSwapsLongestMessage(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)
	st.SetSupportedModel(&store.SupportedModel{
		ID: "test-compressor", ModelType: "compressor", Active: true,
	})
	st.SetSupportedModel(&store.SupportedModel{
		ID: "test-chat", ModelType: "text", Active: true,
	})
	srv.SyncModelCatalog()
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	// Helper that registers a provider and returns its keys + conn.
	type prov struct {
		conn   *websocket.Conn
		pubB64 string
		priv   *[32]byte
	}
	mkProv := func(memGB int, modelID, modelType string) *prov {
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
				MachineModel: "Mac", ChipName: "M", MemoryGB: memGB,
			},
			Models:    []protocol.ModelInfo{{ID: modelID, ModelType: modelType}},
			Backend:   "test",
			PublicKey: pubB64,
		}
		regData, _ := json.Marshal(regMsg)
		conn.Write(ctx, websocket.MessageText, regData)
		return &prov{conn: conn, pubB64: pubB64, priv: priv}
	}

	cprov := mkProv(16, "test-compressor", "compressor")
	defer cprov.conn.Close(websocket.StatusNormalClosure, "")
	chatprov := mkProv(64, "test-chat", "text")
	defer chatprov.conn.Close(websocket.StatusNormalClosure, "")
	time.Sleep(200 * time.Millisecond)

	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
		reg.RecordChallengeSuccess(id)
	}

	// Compressor handler: drops every other word.
	go func() {
		for {
			_, data, err := cprov.conn.Read(ctx)
			if err != nil {
				return
			}
			var raw map[string]any
			if err := json.Unmarshal(data, &raw); err != nil {
				continue
			}
			switch raw["type"] {
			case protocol.TypeAttestationChallenge:
				r := protocol.AttestationResponseMessage{
					Type: protocol.TypeAttestationResponse, Nonce: raw["nonce"].(string),
					PublicKey: cprov.pubB64, Signature: "dummy",
				}
				rd, _ := json.Marshal(r)
				cprov.conn.Write(ctx, websocket.MessageText, rd)
			case protocol.TypePromptCompressionRequest:
				var msg protocol.PromptCompressionRequestMessage
				json.Unmarshal(data, &msg)
				payload := &e2e.EncryptedPayload{
					EphemeralPublicKey: msg.EncryptedBody.EphemeralPublicKey,
					Ciphertext:         msg.EncryptedBody.Ciphertext,
				}
				plain, _ := e2e.DecryptWithPrivateKey(payload, *cprov.priv)
				var body protocol.PromptCompressionRequestBody
				json.Unmarshal(plain, &body)
				words := strings.Fields(body.Prompt)
				kept := make([]string, 0)
				for i, w := range words {
					if i%2 == 0 {
						kept = append(kept, w)
					}
				}
				complete := protocol.PromptCompressionCompleteMessage{
					Type:             protocol.TypePromptCompressionComplete,
					RequestID:        msg.RequestID,
					CompressorModel:  body.CompressorModel,
					CompressedPrompt: strings.Join(kept, " "),
					Usage: protocol.PromptCompressionUsage{
						OriginalTokens:   len(words),
						CompressedTokens: len(kept),
						TotalTokens:      len(words),
					},
					DurationSecs: 0.01,
				}
				cd, _ := json.Marshal(complete)
				cprov.conn.Write(ctx, websocket.MessageText, cd)
			}
		}
	}()

	// Chat provider: capture the prompt it received, return canned reply.
	gotPromptCh := make(chan string, 1)
	go func() {
		for {
			_, data, err := chatprov.conn.Read(ctx)
			if err != nil {
				return
			}
			var raw map[string]any
			if err := json.Unmarshal(data, &raw); err != nil {
				continue
			}
			switch raw["type"] {
			case protocol.TypeAttestationChallenge:
				r := protocol.AttestationResponseMessage{
					Type: protocol.TypeAttestationResponse, Nonce: raw["nonce"].(string),
					PublicKey: chatprov.pubB64, Signature: "dummy",
				}
				rd, _ := json.Marshal(r)
				chatprov.conn.Write(ctx, websocket.MessageText, rd)
			case protocol.TypeInferenceRequest:
				var msg protocol.InferenceRequestMessage
				json.Unmarshal(data, &msg)
				payload := &e2e.EncryptedPayload{
					EphemeralPublicKey: msg.EncryptedBody.EphemeralPublicKey,
					Ciphertext:         msg.EncryptedBody.Ciphertext,
				}
				plain, _ := e2e.DecryptWithPrivateKey(payload, *chatprov.priv)
				// Decode the inference body and extract the user message.
				var body map[string]any
				json.Unmarshal(plain, &body)
				if msgs, ok := body["messages"].([]any); ok && len(msgs) > 0 {
					if obj, ok := msgs[0].(map[string]any); ok {
						if c, ok := obj["content"].(string); ok {
							select {
							case gotPromptCh <- c:
							default:
							}
						}
					}
				}
				// Reply with a single chunk + complete.
				chunk := protocol.InferenceResponseChunkMessage{
					Type: protocol.TypeInferenceResponseChunk, RequestID: msg.RequestID,
					Data: `data: {"id":"x","choices":[{"delta":{"content":"ok"}}]}`,
				}
				cd, _ := json.Marshal(chunk)
				chatprov.conn.Write(ctx, websocket.MessageText, cd)
				done := protocol.InferenceCompleteMessage{
					Type: protocol.TypeInferenceComplete, RequestID: msg.RequestID,
					Usage: protocol.UsageInfo{PromptTokens: 1, CompletionTokens: 1},
				}
				dd, _ := json.Marshal(done)
				chatprov.conn.Write(ctx, websocket.MessageText, dd)
			}
		}
	}()

	// Make the user message long enough that smart_prefill engages
	// (>= 2000 token estimate, so we need ≥ ~8000 chars).
	longContent := strings.Repeat("the quick brown fox jumps over the lazy dog ", 250)
	body, _ := json.Marshal(map[string]any{
		"model": "test-chat",
		"smart_prefill": map[string]any{
			"enabled":          true,
			"compressor_model": "test-compressor",
		},
		"messages": []any{
			map[string]any{"role": "user", "content": longContent},
		},
	})
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+"/v1/chat/completions", strings.NewReader(string(body)))
	req.Header.Set("Authorization", "Bearer test-key")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("http: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		respBody, _ := io.ReadAll(resp.Body)
		t.Fatalf("status=%d body=%s", resp.StatusCode, respBody)
	}

	if resp.Header.Get("X-SmartPrefill-Compressor") == "" {
		t.Errorf("missing X-SmartPrefill-Compressor header — middleware did not run")
	}
	if origStr := resp.Header.Get("X-SmartPrefill-Original-Tokens"); origStr == "" {
		t.Errorf("missing X-SmartPrefill-Original-Tokens header")
	}

	select {
	case got := <-gotPromptCh:
		if len(got) >= len(longContent) {
			t.Errorf("chat provider received prompt of len %d (original %d) — middleware did not compress",
				len(got), len(longContent))
		}
		if !strings.Contains(got, "the") {
			t.Errorf("compressed prompt looks malformed: %q", got[:min(len(got), 100)])
		}
	case <-time.After(5 * time.Second):
		t.Fatal("chat provider never received the request")
	}
}

// TestSmartPrefillFallsThroughOnShortPrompt — middleware should be a no-op
// when the prompt is below the min threshold; chat provider sees original.
func TestSmartPrefillFallsThroughOnShortPrompt(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)
	st.SetSupportedModel(&store.SupportedModel{
		ID: "test-chat", ModelType: "text", Active: true,
	})
	srv.SyncModelCatalog()
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	// Only register the chat provider — no compressor available.
	pub, priv, _ := box.GenerateKey(crand.Reader)
	pubB64 := base64.StdEncoding.EncodeToString(pub[:])
	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close(websocket.StatusNormalClosure, "")
	reg64, _ := json.Marshal(protocol.RegisterMessage{
		Type:      protocol.TypeRegister,
		Hardware:  protocol.Hardware{ChipName: "M3", MemoryGB: 64},
		Models:    []protocol.ModelInfo{{ID: "test-chat", ModelType: "text"}},
		Backend:   "test",
		PublicKey: pubB64,
	})
	conn.Write(ctx, websocket.MessageText, reg64)
	time.Sleep(150 * time.Millisecond)
	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
		reg.RecordChallengeSuccess(id)
	}

	gotPromptCh := make(chan string, 1)
	go func() {
		for {
			_, data, err := conn.Read(ctx)
			if err != nil {
				return
			}
			var raw map[string]any
			json.Unmarshal(data, &raw)
			switch raw["type"] {
			case protocol.TypeAttestationChallenge:
				r := protocol.AttestationResponseMessage{
					Type: protocol.TypeAttestationResponse, Nonce: raw["nonce"].(string),
					PublicKey: pubB64, Signature: "dummy",
				}
				rd, _ := json.Marshal(r)
				conn.Write(ctx, websocket.MessageText, rd)
			case protocol.TypeInferenceRequest:
				var msg protocol.InferenceRequestMessage
				json.Unmarshal(data, &msg)
				payload := &e2e.EncryptedPayload{
					EphemeralPublicKey: msg.EncryptedBody.EphemeralPublicKey,
					Ciphertext:         msg.EncryptedBody.Ciphertext,
				}
				plain, _ := e2e.DecryptWithPrivateKey(payload, *priv)
				var body map[string]any
				json.Unmarshal(plain, &body)
				if msgs, ok := body["messages"].([]any); ok && len(msgs) > 0 {
					if obj, ok := msgs[0].(map[string]any); ok {
						if c, ok := obj["content"].(string); ok {
							select {
							case gotPromptCh <- c:
							default:
							}
						}
					}
				}
				// Send a chunk + complete to free the chat handler.
				chunk := protocol.InferenceResponseChunkMessage{
					Type: protocol.TypeInferenceResponseChunk, RequestID: msg.RequestID,
					Data: `data: {"id":"x","choices":[{"delta":{"content":"ok"}}]}`,
				}
				cd, _ := json.Marshal(chunk)
				conn.Write(ctx, websocket.MessageText, cd)
				done := protocol.InferenceCompleteMessage{
					Type: protocol.TypeInferenceComplete, RequestID: msg.RequestID,
					Usage: protocol.UsageInfo{PromptTokens: 1, CompletionTokens: 1},
				}
				dd, _ := json.Marshal(done)
				conn.Write(ctx, websocket.MessageText, dd)
			}
		}
	}()

	short := "what is 2 + 2?"
	body, _ := json.Marshal(map[string]any{
		"model":         "test-chat",
		"smart_prefill": true,
		"messages":      []any{map[string]any{"role": "user", "content": short}},
	})
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+"/v1/chat/completions", strings.NewReader(string(body)))
	req.Header.Set("Authorization", "Bearer test-key")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("http: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		respBody, _ := io.ReadAll(resp.Body)
		t.Fatalf("status=%d body=%s", resp.StatusCode, respBody)
	}

	if hdr := resp.Header.Get("X-SmartPrefill-Compressor"); hdr != "" {
		t.Errorf("middleware fired on short prompt, got X-SmartPrefill-Compressor=%q", hdr)
	}
	select {
	case got := <-gotPromptCh:
		if got != short {
			t.Errorf("chat provider received %q, want unchanged %q", got, short)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("chat provider never received the request")
	}
}

// TestPreferredTiersIncludesCompressor asserts the compressor model_type
// gets the same tier preference as embedding/rerank.
func TestPreferredTiersIncludesCompressor(t *testing.T) {
	tiers := registry.PreferredTiersForModelType("compressor")
	if len(tiers) != 2 {
		t.Fatalf("compressor should prefer 2 tiers, got %d", len(tiers))
	}
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
