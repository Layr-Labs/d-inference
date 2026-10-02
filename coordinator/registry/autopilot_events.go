package registry

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry/autopilot"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// A shadow record describes the first observation of a distinct decision, not
// a cost time series. Sequence, time and benefit noise must not bypass ledger
// idempotency; unordered model sets share the same proposal identity.
func autopilotProposalID(a autopilotAction) string {
	identity := []any{"autopilot-shadow-proposal-v1", a.Node.ID, a.Node.State.Revision,
		a.Workload, a.Reason, a.Load, autopilot.SortedStrings(a.Unload),
		autopilot.ResidentIDs(a.Node.State), autopilot.SortedStrings(a.Node.State.SelectedModels)}
	body, _ := json.Marshal(identity) // only bounded strings and string sets
	digest := sha256.Sum256(body)
	return hex.EncodeToString(digest[:])
}

func (r *Registry) queueAutopilotEvent(record store.AutopilotRecord) {
	r.autopilotEventsMu.Lock()
	defer r.autopilotEventsMu.Unlock()
	if r.autopilotEvents == nil {
		r.autopilotEvents = map[string]store.AutopilotRecord{}
	}
	key := record.CommandID + ":" + record.Phase
	if _, exists := r.autopilotEvents[key]; !exists {
		r.autopilotEvents[key] = record
	}
}

// Persistence precedes dispatch. An unavailable ledger stops new mutations;
// existing reservations and terminal observations stay queued for retry.
func (r *Registry) flushAutopilotEvents() bool {
	r.autopilotEventsMu.Lock()
	if len(r.autopilotEvents) == 0 {
		r.autopilotEventsMu.Unlock()
		return true
	}
	batch := make([]store.AutopilotRecord, 0, len(r.autopilotEvents))
	for _, record := range r.autopilotEvents {
		batch = append(batch, record)
	}
	r.autopilotEventsMu.Unlock()
	sink, ok := store.As[store.AutopilotStore](r.store)
	if !ok {
		if r.logger != nil {
			r.logger.Warn("autopilot operation ledger is not configured; suspending new changes")
		}
		return false
	}

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err := sink.RecordAutopilot(ctx, batch); err != nil {
		if r.logger != nil {
			r.logger.Warn("autopilot ledger unavailable; suspending new changes", "records", len(batch))
		}
		return false
	}
	r.autopilotEventsMu.Lock()
	for _, record := range batch {
		delete(r.autopilotEvents, record.CommandID+":"+record.Phase)
	}
	r.autopilotEventsMu.Unlock()
	return true
}

func (r *Registry) recordAutopilotReservation(a autopilotAction, pending *autopilotPendingCommand) bool {
	r.queueAutopilotEvent(store.AutopilotRecord{Reason: a.Reason, Shape: autopilot.ShapeLabel(a.Workload), CommandID: pending.Command.CommandID, At: pending.SentAt,
		ProviderID: a.Node.ID, Phase: "reserved", Load: a.Load, Unload: a.Unload,
		Before: autopilot.ResidentIDs(a.Node.State), After: []string{}, Benefit: a.Benefit})
	return r.flushAutopilotEvents()
}
