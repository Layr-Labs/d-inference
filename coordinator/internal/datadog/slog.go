package datadog

// DD-aware slog handler that injects trace context (dd.trace_id, dd.span_id)
// into structured log entries so Datadog can correlate logs with APM traces.
//
// The DD agent parses these attributes from the JSON output when the
// coordinator's stdout is piped through the agent's log collection.

import (
	"context"
	"log/slog"

	"gopkg.in/DataDog/dd-trace-go.v1/ddtrace/tracer"
)

// TraceHandler wraps a base slog.Handler and injects DD trace context
// (dd.trace_id, dd.span_id) into every log record that has an active trace.
type TraceHandler struct {
	base slog.Handler
}

// NewTraceHandler wraps an existing slog handler with DD trace injection.
func NewTraceHandler(base slog.Handler) *TraceHandler {
	return &TraceHandler{base: base}
}

// Enabled delegates to the underlying handler.
func (h *TraceHandler) Enabled(ctx context.Context, level slog.Level) bool {
	return h.base.Enabled(ctx, level)
}

// Handle injects DD trace context attrs before delegating to the base handler.
func (h *TraceHandler) Handle(ctx context.Context, rec slog.Record) error {
	span, ok := tracer.SpanFromContext(ctx)
	if ok && span != nil {
		rec.AddAttrs(
			slog.Uint64("dd.trace_id", span.Context().TraceID()),
			slog.Uint64("dd.span_id", span.Context().SpanID()),
		)
	}
	return h.base.Handle(ctx, rec)
}

// WithAttrs returns a new handler with the given attributes.
func (h *TraceHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	return &TraceHandler{base: h.base.WithAttrs(attrs)}
}

// WithGroup returns a new handler with the given group name.
func (h *TraceHandler) WithGroup(name string) slog.Handler {
	return &TraceHandler{base: h.base.WithGroup(name)}
}
