package registry

import (
	"github.com/eigeninference/d-inference/coordinator/internal/registry/autopilotledger"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/autopilotstate"
	"github.com/eigeninference/d-inference/coordinator/registry/autopilot"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// A shadow record describes the first observation of a distinct decision, not
// a cost time series. Sequence, time and benefit noise must not bypass ledger
// idempotency; unordered model sets share the same proposal identity.
func autopilotProposalID(a autopilotAction) string {
	return autopilotledger.ProposalID(a.Action)
}

func (r *Registry) queueAutopilotEvent(record store.AutopilotRecord) {
	r.autopilotEvents.Queue(record)
}

// Persistence precedes dispatch. An unavailable ledger stops new mutations;
// existing reservations and terminal observations stay queued for retry.
func (r *Registry) flushAutopilotEvents() bool {
	return r.autopilotEvents.Flush(r.store, r.logger)
}

func (r *Registry) recordAutopilotReservation(a autopilotAction, pending autopilotstate.Delivery) bool {
	r.queueAutopilotEvent(store.AutopilotRecord{Reason: a.Reason, Shape: autopilot.ShapeLabel(a.Workload), CommandID: pending.Command.CommandID, At: pending.SentAt,
		ProviderID: a.Node.ID, Phase: "reserved", Load: a.Load, Unload: a.Unload,
		Before: autopilot.ResidentIDs(a.Node.State), After: []string{}, Benefit: a.Benefit})
	return r.flushAutopilotEvents()
}
