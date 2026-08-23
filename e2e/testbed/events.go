package testbed

import (
	"encoding/json"
	"sync"
	"time"
)

const SchemaVersion = "1.0.0"

type Segment string

const (
	SegmentTotalE2E              Segment = "total_e2e"
	SegmentParse                 Segment = "parse"
	SegmentReserve               Segment = "reserve"
	SegmentRoute                 Segment = "route"
	SegmentQueueWait             Segment = "queue_wait"
	SegmentEncrypt               Segment = "encrypt"
	SegmentDispatch              Segment = "dispatch"
	SegmentE2EEncrypt            Segment = "e2e_encrypt"
	SegmentCoordinatorToProvider Segment = "coordinator_to_provider"
	SegmentProviderToBackend     Segment = "provider_to_backend"
	SegmentTTFT                  Segment = "ttft"
	SegmentDecodeTPS             Segment = "decode_tps"
	SegmentProviderToCoordinator Segment = "provider_to_coordinator"
	SegmentProviderToClient      Segment = "provider_to_client"
)

type EventKind string

const (
	EventSegmentStart EventKind = "segment_start"
	EventSegmentEnd   EventKind = "segment_end"
	EventRequestStart EventKind = "request_start"
	EventRequestEnd   EventKind = "request_end"
	EventStreamChunk  EventKind = "stream_chunk"
	EventError        EventKind = "error"
)

type Event struct {
	SchemaVersion string          `json:"schema_version"`
	Kind          EventKind       `json:"kind"`
	RequestID     string          `json:"request_id"`
	Segment       Segment         `json:"segment,omitempty"`
	Timestamp     time.Time       `json:"timestamp"`
	Duration      time.Duration   `json:"duration,omitempty"`
	Metadata      json.RawMessage `json:"metadata,omitempty"`
}

type EventConsumer interface {
	Consume(event Event)
}

type EventFan []EventConsumer

func (f EventFan) Consume(event Event) {
	for _, c := range f {
		c.Consume(event)
	}
}

type EventBuffer struct {
	mu     sync.RWMutex
	events []Event
}

func NewEventBuffer() *EventBuffer {
	return &EventBuffer{
		events: make([]Event, 0),
	}
}

func (b *EventBuffer) Consume(event Event) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.events = append(b.events, cloneEvent(event))
}

func (b *EventBuffer) Events() []Event {
	b.mu.RLock()
	defer b.mu.RUnlock()
	return cloneEvents(b.events)
}

func (b *EventBuffer) Reset() {
	b.mu.Lock()
	defer b.mu.Unlock()
	clear(b.events)
	b.events = b.events[:0]
}

func (b *EventBuffer) ByKind(kind EventKind) []Event {
	b.mu.RLock()
	defer b.mu.RUnlock()
	var out []Event
	for _, e := range b.events {
		if e.Kind == kind {
			out = append(out, cloneEvent(e))
		}
	}
	return out
}

func (b *EventBuffer) BySegment(seg Segment) []Event {
	b.mu.RLock()
	defer b.mu.RUnlock()
	var out []Event
	for _, e := range b.events {
		if e.Segment == seg {
			out = append(out, cloneEvent(e))
		}
	}
	return out
}

func (b *EventBuffer) ByRequest(requestID string) []Event {
	b.mu.RLock()
	defer b.mu.RUnlock()
	var out []Event
	for _, e := range b.events {
		if e.RequestID == requestID {
			out = append(out, cloneEvent(e))
		}
	}
	return out
}

func cloneEvents(events []Event) []Event {
	out := make([]Event, len(events))
	for i := range events {
		out[i] = cloneEvent(events[i])
	}
	return out
}

func cloneEvent(event Event) Event {
	event.Metadata = append(json.RawMessage(nil), event.Metadata...)
	return event
}
