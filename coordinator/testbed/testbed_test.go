package testbed

import (
	"testing"
	"time"
)

func TestEventBufferByKind(t *testing.T) {
	buf := NewEventBuffer()

	buf.Consume(Event{Kind: EventRequestStart, RequestID: "r1"})
	buf.Consume(Event{Kind: EventSegmentStart, RequestID: "r1", Segment: SegmentClientToCoordinator})
	buf.Consume(Event{Kind: EventSegmentEnd, RequestID: "r1", Segment: SegmentClientToCoordinator, Duration: 10 * time.Millisecond})
	buf.Consume(Event{Kind: EventRequestEnd, RequestID: "r1"})

	starts := buf.ByKind(EventRequestStart)
	if len(starts) != 1 {
		t.Fatalf("expected 1 request start, got %d", len(starts))
	}

	ends := buf.ByKind(EventSegmentEnd)
	if len(ends) != 1 {
		t.Fatalf("expected 1 segment end, got %d", len(ends))
	}
	if ends[0].Duration != 10*time.Millisecond {
		t.Fatalf("expected duration 10ms, got %s", ends[0].Duration)
	}
}

func TestEventBufferBySegment(t *testing.T) {
	buf := NewEventBuffer()

	buf.Consume(Event{Kind: EventSegmentEnd, Segment: SegmentTTFT, Duration: 100 * time.Millisecond})
	buf.Consume(Event{Kind: EventSegmentEnd, Segment: SegmentTotalE2E, Duration: 500 * time.Millisecond})
	buf.Consume(Event{Kind: EventSegmentEnd, Segment: SegmentTTFT, Duration: 200 * time.Millisecond})

	ttft := buf.BySegment(SegmentTTFT)
	if len(ttft) != 2 {
		t.Fatalf("expected 2 TTFT events, got %d", len(ttft))
	}

	e2e := buf.BySegment(SegmentTotalE2E)
	if len(e2e) != 1 {
		t.Fatalf("expected 1 E2E event, got %d", len(e2e))
	}
}

func TestEventBufferByRequest(t *testing.T) {
	buf := NewEventBuffer()

	buf.Consume(Event{Kind: EventRequestStart, RequestID: "r1"})
	buf.Consume(Event{Kind: EventRequestStart, RequestID: "r2"})
	buf.Consume(Event{Kind: EventSegmentEnd, RequestID: "r1", Segment: SegmentTTFT})
	buf.Consume(Event{Kind: EventSegmentEnd, RequestID: "r2", Segment: SegmentTotalE2E})

	r1 := buf.ByRequest("r1")
	if len(r1) != 2 {
		t.Fatalf("expected 2 events for r1, got %d", len(r1))
	}

	r2 := buf.ByRequest("r2")
	if len(r2) != 2 {
		t.Fatalf("expected 2 events for r2, got %d", len(r2))
	}
}

func TestEventBufferReset(t *testing.T) {
	buf := NewEventBuffer()
	buf.Consume(Event{Kind: EventRequestStart, RequestID: "r1"})

	if len(buf.Events()) != 1 {
		t.Fatalf("expected 1 event before reset")
	}

	buf.Reset()
	if len(buf.Events()) != 0 {
		t.Fatalf("expected 0 events after reset")
	}
}

func TestEventFan(t *testing.T) {
	b1 := NewEventBuffer()
	b2 := NewEventBuffer()
	fan := EventFan{b1, b2}

	fan.Consume(Event{Kind: EventRequestStart, RequestID: "r1"})

	if len(b1.Events()) != 1 {
		t.Fatalf("b1: expected 1 event, got %d", len(b1.Events()))
	}
	if len(b2.Events()) != 1 {
		t.Fatalf("b2: expected 1 event, got %d", len(b2.Events()))
	}
}

func TestEventSchemaVersion(t *testing.T) {
	buf := NewEventBuffer()
	inst := NewInstrument(buf)
	rid := inst.NewRequestID()
	inst.RequestStart(rid)

	events := buf.Events()
	if events[0].SchemaVersion != SchemaVersion {
		t.Fatalf("expected schema version %s, got %s", SchemaVersion, events[0].SchemaVersion)
	}
}

func TestDefaultConfigs(t *testing.T) {
	cfg := DefaultTestConfig()
	if cfg.Model.ModelID != "mlx-community/gemma-3-270m" {
		t.Fatalf("expected default model ID, got %s", cfg.Model.ModelID)
	}
	if cfg.Provider.TrustLevel != TrustNone {
		t.Fatalf("expected trust none, got %s", cfg.Provider.TrustLevel)
	}
	if cfg.Request.PromptTokens != 64 {
		t.Fatalf("expected 64 prompt tokens, got %d", cfg.Request.PromptTokens)
	}
	if cfg.Request.MaxTokens != 128 {
		t.Fatalf("expected 128 max tokens, got %d", cfg.Request.MaxTokens)
	}
	if cfg.Request.Temperature != 0.0 {
		t.Fatalf("expected 0.0 temperature, got %f", cfg.Request.Temperature)
	}
	if cfg.Request.Streaming != true {
		t.Fatalf("expected streaming true")
	}
	if cfg.Request.Concurrency != 1 {
		t.Fatalf("expected concurrency 1, got %d", cfg.Request.Concurrency)
	}
	if cfg.Request.TotalRequests != 10 {
		t.Fatalf("expected 10 total requests, got %d", cfg.Request.TotalRequests)
	}
}
