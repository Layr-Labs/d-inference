package datadog

import (
	"bytes"
	"encoding/json"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// intakeRecorder is a local stand-in for the Datadog logs and events APIs.
type intakeRecorder struct {
	mu      sync.Mutex
	status  int
	logs    [][]map[string]any
	events  []map[string]any
	apiKeys []string
	gotLogs chan struct{}
	gotEvt  chan struct{}
}

func newIntakeRecorder(status int) (*intakeRecorder, *httptest.Server) {
	r := &intakeRecorder{status: status, gotLogs: make(chan struct{}, 16), gotEvt: make(chan struct{}, 16)}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		body, _ := io.ReadAll(req.Body)
		r.mu.Lock()
		r.apiKeys = append(r.apiKeys, req.Header.Get("Dd-Api-Key"))
		switch req.URL.Path {
		case "/logs":
			var batch []map[string]any
			_ = json.Unmarshal(body, &batch)
			r.logs = append(r.logs, batch)
			r.mu.Unlock()
			r.gotLogs <- struct{}{}
		case "/events":
			var evt map[string]any
			_ = json.Unmarshal(body, &evt)
			r.events = append(r.events, evt)
			r.mu.Unlock()
			r.gotEvt <- struct{}{}
		default:
			r.mu.Unlock()
		}
		w.WriteHeader(r.status)
	}))
	return r, srv
}

func waitFor(t *testing.T, ch <-chan struct{}, what string) {
	t.Helper()
	select {
	case <-ch:
	case <-time.After(5 * time.Second):
		t.Fatalf("timed out waiting for %s", what)
	}
}

// newIntakeClient builds a client with NewClient, then points its intake URLs
// at the local recorder. The flush ticker is an hour, so only Close or a
// full batch sends logs.
func newIntakeClient(t *testing.T, apiKey string, srv *httptest.Server, logs *bytes.Buffer) *Client {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(logs, &slog.HandlerOptions{Level: slog.LevelWarn}))
	c, err := NewClient(Config{
		APIKey:       apiKey,
		Site:         "example.test",
		Env:          "test",
		Service:      "svc",
		StatsdAddr:   "127.0.0.1:1",
		FlushSecs:    3600,
		MaxBatchSize: 100,
	}, logger)
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	if srv != nil {
		c.logsURL = srv.URL + "/logs"
		c.eventsURL = srv.URL + "/events"
		c.seriesURL = srv.URL + "/series"
		c.httpClient = srv.Client()
	}
	return c
}

func TestNewClientDerivesIntakeURLsFromSite(t *testing.T) {
	t.Setenv("DD_HOSTNAME", "")
	c := newIntakeClient(t, "", nil, &bytes.Buffer{})
	defer c.Close()

	if c.logsURL != "https://http-intake.logs.example.test/api/v2/logs" ||
		c.eventsURL != "https://api.example.test/api/v1/events" ||
		c.seriesURL != "https://api.example.test/api/v1/series" {
		t.Fatalf("intake URLs = %q %q %q", c.logsURL, c.eventsURL, c.seriesURL)
	}
	if c.metricsHost != "svc" || c.flushIntervalSecs != 3600 {
		t.Fatalf("metrics host = %q, flush = %d", c.metricsHost, c.flushIntervalSecs)
	}
	if len(c.metricsTags) != 2 || c.metricsTags[0] != "env:test" || c.metricsTags[1] != "service:svc" {
		t.Fatalf("metrics tags = %v", c.metricsTags)
	}
	if c.Statsd == nil {
		t.Fatal("DogStatsD client not created for a valid address")
	}
	if c.httpMetrics() {
		t.Fatal("HTTP metrics enabled without an API key")
	}
}

// Without an API key, counters, gauges and histograms go to DogStatsD.
func TestMetricsWithoutAPIKeyGoToDogStatsD(t *testing.T) {
	conn, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()

	c, err := NewClient(Config{Env: "test", Service: "svc", StatsdAddr: conn.LocalAddr().String(), FlushSecs: 3600, MaxBatchSize: 10},
		slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatal(err)
	}
	c.Count("jobs.done", 3, []string{"model:a"})
	c.Incr("jobs.started", nil)
	c.Gauge("providers.online", 7, nil)
	c.Histogram("latency.ms", 12.5, nil)
	c.Close()

	wants := []string{
		"d_inference.jobs.done:3|c",
		"d_inference.jobs.started:1|c",
		"d_inference.providers.online:7|g",
		"d_inference.latency.ms:12.5|h",
		"model:a",
		"env:test",
	}
	missing := func(payload string) []string {
		var out []string
		for _, w := range wants {
			if !strings.Contains(payload, w) {
				out = append(out, w)
			}
		}
		return out
	}
	// The client aggregates counters and gauges and may send them in a
	// different packet from the histogram, so read until all have arrived.
	var got strings.Builder
	buf := make([]byte, 64<<10)
	_ = conn.SetReadDeadline(time.Now().Add(3 * time.Second))
	for len(missing(got.String())) > 0 {
		n, _, err := conn.ReadFrom(buf)
		if err != nil {
			t.Fatalf("statsd payload %q is missing %v: %v", got.String(), missing(got.String()), err)
		}
		got.Write(buf[:n])
	}
}

func TestForwardLogFlushesOnCloseAndSendsFatalEvent(t *testing.T) {
	rec, srv := newIntakeRecorder(http.StatusAccepted)
	defer srv.Close()
	t.Setenv("DD_ENV", "test")
	c := newIntakeClient(t, "test-api-key", srv, &bytes.Buffer{})

	c.ForwardLog(TelemetryLogEntry{
		Source:    "provider",
		Severity:  "fatal",
		Kind:      "panic",
		Message:   "backend crashed",
		MachineID: "machine-1",
		AccountID: "acct-1",
		RequestID: "req-1",
		SessionID: "sess-1",
		Version:   "1.2.3",
		Fields:    map[string]any{"model": "m"},
		Stack:     "goroutine 1 [running]",
	})
	waitFor(t, rec.gotEvt, "the fatal event")
	c.Close()
	waitFor(t, rec.gotLogs, "the log batch")

	rec.mu.Lock()
	defer rec.mu.Unlock()
	if len(rec.logs) != 1 || len(rec.logs[0]) != 1 {
		t.Fatalf("log batches = %v", rec.logs)
	}
	entry := rec.logs[0][0]
	if entry["ddsource"] != "provider" || entry["ddtags"] != "kind:panic,severity:fatal" ||
		entry["hostname"] != "machine-1" || entry["status"] != "critical" || entry["message"] != "backend crashed" {
		t.Fatalf("log entry = %v", entry)
	}
	attrs, _ := entry["attributes"].(map[string]any)
	for k, want := range map[string]string{
		"dd.kind": "panic", "account_id": "acct-1", "request_id": "req-1", "session_id": "sess-1",
		"version": "1.2.3", "error.stack": "goroutine 1 [running]", "model": "m",
	} {
		if attrs[k] != want {
			t.Errorf("attribute %s = %v, want %q", k, attrs[k], want)
		}
	}

	if len(rec.events) != 1 {
		t.Fatalf("events = %v", rec.events)
	}
	evt := rec.events[0]
	if evt["title"] != "[d-inference] Fatal: backend crashed" || evt["alert_type"] != "error" ||
		!strings.Contains(evt["text"].(string), "goroutine 1 [running]") {
		t.Fatalf("event = %v", evt)
	}
	tags, _ := evt["tags"].([]any)
	if len(tags) != 3 || tags[2] != "env:test" {
		t.Fatalf("event tags = %v", tags)
	}
	for _, k := range rec.apiKeys {
		if k != "test-api-key" {
			t.Fatalf("request API key = %q", k)
		}
	}
}

func TestForwardLogFlushesAFullBatchWithoutWaiting(t *testing.T) {
	rec, srv := newIntakeRecorder(http.StatusAccepted)
	defer srv.Close()
	c := newIntakeClient(t, "test-api-key", srv, &bytes.Buffer{})
	defer c.Close()

	for i := 0; i < 100; i++ {
		c.ForwardLog(TelemetryLogEntry{Source: "coordinator", Severity: "info", Kind: "tick", Message: "m"})
	}
	waitFor(t, rec.gotLogs, "the full batch")
	rec.mu.Lock()
	defer rec.mu.Unlock()
	if len(rec.logs) != 1 || len(rec.logs[0]) != 100 {
		t.Fatalf("got %d batches, first has %d entries; want one batch of 100", len(rec.logs), len(rec.logs[0]))
	}
	if len(rec.events) != 0 {
		t.Fatalf("non-fatal logs sent events: %v", rec.events)
	}
}

func TestFlushLogsReportsIntakeErrors(t *testing.T) {
	rec, srv := newIntakeRecorder(http.StatusForbidden)
	defer srv.Close()
	var logs bytes.Buffer
	c := newIntakeClient(t, "test-api-key", srv, &logs)

	c.ForwardLog(TelemetryLogEntry{Source: "coordinator", Severity: "warn", Kind: "k", Message: "m"})
	c.Close()
	waitFor(t, rec.gotLogs, "the rejected batch")
	if !strings.Contains(logs.String(), "logs API returned error") || !strings.Contains(logs.String(), "status=403") {
		t.Fatalf("intake error not logged: %q", logs.String())
	}

	// An unreachable intake is logged too, not retried or panicked on.
	var down bytes.Buffer
	c2 := newIntakeClient(t, "test-api-key", nil, &down)
	c2.logsURL = "http://127.0.0.1:1/logs"
	c2.eventsURL = "http://127.0.0.1:1/events"
	c2.ForwardLog(TelemetryLogEntry{Source: "coordinator", Severity: "error", Kind: "k", Message: "m"})
	c2.emitDDEvent(TelemetryLogEntry{Message: "m"})
	c2.Close()
	if !strings.Contains(down.String(), "logs API request failed") || !strings.Contains(down.String(), "events API request failed") {
		t.Fatalf("unreachable intake not logged: %q", down.String())
	}
}
