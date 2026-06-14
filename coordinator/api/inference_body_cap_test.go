package api

import (
	"bytes"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
)

// Regression for OOM-M1: the plaintext inference path read the request body with
// an unbounded io.ReadAll, so any API-key holder could POST a multi-GB body and
// OOM the coordinator (the trusted TEE component). parseInferencePrelude now caps
// it with http.MaxBytesReader. These exercise the prelude directly — the size
// check returns before any auth/store access, so a zero-value Server suffices.

// infiniteReader yields 'a' forever; used with io.LimitReader so the oversized
// test streams cap+1 bytes instead of allocating the whole over-cap body.
type infiniteReader struct{}

func (infiniteReader) Read(p []byte) (int, error) {
	for i := range p {
		p[i] = 'a'
	}
	return len(p), nil
}

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
