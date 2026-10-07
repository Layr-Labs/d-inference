package telemetry_test

import (
	"encoding/json"
	"io"
	"log/slog"
	"net"
	"net/http"
	"sync"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/datadog"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/telemetry"
)

func testLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

// fakeSink is a capturing MetricsSink. It is a test double for the COLLABORATOR
// (the metrics backend), not for the Emitter under test.
type fakeSink struct {
	source, severity, kind string
	calls                  int
}

func (f *fakeSink) IncCounterEvent(source, severity, kind string) {
	f.source, f.severity, f.kind = source, severity, kind
	f.calls++
}

func TestEmitFillsDefaultsAndCounts(t *testing.T) {
	sink := &fakeSink{}
	e := production.NewEmitter(testLogger(), sink, "v1.2.3")

	e.Emit(production.Event{Message: "hello"})

	if sink.calls != 1 {
		t.Fatalf("metrics called %d times, want 1", sink.calls)
	}
	if sink.source != string(protocol.TelemetrySourceCoordinator) {
		t.Fatalf("source = %q, want coordinator", sink.source)
	}
	if sink.severity != string(protocol.SeverityInfo) {
		t.Fatalf("severity = %q, want default info", sink.severity)
	}
	if sink.kind != string(protocol.KindCustom) {
		t.Fatalf("kind = %q, want default custom", sink.kind)
	}
}

func TestEmitPassesSeverityAndKind(t *testing.T) {
	sink := &fakeSink{}
	e := production.NewEmitter(testLogger(), sink, "v1")

	e.Emit(production.Event{Message: "boom", Severity: protocol.SeverityError, Kind: protocol.KindCustom})

	if sink.severity != string(protocol.SeverityError) {
		t.Fatalf("severity = %q, want error", sink.severity)
	}
	if sink.kind != string(protocol.KindCustom) {
		t.Fatalf("kind = %q, want custom", sink.kind)
	}
}

func TestEmitNilEmitterIsNoOp(t *testing.T) {
	var e *production.Emitter
	// Must not panic on a nil receiver — telemetry must never break the caller.
	e.Emit(production.Event{Message: "x"})
}

func TestEmitNilMetricsIsSafe(t *testing.T) {
	e := production.NewEmitter(testLogger(), nil, "v1")
	// No metrics sink wired — Emit should still log without panicking.
	e.Emit(production.Event{Message: "x", Severity: protocol.SeverityWarn})
}

type captureTransport func(*http.Request) (*http.Response, error)

func (f captureTransport) RoundTrip(req *http.Request) (*http.Response, error) { return f(req) }

func TestNewEmitterDefaultsVersion(t *testing.T) {
	udp, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = udp.Close() })
	var logs []struct {
		Message string            `json:"message"`
		Attrs   map[string]string `json:"attributes"`
	}
	client, err := datadog.NewClient(datadog.Config{
		APIKey: "test-key", StatsdAddr: udp.LocalAddr().String(), FlushSecs: 3600, MaxBatchSize: 100,
		HTTPClient: &http.Client{Transport: captureTransport(func(req *http.Request) (*http.Response, error) {
			if err := json.NewDecoder(req.Body).Decode(&logs); err != nil {
				return nil, err
			}
			return &http.Response{StatusCode: http.StatusAccepted, Body: http.NoBody, Header: make(http.Header)}, nil
		})},
	}, testLogger())
	if err != nil {
		t.Fatal(err)
	}
	closeClient := sync.OnceFunc(client.Close)
	t.Cleanup(closeClient)
	for _, version := range []string{"", "custom"} {
		emitter := production.NewEmitter(testLogger(), nil, version)
		emitter.SetDatadog(client)
		emitter.Emit(production.Event{Message: version})
	}
	closeClient()
	if len(logs) != 2 {
		t.Fatalf("forwarded %d logs, want 2", len(logs))
	}
	if got := logs[0].Attrs["version"]; got != production.CoordinatorVersion {
		t.Fatalf("empty version = %q, want default %q", got, production.CoordinatorVersion)
	}
	if got := logs[1].Attrs["version"]; got != "custom" {
		t.Fatalf("explicit version = %q, want custom", got)
	}
}
