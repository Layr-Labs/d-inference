package inference

import (
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/attempt"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/backend"
	providerdispatch "github.com/eigeninference/d-inference/coordinator/internal/inference/dispatch"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/providerwire"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/retry"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// PrimaryResources retain the request's existing selection, wire accounting and
// serving-slot authorities across retries. None owns settlement independently.
type PrimaryResources struct {
	Plan       *providerdispatch.Plan
	Accounting *providerwire.Accounting
	Slots      *backend.Latch
}

type PrimaryTerminal struct {
	UnservableReason string
	ClientStatus     int
	ClientReason     string
	ClientMessage    string
}

type ProviderBodyOverflow struct {
	Message string
	Bytes   int
}

// PrimaryHistory is the prior attempt's evidence, not mutable dispatch state.
// Successful queue handoff must preserve it without attributing it to the write.
type PrimaryHistory struct {
	Failure         retry.AttemptFailure
	DeadlineFailure bool
	Terminal        PrimaryTerminal
	Overflow        ProviderBodyOverflow
}

type PrimaryRequest struct {
	Dispatch           providerdispatch.Input
	Metadata           providerdispatch.PendingMetadata
	Writer             http.ResponseWriter
	Refund             func()
	History            PrimaryHistory
	RequestID          string
	Stream             bool
	SpeculativeAt      time.Duration
	VisionImageCount   int
	PredictiveRefusals int
	AttributionFrozen  bool
	StickyFault        bool
}

type PrimaryResult struct {
	Outcome       attempt.Outcome
	Provider      *registry.Provider
	Pending       *registry.PendingRequest
	RequestID     string
	History       PrimaryHistory
	DispatchError string
	DispatchCode  int
	HedgeAdvance  <-chan time.Time
}

// Primary owns selection through queue handoff; the request owner still owns
// cancellation, reservations, outcomes and the final response/settlement.
type Primary struct {
	s         *Owner
	resources PrimaryResources
}

func (s *Owner) NewPrimary(resources PrimaryResources) *Primary {
	if resources.Plan == nil {
		resources.Plan = s.NewDispatcher().NewPlan(nil)
	}
	if resources.Accounting == nil {
		resources.Accounting = &providerwire.Accounting{}
	}
	if resources.Slots == nil {
		resources.Slots = s.NewBackendLatch()
	}
	return &Primary{s: s, resources: resources}
}
