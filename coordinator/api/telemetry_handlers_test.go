package api

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
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

