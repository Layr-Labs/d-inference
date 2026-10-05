package autopilotstate

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type pendingCommand struct {
	command        protocol.ModelAutopilotMessage
	sentAt         time.Time
	capacitySeq    uint64
	status         string
	uncertain      bool
	lastSentAt     time.Time
	attempts       int
	failureBackoff time.Duration
}

// Delivery binds the durable-intent step and its rollback to one reservation,
// rather than to a command ID that a later reservation could reuse.
type Delivery struct {
	Command   protocol.ModelAutopilotMessage
	SentAt    time.Time
	Attempts  int
	Status    string
	Uncertain bool
	receipt   *pendingCommand
}

// ProvenUnsent is valid for current delivery evidence sampled after the writer
// returns. A rejected retry or acknowledged command remains ambiguous.
func (d Delivery) ProvenUnsent(queueFull bool) bool {
	return queueFull && d.Attempts == 1 && d.Status == "reserved" && !d.Uncertain
}

func (s *State) Reserve(command protocol.ModelAutopilotMessage, capacitySeq uint64, now time.Time, failureBackoff time.Duration) Delivery {
	s.pending = &pendingCommand{command: command, sentAt: now, capacitySeq: capacitySeq, status: "reserved", lastSentAt: now, attempts: 1, failureBackoff: failureBackoff}
	delivery, _ := s.PrepareDelivery()
	return delivery
}

func (s *State) PrepareDelivery() (Delivery, bool) {
	if !s.hasPending() {
		return Delivery{}, false
	}
	return Delivery{Command: s.pending.command, SentAt: s.pending.sentAt, Attempts: s.pending.attempts, Status: s.pending.status, Uncertain: s.pending.uncertain, receipt: s.pending}, true
}

func (s *State) RollbackDelivery(delivery Delivery) bool {
	if s == nil || delivery.receipt == nil || s.pending != delivery.receipt {
		return false
	}
	s.pending = nil
	return true
}

// Retry preserves both command identity and acceptance deadline, including after
// uncertainty. An expired command must be resolved by the provider, not replaced.
func (s *State) Retry(now time.Time) (Delivery, bool) {
	if !s.hasPending() || s.pending.attempts >= 3 || now.Sub(s.pending.lastSentAt) < 30*time.Second {
		return Delivery{}, false
	}
	s.pending.attempts++
	s.pending.lastSentAt = now
	return s.PrepareDelivery()
}

func (s *State) Status(providerID string, msg *protocol.ModelAutopilotStatusMessage, now func() time.Time, emit func(store.AutopilotRecord)) bool {
	if msg == nil || (msg.Status != protocol.LoadModelStatusStarted && msg.Status != protocol.LoadModelStatusSucceeded && msg.Status != protocol.LoadModelStatusFailed) || !s.hasPending() || s.pending.command.CommandID != msg.CommandID {
		return false
	}
	pending := s.pending
	if (pending.status == protocol.LoadModelStatusSucceeded || pending.status == protocol.LoadModelStatusFailed) && msg.Status != pending.status {
		return false
	}
	if pending.status != msg.Status && msg.Status == protocol.LoadModelStatusStarted {
		emit(store.AutopilotRecord{CommandID: msg.CommandID, At: now(), ProviderID: providerID, Phase: "started", Load: pending.command.LoadModelID})
	}
	pending.status = msg.Status
	return true
}

func (s *State) WriteFailed(providerID string, command protocol.ModelAutopilotMessage, queueFull bool, now func() time.Time, emit func(store.AutopilotRecord)) {
	delivery, ok := s.PrepareDelivery()
	if !ok || delivery.Command.CommandID != command.CommandID {
		return
	}
	pending := s.pending
	if delivery.ProvenUnsent(queueFull) {
		emit(store.AutopilotRecord{CommandID: command.CommandID, At: now(), ProviderID: providerID,
			Phase: "failed", Load: command.LoadModelID, Unload: command.UnloadModelIDs,
			Before: command.ExpectedResidentModels, After: command.ExpectedResidentModels})
		s.backoffUntil = now().Add(pending.failureBackoff)
		s.pending = nil
		return
	}
	pending.uncertain = true
}

func (s *State) Watchdog(providerID string, watchdog time.Duration, now time.Time, report func(store.AutopilotRecord, time.Duration)) {
	if !s.hasPending() || now.Sub(s.pending.sentAt) <= watchdog {
		return
	}
	pending := s.pending
	if !pending.uncertain {
		report(store.AutopilotRecord{CommandID: pending.command.CommandID, At: now, ProviderID: providerID, Phase: "uncertain", Load: pending.command.LoadModelID}, now.Sub(pending.sentAt))
	}
	pending.uncertain = true
}

// Disconnect retains unresolved command ownership but removes optimistic credit.
// Arrays in the queued event cannot alias a delivery retained by the caller.
func (s *State) Disconnect(providerID string, now func() time.Time, emit func(store.AutopilotRecord)) {
	if !s.hasPending() {
		return
	}
	pending := s.pending
	at := now()
	emit(store.AutopilotRecord{CommandID: pending.command.CommandID, At: at, ProviderID: providerID,
		Phase: "uncertain", Reason: pending.command.Reason, Load: pending.command.LoadModelID,
		Unload: append([]string{}, pending.command.UnloadModelIDs...), Before: append([]string{}, pending.command.ExpectedResidentModels...),
		ElapsedMS: max(0, at.Sub(pending.sentAt).Milliseconds())})
	pending.uncertain = true
}
