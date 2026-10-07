// Package autopilotledger owns pending Autopilot operation records and durable
// proposal identities. Persistence completes before a reserved command is sent.
package autopilotledger

import (
	"context"
	"log/slog"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// Events deduplicates pending phases without holding its lock during store IO.
// Its zero value is ready for use.
type Events struct {
	mu      sync.Mutex
	pending map[string]store.AutopilotRecord
}

func (e *Events) Queue(record store.AutopilotRecord) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.pending == nil {
		e.pending = map[string]store.AutopilotRecord{}
	}
	key := record.CommandID + ":" + record.Phase
	if _, exists := e.pending[key]; !exists {
		e.pending[key] = record
	}
}

// Flush leaves failed writes pending. False suspends new mutations while
// existing reservations and terminal observations remain available for retry.
func (e *Events) Flush(s store.Store, logger *slog.Logger) bool {
	e.mu.Lock()
	if len(e.pending) == 0 {
		e.mu.Unlock()
		return true
	}
	batch := make([]store.AutopilotRecord, 0, len(e.pending))
	for _, record := range e.pending {
		batch = append(batch, record)
	}
	e.mu.Unlock()
	sink, ok := store.As[store.AutopilotStore](s)
	if !ok {
		if logger != nil {
			logger.Warn("autopilot operation ledger is not configured; suspending new changes")
		}
		return false
	}

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err := sink.RecordAutopilot(ctx, batch); err != nil {
		if logger != nil {
			logger.Warn("autopilot ledger unavailable; suspending new changes", "records", len(batch))
		}
		return false
	}
	e.mu.Lock()
	for _, record := range batch {
		delete(e.pending, record.CommandID+":"+record.Phase)
	}
	e.mu.Unlock()
	return true
}
