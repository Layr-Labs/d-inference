package observation

import (
	"context"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/telemetry"
)

func (s *Owner) Emit(ctx context.Context, severity protocol.TelemetrySeverity, kind protocol.TelemetryKind, message string, fields map[string]any) {
	if s == nil || s.emitter == nil {
		return
	}
	s.emitter.Emit(telemetry.Event{Severity: severity, Kind: kind, Message: message, Fields: fields})
}
func (s *Owner) EmitRequest(ctx context.Context, severity protocol.TelemetrySeverity, requestID, message string, fields map[string]any) {
	if s == nil || s.emitter == nil {
		return
	}
	s.emitter.Emit(telemetry.Event{Severity: severity, Kind: protocol.KindInferenceError, Message: message, Fields: fields, RequestID: requestID})
}
func (s *Owner) EmitPanic(ctx context.Context, message, stack string, fields map[string]any) {
	if s == nil || s.emitter == nil {
		return
	}
	s.emitter.Emit(telemetry.Event{Severity: protocol.SeverityFatal, Kind: protocol.KindPanic, Message: message, Fields: fields, Stack: stack})
}
func (s *Owner) Incr(name string, tags []string)                 { s.ddIncr(name, tags) }
func (s *Owner) Count(name string, value int64, tags []string)   { s.ddCount(name, value, tags) }
func (s *Owner) Gauge(name string, value float64, tags []string) { s.ddGauge(name, value, tags) }
func (s *Owner) Histogram(name string, value float64, tags []string) {
	if s != nil && s.dd != nil {
		s.dd.Histogram(name, value, tags)
	}
}
