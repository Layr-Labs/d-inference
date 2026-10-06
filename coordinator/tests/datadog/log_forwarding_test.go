package datadog_test

import (
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	production "github.com/eigeninference/d-inference/coordinator/datadog"
)

// intakeRequest is one request received by the local stand-in for the Datadog
// logs, events and series APIs. host is the intake host the client addressed.
type intakeRequest struct {
	host   string
	path   string
	apiKey string
	body   []byte
}

func newIntake(t *testing.T, status int) (<-chan intakeRequest, *http.Client) {
	t.Helper()
	requests := make(chan intakeRequest, 16)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		requests <- intakeRequest{host: r.Host, path: r.URL.Path, apiKey: r.Header.Get("Dd-Api-Key"), body: body}
		w.WriteHeader(status)
	}))
	t.Cleanup(server.Close)
	return requests, intakeClient(t, server)
}

func nextIntakeRequest(t *testing.T, requests <-chan intakeRequest, what string) intakeRequest {
	t.Helper()
	select {
	case request := <-requests:
		return request
	case <-time.After(5 * time.Second):
		t.Fatalf("timed out waiting for %s", what)
		return intakeRequest{}
	}
}

// logLines receives each record of a text slog handler as one write.
type logLines chan string

func (l logLines) Write(p []byte) (int, error) {
	l <- string(p)
	return len(p), nil
}

func waitForLogLines(t *testing.T, lines logLines, wants ...string) {
	t.Helper()
	missing := append([]string{}, wants...)
	deadline := time.After(5 * time.Second)
	for len(missing) > 0 {
		select {
		case line := <-lines:
			for i, want := range missing {
				if strings.Contains(line, want) {
					missing = append(missing[:i], missing[i+1:]...)
					break
				}
			}
		case <-deadline:
			t.Fatalf("log lines %q were not written", missing)
		}
	}
}

// newForwardingClient builds a client that forwards to intake. The flush
// ticker is an hour, so only Close, Flush or a full batch sends logs.
func newForwardingClient(t *testing.T, intake *http.Client, logs io.Writer) *production.Client {
	t.Helper()
	c, err := production.NewClient(production.Config{
		APIKey:       "test-api-key",
		Site:         "example.test",
		Env:          "test",
		Service:      "svc",
		StatsdAddr:   "127.0.0.1:1",
		FlushSecs:    3600,
		MaxBatchSize: 100,
		HTTPClient:   intake,
	}, slog.New(slog.NewTextHandler(logs, &slog.HandlerOptions{Level: slog.LevelWarn})))
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	return c
}

func TestNewClientDerivesIntakeURLsFromSite(t *testing.T) {
	t.Setenv("DD_HOSTNAME", "")
	requests, intake := newIntake(t, http.StatusAccepted)
	c := newForwardingClient(t, intake, io.Discard)
	defer c.Close()
	if c.Statsd == nil {
		t.Fatal("DogStatsD client not created for a valid address")
	}

	c.ForwardLog(production.TelemetryLogEntry{Source: "coordinator", Severity: "fatal", Kind: "k", Message: "m"})
	c.Gauge("providers.online", 1, nil)
	c.Incr("jobs.done", nil)
	c.Flush()

	hosts := map[string]string{}
	var series struct {
		Series []struct {
			Type     string   `json:"type"`
			Interval int64    `json:"interval"`
			Tags     []string `json:"tags"`
			Host     string   `json:"host"`
		} `json:"series"`
	}
	for len(hosts) < 3 {
		request := nextIntakeRequest(t, requests, "the logs, events and series requests")
		hosts[request.path] = request.host
		if request.path == "/api/v1/series" {
			if err := json.Unmarshal(request.body, &series); err != nil {
				t.Fatal(err)
			}
		}
	}
	for path, host := range map[string]string{
		"/api/v2/logs":   "http-intake.logs.example.test",
		"/api/v1/events": "api.example.test",
		"/api/v1/series": "api.example.test",
	} {
		if hosts[path] != host {
			t.Fatalf("intake hosts = %v, want %s on %s", hosts, host, path)
		}
	}
	if len(series.Series) != 2 {
		t.Fatalf("series = %+v, want a gauge and a count", series.Series)
	}
	for _, metric := range series.Series {
		if metric.Host != "svc" || strings.Join(metric.Tags, ",") != "env:test,service:svc" {
			t.Fatalf("metric host = %q, tags = %v; want the service name and env/service tags", metric.Host, metric.Tags)
		}
		if metric.Type == "count" && metric.Interval != 3600 {
			t.Fatalf("count interval = %d, want the 3600s flush window", metric.Interval)
		}
	}
}

// Without an API key, counters, gauges and histograms go to DogStatsD.
func TestMetricsWithoutAPIKeyGoToDogStatsD(t *testing.T) {
	conn, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()

	c, err := production.NewClient(production.Config{Env: "test", Service: "svc", StatsdAddr: conn.LocalAddr().String(), FlushSecs: 3600, MaxBatchSize: 10},
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
	requests, intake := newIntake(t, http.StatusAccepted)
	t.Setenv("DD_ENV", "test")
	c := newForwardingClient(t, intake, io.Discard)

	c.ForwardLog(production.TelemetryLogEntry{
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
	event := nextIntakeRequest(t, requests, "the fatal event")
	c.Close()
	logs := nextIntakeRequest(t, requests, "the log batch")
	select {
	case extra := <-requests:
		t.Fatalf("unexpected extra intake request to %s", extra.path)
	default:
	}

	if event.path != "/api/v1/events" || logs.path != "/api/v2/logs" {
		t.Fatalf("request paths = %q then %q, want the event before the log batch", event.path, logs.path)
	}
	var batch []map[string]any
	if err := json.Unmarshal(logs.body, &batch); err != nil {
		t.Fatal(err)
	}
	if len(batch) != 1 {
		t.Fatalf("log batch = %v", batch)
	}
	entry := batch[0]
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

	var evt map[string]any
	if err := json.Unmarshal(event.body, &evt); err != nil {
		t.Fatal(err)
	}
	text, _ := evt["text"].(string)
	if evt["title"] != "[d-inference] Fatal: backend crashed" || evt["alert_type"] != "error" ||
		!strings.Contains(text, "goroutine 1 [running]") {
		t.Fatalf("event = %v", evt)
	}
	tags, _ := evt["tags"].([]any)
	if len(tags) != 3 || tags[2] != "env:test" {
		t.Fatalf("event tags = %v", tags)
	}
	for _, request := range []intakeRequest{event, logs} {
		if request.apiKey != "test-api-key" {
			t.Fatalf("request API key = %q", request.apiKey)
		}
	}
}

func TestForwardLogFlushesAFullBatchWithoutWaiting(t *testing.T) {
	requests, intake := newIntake(t, http.StatusAccepted)
	c := newForwardingClient(t, intake, io.Discard)

	for i := 0; i < 100; i++ {
		c.ForwardLog(production.TelemetryLogEntry{Source: "coordinator", Severity: "info", Kind: "tick", Message: "m"})
	}
	request := nextIntakeRequest(t, requests, "the full batch")
	var batch []map[string]any
	if err := json.Unmarshal(request.body, &batch); err != nil {
		t.Fatal(err)
	}
	if request.path != "/api/v2/logs" || len(batch) != 100 {
		t.Fatalf("first request to %s has %d entries; want one log batch of 100", request.path, len(batch))
	}
	c.Close()
	select {
	case extra := <-requests:
		t.Fatalf("non-fatal logs sent an extra request to %s", extra.path)
	default:
	}
}

func TestFlushLogsReportsIntakeErrors(t *testing.T) {
	requests, intake := newIntake(t, http.StatusForbidden)
	rejected := make(logLines, 16)
	c := newForwardingClient(t, intake, rejected)

	c.ForwardLog(production.TelemetryLogEntry{Source: "coordinator", Severity: "warn", Kind: "k", Message: "m"})
	c.Close()
	nextIntakeRequest(t, requests, "the rejected batch")
	waitForLogLines(t, rejected, `logs API returned error" status=403`)

	// An unreachable intake is logged too, not retried or panicked on.
	unreachable := &http.Client{Transport: intakeTransport(func(*http.Request) (*http.Response, error) {
		return nil, errors.New("intake unreachable")
	})}
	down := make(logLines, 16)
	c2 := newForwardingClient(t, unreachable, down)
	c2.ForwardLog(production.TelemetryLogEntry{Source: "coordinator", Severity: "fatal", Kind: "k", Message: "m"})
	c2.Close()
	waitForLogLines(t, down, "logs API request failed", "events API request failed")
}
