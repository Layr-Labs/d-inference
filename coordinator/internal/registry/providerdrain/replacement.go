package providerdrain

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// CanReplace authorizes inventory mutation only after the named drain settled.
func (a *Authority) CanReplace(drainRequestID string) bool {
	return a != nil && a.committed && a.ready && a.requestID == drainRequestID
}

// BeginReplacement records committed inventory while keeping admission closed.
// selected is the caller's validated inventory, never retained by the authority.
func (a *Authority) BeginReplacement(requestID string, selected map[string]protocol.ModelInfo, removed []string) uint64 {
	a.ready = false
	a.replacementPending = true
	a.replacementAcked = false
	a.replacementReadySeq = 0
	a.replacementAppliedSeq = 0
	a.replacementID = requestID
	// Retain removals across unconfirmed replacements, excluding restored IDs.
	pendingRemoved := make([]string, 0, len(a.removedModels)+len(removed))
	seenRemoved := make(map[string]struct{}, len(a.removedModels)+len(removed))
	for _, id := range append(append([]string(nil), a.removedModels...), removed...) {
		if _, restored := selected[id]; restored {
			continue
		}
		if _, seen := seenRemoved[id]; !seen {
			seenRemoved[id] = struct{}{}
			pendingRemoved = append(pendingRemoved, id)
		}
	}
	a.removedModels = pendingRemoved
	return a.generation
}

func (a *Authority) ConfirmReceipt(requestID string, generation uint64) bool {
	if !a.committed || !a.replacementPending || a.generation != generation || a.replacementID != requestID {
		return false
	}
	a.replacementAcked = true
	return true
}

// AppliedCapacity accepts only already-applied, ordered serving heartbeats.
func (a *Authority) AppliedCapacity(status string, capacitySeq uint64) {
	if a.replacementPending && a.replacementAcked && capacitySeq > 0 && (status == "idle" || status == "serving") {
		a.replacementAppliedSeq = capacitySeq
	}
}

func (a *Authority) Readiness(requestID, drainRequestID string, capacitySeq uint64, models []protocol.ModelInfo) (added, removed []string, resumed bool, ack *protocol.ModelsReplaceResumedMessage) {
	// Retry the identical receipt if the prior control-writer handoff failed
	// after routing resumed. No inventory mutation is repeated.
	if requestID != "" && drainRequestID != "" && capacitySeq > 0 && !a.committed &&
		a.lastResumed.RequestID == requestID && a.lastResumed.DrainRequestID == drainRequestID && a.lastResumed.CapacitySeq == capacitySeq {
		last := a.lastResumed
		return nil, nil, false, &last
	}
	if !a.committed || !a.replacementPending || !a.replacementAcked ||
		a.replacementID != requestID || a.requestID != drainRequestID || capacitySeq == 0 {
		return nil, nil, false, nil
	}
	if capacitySeq > a.replacementReadySeq {
		a.replacementReadySeq = capacitySeq
	}
	return a.Resume(models)
}

func (a *Authority) Resume(models []protocol.ModelInfo) (added, removed []string, resumed bool, ack *protocol.ModelsReplaceResumedMessage) {
	if !a.committed || !a.replacementPending || !a.replacementAcked ||
		a.replacementReadySeq == 0 || a.replacementAppliedSeq < a.replacementReadySeq {
		return nil, nil, false, nil
	}
	confirmation := protocol.ModelsReplaceResumedMessage{
		Type: protocol.TypeModelsReplaceResumed, RequestID: a.replacementID,
		DrainRequestID: a.requestID, CapacitySeq: a.replacementReadySeq,
	}
	for _, model := range models {
		added = append(added, model.ID)
	}
	removed = append([]string(nil), a.removedModels...)
	a.committed = false
	a.replacementPending = false
	a.replacementAcked = false
	a.replacementReadySeq = 0
	a.replacementAppliedSeq = 0
	a.replacementID = ""
	a.removedModels = nil
	a.requestID = ""
	a.until = time.Time{}
	a.lastResumed = confirmation
	return added, removed, true, &confirmation
}
