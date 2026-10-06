package registry_test

import (
	"context"
	"errors"
	"log/slog"
	"os"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/autopilotledger"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

type unavailableAutopilotStore struct{ *memory.MemoryStore }

func (*unavailableAutopilotStore) RecordAutopilot(context.Context, []store.AutopilotRecord) error {
	return errors.New("unavailable")
}

func TestAutopilotNeverDispatchesWithoutDurableIntent(t *testing.T) {
	sent := 0
	r, c, now := newAutopilotControllerTest(t, false, func(d *production.Dependencies) {
		d.AutopilotSender = func(string, protocol.ModelAutopilotMessage) error { sent++; return nil }
	})
	r.SetStore(&unavailableAutopilotStore{memory.NewMemory(store.Config{})})
	p := autopilotControllerProvider(t, r, "provider", now)
	s := c.Tick(now)
	if sent != 0 || s.Issued != 0 {
		t.Fatal("dispatch occurred without persisted intent")
	}
	p.Mu().Lock()
	_, pending := r.states[p.ID].PrepareDelivery()
	p.Mu().Unlock()
	if pending {
		t.Fatal("unsent intent retained a routing fence")
	}
}

type blockingAutopilotStore struct {
	*memory.MemoryStore
	entered, release chan struct{}
	enteredOnce      sync.Once
	recorded         chan []store.AutopilotRecord
}

func (s *blockingAutopilotStore) RecordAutopilot(ctx context.Context, r []store.AutopilotRecord) error {
	s.enteredOnce.Do(func() { close(s.entered) })
	select {
	case <-s.release:
		err := s.MemoryStore.RecordAutopilot(ctx, r)
		if err == nil {
			s.recorded <- r
		}
		return err
	case <-ctx.Done():
		return ctx.Err()
	}
}

func TestAutopilotLedgerIOCannotBlockHeartbeatEventQueue(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	events := new(autopilotledger.Events)
	sink := &blockingAutopilotStore{MemoryStore: memory.NewMemory(store.Config{}), entered: make(chan struct{}), release: make(chan struct{}), recorded: make(chan []store.AutopilotRecord, 2)}
	record := store.AutopilotRecord{CommandID: "one", At: time.Now(), Phase: "reserved"}
	events.Queue(record)
	done := make(chan bool, 1)
	go func() { done <- events.Flush(sink, logger) }()
	<-sink.entered
	queued := make(chan struct{})
	go func() { record.Phase = "succeeded"; events.Queue(record); close(queued) }()
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
	<-sink.recorded
	if !events.Flush(sink, logger) {
		t.Fatal("flush failed")
	}
	var remaining int
	select {
	case batch := <-sink.recorded:
		remaining = len(batch)
		if remaining == 1 && (batch[0].CommandID != "one" || batch[0].Phase != "succeeded") {
			t.Fatalf("remaining event changed identity: %+v", batch)
		}
	default:
	}
	if remaining != 1 {
		t.Fatal("concurrent terminal event was lost")
	}
}
