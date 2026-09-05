package outcomes

import (
	"sync"
	"sync/atomic"
	"time"
)

// Tracker keeps bounded request evidence. No content or provider text is ever
// accepted. publish must be nonblocking; it is called under the per-request lock
// so revisions enter the sink in order. Store replay also enforces revision order.
type Tracker struct {
	mu        sync.Mutex
	record    Record
	publish   func(*Record)
	winning   *Attempt
	content   bool
	committed bool
	rejected  bool
}

type Attempt struct {
	parent      *Tracker
	record      AttemptRecord
	index       int
	refused     bool
	contentSeen atomic.Bool
}

func New(id, endpoint string, received time.Time, publish func(*Record)) *Tracker {
	t := &Tracker{publish: publish, record: Record{
		CoordRequestID: id, SchemaVersion: SchemaVersion, ReceivedAt: received,
		Endpoint: endpoint, Termination: "open", ResponseProgress: "unknown",
		ProviderOutcome: "unknown", ResponseTerminal: "unknown", Attempts: []AttemptRecord{},
	}}
	t.emitLocked()
	return t
}

func (t *Tracker) Shape(model string, stream bool) {
	if t == nil {
		return
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	t.record.Model = model
	t.record.Stream = &stream
}

func (t *Tracker) NewAttempt(id string, ordinal int, backup string) *Attempt {
	if t == nil {
		return nil
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	a := &Attempt{parent: t, index: -1, record: AttemptRecord{RequestID: id, Attempt: ordinal, BackupOf: backup, ProviderOutcome: "no_terminal"}}
	t.record.AttemptCount++
	if len(t.record.Attempts) < MaxAttempts {
		a.index = len(t.record.Attempts)
		t.record.Attempts = append(t.record.Attempts, a.record)
	} else {
		t.record.AttemptsTruncated = true
	}
	return a
}

func (a *Attempt) Parent() *Tracker {
	if a == nil {
		return nil
	}
	return a.parent
}

// Observe accepts only code-owned milestone names and normalized raw reasons.
// provider_error and provider_complete are independent of the route's terminal:
// a speculative loser may complete, or a client may leave before completion.
func (a *Attempt) Observe(event, reason string, status int) {
	if a == nil {
		return
	}
	t := a.parent
	t.mu.Lock()
	defer t.mu.Unlock()
	before, conflictBefore, reasonBefore := a.record, t.record.EvidenceConflict, t.record.RawReason
	switch event {
	case "write_started":
		a.record.WriteStarted = true
	case "write_completed":
		if !a.record.WriteCompleted {
			t.record.DispatchedAttemptCount++
		}
		a.record.WriteCompleted = true
	case "acknowledged":
		a.record.ProviderAcknowledged = true
	case "content":
		a.contentSeen.Store(true)
		a.record.ContentObserved = true
		t.content = true
	case "committed":
		if t.winning != nil && t.winning != a {
			t.record.EvidenceConflict = true
		}
		a.record.Winning = true
		t.winning = a
		t.committed = true
	case "provider_complete", "provider_error":
		outcome := "completed"
		if event == "provider_error" {
			outcome = "error"
		}
		if a.record.ProviderOutcome != "no_terminal" && a.record.ProviderOutcome != outcome {
			t.record.EvidenceConflict = true
		}
		if a.record.ProviderOutcome == "no_terminal" {
			a.record.ProviderOutcome = outcome
		}
	case "not_dispatched":
		if !a.record.WriteStarted && !a.record.WriteCompleted && a.record.ProviderOutcome == "no_terminal" {
			a.record.ProviderOutcome = "not_dispatched"
		}
	case "route_terminal": // Synthetic cancellation/timeout is not a provider terminal.
		if a.record.Winning && reason != "" && t.record.RawReason == "" {
			t.record.RawReason = reason
		}
	}
	if reason != "" {
		// Keep the actual diagnostic terminal class. A provider refusal remains
		// linked even if a later synthetic loser outcome supersedes its class.
		if a.record.RawReason == "" || a.record.RawReason == "unknown" {
			a.record.RawReason = reason
		}
		if event == "provider_error" && AttemptCode(reason) != "" && !a.refused {
			a.refused = true
			t.record.DeadlineRefusalCount++
			a.record.NormalizedCode = AttemptCode(reason)
		}
	}
	if status > 0 && a.record.HTTPStatus == nil {
		a.record.HTTPStatus = &status
	}
	if a.index >= 0 {
		t.record.Attempts[a.index] = a.record
	}
	if t.record.FinalizedAt != nil && (a.record != before || t.record.EvidenceConflict != conflictBefore || t.record.RawReason != reasonBefore) {
		t.classifyLocked()
		t.emitLocked()
	}
}

func (t *Tracker) Rejection(reason string, exhausted bool) {
	if t == nil {
		return
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.rejected && t.record.RawReason != reason {
		t.record.EvidenceConflict = true
	}
	if !t.rejected {
		t.record.RawReason = reason
		t.record.NormalizedCode = RequestCode(reason, exhausted)
	}
	t.rejected = true
}

func (t *Tracker) Egress(completed, writeError bool, terminal ...string) {
	if t == nil {
		return
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	t.record.ClientWriteError = t.record.ClientWriteError || writeError
	t.record.ResponseEgressCompleted = (t.record.ResponseEgressCompleted || completed) && !t.record.ClientWriteError
	if len(terminal) > 0 {
		switch terminal[0] {
		case "completed", "incomplete", "error":
			t.record.ResponseTerminal = terminal[0]
		}
	}
}

// ContentWritten records a fully accepted write containing generated content.
// Header/preamble/error writes never call it. It is independent of provider ingress.
func (t *Tracker) ContentWritten() {
	if t == nil {
		return
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	t.record.ContentEgressObserved = true
}

func (t *Tracker) Finish(status int, departed, writeError bool) {
	if t == nil {
		return
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.record.FinalizedAt != nil {
		return
	}
	now := time.Now()
	t.record.FinalizedAt = &now
	t.record.HTTPStatus = &status
	t.record.ClientDeparted = departed
	t.record.ClientWriteError = t.record.ClientWriteError || writeError
	if t.record.ClientWriteError {
		t.record.ResponseEgressCompleted = false
	}
	t.classifyLocked()
	t.emitLockedAt(now)
}

func (t *Tracker) classifyLocked() {
	r := &t.record
	r.ResponseProgress = "none"
	if t.content {
		r.ResponseProgress = "content_observed"
	}
	r.ProviderOutcome = "unknown"
	if t.winning != nil {
		r.ProviderOutcome = t.winning.record.ProviderOutcome
	} else if r.AttemptCount == 0 {
		r.ProviderOutcome = "not_dispatched"
	}
	complete := r.ProviderOutcome == "completed" && r.ResponseTerminal == "completed" && r.ResponseEgressCompleted && !r.ClientWriteError
	if complete {
		r.ResponseProgress = "completion_confirmed"
	}
	switch {
	case r.EvidenceConflict:
		r.Termination = "unknown"
	case r.ClientDeparted:
		r.Termination = "client_departure"
	case complete:
		r.Termination = "completed"
	case t.committed || r.ClientWriteError && r.HTTPStatus != nil && *r.HTTPStatus < 400:
		r.Termination = "interrupted"
	case r.HTTPStatus != nil && *r.HTTPStatus >= 400:
		r.Termination = "rejected"
		if r.RawReason == "" {
			r.RawReason = "unknown"
		}
	default:
		r.Termination = "unknown"
	}
}

func (t *Tracker) emitLocked() { t.emitLockedAt(time.Now()) }

func (t *Tracker) emitLockedAt(at time.Time) {
	t.record.Revision++
	t.record.ObservedAt = at
	if t.publish == nil {
		return
	}
	r := t.record
	r.Attempts = append([]AttemptRecord{}, r.Attempts...)
	t.publish(&r)
}

func (t *Tracker) Snapshot() Record {
	t.mu.Lock()
	defer t.mu.Unlock()
	r := t.record
	r.Attempts = append([]AttemptRecord{}, r.Attempts...)
	return r
}

func (t *Tracker) HasContent() bool {
	if t == nil {
		return false
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.content
}

// NeedsContent is a cheap per-attempt gate for the first-content parser.
func (a *Attempt) NeedsContent() bool { return a != nil && !a.contentSeen.Load() }
