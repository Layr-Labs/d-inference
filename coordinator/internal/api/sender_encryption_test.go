package api

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"golang.org/x/crypto/nacl/box"

	"github.com/darkbloom/coordinator/internal/e2e"
	"github.com/darkbloom/coordinator/internal/registry"
	"github.com/darkbloom/coordinator/internal/store"
)

const senderTestMnemonic = "praise warfare warrior rebuild raven garlic kite blast crew impulse pencil hidden"

func newEncryptedTestServer(t *testing.T) (*httptest.Server, *e2e.CoordinatorKey) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	// Seed a one-entry catalog so requests for any other model fast-fail with
	// 404 model_not_found instead of queueing for 120s waiting on a provider.
	reg.SetModelCatalog([]registry.CatalogEntry{{ID: "test-known-model"}})
	srv := NewServer(reg, st, logger)

	coordKey, err := e2e.DeriveCoordinatorKey(senderTestMnemonic)
	if err != nil {
		t.Fatalf("derive coordinator key: %v", err)
	}
	srv.SetCoordinatorKey(coordKey)

	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)
	return ts, coordKey
}

func TestEncryptionKeyEndpoint(t *testing.T) {
	ts, coordKey := newEncryptedTestServer(t)

	resp, err := http.Get(ts.URL + "/v1/encryption-key")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d", resp.StatusCode)
	}
	var body struct {
		KID       string `json:"kid"`
		PublicKey string `json:"public_key"`
		Algorithm string `json:"algorithm"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatal(err)
	}
	if body.KID != coordKey.KID {
		t.Fatalf("kid mismatch: %q != %q", body.KID, coordKey.KID)
	}
	if body.Algorithm != "x25519-nacl-box" {
		t.Fatalf("algorithm = %q", body.Algorithm)
	}
	pub, err := base64.StdEncoding.DecodeString(body.PublicKey)
	if err != nil || len(pub) != 32 {
		t.Fatalf("public_key invalid: err=%v len=%d", err, len(pub))
	}
	if !bytes.Equal(pub, coordKey.PublicKey[:]) {
		t.Fatal("published public key differs from derived public key")
	}
}

func TestEncryptionKeyEndpoint_Disabled(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)
	// No SetCoordinatorKey call → endpoint should report 503.

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	resp, err := http.Get(ts.URL + "/v1/encryption-key")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want 503", resp.StatusCode)
	}
}

// sealRequest is the test-side mirror of what the console-ui will do.
func sealRequest(t *testing.T, plaintext []byte, coordPub [32]byte, kid string) ([]byte, *[32]byte, *[32]byte) {
	t.Helper()
	ephemPub, ephemPriv, err := box.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	var nonce [24]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		t.Fatal(err)
	}
	sealed := box.Seal(nonce[:], plaintext, &nonce, &coordPub, ephemPriv)
	env, _ := json.Marshal(map[string]any{
		"kid":                  kid,
		"ephemeral_public_key": base64.StdEncoding.EncodeToString(ephemPub[:]),
		"ciphertext":           base64.StdEncoding.EncodeToString(sealed),
	})
	return env, ephemPub, ephemPriv
}

// unsealResponse is the test-side mirror of what the console-ui will do for
// non-streaming sealed responses.
func unsealResponse(t *testing.T, body []byte, coordPub [32]byte, ephemPriv *[32]byte) []byte {
	t.Helper()
	var env struct {
		KID        string `json:"kid"`
		Ciphertext string `json:"ciphertext"`
	}
	if err := json.Unmarshal(body, &env); err != nil {
		t.Fatalf("response is not a sealed envelope: %v\nbody: %s", err, body)
	}
	ct, err := base64.StdEncoding.DecodeString(env.Ciphertext)
	if err != nil {
		t.Fatalf("response ciphertext bad b64: %v", err)
	}
	if len(ct) < 24 {
		t.Fatalf("response ciphertext too short")
	}
	var nonce [24]byte
	copy(nonce[:], ct[:24])
	pt, ok := box.Open(nil, ct[24:], &nonce, &coordPub, ephemPriv)
	if !ok {
		t.Fatal("response decrypt failed")
	}
	return pt
}

// TestSealedRequest_RoundTrip confirms the middleware decrypts the request,
// the inference handler sees plaintext, and the error response (no providers
// available) gets sealed back to the sender on the way out.
func TestSealedRequest_RoundTrip(t *testing.T) {
	ts, coordKey := newEncryptedTestServer(t)

	plaintext := []byte(`{"model":"qwen3.5-no-such-model","messages":[{"role":"user","content":"hi"}]}`)
	env, _, ephemPriv := sealRequest(t, plaintext, coordKey.PublicKey, coordKey.KID)

	req, _ := http.NewRequestWithContext(context.Background(), http.MethodPost, ts.URL+"/v1/chat/completions", bytes.NewReader(env))
	req.Header.Set("Content-Type", SealedContentType)
	req.Header.Set("Authorization", "Bearer test-key")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)

	// The handler should have returned a model-not-found error (sealed).
	// Verify the response is sealed and decrypts to a sane error JSON.
	if got := resp.Header.Get("Content-Type"); !strings.HasPrefix(got, SealedContentType) {
		t.Fatalf("response content-type = %q, want sealed; body=%s", got, body)
	}
	if got := resp.Header.Get("X-Eigen-Sealed"); got != "true" {
		t.Fatalf("X-Eigen-Sealed = %q", got)
	}
	pt := unsealResponse(t, body, coordKey.PublicKey, ephemPriv)

	var errBody struct {
		Error struct {
			Type    string `json:"type"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal(pt, &errBody); err != nil {
		t.Fatalf("decrypted body is not an error JSON: %v\nbody: %s", err, pt)
	}
	if errBody.Error.Type != "model_not_found" {
		t.Fatalf("error type = %q (decrypted body = %s)", errBody.Error.Type, pt)
	}
}

// TestSealedRequest_TamperedCiphertext flips a byte in the ciphertext and
// expects a 400 with a clear error type.
func TestSealedRequest_TamperedCiphertext(t *testing.T) {
	ts, coordKey := newEncryptedTestServer(t)

	plaintext := []byte(`{"model":"x","messages":[{"role":"user","content":"hi"}]}`)
	env, _, _ := sealRequest(t, plaintext, coordKey.PublicKey, coordKey.KID)

	// Mutate ciphertext field.
	var parsed map[string]any
	json.Unmarshal(env, &parsed)
	ctB64 := parsed["ciphertext"].(string)
	ct, _ := base64.StdEncoding.DecodeString(ctB64)
	ct[len(ct)-1] ^= 0xff
	parsed["ciphertext"] = base64.StdEncoding.EncodeToString(ct)
	env2, _ := json.Marshal(parsed)

	req, _ := http.NewRequest(http.MethodPost, ts.URL+"/v1/chat/completions", bytes.NewReader(env2))
	req.Header.Set("Content-Type", SealedContentType)
	req.Header.Set("Authorization", "Bearer test-key")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400; body=%s", resp.StatusCode, body)
	}
	if !bytes.Contains(body, []byte("decryption_failed")) {
		t.Fatalf("expected decryption_failed error, got: %s", body)
	}
}

// TestSealedRequest_WrongKID seals to a kid that doesn't match the coordinator
// — should be rejected up front, before any decryption attempt.
func TestSealedRequest_WrongKID(t *testing.T) {
	ts, coordKey := newEncryptedTestServer(t)

	plaintext := []byte(`{"model":"x","messages":[{"role":"user","content":"hi"}]}`)
	env, _, _ := sealRequest(t, plaintext, coordKey.PublicKey, "deadbeefdeadbeef")

	req, _ := http.NewRequest(http.MethodPost, ts.URL+"/v1/chat/completions", bytes.NewReader(env))
	req.Header.Set("Content-Type", SealedContentType)
	req.Header.Set("Authorization", "Bearer test-key")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("status = %d", resp.StatusCode)
	}
	if !bytes.Contains(body, []byte("kid_mismatch")) {
		t.Fatalf("expected kid_mismatch, got: %s", body)
	}
}

// TestSealedRequest_CaseInsensitiveContentType regression-guards the
// reviewer-flagged bug: the gate was case-sensitive HasPrefix, so a client
// sending Application/Darkbloom-Sealed+json would silently fall through
// to the plaintext handler. RFC 7231 §3.1.1.1 says media types are
// case-insensitive.
func TestSealedRequest_CaseInsensitiveContentType(t *testing.T) {
	ts, coordKey := newEncryptedTestServer(t)

	plaintext := []byte(`{"model":"qwen3.5-no-such-model","messages":[{"role":"user","content":"hi"}]}`)
	env, _, ephemPriv := sealRequest(t, plaintext, coordKey.PublicKey, coordKey.KID)

	req, _ := http.NewRequest(http.MethodPost, ts.URL+"/v1/chat/completions", bytes.NewReader(env))
	// Mixed case + a charset parameter — both should be tolerated.
	req.Header.Set("Content-Type", "Application/Darkbloom-Sealed+JSON; charset=utf-8")
	req.Header.Set("Authorization", "Bearer test-key")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)

	if got := resp.Header.Get("Content-Type"); !strings.HasPrefix(strings.ToLower(got), SealedContentType) {
		t.Fatalf("middleware did not engage on mixed-case content-type: ct=%q body=%s", got, body)
	}
	pt := unsealResponse(t, body, coordKey.PublicKey, ephemPriv)
	if !bytes.Contains(pt, []byte("model_not_found")) {
		t.Fatalf("expected model_not_found inside sealed response, got: %s", pt)
	}
}

// TestSealedRequest_LegacyContentType verifies that the pre-rename content
// type (application/eigeninference-sealed+json) is still accepted during the
// transition period so existing clients are not silently dropped to plaintext.
func TestSealedRequest_LegacyContentType(t *testing.T) {
	ts, coordKey := newEncryptedTestServer(t)

	plaintext := []byte(`{"model":"qwen3.5-no-such-model","messages":[{"role":"user","content":"hi"}]}`)
	env, _, ephemPriv := sealRequest(t, plaintext, coordKey.PublicKey, coordKey.KID)

	req, _ := http.NewRequest(http.MethodPost, ts.URL+"/v1/chat/completions", bytes.NewReader(env))
	req.Header.Set("Content-Type", LegacySealedContentType)
	req.Header.Set("Authorization", "Bearer test-key")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)

	if got := resp.Header.Get("Content-Type"); !strings.HasPrefix(strings.ToLower(got), SealedContentType) {
		t.Fatalf("middleware did not engage on legacy content-type: ct=%q body=%s", got, body)
	}
	pt := unsealResponse(t, body, coordKey.PublicKey, ephemPriv)
	if !bytes.Contains(pt, []byte("model_not_found")) {
		t.Fatalf("expected model_not_found inside sealed response, got: %s", pt)
	}
}

// TestSealedTransport_SSE exercises the per-event SSE sealing path directly,
// without spinning up a real coordinator (the inference handlers don't have
// a no-provider streaming branch we can hit without a fake provider). We
// build a fake "downstream" handler that emits a few SSE events, run it
// through sealedTransport, and verify each event decrypts cleanly on the
// reader side and contains the original payload in order.
func TestSealedTransport_SSE(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)

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
	mux.HandleFunc("POST /v1/test-sse", srv.sealedTransport(func(w http.ResponseWriter, r *http.Request) {
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

// TestSealedRequest_PlaintextStillWorks is the regression test: an ordinary
// JSON POST to the same endpoint must continue to work exactly as before.
func TestSealedRequest_PlaintextStillWorks(t *testing.T) {
	ts, _ := newEncryptedTestServer(t)

	plaintext := []byte(`{"model":"qwen3.5-no-such-model","messages":[{"role":"user","content":"hi"}]}`)
	req, _ := http.NewRequest(http.MethodPost, ts.URL+"/v1/chat/completions", bytes.NewReader(plaintext))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer test-key")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)

	if got := resp.Header.Get("Content-Type"); strings.HasPrefix(got, SealedContentType) {
		t.Fatalf("plaintext request got sealed response: ct=%q body=%s", got, body)
	}

	// Should be a normal JSON error, model_not_found.
	if !bytes.Contains(body, []byte("model_not_found")) {
		t.Fatalf("expected model_not_found in plaintext body, got: %s", body)
	}
}
