package api

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// Regression for the plaintext inference body cap: the path read the request
// body with an unbounded io.ReadAll, so any API-key holder could POST a multi-GB
// body and OOM the coordinator (the trusted TEE component). parseInferencePrelude
// now caps it with http.MaxBytesReader. These exercise the prelude directly — the
// size check returns before any auth/store access, so a zero-value Server
// suffices. (infiniteReader is shared from body_cap_test.go in this package.)

// Load-bearing regression: without the cap, io.ReadAll consumes the whole
// oversized body and the request falls through to a 400 (invalid JSON) — this
// asserts 413, so it fails on the unpatched code.
func TestParseInferencePreludeRejectsOversizedBody(t *testing.T) {
	s := &Server{}
	body := io.LimitReader(infiniteReader{}, int64(maxInferenceBodyBytes)+1)
	r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", body)
	w := httptest.NewRecorder()

	if _, ok := s.parseInferencePrelude(w, r); ok {
		t.Fatal("expected parseInferencePrelude to reject the oversized body")
	}
	if w.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("oversized body: got status %d, want 413", w.Code)
	}
}

// False-trigger guard (NOT a fail-without-fix regression — an 8-byte body never
// hits the cap, so this passes with or without the fix): a small invalid-JSON
// body must fail JSON parsing (400), not the size cap (413), proving the cap
// doesn't reject normal-sized requests.
func TestParseInferencePreludeUnderCapNotSizeRejected(t *testing.T) {
	s := &Server{}
	r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions",
		bytes.NewReader([]byte("not json")))
	w := httptest.NewRecorder()

	if _, ok := s.parseInferencePrelude(w, r); ok {
		t.Fatal("expected invalid JSON to be rejected")
	}
	if w.Code == http.StatusRequestEntityTooLarge {
		t.Fatal("under-cap body was wrongly rejected as too large (413)")
	}
	if w.Code != http.StatusBadRequest {
		t.Fatalf("invalid JSON: got status %d, want 400", w.Code)
	}
}

// Regression for the re-marshal inflation that the read cap alone didn't catch:
// the handlers re-marshal the parsed body before sealing it, and encoding/json's
// default HTML escaping turns each '<' '>' '&' into a 6-byte \uXXXX escape. A
// benign body that fit the read cap could thus re-marshal ~6× larger and produce
// a WebSocket frame the provider rejects (tearing down its session). The forward
// marshaler disables HTML escaping; this asserts the angle brackets survive raw
// and the output tracks the input size instead of exploding.
func TestMarshalForwardBodyDoesNotHTMLEscape(t *testing.T) {
	const n = 1 << 20 // 1 MiB of '<'
	body := map[string]any{
		"model":    "m",
		"messages": []any{map[string]any{"role": "user", "content": strings.Repeat("<", n)}},
	}

	got, err := marshalForwardBody(body)
	if err != nil {
		t.Fatalf("marshalForwardBody: %v", err)
	}
	// The 6-byte JSON escape for '<' is the ASCII run \ u 0 0 3 c.
	escapedAngle := []byte{'\\', 'u', '0', '0', '3', 'c'}
	if bytes.Contains(got, escapedAngle) {
		t.Fatal(`marshalForwardBody HTML-escaped '<' to < — expected raw bytes`)
	}
	if !bytes.Contains(got, bytes.Repeat([]byte("<"), 8)) {
		t.Fatal("marshalForwardBody dropped the raw '<' run")
	}
	if got[len(got)-1] == '\n' {
		t.Fatal("marshalForwardBody left the encoder's trailing newline")
	}

	// The unescaped body must track the input (~1 MiB + small envelope); the
	// default escaping marshaler inflates the same body ~6×. Prove the gap.
	escaped, err := json.Marshal(body)
	if err != nil {
		t.Fatalf("json.Marshal: %v", err)
	}
	if len(escaped) <= len(got) {
		t.Fatalf("expected default Marshal (%d) larger than unescaped (%d)", len(escaped), len(got))
	}
	if len(got) > n+4096 {
		t.Fatalf("unescaped body unexpectedly large: %d bytes (input ~%d)", len(got), n)
	}
}
