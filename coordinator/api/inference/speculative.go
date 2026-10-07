package inference

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/attempt"
	providerdispatch "github.com/eigeninference/d-inference/coordinator/internal/inference/dispatch"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/retry"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

type SpeculativeRequest struct {
	Dispatch      providerdispatch.Input
	Primary       *registry.Provider
	Pending       *registry.PendingRequest
	RequestID     string
	Metadata      providerdispatch.PendingMetadata
	SpeculativeAt time.Duration
	Failure       retry.AttemptFailure
}

// SpeculativeWaits continue on the actual pending requests. Race includes the
// accepted-empty-completion wait so the governor slot remains held until its
// terminal arbitration, not merely until a winner has been selected.
type SpeculativeWaits struct {
	NoBackup func(*PrimaryHistory) attempt.Outcome
	Accepted func() attempt.Outcome
	Race     func(*registry.Provider, *registry.PendingRequest) attempt.Outcome
}

type SpeculativeResult struct {
	Outcome         attempt.Outcome
	GovernorVerdict string
}

// Speculative owns the request-wide hedge attempt and its governor accounting.
// It shares the primary's retained plan and the same owner's dispatch resources.
type Speculative struct {
	s         *Owner
	plan      *providerdispatch.Plan
	attempted bool
	verdict   string
}

func (s *Owner) NewSpeculative(plan *providerdispatch.Plan) *Speculative {
	if plan == nil {
		plan = s.NewDispatcher().NewPlan(nil)
	}
	return &Speculative{s: s, plan: plan}
}
