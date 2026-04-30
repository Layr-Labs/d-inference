package store

// Telemetry support for the in-memory store.
//
// Datadog handles durable storage, retention, and querying. The in-memory
// store keeps a bounded ring buffer purely for the admin metrics endpoint
// and as a debug safety net.

import (
	"context"
	"time"
)

// memTelemetryCap is the maximum number of telemetry events retained in
// memory. Older events are dropped when the buffer is full.
const memTelemetryCap = 10_000

// TelemetryEventsSnapshot returns a copy of the in-memory telemetry buffer,
// newest first. Intended for tests and debugging only.
func (s *MemoryStore) TelemetryEventsSnapshot() []TelemetryEventRecord {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]TelemetryEventRecord, len(s.telemetryEvents))
	for i, e := range s.telemetryEvents {
		out[len(s.telemetryEvents)-1-i] = e
	}
	return out
}

// InsertTelemetryEvents appends events to the ring buffer.
func (s *MemoryStore) InsertTelemetryEvents(_ context.Context, events []TelemetryEventRecord) error {
	if len(events) == 0 {
		return nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	now := time.Now().UTC()
	for i := range events {
		e := events[i]
		if e.ReceivedAt.IsZero() {
			e.ReceivedAt = now
		}
		s.telemetryEvents = append(s.telemetryEvents, e)
	}
	// Trim from the front if we've exceeded the cap.
	if overflow := len(s.telemetryEvents) - memTelemetryCap; overflow > 0 {
		s.telemetryEvents = s.telemetryEvents[overflow:]
	}
	return nil
}
