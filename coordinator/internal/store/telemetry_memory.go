package store

// Telemetry support for the in-memory store.
//
// The memory implementation uses a bounded ring buffer (capped at
// memTelemetryCap events). Oldest events are discarded on overflow.

import (
	"context"
	"sort"
	"time"
)

// memTelemetryCap is the maximum number of telemetry events retained in
// memory. Older events are dropped when the buffer is full.
const memTelemetryCap = 10_000

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

// ListTelemetryEvents returns matching events, newest first, limited by filter.
func (s *MemoryStore) ListTelemetryEvents(_ context.Context, f TelemetryFilter) ([]TelemetryEventRecord, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]TelemetryEventRecord, 0, min(len(s.telemetryEvents), f.Limit+1))
	for i := len(s.telemetryEvents) - 1; i >= 0; i-- {
		e := s.telemetryEvents[i]
		if !matchFilter(e, f) {
			continue
		}
		out = append(out, e)
		if f.Limit > 0 && len(out) >= f.Limit {
			break
		}
	}
	return out, nil
}

// DeleteTelemetryEventsOlderThan prunes old events; returns rows removed.
func (s *MemoryStore) DeleteTelemetryEventsOlderThan(_ context.Context, before time.Time) (int64, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	keep := s.telemetryEvents[:0]
	var removed int64
	for _, e := range s.telemetryEvents {
		if e.Timestamp.Before(before) {
			removed++
			continue
		}
		keep = append(keep, e)
	}
	s.telemetryEvents = keep
	return removed, nil
}

// CountTelemetryEventsByKind aggregates events by (source, severity, kind).
func (s *MemoryStore) CountTelemetryEventsByKind(_ context.Context, since time.Time) ([]TelemetryKindCount, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	type key struct{ source, severity, kind string }
	counts := make(map[key]int64)
	for _, e := range s.telemetryEvents {
		if e.Timestamp.Before(since) {
			continue
		}
		counts[key{e.Source, e.Severity, e.Kind}]++
	}
	out := make([]TelemetryKindCount, 0, len(counts))
	for k, c := range counts {
		out = append(out, TelemetryKindCount{
			Source: k.source, Severity: k.severity, Kind: k.kind, Count: c,
		})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Count > out[j].Count })
	return out, nil
}

func matchFilter(e TelemetryEventRecord, f TelemetryFilter) bool {
	if f.Source != "" && e.Source != f.Source {
		return false
	}
	if f.Severity != "" && e.Severity != f.Severity {
		return false
	}
	if f.Kind != "" && e.Kind != f.Kind {
		return false
	}
	if f.MachineID != "" && e.MachineID != f.MachineID {
		return false
	}
	if f.AccountID != "" && e.AccountID != f.AccountID {
		return false
	}
	if f.RequestID != "" && e.RequestID != f.RequestID {
		return false
	}
	if !f.Since.IsZero() && e.Timestamp.Before(f.Since) {
		return false
	}
	if !f.Until.IsZero() && e.Timestamp.After(f.Until) {
		return false
	}
	return true
}
