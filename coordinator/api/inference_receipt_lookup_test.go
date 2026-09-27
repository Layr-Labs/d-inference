package api

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/receipts"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// storeCompletedReceipt signs a payload and stores it as a completed row.
func storeCompletedReceipt(t *testing.T, st *store.MemoryStore, signer *receipts.Signer, jobID string, completedAt, expiresAt time.Time) receipts.Envelope {
	t.Helper()
	payload := receipts.Payload{
		SchemaVersion: 1, Issuer: receiptTestIssuer, JobID: jobID, WinningAttemptID: "attempt",
		Nonce: apiTestReceiptNonce(), CallerRef: "key",
		RequestSHA256: strings.Repeat("a", 64), RequestBytesSHA256: strings.Repeat("b", 64), ProviderRequestSHA256: strings.Repeat("c", 64),
		RequestedModel: "model", ResolvedModel: "model", OutputSHA256: receipts.HashBytes([]byte("done")),
		Status: "completed", FinishReason: "stop", CompletedAt: completedAt, LookupExpiresAt: expiresAt,
	}
	envelope, err := signer.Sign(payload)
	if err != nil {
		t.Fatal(err)
	}
	envelopeJSON, err := json.Marshal(envelope)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.CreateInferenceReceipt(context.Background(), store.InferenceReceiptRecord{
		JobID: jobID, Nonce: payload.Nonce, ReceiptHash: envelope.ReceiptHash, State: store.InferenceReceiptCompleted,
		Envelope: envelopeJSON, CreatedAt: completedAt, UpdatedAt: completedAt, ExpiresAt: expiresAt,
	}); err != nil {
		t.Fatal(err)
	}
	return envelope
}

func lookupReceipt(s *Server, handler func(http.ResponseWriter, *http.Request), jobID, hash string) *httptest.ResponseRecorder {
	w := httptest.NewRecorder()
	r := httptest.NewRequest(http.MethodGet, "/", nil)
	r.SetPathValue("job_id", jobID)
	r.SetPathValue("receipt_hash", hash)
	handler(w, r)
	return w
}

func TestInferenceReceiptLookupHidesExpiredAndMissing(t *testing.T) {
	issuer, private := randomReceiptIssuer(t)
	st := store.NewMemory(store.Config{})
	s := newReceiptTestServer(st, issuer)
	signer, err := receipts.NewSigner("receipt-key-test", private)
	if err != nil {
		t.Fatal(err)
	}
	// Strict payload rules never sign an already-expired receipt, so store a
	// valid envelope whose lookup window has since closed.
	completedAt := time.Now().UTC().Add(-2 * time.Hour)
	envelope := storeCompletedReceipt(t, st, signer, "job-expired-receipt", completedAt, completedAt.Add(time.Minute))
	for route, handler := range map[string]func(http.ResponseWriter, *http.Request){
		"job":  s.handleInferenceReceiptByJobID,
		"hash": s.handleInferenceReceiptByHash,
	} {
		if w := lookupReceipt(s, handler, "job-expired-receipt", envelope.ReceiptHash); w.Code != http.StatusNotFound {
			t.Fatalf("%s: expired receipt status = %d, body=%s", route, w.Code, w.Body.String())
		}
	}
	if w := lookupReceipt(s, s.handleInferenceReceiptByJobID, "missing-job", ""); w.Code != http.StatusNotFound {
		t.Fatalf("missing receipt status = %d", w.Code)
	}
	if got := receiptMetricCount(s, "inference_receipt_lookup_total", MetricLabel{"route", "job"}, MetricLabel{"result", "not_found"}); got != 2 {
		t.Fatalf("job not_found lookup metric = %d, want 2", got)
	}
}

func TestInferenceReceiptLookupRejectsReceiptWhoseKeyLeftTheRing(t *testing.T) {
	issuer, _ := randomReceiptIssuer(t)
	st := store.NewMemory(store.Config{})
	s := newReceiptTestServer(st, issuer)
	_, retired, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	retiredSigner, err := receipts.NewSigner("receipt-key-retired", retired)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	storeCompletedReceipt(t, st, retiredSigner, "job-rotated-away", now, now.Add(time.Hour))

	w := lookupReceipt(s, s.handleInferenceReceiptByJobID, "job-rotated-away", "")
	if w.Code != http.StatusServiceUnavailable {
		t.Fatalf("receipt with unpublished key: status = %d, want 503; body=%s", w.Code, w.Body.String())
	}
	if got := receiptMetricCount(s, "inference_receipt_lookup_total", MetricLabel{"route", "job"}, MetricLabel{"result", "key_unavailable"}); got != 1 {
		t.Fatalf("key_unavailable lookup metric = %d, want 1", got)
	}
}

// failingReceiptLookupStore is a memory store whose receipt reads fail, as a
// Postgres outage would.
type failingReceiptLookupStore struct {
	*store.MemoryStore
}

func (failingReceiptLookupStore) GetInferenceReceiptByJobID(context.Context, string) (store.InferenceReceiptRecord, error) {
	return store.InferenceReceiptRecord{}, errors.New("connection reset")
}

func (failingReceiptLookupStore) GetInferenceReceiptByHash(context.Context, string) (store.InferenceReceiptRecord, error) {
	return store.InferenceReceiptRecord{}, errors.New("connection reset")
}

func TestInferenceReceiptLookupReportsStoreFailureAsUnavailable(t *testing.T) {
	s := newReceiptTestServer(failingReceiptLookupStore{MemoryStore: store.NewMemory(store.Config{})}, nil)
	for route, handler := range map[string]func(http.ResponseWriter, *http.Request){
		"job":  s.handleInferenceReceiptByJobID,
		"hash": s.handleInferenceReceiptByHash,
	} {
		w := lookupReceipt(s, handler, "job", strings.Repeat("a", 64))
		if w.Code != http.StatusServiceUnavailable {
			t.Fatalf("%s lookup status = %d, want 503; body=%s", route, w.Code, w.Body.String())
		}
		if got := receiptMetricCount(s, "inference_receipt_lookup_total", MetricLabel{"route", route}, MetricLabel{"result", "store_error"}); got != 1 {
			t.Fatalf("%s store_error lookup metric = %d, want 1", route, got)
		}
	}
}

func TestInferenceReceiptKeysPublishActiveAndRetainedKeys(t *testing.T) {
	_, active, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	retired, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	issuer := newReceiptTestIssuer(t, "receipt-2026-09", active, map[string]ed25519.PublicKey{"receipt-2026-06": retired})
	s := newReceiptTestServer(store.NewMemory(store.Config{}), issuer)

	w := httptest.NewRecorder()
	s.handleInferenceReceiptKeys(w, httptest.NewRequest(http.MethodGet, "/v1/inference-receipts/keys", nil))
	if w.Code != http.StatusOK || w.Header().Get("Cache-Control") != "public, max-age=300" {
		t.Fatalf("keys status = %d, cache = %q", w.Code, w.Header().Get("Cache-Control"))
	}
	var body inferenceReceiptKeysResponse
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if body.Issuer != receiptTestIssuer || len(body.Keys) != 2 ||
		body.Keys[0].KeyID != "receipt-2026-06" || body.Keys[0].PublicKey != base64.StdEncoding.EncodeToString(retired) ||
		body.Keys[1].KeyID != "receipt-2026-09" || body.Keys[1].PublicKey != base64.StdEncoding.EncodeToString(active.Public().(ed25519.PublicKey)) {
		t.Fatalf("keys response = %+v", body)
	}

	disabled := newReceiptTestServer(store.NewMemory(store.Config{}), nil)
	w = httptest.NewRecorder()
	disabled.handleInferenceReceiptKeys(w, httptest.NewRequest(http.MethodGet, "/v1/inference-receipts/keys", nil))
	if w.Code != http.StatusServiceUnavailable {
		t.Fatalf("disabled keys status = %d, want 503", w.Code)
	}
}
