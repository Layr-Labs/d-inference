package api

import (
	"bytes"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
)

// The console's envelope guard must agree with the actual middleware read cap.
// Exercise real NaCl ciphertext and decryption without a provider or a listener.
func TestSealedRequest_BodyBudget(t *testing.T) {
	key, err := e2e.DeriveCoordinatorKey(senderTestMnemonic)
	if err != nil {
		t.Fatal(err)
	}
	s := &Server{coordinatorKey: key}
	const limit = 16 * 1024 * 1024
	// A 16-character kid and 44-character ephemeral key add 112 JSON bytes.
	const plaintextSize = 3*((limit-112)/4) - 24 - 16
	prefix := []byte(`{"model":"fixture","messages":[{"role":"user","content":"`)
	suffix := []byte(`"}]}`)
	plaintext := append(prefix, bytes.Repeat([]byte("a"), plaintextSize-len(prefix)-len(suffix))...)
	plaintext = append(plaintext, suffix...)
	envelope, _, _ := sealRequest(t, plaintext, key.PublicKey, key.KID)
	if len(envelope) != limit {
		t.Fatalf("sealed fixture = %d bytes, want %d", len(envelope), limit)
	}

	for _, extra := range []int{0, 1} {
		name := "exact_cap"
		if extra != 0 {
			name = "one_byte_over"
		}
		t.Run(name, func(t *testing.T) {
			body := envelope
			if extra != 0 {
				// Valid trailing JSON whitespace isolates the read cap from parsing.
				body = append(append([]byte(nil), envelope...), ' ')
			}
			req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewReader(body))
			req.Header.Set("Content-Type", SealedContentType)
			rec := httptest.NewRecorder()
			called := false
			s.sealedTransport(func(w http.ResponseWriter, r *http.Request) {
				called = true
				got, err := io.ReadAll(r.Body)
				if err != nil || !bytes.Equal(got, plaintext) {
					t.Fatalf("plaintext mismatch: len=%d err=%v", len(got), err)
				}
				if !isSealedRequest(r) || r.Header.Get("Content-Type") != "application/json" {
					t.Fatal("missing sealed handoff context or JSON content type")
				}
				w.WriteHeader(http.StatusOK)
			})(rec, req)
			if extra == 0 {
				if !called || rec.Code != http.StatusOK {
					t.Fatalf("exact-cap envelope: called=%v status=%d", called, rec.Code)
				}
			} else if called || rec.Code != http.StatusBadRequest || !bytes.Contains(rec.Body.Bytes(), []byte("invalid_request_error")) {
				t.Fatalf("over-cap envelope: called=%v status=%d body=%s", called, rec.Code, rec.Body.String())
			}
		})
	}
}
