package telemetry

import (
	"io"
	"log/slog"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
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
	e := NewEmitter(testLogger(), sink, "v1.2.3")

	e.Emit(Event{Message: "hello"})

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
	e := NewEmitter(testLogger(), sink, "v1")

	e.Emit(Event{Message: "boom", Severity: protocol.SeverityError, Kind: protocol.KindCustom})

	if sink.severity != string(protocol.SeverityError) {
		t.Fatalf("severity = %q, want error", sink.severity)
	}
	if sink.kind != string(protocol.KindCustom) {
		t.Fatalf("kind = %q, want custom", sink.kind)
	}
}

func TestEmitNilEmitterIsNoOp(t *testing.T) {
	var e *Emitter
	// Must not panic on a nil receiver — telemetry must never break the caller.
	e.Emit(Event{Message: "x"})
}

func TestEmitNilMetricsIsSafe(t *testing.T) {
	e := NewEmitter(testLogger(), nil, "v1")
	// No metrics sink wired — Emit should still log without panicking.
	e.Emit(Event{Message: "x", Severity: protocol.SeverityWarn})
}

func TestNewEmitterDefaultsVersion(t *testing.T) {
	if e := NewEmitter(testLogger(), nil, ""); e.version != CoordinatorVersion {
		t.Fatalf("empty version = %q, want default %q", e.version, CoordinatorVersion)
	}
	if e := NewEmitter(testLogger(), nil, "custom"); e.version != "custom" {
		t.Fatalf("explicit version = %q, want custom", e.version)
	}
}
