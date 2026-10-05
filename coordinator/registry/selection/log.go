package selection

import (
	"context"
	"log/slog"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachepolicy"
)

// DecisionLog is the detached projection of a committed routing decision.
type DecisionLog struct {
	RequestID, Model, Winner   string
	Breakdown                  cachepolicy.ServiceBreakdown
	Path                       string
	CacheTier                  string
	CacheEstimatedTTFTSavedMs  float64
	EffectiveTPS               float64
	EffectiveQueue, Candidates int
}

// LogDecision emits the winning candidate and its cost breakdown. Projection is
// deferred so disabled logging never reads candidate fields or boxes arguments.
func LogDecision(logger *slog.Logger, project func() DecisionLog) {
	if logger == nil {
		return
	}
	// Level check BEFORE the variadic call: slog boxes every key/value pair
	// into any at the call site even when the level is disabled, and this
	// runs under the registry lock on every reserve.
	if !logger.Enabled(context.Background(), slog.LevelDebug) {
		return
	}
	decision := project()
	bd := decision.Breakdown
	logger.Debug("routing_decision",
		"request_id", decision.RequestID,
		"model", decision.Model,
		"winner", decision.Winner,
		"cost_ms", bd.Total,
		"state_ms", bd.StateMs,
		"queue_ms", bd.QueueMs,
		"pending_ms", bd.PendingMs,
		"backlog_ms", bd.BacklogMs,
		"this_req_ms", bd.ThisReqMs,
		"health_ms", bd.HealthMs,
		"selection_path", decision.Path,
		"cache_tier", decision.CacheTier,
		"cache_discount_ms", bd.CacheDiscountMs,
		"cache_estimated_ttft_saved_ms", decision.CacheEstimatedTTFTSavedMs,
		"effective_tps", decision.EffectiveTPS,
		"effective_queue", decision.EffectiveQueue,
		"candidates", decision.Candidates,
	)
}
