package testbed

import (
	"fmt"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
)

func TestInstrumentRequestLifecycle(t *testing.T) {
	buf := NewEventBuffer()
	inst := NewInstrument(buf)

	rid := inst.NewRequestID()
	inst.RequestStart(rid)

	timer := inst.StartSegment(rid, SegmentTotalE2E)
	time.Sleep(1 * time.Millisecond)
	timer.Stop()

	inst.RequestEnd(rid, 10*time.Millisecond)

	events := buf.Events()
	assert.Len(t, events, 4)
	assert.Equal(t, EventRequestStart, events[0].Kind)
	assert.Equal(t, EventSegmentStart, events[1].Kind)
	assert.Equal(t, EventSegmentEnd, events[2].Kind)
	assert.GreaterOrEqual(t, events[2].Duration, time.Millisecond)
	assert.Equal(t, EventRequestEnd, events[3].Kind)
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
	assert.Len(t, events, 6)
	assert.Len(t, buf.ByKind(EventStreamChunk), 2)
}

func TestInstrumentError(t *testing.T) {
	buf := NewEventBuffer()
	inst := NewInstrument(buf)

	rid := inst.NewRequestID()
	inst.Error(rid, fmt.Errorf("test error"))

	events := buf.Events()
	assert.Len(t, events, 1)
	assert.Equal(t, EventError, events[0].Kind)
}

func TestInstrumentFanOut(t *testing.T) {
	b1 := NewEventBuffer()
	b2 := NewEventBuffer()
	fan := EventFan{b1, b2}

	inst := NewInstrument(fan)
	rid := inst.NewRequestID()
	inst.RequestStart(rid)

	assert.Len(t, b1.Events(), 1)
	assert.Len(t, b2.Events(), 1)
}
