package store

import (
	"context"
	"encoding/json"
	"testing"
	"time"
)

func mkEvent(id string, ts time.Time, source, kind string) TelemetryEventRecord {
	return TelemetryEventRecord{
		ID:        id,
		Timestamp: ts,
		Source:    source,
		Severity:  "error",
		Kind:      kind,
		Version:   "0.3.10",
		MachineID: "m1",
		AccountID: "a1",
		Message:   "hello",
		Fields:    json.RawMessage(`{"component":"provider"}`),
	}
}

func TestMemoryTelemetryInsert(t *testing.T) {
	s := NewMemory("")
	ctx := context.Background()
	now := time.Now().UTC()

	events := []TelemetryEventRecord{
		mkEvent("00000000-0000-0000-0000-000000000001", now.Add(-3*time.Minute), "provider", "panic"),
		mkEvent("00000000-0000-0000-0000-000000000002", now.Add(-2*time.Minute), "provider", "backend_crash"),
		mkEvent("00000000-0000-0000-0000-000000000003", now.Add(-1*time.Minute), "coordinator", "inference_error"),
	}
	if err := s.InsertTelemetryEvents(ctx, events); err != nil {
		t.Fatalf("insert: %v", err)
	}

	// Verify the internal ring buffer has the events.
	s.mu.RLock()
	count := len(s.telemetryEvents)
	s.mu.RUnlock()
	if count != 3 {
		t.Fatalf("stored events: got %d want 3", count)
	}
}

func TestMemoryTelemetryRingBuffer(t *testing.T) {
	s := NewMemory("")
	ctx := context.Background()

	// Push more than the cap.
	batch := make([]TelemetryEventRecord, memTelemetryCap+50)
	for i := range batch {
		batch[i] = mkEvent(
			time.Now().Add(time.Duration(i)*time.Microsecond).Format("2006-01-02T15-04-05.000000"),
			time.Now().Add(time.Duration(i)*time.Microsecond),
			"provider", "log",
		)
	}
	if err := s.InsertTelemetryEvents(ctx, batch); err != nil {
		t.Fatalf("insert: %v", err)
	}
	s.mu.RLock()
	count := len(s.telemetryEvents)
	s.mu.RUnlock()
	if count != memTelemetryCap {
		t.Fatalf("ring buffer cap: got %d want %d", count, memTelemetryCap)
	}
}
