package api

import (
	"context"
	"encoding/base64"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/receipts"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// storeWithoutReceipts hides the optional receipt capability, as a backend
// that does not implement it would.
type storeWithoutReceipts struct {
	store.Store
}

func TestInferenceReceiptRequestValidation(t *testing.T) {
	issuer, _ := randomReceiptIssuer(t)
	s := newReceiptTestServer(store.NewMemory(store.Config{}), issuer)
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

	withField := func(key string, value any) map[string]any {
		out := make(map[string]any, len(parsed)+1)
		for k, v := range parsed {
			out[k] = v
		}
		out[key] = value
		return out
	}
	for name, tc := range map[string]struct {
		server          *Server
		nonce           string
		parsed          map[string]any
		responses       bool
		wantUnavailable bool
	}{
		"malformed nonce":    {server: s, nonce: "guessable", parsed: parsed},
		"streaming":          {server: s, nonce: nonce, parsed: withField("stream", true)},
		"responses endpoint": {server: s, nonce: nonce, parsed: parsed, responses: true},
		"tool calls":         {server: s, nonce: nonce, parsed: withField("tools", []any{map[string]any{"type": "function"}})},
		"receipts disabled": {
			server: newReceiptTestServer(store.NewMemory(store.Config{}), nil),
			nonce:  nonce, parsed: parsed, wantUnavailable: true,
		},
		"store without receipt capability": {
			server: newReceiptTestServer(storeWithoutReceipts{Store: store.NewMemory(store.Config{})}, issuer),
			nonce:  nonce, parsed: parsed, wantUnavailable: true,
		},
	} {
		t.Run(name, func(t *testing.T) {
			request := r.Clone(r.Context())
			request.Header.Set(inferenceReceiptNonceHeader, tc.nonce)
			_, err := tc.server.newInferenceReceiptRequest(request, tc.parsed, body, "/v1/chat/completions", tc.responses)
			if err == nil {
				t.Fatal("accepted a request that cannot receive a receipt")
			}
			if got := errors.Is(err, errInferenceReceiptUnavailable); got != tc.wantUnavailable {
				t.Fatalf("unavailable = %v, want %v (err %v)", got, tc.wantUnavailable, err)
			}
		})
	}
}

func TestRejectInferenceReceiptRequestSeparatesInvalidFromUnavailable(t *testing.T) {
	s := newReceiptTestServer(store.NewMemory(store.Config{}), nil)
	for _, tc := range []struct {
		err    error
		status int
		result string
	}{
		{errors.New("receipt nonce must be canonical"), http.StatusBadRequest, "invalid"},
		{errInferenceReceiptUnavailable, http.StatusServiceUnavailable, "unavailable"},
	} {
		w := httptest.NewRecorder()
		s.rejectInferenceReceiptRequest(w, tc.err)
		if w.Code != tc.status {
			t.Fatalf("%v: status = %d, want %d", tc.err, w.Code, tc.status)
		}
		if got := receiptMetricCount(s, "inference_receipt_request_total", MetricLabel{"result", tc.result}); got != 1 {
			t.Fatalf("%s request metric = %d, want 1", tc.result, got)
		}
	}
}

func TestReserveInferenceReceiptEnforcesSingleUseNonce(t *testing.T) {
	issuer, _ := randomReceiptIssuer(t)
	s := newReceiptTestServer(store.NewMemory(store.Config{}), issuer)
	request := func(jobID string) *inferenceReceiptRequest {
		now := time.Now().UTC()
		return &inferenceReceiptRequest{JobID: jobID, Nonce: apiTestReceiptNonce(), CreatedAt: now, LookupExpiresAt: now.Add(issuer.retention)}
	}
	if err := s.reserveInferenceReceipt(context.Background(), request("job-first")); err != nil {
		t.Fatalf("first reservation: %v", err)
	}
	err := s.reserveInferenceReceipt(context.Background(), request("job-replayed-nonce"))
	if !errors.Is(err, store.ErrInferenceReceiptConflict) {
		t.Fatalf("reused nonce error = %v, want ErrInferenceReceiptConflict", err)
	}
	for result, want := range map[string]int64{"accepted": 1, "nonce_conflict": 1} {
		if got := receiptMetricCount(s, "inference_receipt_request_total", MetricLabel{"result", result}); got != want {
			t.Fatalf("%s request metric = %d, want %d", result, got, want)
		}
	}
}
