package selection

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachepolicy"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/capacityvalue"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/forecast"
)

// SummaryInput contains only the scalar evidence recorded for a scanned candidate.
type SummaryInput struct {
	ProviderID   string
	FirstContent forecast.Estimate
	Breakdown    cachepolicy.ServiceBreakdown

	CostMs, EffectiveTPS                                         float64
	EffectiveQueue, TotalPending, BackendRunning, BackendWaiting int

	ActiveTokenBudgetUsed, ActiveTokenBudgetMax, QueuedPrefillTokens int64
	SlotState                                                        string
	HBAgeMs                                                          int32
}

// CandidateSummary is a fixed-size, allocation-free summary of one scanned
// routing candidate. The slot vocabulary remains owned by the caller.
type CandidateSummary[S ~string] struct {
	ProviderID string
	// FirstContent carries the advisory delivery forecast separately from the
	// historical cost/TTFT diagnostics. It contains no prompt or cache identity.
	FirstContent forecast.Estimate

	CostMs, StateMs, QueueMs, PendingMs, BacklogMs, ThisReqMs, HealthMs, CapacityRateMs, CacheDiscountMs float64
	TTFTMs, EffectiveTPS                                                                                 float64

	EffectiveQueue, TotalPending, BackendRunning, BackendWaiting int32

	ActiveTokenBudgetUsed, ActiveTokenBudgetMax, QueuedPrefillTokens int64

	// SlotState is the folded (closed) slot state of the candidate's slot for
	// the requested model at snapshot time.
	SlotState S
	// HBAgeMs is the age of the candidate's last heartbeat at snapshot time
	// (clamped to int32).
	HBAgeMs int32
	// Present is false for an unfilled slot (fewer candidates than the array).
	Present bool
}

// SummarizeCandidate builds the fixed-size summary of a scanned candidate.
// A nil input represents an absent candidate or provider. Every field is a
// value copy; folding retains the caller's closed slot-state vocabulary.
func SummarizeCandidate[S ~string](in *SummaryInput, foldSlot func(string) S) CandidateSummary[S] {
	if in == nil {
		return CandidateSummary[S]{}
	}
	bd := in.Breakdown
	return CandidateSummary[S]{
		ProviderID:            in.ProviderID,
		FirstContent:          in.FirstContent,
		CostMs:                in.CostMs,
		StateMs:               bd.StateMs,
		QueueMs:               bd.QueueMs,
		PendingMs:             bd.PendingMs,
		BacklogMs:             bd.BacklogMs,
		ThisReqMs:             bd.ThisReqMs,
		HealthMs:              bd.HealthMs,
		CapacityRateMs:        bd.CapacityRateMs,
		CacheDiscountMs:       bd.CacheDiscountMs,
		TTFTMs:                bd.TTFTMs,
		EffectiveTPS:          in.EffectiveTPS,
		EffectiveQueue:        ClampInt32(in.EffectiveQueue),
		TotalPending:          ClampInt32(in.TotalPending),
		BackendRunning:        ClampInt32(in.BackendRunning),
		BackendWaiting:        ClampInt32(in.BackendWaiting),
		ActiveTokenBudgetUsed: in.ActiveTokenBudgetUsed,
		ActiveTokenBudgetMax:  in.ActiveTokenBudgetMax,
		QueuedPrefillTokens:   in.QueuedPrefillTokens,
		SlotState:             foldSlot(in.SlotState),
		HBAgeMs:               in.HBAgeMs,
		Present:               true,
	}
}

// HeartbeatAgeMs is now minus lastHeartbeat in milliseconds, clamped to int32.
// A zero lastHeartbeat saturates rather than producing a nonsense value.
func HeartbeatAgeMs(now, lastHeartbeat time.Time) int32 {
	if lastHeartbeat.IsZero() {
		return ClampMsInt32(int64(^uint32(0) >> 1))
	}
	return ClampMsInt32(now.Sub(lastHeartbeat).Milliseconds())
}

// ClampInt32 narrows an int to int32, saturating at the bounds.
func ClampInt32(v int) int32 {
	const maxI32, minI32 = int(^uint32(0) >> 1), -int(^uint32(0)>>1) - 1
	if v > maxI32 {
		return int32(maxI32)
	}
	if v < minI32 {
		return int32(minI32)
	}
	return int32(v)
}

// ClampMsInt32 narrows a millisecond count (int64) to int32, saturating.
func ClampMsInt32(ms int64) int32 {
	return capacityvalue.ClampMsInt32(ms)
}
