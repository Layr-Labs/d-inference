package api

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

type telemetryReadSpy struct {
	reader *strings.Reader
	reads  int
}

func (b *telemetryReadSpy) Read(p []byte) (int, error) {
	b.reads++
	return b.reader.Read(p)
}

func (b *telemetryReadSpy) Close() error { return nil }

func TestTelemetryIngestIsGoneWithoutReadingOrForwardingBody(t *testing.T) {
	const sentinel = "PROMPT_SECRET_DO_NOT_EXFILTRATE"
	body := &telemetryReadSpy{reader: strings.NewReader(`{"events":[{"message":"` + sentinel + `"}]}`)}

	srv, _ := testServer(t)
	collector := newUDPCollector(t)
	defer collector.Close()
	dd := newTestDD(t, collector)
	defer dd.Close()
	srv.SetDatadog(dd)

	req := httptest.NewRequest(http.MethodPost, "/v1/telemetry/events", nil)
	req.Body = body
	req.Header.Set("Content-Type", "application/json")
	rr := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rr, req)

	if rr.Code != http.StatusGone {
		t.Fatalf("status = %d, want %d (body=%s)", rr.Code, http.StatusGone, rr.Body.String())
	}
	if body.reads != 0 {
		t.Fatalf("telemetry request body was read %d time(s)", body.reads)
	}
	if strings.Contains(rr.Body.String(), sentinel) {
		t.Fatalf("request data reflected in response: %s", rr.Body.String())
	}

	if srv.metrics != nil {
		for key, value := range srv.metrics.Snapshot().Counters {
			if strings.HasPrefix(key, "telemetry_events_total") && value != 0 {
				t.Fatalf("ingest counter changed despite disabled sink: %s=%d", key, value)
			}
		}
	}
	_ = dd.Statsd.Flush()
	for _, packet := range collector.drain() {
		if strings.Contains(packet, "telemetry.events_ingested") {
			t.Fatalf("telemetry forward metric emitted despite disabled sink: %q", packet)
		}
	}
}

// TestTelemetryFieldAllowlistHasKnownKeys is a Go-side existence spot-check only.
// Cross-language agreement between the Go, Swift, and TypeScript allowlists is
// enforced by TestTelemetryAllowlistThreeWayParity in
// telemetry_allowlist_parity_test.go.
func TestTelemetryFieldAllowlistHasKnownKeys(t *testing.T) {
	for _, k := range []string{"component", "model", "exit_code", "reason", "duration_ms", "boot_macos_major", "boot_sip_status"} {
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
