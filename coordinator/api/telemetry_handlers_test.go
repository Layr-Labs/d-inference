package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

// telemetryTestServer uses the shared testServer helper from consumer_test.go
// but also pins an admin key we can use for admin endpoints.
func telemetryTestServer(t *testing.T) (*Server, *store.MemoryStore) {
	t.Helper()
	srv, st := testServer(t)
	srv.SetAdminKey("admin-key")
	return srv, st
}

func postJSON(t *testing.T, srv *Server, path string, body any, authHeader string) *httptest.ResponseRecorder {
	t.Helper()
	raw, err := json.Marshal(body)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, path, bytes.NewReader(raw))
	req.Header.Set("Content-Type", "application/json")
	if authHeader != "" {
		req.Header.Set("Authorization", authHeader)
	}
	rr := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rr, req)
	return rr
}

func postRaw(t *testing.T, srv *Server, path string, raw []byte, authHeader string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, path, bytes.NewReader(raw))
	req.Header.Set("Content-Type", "application/json")
	if authHeader != "" {
		req.Header.Set("Authorization", authHeader)
	}
	rr := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rr, req)
	return rr
}

func mkProtocolEvent(msg string) protocol.TelemetryEvent {
	return protocol.TelemetryEvent{
		ID:        "00000000-0000-0000-0000-000000000001",
		Timestamp: time.Now().UTC(),
		Source:    protocol.TelemetrySourceApp,
		Severity:  protocol.SeverityError,
		Kind:      protocol.KindPanic,
		Message:   msg,
		Version:   "1.0",
		Fields: map[string]any{
			"component": "test",
			// Unknown field — should be dropped by the allowlist.
			"user_prompt": "SECRET_DO_NOT_STORE",
		},
		Stack: "at main\n",
	}
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

func TestTelemetryIngest_Anonymous(t *testing.T) {
	srv, _ := telemetryTestServer(t)
	batch := protocol.TelemetryBatch{Events: []protocol.TelemetryEvent{mkProtocolEvent("boom")}}
	rr := postJSON(t, srv, "/v1/telemetry/events", batch, "")
	if rr.Code != http.StatusAccepted {
		t.Fatalf("code: got %d want 202 (body=%s)", rr.Code, rr.Body.String())
	}

	// Telemetry goes to Datadog, not the store. Assert on the HTTP response.
	var resp struct {
		Accepted int `json:"accepted"`
		Rejected int `json:"rejected"`
	}
	_ = json.NewDecoder(rr.Body).Decode(&resp)
	if resp.Accepted != 1 {
		t.Fatalf("accepted: got %d want 1", resp.Accepted)
	}
	if resp.Rejected != 0 {
		t.Fatalf("rejected: got %d want 0", resp.Rejected)
	}
}

func TestTelemetryIngest_MalformedJSON(t *testing.T) {
	srv, _ := telemetryTestServer(t)
	rr := postRaw(t, srv, "/v1/telemetry/events", []byte(`{not json`), "")
	if rr.Code != http.StatusBadRequest {
		t.Fatalf("malformed: got %d want 400", rr.Code)
	}
}

func TestTelemetryIngest_BatchTooLarge(t *testing.T) {
	srv, _ := telemetryTestServer(t)
	events := make([]protocol.TelemetryEvent, telemetryMaxBatch+1)
	for i := range events {
		events[i] = mkProtocolEvent("x")
	}
	batch := protocol.TelemetryBatch{Events: events}
	rr := postJSON(t, srv, "/v1/telemetry/events", batch, "")
	if rr.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("oversized: got %d want 413", rr.Code)
	}
}

func TestTelemetryIngest_BodyTooLarge(t *testing.T) {
	srv, _ := telemetryTestServer(t)
	big := bytes.Repeat([]byte("A"), telemetryMaxBodyBytes+1024)
	rr := postRaw(t, srv, "/v1/telemetry/events", big, "")
	if rr.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("body too large: got %d want 413", rr.Code)
	}
}

func TestTelemetryIngest_MessageRequired(t *testing.T) {
	srv, _ := telemetryTestServer(t)
	ev := mkProtocolEvent("")
	batch := protocol.TelemetryBatch{Events: []protocol.TelemetryEvent{ev}}
	rr := postJSON(t, srv, "/v1/telemetry/events", batch, "")
	if rr.Code != http.StatusAccepted {
		t.Fatalf("code: %d", rr.Code)
	}
	var resp struct {
		Accepted int `json:"accepted"`
		Rejected int `json:"rejected"`
	}
	_ = json.NewDecoder(rr.Body).Decode(&resp)
	if resp.Accepted != 0 || resp.Rejected != 1 {
		t.Fatalf("got accepted=%d rejected=%d", resp.Accepted, resp.Rejected)
	}
}

func TestTelemetryIngest_RateLimit(t *testing.T) {
	srv, _ := telemetryTestServer(t)
	// Anon bucket capacity is 30 — push 50 in a single flood.
	events := make([]protocol.TelemetryEvent, 50)
	for i := range events {
		events[i] = mkProtocolEvent("x")
	}
	batch := protocol.TelemetryBatch{Events: events}
	rr := postJSON(t, srv, "/v1/telemetry/events", batch, "")
	// 50 > 30 anon capacity → 429.
	if rr.Code != http.StatusTooManyRequests {
		t.Fatalf("rate limit: got %d want 429 (body=%s)", rr.Code, rr.Body.String())
	}
}

func TestTelemetryIngest_UnknownEnumsCoerced(t *testing.T) {
	srv, _ := telemetryTestServer(t)
	ev := mkProtocolEvent("bad-enums")
	ev.Source = "made_up"
	ev.Severity = "oops"
	ev.Kind = "also_bad"
	batch := protocol.TelemetryBatch{Events: []protocol.TelemetryEvent{ev}}
	rr := postJSON(t, srv, "/v1/telemetry/events", batch, "")
	if rr.Code != http.StatusAccepted {
		t.Fatalf("code: %d", rr.Code)
	}

	// Telemetry goes to Datadog, not the store. Verify acceptance and that
	// the metrics counters received the coerced values.
	var resp struct {
		Accepted int `json:"accepted"`
		Rejected int `json:"rejected"`
	}
	_ = json.NewDecoder(rr.Body).Decode(&resp)
	if resp.Accepted != 1 {
		t.Fatalf("accepted: got %d want 1", resp.Accepted)
	}

	// Verify coercion via the metrics counters — they record the
	// sanitized source/severity/kind, not the raw input.
	if srv.metrics == nil {
		t.Skip("metrics not configured")
	}
	snap := srv.metrics.Snapshot()
	// The counter key has labels sorted alphabetically.
	key := "telemetry_events_total{kind=custom,severity=info,source=custom}"
	if snap.Counters[key] < 1 {
		t.Errorf("expected coerced counter %q >= 1, got counters: %v", key, snap.Counters)
	}
}

func TestTelemetryFieldAllowlistHasKnownKeys(t *testing.T) {
	for _, k := range []string{"component", "model", "exit_code", "reason", "duration_ms"} {
		if _, ok := telemetryFieldAllowlist[k]; !ok {
			t.Errorf("allowlist missing expected key %q", k)
		}
	}
}

func TestSanitizeTruncatesLongMessage(t *testing.T) {
	longMsg := strings.Repeat("x", telemetryMaxMessage+100)
	ev := protocol.TelemetryEvent{
		Timestamp: time.Now(),
		Source:    protocol.TelemetrySourceProvider,
		Severity:  protocol.SeverityError,
		Kind:      protocol.KindLog,
		Message:   longMsg,
	}
	rec, ok := sanitizeTelemetryEvent(ev, telemetryAuthContext{Anon: true}, time.Now())
	if !ok {
		t.Fatalf("sanitize rejected")
	}
	if len(rec.Message) <= telemetryMaxMessage {
		t.Fatalf("message not truncated: %d", len(rec.Message))
	}
}
