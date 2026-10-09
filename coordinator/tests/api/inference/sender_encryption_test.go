package inference_test

import (
	"bytes"
	"encoding/base64"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	inference "github.com/eigeninference/d-inference/coordinator/api/inference"
	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"golang.org/x/crypto/nacl/box"
)

// TestSealedTransport_SSE exercises the per-event SSE sealing path directly,
// without spinning up a real coordinator (the inference handlers don't have
// a no-provider streaming branch we can hit without a fake provider). We
// build a fake "downstream" handler that emits a few SSE events, run it
// through sealedTransport, and verify each event decrypts cleanly on the
// reader side and contains the original payload in order.
func TestSealedTransport_SSE(t *testing.T) {
	srv := &inference.Owner{}

	coordKey, err := e2e.DeriveCoordinatorKey(senderTestMnemonic)
	if err != nil {
		t.Fatal(err)
	}
	srv.SetCoordinatorKey(coordKey)

	// Fake downstream handler emitting three SSE events split across multiple
	// Write calls — exercises the buffer-until-\n\n logic.
	events := []string{
		`data: {"choice":"hello"}`,
		`data: {"choice":" world"}`,
		`data: [DONE]`,
	}
	mux := http.NewServeMux()
	mux.HandleFunc("POST /v1/test-sse", srv.SealedTransport(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		f, _ := w.(http.Flusher)
		for _, e := range events {
			// Split each event across two writes to verify the writer buffers
			// correctly across Write boundaries.
			io.WriteString(w, e[:5])
			io.WriteString(w, e[5:]+"\n\n")
			if f != nil {
				f.Flush()
			}
		}
	}))
	ts := httptest.NewServer(mux)
	defer ts.Close()

	plaintext := []byte(`{"stream":true}`)
	env, _, ephemPriv := sealRequest(t, plaintext, coordKey.PublicKey, coordKey.KID)

	req, _ := http.NewRequest(http.MethodPost, ts.URL+"/v1/test-sse", bytes.NewReader(env))
	req.Header.Set("Content-Type", SealedContentType)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	if got := resp.Header.Get("Content-Type"); !strings.HasPrefix(got, "text/event-stream") {
		t.Fatalf("response content-type = %q, want SSE", got)
	}
	if got := resp.Header.Get("X-Eigen-Sealed"); got != "true" {
		t.Fatalf("X-Eigen-Sealed = %q", got)
	}

	body, _ := io.ReadAll(resp.Body)
	// Each event on the wire is `data: <b64(nonce||sealed)>\n\n`. Decode each
	// and verify it matches one of the original events in order.
	parts := bytes.Split(bytes.TrimRight(body, "\n"), []byte("\n\n"))
	if len(parts) != len(events) {
		t.Fatalf("got %d sealed events, want %d (body=%s)", len(parts), len(events), body)
	}
	for i, p := range parts {
		if !bytes.HasPrefix(p, []byte("data: ")) {
			t.Fatalf("event %d missing data: prefix: %q", i, p)
		}
		ctB64 := bytes.TrimPrefix(p, []byte("data: "))
		ct, err := base64.StdEncoding.DecodeString(string(ctB64))
		if err != nil {
			t.Fatalf("event %d b64 decode: %v", i, err)
		}
		var nonce [24]byte
		copy(nonce[:], ct[:24])
		pt, ok := box.Open(nil, ct[24:], &nonce, &coordKey.PublicKey, ephemPriv)
		if !ok {
			t.Fatalf("event %d decrypt failed", i)
		}
		if string(pt) != events[i] {
			t.Fatalf("event %d mismatch:\n got: %q\nwant: %q", i, pt, events[i])
		}
	}
}

// Reusing the request's key agreement must not reuse nonces or leak the key
// across consumers. Include a final partial event to exercise finish as well
// as the normal blank-line-delimited path.
func TestSealedTransportRequestKeyIsolation(t *testing.T) {
	key, err := e2e.DeriveCoordinatorKey(senderTestMnemonic)
	if err != nil {
		t.Fatal(err)
	}
	srv := &inference.Owner{}
	srv.SetCoordinatorKey(key)
	const event = `data: {"choices":[{"delta":{"content":"same text"}}]}`
	handler := srv.SealedTransport(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		io.WriteString(w, event+"\n\n"+event+"\n\n"+event)
	})
	var clients []*[32]byte
	var ciphertexts [][]byte
	nonces := make(map[[24]byte]bool)
	for i := 0; i < 2; i++ {
		envelope, _, private := sealRequest(t, []byte(`{"stream":true}`), key.PublicKey, key.KID)
		clients = append(clients, private)
		r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewReader(envelope))
		r.Header.Set("Content-Type", SealedContentType)
		w := httptest.NewRecorder()
		handler(w, r)
		parts := bytes.Split(bytes.TrimSpace(w.Body.Bytes()), []byte("\n\n"))
		if len(parts) != 3 {
			t.Fatalf("request %d: got %d events, want 3", i, len(parts))
		}
		for _, part := range parts {
			ciphertext, err := base64.StdEncoding.DecodeString(string(bytes.TrimPrefix(part, []byte("data: "))))
			if err != nil || len(ciphertext) < 24+box.Overhead {
				t.Fatalf("invalid sealed event: %v", err)
			}
			var nonce [24]byte
			copy(nonce[:], ciphertext[:24])
			if nonces[nonce] {
				t.Fatal("nonce reused across sealed events")
			}
			nonces[nonce] = true
			plaintext, ok := box.Open(nil, ciphertext[24:], &nonce, &key.PublicKey, private)
			if !ok || string(plaintext) != event {
				t.Fatalf("request %d: original NaCl Box client could not decode event", i)
			}
			ciphertexts = append(ciphertexts, ciphertext)
		}
	}
	for i, ciphertext := range ciphertexts {
		var nonce [24]byte
		copy(nonce[:], ciphertext[:24])
		if _, ok := box.Open(nil, ciphertext[24:], &nonce, &key.PublicKey, clients[1-i/3]); ok {
			t.Fatal("another consumer decrypted the response")
		}
	}
}
