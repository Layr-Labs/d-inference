package api

import (
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// TestNewPrefillKeepaliver: the keepaliver is gated on the server interval —
// disabled (interval 0, the default) returns nil; enabled returns a keepaliver.
func TestNewPrefillKeepaliver(t *testing.T) {
	srv, _ := testServer(t)

	// Default interval (0) → keepalives disabled → nil.
	rec := httptest.NewRecorder()
	if k := srv.newPrefillKeepaliver(rec, "job-1"); k != nil {
		t.Fatalf("newPrefillKeepaliver with interval 0 = %v, want nil", k)
	}

	// Enabled interval → non-nil.
	srv.SetPrefillKeepaliveInterval(5 * time.Millisecond)
	rec = httptest.NewRecorder()
	if k := srv.newPrefillKeepaliver(rec, "job-1"); k == nil {
		t.Fatal("newPrefillKeepaliver with interval 5ms = nil, want non-nil")
	}
}

// TestPrefillKeepaliverWriteKeepalive drives writeKeepalive synchronously (no
// goroutine) to avoid racing on the recorder: the first call commits the SSE 200
// header and one comment; the second appends a second comment without rewriting
// the header.
func TestPrefillKeepaliverWriteKeepalive(t *testing.T) {
	srv, _ := testServer(t)
	srv.SetPrefillKeepaliveInterval(5 * time.Millisecond)
	rec := httptest.NewRecorder()
	k := srv.newPrefillKeepaliver(rec, "job-xyz")
	if k == nil {
		t.Fatal("newPrefillKeepaliver = nil, want non-nil")
	}

	// First keepalive commits the SSE 200 header and writes one comment.
	if !k.writeKeepalive() {
		t.Fatal("first writeKeepalive() = false, want true")
	}
	if rec.Code != 200 {
		t.Errorf("rec.Code = %d, want 200", rec.Code)
	}
	if ct := rec.Header().Get("Content-Type"); ct != "text/event-stream" {
		t.Errorf("Content-Type = %q, want text/event-stream", ct)
	}
	if n := strings.Count(rec.Body.String(), ": keepalive"); n != 1 {
		t.Errorf("keepalive count after one write = %d, want 1", n)
	}

	// Second keepalive: still true, a second comment, header NOT rewritten.
	if !k.writeKeepalive() {
		t.Fatal("second writeKeepalive() = false, want true")
	}
	if n := strings.Count(rec.Body.String(), ": keepalive"); n != 2 {
		t.Errorf("keepalive count after two writes = %d, want 2", n)
	}
	if vs := rec.Header()["Content-Type"]; len(vs) != 1 || vs[0] != "text/event-stream" {
		t.Errorf("Content-Type header rewritten: %v, want single [text/event-stream]", vs)
	}
}

// TestPrefillKeepaliverTakeOver covers ownership handoff: takeOver reports
// whether a keepalive committed, after which writeKeepalive is a no-op; an
// uncommitted keepaliver and a nil keepaliver both report false.
func TestPrefillKeepaliverTakeOver(t *testing.T) {
	srv, _ := testServer(t)
	srv.SetPrefillKeepaliveInterval(5 * time.Millisecond)

	// Committed keepaliver: takeOver reports true; further writes are no-ops.
	rec := httptest.NewRecorder()
	k := srv.newPrefillKeepaliver(rec, "job-1")
	if k == nil {
		t.Fatal("newPrefillKeepaliver = nil, want non-nil")
	}
	if !k.writeKeepalive() {
		t.Fatal("writeKeepalive() = false, want true")
	}
	if !k.takeOver() {
		t.Fatal("takeOver() after commit = false, want true")
	}
	before := rec.Body.String()
	if k.writeKeepalive() {
		t.Error("writeKeepalive() after takeOver = true, want false")
	}
	if after := rec.Body.String(); after != before {
		t.Errorf("body changed after takeOver: before=%q after=%q", before, after)
	}

	// Brand-new (uncommitted) keepaliver: takeOver reports false.
	rec2 := httptest.NewRecorder()
	k2 := srv.newPrefillKeepaliver(rec2, "job-2")
	if k2 == nil {
		t.Fatal("newPrefillKeepaliver = nil, want non-nil")
	}
	if k2.takeOver() {
		t.Error("takeOver() on uncommitted keepaliver = true, want false")
	}

	// Nil keepaliver: takeOver reports false (keepalives disabled).
	var k3 *prefillKeepaliver
	if k3.takeOver() {
		t.Error("nil keepaliver takeOver() = true, want false")
	}
}

// TestWriteSSEResponseHeader pins the shared SSE response header: status 200,
// event-stream content type, and the per-job correlation header.
func TestWriteSSEResponseHeader(t *testing.T) {
	rec := httptest.NewRecorder()
	writeSSEResponseHeader(rec, "job-123")

	if rec.Code != 200 {
		t.Errorf("rec.Code = %d, want 200", rec.Code)
	}
	if ct := rec.Header().Get("Content-Type"); ct != "text/event-stream" {
		t.Errorf("Content-Type = %q, want text/event-stream", ct)
	}
	if cc := rec.Header().Get("Cache-Control"); cc != "no-cache" {
		t.Errorf("Cache-Control = %q, want no-cache", cc)
	}
	if id := rec.Header().Get("X-Inference-Job-ID"); id != "job-123" {
		t.Errorf("X-Inference-Job-ID = %q, want job-123", id)
	}
}

// TestWriteSSEErrorEvent confirms a terminal in-band error is emitted as a
// data: {...} event carrying the error payload, followed by data: [DONE].
func TestWriteSSEErrorEvent(t *testing.T) {
	rec := httptest.NewRecorder()
	writeSSEErrorEvent(rec, errorResponse("provider_error", "boom"))

	body := rec.Body.String()
	if !strings.Contains(body, "data: ") {
		t.Errorf("body missing data: line: %q", body)
	}
	errIdx := strings.Index(body, "provider_error")
	if errIdx < 0 {
		t.Fatalf("body missing provider_error error payload: %q", body)
	}
	doneIdx := strings.Index(body, "data: [DONE]")
	if doneIdx < 0 {
		t.Fatalf("body missing data: [DONE] terminator: %q", body)
	}
	if doneIdx < errIdx {
		t.Errorf("data: [DONE] must follow the error event; body=%q", body)
	}
}

// TestWriteResponsesSSEErrorEvent confirms the Responses-API-shaped terminal
// error is emitted as an `event: error` SSE event carrying the error type and
// message, with NO data: [DONE] terminator (strict Responses clients end on the
// error event, unlike the chat-completions shape).
func TestWriteResponsesSSEErrorEvent(t *testing.T) {
	rec := httptest.NewRecorder()
	writeResponsesSSEErrorEvent(rec, "provider_error", "boom")

	body := rec.Body.String()
	if !strings.Contains(body, "event: error") {
		t.Errorf("body missing event: error line: %q", body)
	}
	if !strings.Contains(body, "provider_error") {
		t.Errorf("body missing provider_error error type: %q", body)
	}
	if !strings.Contains(body, "boom") {
		t.Errorf("body missing boom error message: %q", body)
	}
	if strings.Contains(body, "[DONE]") {
		t.Errorf("Responses error event must not emit [DONE]; body=%q", body)
	}
}
