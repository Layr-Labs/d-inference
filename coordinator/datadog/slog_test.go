package datadog

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"strconv"
	"strings"
	"testing"

	"gopkg.in/DataDog/dd-trace-go.v1/ddtrace/mocktracer"
	"gopkg.in/DataDog/dd-trace-go.v1/ddtrace/tracer"
)

func TestTraceHandlerAddsTraceIDsOnlyInsideASpan(t *testing.T) {
	mt := mocktracer.Start()
	defer mt.Stop()

	var out bytes.Buffer
	base := slog.NewJSONHandler(&out, &slog.HandlerOptions{Level: slog.LevelInfo})
	handler := NewTraceHandler(base)
	logger := slog.New(handler.WithAttrs([]slog.Attr{slog.String("component", "test")}).WithGroup("req"))

	if handler.Enabled(context.Background(), slog.LevelDebug) {
		t.Fatal("debug enabled although the base handler is at info")
	}
	if !handler.Enabled(context.Background(), slog.LevelInfo) {
		t.Fatal("info disabled although the base handler is at info")
	}

	span, ctx := tracer.StartSpanFromContext(context.Background(), "op")
	logger.InfoContext(ctx, "inside", "k", "v")
	span.Finish()
	logger.InfoContext(context.Background(), "outside")

	lines := strings.Split(strings.TrimSpace(out.String()), "\n")
	if len(lines) != 2 {
		t.Fatalf("log lines = %q", out.String())
	}
	var inside, outside map[string]any
	dec := json.NewDecoder(strings.NewReader(lines[0]))
	dec.UseNumber() // trace IDs are 64-bit and do not fit a float64
	if err := dec.Decode(&inside); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal([]byte(lines[1]), &outside); err != nil {
		t.Fatal(err)
	}
	if inside["component"] != "test" {
		t.Fatalf("WithAttrs attribute lost: %v", inside)
	}
	group, _ := inside["req"].(map[string]any)
	if group == nil || group["k"] != "v" {
		t.Fatalf("WithGroup attribute lost: %v", inside)
	}
	traceID := fmt.Sprint(group["dd.trace_id"])
	spanID := fmt.Sprint(group["dd.span_id"])
	if traceID != strconv.FormatUint(span.Context().TraceID(), 10) ||
		spanID != strconv.FormatUint(span.Context().SpanID(), 10) || traceID == "0" {
		t.Fatalf("trace ids = %v/%v, want %d/%d", group["dd.trace_id"], group["dd.span_id"],
			span.Context().TraceID(), span.Context().SpanID())
	}
	if og, _ := outside["req"].(map[string]any); og != nil {
		if _, has := og["dd.trace_id"]; has {
			t.Fatalf("trace id added outside a span: %v", outside)
		}
	}
}
