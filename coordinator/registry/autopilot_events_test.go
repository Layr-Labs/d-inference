package registry

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type unavailableAutopilotStore struct{ *store.MemoryStore }

func (*unavailableAutopilotStore) RecordAutopilot(context.Context, []store.AutopilotRecord) error {
	return errors.New("unavailable")
}
func TestAutopilotNeverDispatchesWithoutDurableIntent(t *testing.T) {
	r, c, now := newAutopilotControllerTest(t, false)
	r.SetStore(&unavailableAutopilotStore{store.NewMemory(store.Config{})})
	p := autopilotControllerProvider(t, r, "provider", now)
	sent := 0
	r.autopilotSender = func(string, protocol.ModelAutopilotMessage) error { sent++; return nil }
	s := c.tick(now)
	if sent != 0 || s.Issued != 0 {
		t.Fatal("dispatch occurred without persisted intent")
	}
	p.mu.Lock()
	pending := p.autopilotPending
	p.mu.Unlock()
	if pending != nil {
		t.Fatal("unsent intent retained a routing fence")
	}
}

type blockingAutopilotStore struct {
	*store.MemoryStore
	entered, release chan struct{}
}

func (s *blockingAutopilotStore) RecordAutopilot(ctx context.Context, r []store.AutopilotRecord) error {
	close(s.entered)
	select {
	case <-s.release:
		return s.MemoryStore.RecordAutopilot(ctx, r)
	case <-ctx.Done():
		return ctx.Err()
	}
}
func TestAutopilotLedgerIOCannotBlockHeartbeatEventQueue(t *testing.T) {
	r := New(testLogger())
	sink := &blockingAutopilotStore{store.NewMemory(store.Config{}), make(chan struct{}), make(chan struct{})}
	r.SetStore(sink)
	record := store.AutopilotRecord{CommandID: "one", At: time.Now(), Phase: "reserved"}
	r.queueAutopilotEvent(record)
	done := make(chan bool, 1)
	go func() { done <- r.flushAutopilotEvents() }()
	<-sink.entered
	queued := make(chan struct{})
	go func() { record.Phase = "succeeded"; r.queueAutopilotEvent(record); close(queued) }()
	select {
	case <-queued:
	case <-time.After(time.Second):
		close(sink.release)
		<-done
		t.Fatal("ledger IO held the heartbeat event lock")
	}
	close(sink.release)
	if !<-done {
		t.Fatal("flush failed")
	}
	r.autopilotEventsMu.Lock()
	remaining := len(r.autopilotEvents)
	r.autopilotEventsMu.Unlock()
	if remaining != 1 {
		t.Fatal("concurrent terminal event was lost")
	}
}
