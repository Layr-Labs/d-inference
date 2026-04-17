package api

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/coordinator/internal/protocol"
	"github.com/eigeninference/coordinator/internal/store"
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
	srv, st := telemetryTestServer(t)
	batch := protocol.TelemetryBatch{Events: []protocol.TelemetryEvent{mkProtocolEvent("boom")}}
	rr := postJSON(t, srv, "/v1/telemetry/events", batch, "")
	if rr.Code != http.StatusAccepted {
		t.Fatalf("code: got %d want 202 (body=%s)", rr.Code, rr.Body.String())
	}

	events, _ := st.ListTelemetryEvents(context.Background(), store.TelemetryFilter{Limit: 10})
	if len(events) != 1 {
		t.Fatalf("stored events: got %d want 1", len(events))
	}

	// Prompt field must be stripped by the allowlist.
	if strings.Contains(string(events[0].Fields), "SECRET_DO_NOT_STORE") {
		t.Fatalf("field allowlist failed — prompt leaked: %s", events[0].Fields)
	}
	if !strings.Contains(string(events[0].Fields), "component") {
		t.Fatalf("allowed field missing: %s", events[0].Fields)
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
	srv, st := telemetryTestServer(t)
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
	events, _ := st.ListTelemetryEvents(context.Background(), store.TelemetryFilter{Limit: 10})
	if len(events) != 0 {
		t.Fatalf("expected no stored events")
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
	srv, st := telemetryTestServer(t)
	ev := mkProtocolEvent("bad-enums")
	ev.Source = "made_up"
	ev.Severity = "oops"
	ev.Kind = "also_bad"
	batch := protocol.TelemetryBatch{Events: []protocol.TelemetryEvent{ev}}
	rr := postJSON(t, srv, "/v1/telemetry/events", batch, "")
	if rr.Code != http.StatusAccepted {
		t.Fatalf("code: %d", rr.Code)
	}
	events, _ := st.ListTelemetryEvents(context.Background(), store.TelemetryFilter{Limit: 10})
	if len(events) != 1 {
		t.Fatalf("stored: %d", len(events))
	}
	if events[0].Source != "custom" {
		t.Errorf("source coercion: got %q want 'custom'", events[0].Source)
	}
	if events[0].Severity != "info" {
		t.Errorf("severity coercion: got %q want 'info'", events[0].Severity)
	}
	if events[0].Kind != "custom" {
		t.Errorf("kind coercion: got %q want 'custom'", events[0].Kind)
	}
}

func TestTelemetryAdmin_RequiresAuth(t *testing.T) {
	srv, _ := telemetryTestServer(t)
	req := httptest.NewRequest(http.MethodGet, "/v1/admin/telemetry", nil)
	rr := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rr, req)
	if rr.Code != http.StatusForbidden {
		t.Fatalf("admin without auth: got %d want 403", rr.Code)
	}
}

func TestTelemetryAdmin_ListAndSummary(t *testing.T) {
	srv, _ := telemetryTestServer(t)

	// Seed with a few events (anonymous ingest).
	batch := protocol.TelemetryBatch{Events: []protocol.TelemetryEvent{
		mkProtocolEvent("one"),
		mkProtocolEvent("two"),
	}}
	postJSON(t, srv, "/v1/telemetry/events", batch, "")

	// Admin list
	req := httptest.NewRequest(http.MethodGet, "/v1/admin/telemetry?limit=5", nil)
	req.Header.Set("Authorization", "Bearer admin-key")
	rr := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("admin list: got %d want 200", rr.Code)
	}
	var listResp struct {
		Events []any `json:"events"`
	}
	_ = json.NewDecoder(rr.Body).Decode(&listResp)
	if len(listResp.Events) != 2 {
		t.Fatalf("admin list events: got %d want 2", len(listResp.Events))
	}

	// Admin summary
	req = httptest.NewRequest(http.MethodGet, "/v1/admin/telemetry/summary?window=1h", nil)
	req.Header.Set("Authorization", "Bearer admin-key")
	rr = httptest.NewRecorder()
	srv.Handler().ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("admin summary: got %d want 200", rr.Code)
	}
}

func TestTelemetryFieldAllowlistHasKnownKeys(t *testing.T) {
	// Canonical sanity: a handful of hot-path fields must exist, else a typo
	// in the allowlist will silently drop production telemetry.
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
