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

func TestMemoryTelemetryInsertAndList(t *testing.T) {
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

	got, err := s.ListTelemetryEvents(ctx, TelemetryFilter{Limit: 10})
	if err != nil || len(got) != 3 {
		t.Fatalf("list all: got %d want 3 err=%v", len(got), err)
	}
	if got[0].ID != "00000000-0000-0000-0000-000000000003" {
		t.Fatalf("expected newest first, got %s", got[0].ID)
	}

	byProvider, _ := s.ListTelemetryEvents(ctx, TelemetryFilter{Source: "provider", Limit: 10})
	if len(byProvider) != 2 {
		t.Fatalf("filter by source: got %d want 2", len(byProvider))
	}

	byKind, _ := s.ListTelemetryEvents(ctx, TelemetryFilter{Kind: "panic", Limit: 10})
	if len(byKind) != 1 || byKind[0].Kind != "panic" {
		t.Fatalf("filter by kind: got %+v", byKind)
	}
}

func TestMemoryTelemetryRingBuffer(t *testing.T) {
	s := NewMemory("")
	ctx := context.Background()

	// Push more than the cap.
	batch := make([]TelemetryEventRecord, memTelemetryCap+50)
	for i := range batch {
		batch[i] = mkEvent(
			// UUID-ish unique IDs
			time.Now().Add(time.Duration(i)*time.Microsecond).Format("2006-01-02T15-04-05.000000"),
			time.Now().Add(time.Duration(i)*time.Microsecond),
			"provider", "log",
		)
	}
	if err := s.InsertTelemetryEvents(ctx, batch); err != nil {
		t.Fatalf("insert: %v", err)
	}
	events, _ := s.ListTelemetryEvents(ctx, TelemetryFilter{Limit: memTelemetryCap + 100})
	if len(events) != memTelemetryCap {
		t.Fatalf("ring buffer cap: got %d want %d", len(events), memTelemetryCap)
	}
}

func TestMemoryTelemetryPrune(t *testing.T) {
	s := NewMemory("")
	ctx := context.Background()
	now := time.Now().UTC()

	events := []TelemetryEventRecord{
		mkEvent("a", now.Add(-10*time.Hour), "provider", "log"),
		mkEvent("b", now.Add(-1*time.Hour), "provider", "log"),
	}
	_ = s.InsertTelemetryEvents(ctx, events)

	removed, err := s.DeleteTelemetryEventsOlderThan(ctx, now.Add(-2*time.Hour))
	if err != nil {
		t.Fatalf("prune: %v", err)
	}
	if removed != 1 {
		t.Fatalf("removed: got %d want 1", removed)
	}

	remaining, _ := s.ListTelemetryEvents(ctx, TelemetryFilter{Limit: 10})
	if len(remaining) != 1 || remaining[0].ID != "b" {
		t.Fatalf("after prune: got %+v", remaining)
	}
}

func TestMemoryTelemetryCountByKind(t *testing.T) {
	s := NewMemory("")
	ctx := context.Background()
	now := time.Now().UTC()

	_ = s.InsertTelemetryEvents(ctx, []TelemetryEventRecord{
		mkEvent("a", now, "provider", "panic"),
		mkEvent("b", now, "provider", "panic"),
		mkEvent("c", now, "coordinator", "inference_error"),
	})

	counts, err := s.CountTelemetryEventsByKind(ctx, now.Add(-1*time.Hour))
	if err != nil {
		t.Fatalf("count: %v", err)
	}
	if len(counts) != 2 {
		t.Fatalf("groups: got %d want 2 (%+v)", len(counts), counts)
	}
	if counts[0].Count != 2 {
		t.Fatalf("top count: got %d want 2", counts[0].Count)
	}
}
