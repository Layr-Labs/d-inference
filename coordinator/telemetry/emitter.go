package telemetry

// Internal emitter for coordinator-side telemetry. Mirrors events to the
// process logger and forwards them to Datadog (Logs API + DogStatsD).
//
// No Postgres or in-memory store writes — Datadog is the sole durable sink.
// If a forward fails we log and move on — telemetry must never break the
// request path.

import (
	"log/slog"
	"time"

	"github.com/eigeninference/d-inference/coordinator/datadog"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/google/uuid"
)

// CoordinatorVersion is the build version stamped on events the coordinator
// emits about itself. Set from the build system or the latest release.
var CoordinatorVersion = "dev"

// SessionID is a per-process UUID so admin UI can group events from one boot.
var SessionID = uuid.NewString()

// MetricsSink is the minimal interface the emitter needs to bump counters.
// The api package injects a small adapter so the metric-label types stay
// private to each package.
type MetricsSink interface {
	IncCounterEvent(source, severity, kind string)
}

// Emitter writes coordinator-side telemetry events. Safe for concurrent use.
type Emitter struct {
	logger  *slog.Logger
	metrics MetricsSink
	dd      *datadog.Client
	version string
}

// NewEmitter wires the coordinator-side emitter.
func NewEmitter(logger *slog.Logger, metrics MetricsSink, version string) *Emitter {
	if version == "" {
		version = CoordinatorVersion
	}
	return &Emitter{
		logger:  logger,
		metrics: metrics,
		version: version,
	}
}

// SetDatadog wires the Datadog client so coordinator-emitted events are also
// forwarded to the DD Logs API.
func (e *Emitter) SetDatadog(dd *datadog.Client) {
	if e != nil {
		e.dd = dd
	}
}

// Emit records a single event. The event's source is forced to "coordinator"
// because that's the only thing this emitter legitimately speaks for.
func (e *Emitter) Emit(ev Event) {
	if e == nil {
		return
	}
	if ev.Kind == "" {
		ev.Kind = protocol.KindCustom
	}
	if ev.Severity == "" {
		ev.Severity = protocol.SeverityInfo
	}
	if ev.Timestamp.IsZero() {
		ev.Timestamp = time.Now().UTC()
	}

	// Mirror to the process logger so operators get something useful in
	// stdout without having to query Datadog. Map severity to slog level.
	logArgs := []any{"kind", ev.Kind}
	if ev.RequestID != "" {
		logArgs = append(logArgs, "request_id", ev.RequestID)
	}
	for k, v := range ev.Fields {
		logArgs = append(logArgs, k, v)
	}
	switch ev.Severity {
	case protocol.SeverityFatal, protocol.SeverityError:
		e.logger.Error("telemetry: "+ev.Message, logArgs...)
	case protocol.SeverityWarn:
		e.logger.Warn("telemetry: "+ev.Message, logArgs...)
	case protocol.SeverityDebug:
		e.logger.Debug("telemetry: "+ev.Message, logArgs...)
	default:
		e.logger.Info("telemetry: "+ev.Message, logArgs...)
	}

	// Metrics.
	if e.metrics != nil {
		e.metrics.IncCounterEvent(
			string(protocol.TelemetrySourceCoordinator),
			string(ev.Severity),
			string(ev.Kind),
		)
	}

	// Forward to Datadog Logs API.
	if e.dd != nil {
		e.dd.ForwardLog(datadog.TelemetryLogEntry{
			Source:    string(protocol.TelemetrySourceCoordinator),
			Severity:  string(ev.Severity),
			Kind:      string(ev.Kind),
			Message:   ev.Message,
			RequestID: ev.RequestID,
			SessionID: SessionID,
			Version:   e.version,
			Fields:    ev.Fields,
			Stack:     ev.Stack,
		})
	}
}

// Event is a coordinator-side event shape. It's intentionally a subset of the
// wire protocol — things like source/machine_id are filled in automatically.
type Event struct {
	Timestamp time.Time
	Severity  protocol.TelemetrySeverity
	Kind      protocol.TelemetryKind
	Message   string
	Fields    map[string]any
	RequestID string
	Stack     string
}
