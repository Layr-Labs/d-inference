package retry

import (
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/backend"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/failure"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

const (
	QueueDeadlineError  = "first-content deadline expired while queued for a provider"
	QueueDeadlineReason = "queue_deadline"
	OversizedReason     = "oversized_request"
)

// TerminalFailure is immutable evidence selected for the exhaustion response.
// It is distinct from the current attempt's route row, which must stay truthful
// even when a previous genuine fault controls the request-wide terminal.
type TerminalFailure struct {
	message protocol.InferenceErrorMessage
	slot    backend.Slot
}

func NewTerminalFailure(msg protocol.InferenceErrorMessage, slot backend.Slot) TerminalFailure {
	return TerminalFailure{message: msg, slot: slot}
}

func (f TerminalFailure) ErrorText() string     { return f.message.Error }
func (f TerminalFailure) StatusCode() int       { return f.message.StatusCode }
func (f TerminalFailure) TerminalCause() string { return f.message.TerminalCause }
func (f TerminalFailure) Deadline() bool {
	return failure.IsDeadlineUnreachableErrorReason(f.message.ErrorReason)
}
func (f TerminalFailure) Slot() backend.Slot { return f.slot }

func (f TerminalFailure) RetryTraits(traits registry.RequestTraits) registry.RequestTraits {
	if f.Deadline() {
		traits.AvoidVersion = ""
	}
	return traits
}

// TerminalEvidence owns only the request-wide genuine-fault precedence slot.
type TerminalEvidence struct{ fault *TerminalFailure }

func (e *TerminalEvidence) Observe(provider *registry.Provider, model string, msg protocol.InferenceErrorMessage, modelContext int, latch *backend.Latch) AttemptFailure {
	evidence := ProviderFailure(provider, model, msg)
	if IsGenuinePreContentFault(evidence.Message, evidence.ProviderBudget, modelContext) {
		e.Capture(evidence.Message, evidence.ProviderBudget, modelContext, latch.Capture(provider, model))
	}
	return evidence
}

func (e *TerminalEvidence) Capture(msg protocol.InferenceErrorMessage, providerBudget int64, modelContext int, slot backend.Slot) {
	if !IsGenuinePreContentFault(msg, providerBudget, modelContext) {
		return
	}
	fault := NewTerminalFailure(msg, slot)
	e.fault = &fault
}

func (e *TerminalEvidence) Select(current TerminalFailure, clientError bool) (TerminalFailure, bool) {
	if e.fault != nil && !clientError {
		return *e.fault, true
	}
	return current, false
}

type Dominance int

const (
	Undecided Dominance = iota
	ClientError
	GenuineFault
	Unservable
	Deadline
)

type TerminalPolicy struct {
	ClientError      bool
	ClientStatus     int
	ClientReason     string
	Unservable       bool
	UnservableReason string
}

// ResolveTerminal applies the status and attribution precedence ladder once.
// The selected immutable failure remains available for the actual HTTP body
// and slot attribution, rather than exporting the evidence ledger's state.
func ResolveTerminal(f TerminalFailure, sticky bool, policy TerminalPolicy) (status int, reason string, timeoutReclassified bool, dominance Dominance) {
	status, reason, timeoutReclassified = ClassifyExhaustedStatus(f.StatusCode(), f.TerminalCause())
	if timeoutReclassified && f.ErrorText() == QueueDeadlineError {
		reason = QueueDeadlineReason
	}
	switch {
	case policy.ClientError:
		status, reason = policy.ClientStatus, "client_error"
		if policy.ClientReason != "" {
			reason = policy.ClientReason
		}
		return status, reason, timeoutReclassified, ClientError
	case sticky:
		return status, reason, timeoutReclassified, GenuineFault
	case policy.Unservable:
		reason = policy.UnservableReason
		if reason == "" {
			reason = OversizedReason
		}
		return http.StatusTooManyRequests, reason, timeoutReclassified, Unservable
	case f.Deadline():
		return http.StatusTooManyRequests, failure.ErrorReasonDeadlineUnreachable, timeoutReclassified, Deadline
	default:
		return status, reason, timeoutReclassified, Undecided
	}
}
