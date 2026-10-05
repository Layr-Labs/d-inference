// Package providerdrain owns a connection's admission fence and replacement
// receipts. The registry serializes all operations with the provider lock.
package providerdrain

import (
	"errors"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// TTL is the heartbeat-loss fallback for an uncommitted drain announcement.
const TTL = 150 * time.Second

var ErrSuperseded = errors.New("provider drain superseded")

// Authority is connection-scoped. Its zero value has open admission.
type Authority struct {
	until                 time.Time
	committed             bool
	requestID             string
	generation            uint64
	ready                 bool
	replacementPending    bool
	replacementAcked      bool
	replacementReadySeq   uint64
	replacementAppliedSeq uint64
	replacementID         string
	removedModels         []string
	lastResumed           protocol.ModelsReplaceResumedMessage
	pendingDone           chan struct{}
}

func (a *Authority) Draining(now time.Time) bool {
	return a != nil && (a.committed || (!a.until.IsZero() && now.Before(a.until)))
}

// Mark refreshes an announcement and reports only transitions into draining.
func (a *Authority) Mark(now time.Time) bool {
	was := a.Draining(now)
	a.until = now.Add(TTL)
	return !was
}

func (a *Authority) Heartbeat(status string, now time.Time) {
	switch status {
	case protocol.HeartbeatStatusDraining:
		a.until = now.Add(TTL)
	case "idle", "serving":
		a.until = time.Time{}
	}
}

// Commit supersedes earlier receipts, including those using the same wire ID.
func (a *Authority) Commit(requestID string, pendingCount int) uint64 {
	a.committed = true
	a.requestID = requestID
	a.generation++
	a.ready = false
	a.replacementPending = false
	a.replacementAcked = false
	a.replacementReadySeq = 0
	a.replacementAppliedSeq = 0
	a.replacementID = ""
	a.lastResumed = protocol.ModelsReplaceResumedMessage{}
	// Failed replacements already changed inventory. Preserve their removals
	// so eventual readiness can reconcile queues through another barrier.
	if pendingCount > 0 && a.pendingDone == nil {
		a.pendingDone = make(chan struct{})
	}
	return a.generation
}

func (a *Authority) Complete(requestID string, generation uint64, pendingCount int) bool {
	if !a.committed || a.replacementPending || a.requestID != requestID || a.generation != generation || pendingCount != 0 {
		return false
	}
	a.ready = true
	return true
}

// Pending returns the settlement event for this exact barrier, not its state.
func (a *Authority) Pending(generation uint64) (<-chan struct{}, bool) {
	if a == nil || !a.committed || a.generation != generation {
		return nil, false
	}
	return a.pendingDone, true
}

// ReservationAdded covers pre-barrier work that enters pending ownership late.
// Ordinary dispatch never allocates a settlement event.
func (a *Authority) ReservationAdded() {
	if a != nil && a.committed && a.pendingDone == nil {
		a.pendingDone = make(chan struct{})
	}
}

// SettlePending broadcasts final reservation removal, including disconnect.
func (a *Authority) SettlePending() {
	if a != nil && a.pendingDone != nil {
		close(a.pendingDone)
		a.pendingDone = nil
	}
}

// Disconnect invalidates receipts before the registry flushes reservations.
// Settlement is signaled separately, at the original final-removal boundary.
func (a *Authority) Disconnect() {
	if a == nil {
		return
	}
	a.committed = false
	a.ready = false
	a.replacementPending = false
	a.replacementAcked = false
	a.replacementReadySeq = 0
	a.replacementAppliedSeq = 0
	a.replacementID = ""
	a.lastResumed = protocol.ModelsReplaceResumedMessage{}
	a.removedModels = nil
	a.requestID = ""
}
