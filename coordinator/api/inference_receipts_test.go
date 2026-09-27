package api

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/receipts"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

func TestInferenceReceiptRequestValidation(t *testing.T) {
	seed, _ := randomReceiptKey(t)
	s := &Server{inferenceReceiptEnabled: true, inferenceReceiptSigner: seed}
	nonceBytes := make([]byte, 32)
	for i := range nonceBytes {
		nonceBytes[i] = byte(i + 1)
	}
	nonce := base64.RawURLEncoding.EncodeToString(nonceBytes)
	body := []byte(`{"model":"gemma-4-26b","messages":[{"role":"system","content":"Be exact."},{"role":"user","content":"2+2?"}],"temperature":0}`)
	parsed := map[string]any{
		"model": "gemma-4-26b",
		"messages": []any{
			map[string]any{"role": "system", "content": "Be exact."},
			map[string]any{"role": "user", "content": "2+2?"},
		},
		"temperature": float64(0),
	}
	r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	r.Header.Set(inferenceReceiptHeader, inferenceReceiptRequired)
	r.Header.Set(inferenceReceiptNonceHeader, nonce)
	r = r.WithContext(context.WithValue(r.Context(), ctxKeyAPIKey, &store.APIKey{ID: "key_agent_a"}))

	got, err := s.newInferenceReceiptRequest(r, parsed, body, "/v1/chat/completions", false)
	if err != nil {
		t.Fatalf("newInferenceReceiptRequest: %v", err)
	}
	if got == nil || got.Nonce != nonce || got.CallerRef != "key_agent_a" {
		t.Fatalf("request context = %+v", got)
	}
	canonical, err := receipts.HashCanonicalJSON(body)
	if err != nil {
		t.Fatal(err)
	}
	if got.RequestSHA256 != canonical || got.RequestBytesSHA256 != receipts.HashBytes(body) {
		t.Fatalf("request hashes = (%s,%s), want (%s,%s)", got.RequestSHA256, got.RequestBytesSHA256, canonical, receipts.HashBytes(body))
	}
	if got.JobID == "" || !got.LookupExpiresAt.After(got.CreatedAt) {
		t.Fatalf("invalid coordinator receipt identity/times: %+v", got)
	}

	tests := map[string]func(*http.Request, map[string]any, string, bool){
		"malformed nonce": func(r *http.Request, _ map[string]any, endpoint string, responses bool) {
			r.Header.Set(inferenceReceiptNonceHeader, "guessable")
			_, err := s.newInferenceReceiptRequest(r, parsed, body, endpoint, responses)
			if err == nil {
				t.Fatal("accepted malformed nonce")
			}
		},
		"streaming": func(r *http.Request, _ map[string]any, endpoint string, responses bool) {
			stream := make(map[string]any, len(parsed)+1)
			for key, value := range parsed {
				stream[key] = value
			}
			stream["stream"] = true
			_, err := s.newInferenceReceiptRequest(r, stream, body, endpoint, responses)
			if err == nil {
				t.Fatal("accepted streaming request in non-streaming receipt MVP")
			}
		},
		"responses endpoint": func(r *http.Request, _ map[string]any, endpoint string, responses bool) {
			_, err := s.newInferenceReceiptRequest(r, parsed, body, endpoint, true)
			if err == nil {
				t.Fatal("accepted Responses API request in chat-only receipt MVP")
			}
		},
		"tool calls": func(r *http.Request, _ map[string]any, endpoint string, responses bool) {
			withTools := make(map[string]any, len(parsed)+1)
			for key, value := range parsed {
				withTools[key] = value
			}
			withTools["tools"] = []any{map[string]any{"type": "function"}}
			_, err := s.newInferenceReceiptRequest(r, withTools, body, endpoint, responses)
			if err == nil {
				t.Fatal("accepted tool request in plain-text receipt MVP")
			}
		},
		"receipt disabled": func(r *http.Request, _ map[string]any, endpoint string, responses bool) {
			disabled := &Server{}
			_, err := disabled.newInferenceReceiptRequest(r, parsed, body, endpoint, responses)
			if err == nil {
				t.Fatal("accepted receipt request while receipts disabled")
			}
		},
	}
	for name, run := range tests {
		t.Run(name, func(t *testing.T) {
			request := r.Clone(context.Background())
			request.Header = r.Header.Clone()
			request.Header.Set(inferenceReceiptNonceHeader, nonce)
			run(request, parsed, "/v1/chat/completions", false)
		})
	}
}

func TestInferenceReceiptFinalizationSignsCommittedRequestAndOutput(t *testing.T) {
	seed, privateKey := randomReceiptKey(t)
	st := store.NewMemory(store.Config{})
	s := &Server{
		store: st, inferenceReceiptEnabled: true, inferenceReceiptSigner: seed,
		inferenceReceiptIssuer:    "https://coordinator.example",
		inferenceReceiptRetention: 90 * 24 * time.Hour,
	}
	now := time.Now().UTC().Truncate(time.Second)
	req := &inferenceReceiptRequest{
		JobID: "job-receipt-test", Nonce: apiTestReceiptNonce(), CallerRef: "key-agent",
		RequestSHA256: strings.Repeat("a", 64), RequestBytesSHA256: strings.Repeat("b", 64),
		RequestedModel: "gemma-4-26b", CreatedAt: now, LookupExpiresAt: now.Add(90 * 24 * time.Hour),
	}
	if err := st.CreateInferenceReceipt(context.Background(), store.InferenceReceiptRecord{
		JobID: req.JobID, Nonce: req.Nonce, State: store.InferenceReceiptPending, CreatedAt: now, UpdatedAt: now, ExpiresAt: req.LookupExpiresAt,
	}); err != nil {
		t.Fatal(err)
	}
	pr := &registry.PendingRequest{
		RequestID: "winning-attempt-id", Model: "resolved-build-id", PublicModel: "gemma-4-26b",
		InferenceReceipt: &registry.InferenceReceiptContext{
			JobID: req.JobID, Nonce: req.Nonce, CallerRef: req.CallerRef,
			RequestSHA256: req.RequestSHA256, RequestBytesSHA256: req.RequestBytesSHA256,
			ProviderRequestSHA256: strings.Repeat("c", 64), RequestedModel: req.RequestedModel,
			CreatedAt: req.CreatedAt, LookupExpiresAt: req.LookupExpiresAt,
		},
	}
	response := map[string]any{"model": "gemma-4-26b", "choices": []any{
		map[string]any{"message": map[string]any{"role": "assistant", "content": "4"}, "finish_reason": "stop"},
	}}
	w := httptest.NewRecorder()
	if err := s.finalizeInferenceReceipt(w, pr, response); err != nil {
		t.Fatalf("finalizeInferenceReceipt: %v", err)
	}
	if got := w.Header().Get(inferenceReceiptHashHeader); got == "" {
		t.Fatal("missing receipt hash response header")
	}
	record, err := st.GetInferenceReceiptByJobID(context.Background(), req.JobID)
	if err != nil {
		t.Fatal(err)
	}
	var envelope receipts.Envelope
	if err := json.Unmarshal(record.Envelope, &envelope); err != nil {
		t.Fatal(err)
	}
	if err := receipts.Verify(envelope, privateKey.Public().(ed25519.PublicKey)); err != nil {
		t.Fatalf("Verify: %v", err)
	}
	payload := envelope.Payload
	if payload.JobID != req.JobID || payload.WinningAttemptID != pr.RequestID || payload.Nonce != req.Nonce || payload.CallerRef != req.CallerRef {
		t.Fatalf("receipt identity mismatch: %+v", payload)
	}
	if payload.RequestSHA256 != req.RequestSHA256 || payload.RequestBytesSHA256 != req.RequestBytesSHA256 || payload.ProviderRequestSHA256 != strings.Repeat("c", 64) {
		t.Fatalf("receipt omitted request commitments: %+v", payload)
	}
	if payload.OutputSHA256 != receipts.HashBytes([]byte("4")) || payload.RequestedModel != "gemma-4-26b" || payload.ResolvedModel != "resolved-build-id" || payload.FinishReason != "stop" {
		t.Fatalf("receipt output/model mismatch: %+v", payload)
	}
	if record.ReceiptHash != envelope.ReceiptHash || record.State != store.InferenceReceiptCompleted {
		t.Fatalf("stored envelope mismatch: %+v", record)
	}
}

func TestInferenceReceiptFinalizationFailsClosedOnUnsupportedOutput(t *testing.T) {
	seed, _ := randomReceiptKey(t)
	st := store.NewMemory(store.Config{})
	s := &Server{store: st, inferenceReceiptEnabled: true, inferenceReceiptSigner: seed, inferenceReceiptIssuer: "https://coordinator.example"}
	now := time.Now().UTC()
	req := &inferenceReceiptRequest{JobID: "job-invalid-output", Nonce: apiTestReceiptNonce(), CallerRef: "key", RequestSHA256: strings.Repeat("a", 64), RequestBytesSHA256: strings.Repeat("b", 64), RequestedModel: "model", CreatedAt: now, LookupExpiresAt: now.Add(90 * 24 * time.Hour)}
	if err := st.CreateInferenceReceipt(context.Background(), store.InferenceReceiptRecord{JobID: req.JobID, Nonce: req.Nonce, State: store.InferenceReceiptPending, CreatedAt: now, UpdatedAt: now, ExpiresAt: req.LookupExpiresAt}); err != nil {
		t.Fatal(err)
	}
	pr := &registry.PendingRequest{RequestID: "attempt", Model: "model", PublicModel: "model", InferenceReceipt: &registry.InferenceReceiptContext{
		JobID: req.JobID, Nonce: req.Nonce, CallerRef: req.CallerRef, RequestSHA256: req.RequestSHA256, RequestBytesSHA256: req.RequestBytesSHA256,
		ProviderRequestSHA256: strings.Repeat("c", 64), RequestedModel: req.RequestedModel, CreatedAt: req.CreatedAt, LookupExpiresAt: req.LookupExpiresAt,
	}}
	err := s.finalizeInferenceReceipt(httptest.NewRecorder(), pr, map[string]any{"choices": []any{map[string]any{"message": map[string]any{"tool_calls": []any{}}}}})
	if err == nil {
		t.Fatal("receipt finalized without a plain-text assistant output")
	}
	record, getErr := st.GetInferenceReceiptByJobID(context.Background(), req.JobID)
	if getErr != nil || record.State != store.InferenceReceiptFailed {
		t.Fatalf("unsupported output was not marked failed: (%+v, %v)", record, getErr)
	}
}

func TestInferenceReceiptLookupHidesExpiredAndMissing(t *testing.T) {
	seed, _ := randomReceiptKey(t)
	st := store.NewMemory(store.Config{})
	s := &Server{store: st, inferenceReceiptEnabled: true, inferenceReceiptSigner: seed, inferenceReceiptIssuer: "https://coordinator.example"}
	jobID := "job-expired-receipt"
	_, private, _ := ed25519.GenerateKey(rand.Reader)
	otherSigner, err := receipts.NewSigner("old-key", private)
	if err != nil {
		t.Fatal(err)
	}
	past := time.Now().UTC().Add(-time.Hour)
	payload := receipts.Payload{
		SchemaVersion: 1, Issuer: "https://coordinator.example", JobID: jobID, WinningAttemptID: "attempt", Nonce: apiTestReceiptNonce(), CallerRef: "key",
		RequestSHA256: strings.Repeat("a", 64), RequestBytesSHA256: strings.Repeat("b", 64), ProviderRequestSHA256: strings.Repeat("c", 64),
		RequestedModel: "model", ResolvedModel: "model", OutputSHA256: receipts.HashBytes([]byte("done")), Status: "completed", FinishReason: "stop",
		CompletedAt: past.Add(-time.Hour), LookupExpiresAt: past,
	}
	// Expired records are never signable under the strict receipt payload rules;
	// this API test stores a valid historical envelope and checks it is hidden.
	payload.LookupExpiresAt = payload.CompletedAt.Add(time.Minute)
	envelope, err := otherSigner.Sign(payload)
	if err != nil {
		t.Fatal(err)
	}
	envelopeJSON, _ := json.Marshal(envelope)
	if err := st.CreateInferenceReceipt(context.Background(), store.InferenceReceiptRecord{JobID: jobID, Nonce: payload.Nonce, ReceiptHash: envelope.ReceiptHash, State: store.InferenceReceiptCompleted, Envelope: envelopeJSON, CreatedAt: payload.CompletedAt, UpdatedAt: payload.CompletedAt, ExpiresAt: payload.LookupExpiresAt}); err != nil {
		t.Fatal(err)
	}
	for _, lookup := range []func(http.ResponseWriter, *http.Request){s.handleInferenceReceiptByJobID, s.handleInferenceReceiptByHash} {
		w := httptest.NewRecorder()
		r := httptest.NewRequest(http.MethodGet, "/", nil)
		if lookup == nil {
			t.Fatal("nil handler")
		}
		r.SetPathValue("job_id", jobID)
		r.SetPathValue("receipt_hash", envelope.ReceiptHash)
		lookup(w, r)
		if w.Code != http.StatusNotFound {
			t.Fatalf("expired receipt status = %d, body=%s", w.Code, w.Body.String())
		}
	}
	w := httptest.NewRecorder()
	r := httptest.NewRequest(http.MethodGet, "/", nil)
	r.SetPathValue("job_id", "missing-job")
	s.handleInferenceReceiptByJobID(w, r)
	if w.Code != http.StatusNotFound {
		t.Fatalf("missing receipt status = %d", w.Code)
	}
}

type failingReceiptLookupStore struct {
	store.Store
}

func (failingReceiptLookupStore) GetInferenceReceiptByJobID(context.Context, string) (store.InferenceReceiptRecord, error) {
	return store.InferenceReceiptRecord{}, errors.New("connection reset")
}

func (failingReceiptLookupStore) GetInferenceReceiptByHash(context.Context, string) (store.InferenceReceiptRecord, error) {
	return store.InferenceReceiptRecord{}, errors.New("connection reset")
}

func TestInferenceReceiptLookupReportsStoreFailureAsUnavailable(t *testing.T) {
	s := &Server{
		store:  failingReceiptLookupStore{Store: store.NewMemory(store.Config{})},
		logger: slog.New(slog.NewTextHandler(io.Discard, nil)),
	}
	for name, lookup := range map[string]func(http.ResponseWriter, *http.Request){
		"job":  s.handleInferenceReceiptByJobID,
		"hash": s.handleInferenceReceiptByHash,
	} {
		w := httptest.NewRecorder()
		r := httptest.NewRequest(http.MethodGet, "/", nil)
		r.SetPathValue("job_id", "job")
		r.SetPathValue("receipt_hash", strings.Repeat("a", 64))
		lookup(w, r)
		if w.Code != http.StatusServiceUnavailable {
			t.Fatalf("%s lookup status = %d, want 503; body=%s", name, w.Code, w.Body.String())
		}
	}
}

func apiTestReceiptNonce() string {
	return apiTestReceiptNonceWithByte(0)
}

func apiTestReceiptNonceWithByte(value byte) string {
	nonce := make([]byte, 32)
	nonce[0] = value
	return base64.RawURLEncoding.EncodeToString(nonce)
}

func TestInferenceReceiptEndToEndNetworkLookup(t *testing.T) {
	seed := make([]byte, ed25519.SeedSize)
	for i := range seed {
		seed[i] = byte(i + 17)
	}
	privateKey := ed25519.NewKeyFromSeed(seed)
	cfg := ServerConfig{
		BaseURL:                    "https://receipts.example",
		InferenceReceiptsEnabled:   true,
		InferenceReceiptKeyID:      "receipt-test-v1",
		InferenceReceiptSigningKey: base64.StdEncoding.EncodeToString(seed),
	}
	ts, cleanup, providerDone := setupE2ETest(t, "test-model", func(ctx context.Context, conn *websocket.Conn, inferReq protocol.InferenceRequestMessage, publicKey string) {
		sendChunk(t, ctx, conn, inferReq, publicKey, `data: {"id":"chatcmpl-test","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","content":"4"},"finish_reason":null}]}`+"\n\n")
		sendChunk(t, ctx, conn, inferReq, publicKey, `data: {"id":"chatcmpl-test","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}`+"\n\n")
		sendComplete(ctx, conn, inferReq.RequestID, protocol.UsageInfo{PromptTokens: 12, CompletionTokens: 1})
	}, cfg)
	defer cleanup()

	nonceBytes := make([]byte, 32)
	for i := range nonceBytes {
		nonceBytes[i] = byte(255 - i)
	}
	nonce := base64.RawURLEncoding.EncodeToString(nonceBytes)
	body := `{"model":"test-model","messages":[{"role":"system","content":"Answer precisely."},{"role":"user","content":"What is 2+2?"}],"temperature":0,"max_tokens":8}`
	req, err := http.NewRequest(http.MethodPost, ts.URL+"/v1/chat/completions", strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer test-key")
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set(inferenceReceiptHeader, inferenceReceiptRequired)
	req.Header.Set(inferenceReceiptNonceHeader, nonce)
	response, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	responseBody, readErr := io.ReadAll(response.Body)
	response.Body.Close()
	if readErr != nil {
		t.Fatal(readErr)
	}
	if response.StatusCode != http.StatusOK {
		t.Fatalf("inference status=%d body=%s", response.StatusCode, responseBody)
	}
	var chat struct {
		Choices []struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
	}
	if err := json.Unmarshal(responseBody, &chat); err != nil {
		t.Fatal(err)
	}
	if len(chat.Choices) != 1 || chat.Choices[0].Message.Content != "4" {
		t.Fatalf("unexpected inference output: %s", responseBody)
	}
	jobID := response.Header.Get(inferenceReceiptJobIDHeader)
	receiptHash := response.Header.Get(inferenceReceiptHashHeader)
	if jobID == "" || receiptHash == "" {
		t.Fatalf("receipt headers missing: job=%q hash=%q", jobID, receiptHash)
	}

	lookup, err := http.Get(ts.URL + "/v1/inference-receipts/jobs/" + jobID)
	if err != nil {
		t.Fatal(err)
	}
	lookupBody, readErr := io.ReadAll(lookup.Body)
	lookup.Body.Close()
	if readErr != nil {
		t.Fatal(readErr)
	}
	if lookup.StatusCode != http.StatusOK {
		t.Fatalf("job lookup status=%d body=%s", lookup.StatusCode, lookupBody)
	}
	if bytesContain(lookupBody, []byte("Answer precisely.")) || bytesContain(lookupBody, []byte("What is 2+2?")) || bytesContain(lookupBody, []byte("\"content\":\"4\"")) {
		t.Fatalf("receipt lookup exposed request or output plaintext: %s", lookupBody)
	}
	var lookupResult inferenceReceiptLookupResponse
	if err := json.Unmarshal(lookupBody, &lookupResult); err != nil {
		t.Fatal(err)
	}
	var envelope receipts.Envelope
	if err := json.Unmarshal(lookupResult.Receipt, &envelope); err != nil {
		t.Fatal(err)
	}
	if err := receipts.Verify(envelope, privateKey.Public().(ed25519.PublicKey)); err != nil {
		t.Fatalf("receipt signature invalid: %v", err)
	}
	payload := envelope.Payload
	canonicalHash, err := receipts.HashCanonicalJSON([]byte(body))
	if err != nil {
		t.Fatal(err)
	}
	if payload.JobID != jobID || payload.Nonce != nonce || payload.CallerRef != "key_admin_seed" ||
		payload.RequestSHA256 != canonicalHash || payload.RequestBytesSHA256 != receipts.HashBytes([]byte(body)) ||
		payload.OutputSHA256 != receipts.HashBytes([]byte("4")) || payload.RequestedModel != "test-model" || payload.ResolvedModel != "test-model" ||
		payload.Issuer != "https://receipts.example" || payload.FinishReason != "stop" {
		t.Fatalf("receipt does not bind inference: %+v", payload)
	}
	byHash, err := http.Get(ts.URL + "/v1/inference-receipts/hashes/" + receiptHash)
	if err != nil {
		t.Fatal(err)
	}
	defer byHash.Body.Close()
	if byHash.StatusCode != http.StatusOK {
		data, _ := io.ReadAll(byHash.Body)
		t.Fatalf("hash lookup status=%d body=%s", byHash.StatusCode, data)
	}
	select {
	case <-providerDone:
	case <-time.After(2 * time.Second):
		t.Fatal("provider did not finish")
	}
}

func bytesContain(haystack, needle []byte) bool {
	return strings.Contains(string(haystack), string(needle))
}

func randomReceiptKey(t *testing.T) (*receipts.Signer, ed25519.PrivateKey) {
	t.Helper()
	_, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	signer, err := receipts.NewSigner("receipt-key-test", private)
	if err != nil {
		t.Fatal(err)
	}
	return signer, private
}
