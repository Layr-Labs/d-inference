package datadog

import (
	"bytes"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

// wireLog mirrors the ddLog JSON the intake receives, decoded independently of
// the struct under test so a renamed field is a failure and not a silent skip.
type wireLog struct {
	DDSource string         `json:"ddsource"`
	DDTags   string         `json:"ddtags"`
	Hostname string         `json:"hostname"`
	Service  string         `json:"service"`
	Status   string         `json:"status"`
	Message  string         `json:"message"`
	Attrs    map[string]any `json:"attributes"`
}

func tagSet(ddtags string) map[string]string {
	out := map[string]string{}
	for t := range strings.SplitSeq(ddtags, ",") {
		k, v, ok := strings.Cut(t, ":")
		if ok {
			out[k] = v
		}
	}
	return out
}

// TestForwardLogCarriesEnvAndService is the regression for the empty log
// panels: the dashboards scope every log query by `env:<x> service:<y>`, and a
// log the coordinator POSTs itself is the only log on an agentless host, so
// without those two tags nothing matches any widget.
func TestForwardLogCarriesEnvAndService(t *testing.T) {
	var batch []wireLog
	var apiKey string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		apiKey = r.Header.Get("Dd-Api-Key")
		body, _ := io.ReadAll(r.Body)
		if err := json.Unmarshal(body, &batch); err != nil {
			t.Errorf("intake got undecodable body %q: %v", body, err)
		}
		w.WriteHeader(http.StatusAccepted)
	}))
	defer srv.Close()

	c := &Client{
		logger:     slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError})),
		apiKey:     "test-key",
		httpClient: srv.Client(),
		logsURL:    srv.URL,
		env:        "production",
		service:    "d-inference-coordinator",
	}

	c.ForwardLog(TelemetryLogEntry{
		Source:    "coordinator",
		Severity:  "error",
		Kind:      "inference_error",
		Message:   "dispatch failed",
		RequestID: "req-1",
		Version:   "0.9.3",
		Fields:    map[string]any{"model": "qwen"},
	})
	c.flushLogs()

	if apiKey != "test-key" {
		t.Fatalf("Dd-Api-Key header = %q, want test-key", apiKey)
	}
	if len(batch) != 1 {
		t.Fatalf("batch size = %d, want 1", len(batch))
	}
	got := batch[0]

	tags := tagSet(got.DDTags)
	for k, want := range map[string]string{
		"env":      "production",
		"service":  "d-inference-coordinator",
		"kind":     "inference_error",
		"severity": "error",
	} {
		if tags[k] != want {
			t.Errorf("ddtags %s = %q, want %q (full: %q)", k, tags[k], want, got.DDTags)
		}
	}
	// service is the configured one, not a hardcoded literal: a DD_SERVICE
	// override has to reach the log payload or $service stops matching.
	if got.Service != "d-inference-coordinator" {
		t.Errorf("service = %q, want d-inference-coordinator", got.Service)
	}
	if got.DDSource != "coordinator" {
		t.Errorf("ddsource = %q, want coordinator", got.DDSource)
	}
	if got.Status != "error" {
		t.Errorf("status = %q, want error", got.Status)
	}
	if got.Attrs["request_id"] != "req-1" || got.Attrs["model"] != "qwen" {
		t.Errorf("attributes lost fields: %v", got.Attrs)
	}
}

// TestForwardLogServiceOverride pins the DD_SERVICE path specifically: the
// payload's service field used to be a literal, so any override diverged from
// the env/service pair on metrics.
func TestForwardLogServiceOverride(t *testing.T) {
	var batch []wireLog
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(body, &batch)
		w.WriteHeader(http.StatusAccepted)
	}))
	defer srv.Close()

	c := &Client{
		logger:     slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError})),
		apiKey:     "k",
		httpClient: srv.Client(),
		logsURL:    srv.URL,
		env:        "staging",
		service:    "other-svc",
	}
	c.ForwardLog(TelemetryLogEntry{Source: "provider", Severity: "warn", Kind: "backend_crash", Message: "m"})
	c.flushLogs()

	if len(batch) != 1 {
		t.Fatalf("batch size = %d, want 1", len(batch))
	}
	if batch[0].Service != "other-svc" {
		t.Errorf("service = %q, want other-svc", batch[0].Service)
	}
	if tags := tagSet(batch[0].DDTags); tags["env"] != "staging" || tags["service"] != "other-svc" {
		t.Errorf("ddtags = %q, want env:staging and service:other-svc", batch[0].DDTags)
	}
}

// TestNewClientWiresLogTags covers the wiring the other tests stub out: they
// build a Client literal with env/service already set, so deleting the two
// assignments in NewClient would leave them all passing while shipping the
// original bug. This one goes through NewClient.
func TestNewClientWiresLogTags(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	c, err := NewClient(Config{
		APIKey:       "k",
		Site:         "datadoghq.com",
		Env:          "production",
		Service:      "d-inference-coordinator",
		StatsdAddr:   "127.0.0.1:8125", // UDP, no listener needed
		FlushSecs:    5,
		MaxBatchSize: 100,
	}, logger)
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	defer c.Close() // buffers are empty, so this makes no network call

	if got := c.logTags(TelemetryLogEntry{Kind: "panic", Severity: "fatal"}); got != "env:production,service:d-inference-coordinator,kind:panic,severity:fatal" {
		t.Errorf("logTags after NewClient = %q", got)
	}
	if c.service != "d-inference-coordinator" {
		t.Errorf("service not carried from Config: %q", c.service)
	}
}

// TestLogTagsOmitsEmpty: a valueless `kind:` tag is not a tag Datadog can
// filter on, so an entry without a kind or severity must not send one.
func TestLogTagsOmitsEmpty(t *testing.T) {
	c := &Client{env: "production", service: "svc"}
	got := c.logTags(TelemetryLogEntry{Source: "coordinator"})
	if got != "env:production,service:svc" {
		t.Errorf("logTags = %q, want env:production,service:svc", got)
	}

	// A client built without a Config (tests, nil-DD paths) sends neither.
	bare := &Client{}
	if got := bare.logTags(TelemetryLogEntry{Kind: "panic", Severity: "fatal"}); got != "kind:panic,severity:fatal" {
		t.Errorf("logTags on unconfigured client = %q", got)
	}
}

// TestFlushLogsReportsRejection pins the whole report. The status was already
// logged; the intake's explanation of it was read and thrown away, which is the
// difference between "403" and "403, your key is not authorized for this site".
func TestFlushLogsReportsRejection(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.ReadAll(r.Body)
		w.WriteHeader(http.StatusForbidden)
		_, _ = w.Write([]byte(`{"errors":["Forbidden"]}`))
	}))
	defer srv.Close()

	var logs bytes.Buffer
	c := &Client{
		logger:     slog.New(slog.NewTextHandler(&logs, &slog.HandlerOptions{Level: slog.LevelWarn})),
		apiKey:     "bad-key",
		httpClient: srv.Client(),
		logsURL:    srv.URL,
		env:        "production",
		service:    "svc",
	}
	c.ForwardLog(TelemetryLogEntry{Source: "coordinator", Severity: "error", Kind: "k", Message: "m"})
	c.flushLogs()

	out := logs.String()
	if !strings.Contains(out, "logs API returned error") {
		t.Fatalf("a rejected batch was not reported; logger output: %q", out)
	}
	if !strings.Contains(out, "403") {
		t.Errorf("report omits the status code: %q", out)
	}
	if !strings.Contains(out, "Forbidden") {
		t.Errorf("report omits the intake's reason: %q", out)
	}
}

// TestEmitDDEventTags: a monitor built on the fatal-event stream scopes by the
// same env/service pair as the dashboards, so the event carries both. env used
// to be re-read from DD_ENV here and service was absent entirely.
func TestEmitDDEventTags(t *testing.T) {
	var got map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(body, &got)
		w.WriteHeader(http.StatusAccepted)
	}))
	defer srv.Close()

	c := &Client{
		logger:     slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError})),
		apiKey:     "k",
		httpClient: srv.Client(),
		eventsURL:  srv.URL,
		env:        "production",
		service:    "d-inference-coordinator",
	}
	// Called directly: ForwardLog dispatches this in a goroutine for fatal
	// entries, which a test cannot join.
	c.emitDDEvent(TelemetryLogEntry{Source: "coordinator", Severity: "fatal", Kind: "panic", Message: "boom"})

	tags, _ := got["tags"].([]any)
	want := map[string]bool{
		"source:coordinator": false, "kind:panic": false,
		"env:production": false, "service:d-inference-coordinator": false,
	}
	for _, tg := range tags {
		if s, ok := tg.(string); ok {
			want[s] = true
		}
	}
	for tag, seen := range want {
		if !seen {
			t.Errorf("event tags missing %q (got %v)", tag, tags)
		}
	}
}

// TestFlushLogsQuietOnSuccess: the warning must be about the status, not about
// every flush, or it becomes noise nobody reads.
func TestFlushLogsQuietOnSuccess(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.ReadAll(r.Body)
		w.WriteHeader(http.StatusAccepted)
	}))
	defer srv.Close()

	var logs bytes.Buffer
	c := &Client{
		logger:     slog.New(slog.NewTextHandler(&logs, &slog.HandlerOptions{Level: slog.LevelWarn})),
		apiKey:     "k",
		httpClient: srv.Client(),
		logsURL:    srv.URL,
	}
	c.ForwardLog(TelemetryLogEntry{Source: "coordinator", Severity: "info", Kind: "k", Message: "m"})
	c.flushLogs()

	if logs.Len() != 0 {
		t.Errorf("202 produced log output: %q", logs.String())
	}
}
