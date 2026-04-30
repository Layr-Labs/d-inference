package testbed

import (
	"fmt"
	"testing"
	"time"
)

func TestInstrumentRequestLifecycle(t *testing.T) {
	buf := NewEventBuffer()
	inst := NewInstrument(buf)

	rid := inst.NewRequestID()
	inst.RequestStart(rid)

	timer := inst.StartSegment(rid, SegmentClientToCoordinator)
	time.Sleep(1 * time.Millisecond)
	timer.Stop()

	inst.RequestEnd(rid, 10*time.Millisecond)

	events := buf.Events()
	if len(events) != 4 {
		t.Fatalf("expected 4 events, got %d", len(events))
	}

	if events[0].Kind != EventRequestStart {
		t.Fatalf("expected request_start, got %s", events[0].Kind)
	}
	if events[1].Kind != EventSegmentStart {
		t.Fatalf("expected segment_start, got %s", events[1].Kind)
	}
	if events[2].Kind != EventSegmentEnd {
		t.Fatalf("expected segment_end, got %s", events[2].Kind)
	}
	if events[2].Duration < time.Millisecond {
		t.Fatalf("segment duration too short: %s", events[2].Duration)
	}
	if events[3].Kind != EventRequestEnd {
		t.Fatalf("expected request_end, got %s", events[3].Kind)
	}
}

func TestInstrumentRequestHelper(t *testing.T) {
	buf := NewEventBuffer()
	inst := NewInstrument(buf)

	ri := inst.NewRequest()
	timer := ri.StartSegment(SegmentTTFT)
	time.Sleep(1 * time.Millisecond)
	timer.Stop()
	ri.StreamChunk(0)
	ri.StreamChunk(1)
	ri.End()

	events := buf.Events()
	if len(events) != 6 {
		t.Fatalf("expected 6 events (request_start + segment_start + segment_end + 2 chunks + request_end), got %d", len(events))
	}

	chunks := buf.ByKind(EventStreamChunk)
	if len(chunks) != 2 {
		t.Fatalf("expected 2 chunk events, got %d", len(chunks))
	}
}

func TestInstrumentError(t *testing.T) {
	buf := NewEventBuffer()
	inst := NewInstrument(buf)

	rid := inst.NewRequestID()
	inst.Error(rid, fmt.Errorf("test error"))

	events := buf.Events()
	if len(events) != 1 {
		t.Fatalf("expected 1 event, got %d", len(events))
	}
	if events[0].Kind != EventError {
		t.Fatalf("expected error event, got %s", events[0].Kind)
	}
}

func TestInstrumentFanOut(t *testing.T) {
	b1 := NewEventBuffer()
	b2 := NewEventBuffer()
	fan := EventFan{b1, b2}

	inst := NewInstrument(fan)
	rid := inst.NewRequestID()
	inst.RequestStart(rid)

	if len(b1.Events()) != 1 {
		t.Fatalf("b1: expected 1 event")
	}
	if len(b2.Events()) != 1 {
		t.Fatalf("b2: expected 1 event")
	}
}
