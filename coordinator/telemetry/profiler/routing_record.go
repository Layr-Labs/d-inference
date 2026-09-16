package profiler

import (
	"encoding/json"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// candidateJSON is the persisted shape of one candidate summary.
type candidateJSON struct {
	ProviderID            string  `json:"provider_id"`
	CostMs                float64 `json:"cost_ms"`
	StateMs               float64 `json:"state_ms"`
	QueueMs               float64 `json:"queue_ms"`
	PendingMs             float64 `json:"pending_ms"`
	BacklogMs             float64 `json:"backlog_ms"`
	ThisReqMs             float64 `json:"this_req_ms"`
	HealthMs              float64 `json:"health_ms"`
	CapacityRateMs        float64 `json:"capacity_rate_ms"`
	CacheDiscountMs       float64 `json:"cache_discount_ms"`
	TTFTMs                float64 `json:"ttft_ms"`
	EffectiveTPS          float64 `json:"effective_tps"`
	EffectiveQueue        int32   `json:"effective_queue"`
	TotalPending          int32   `json:"total_pending"`
	BackendRunning        int32   `json:"backend_running"`
	BackendWaiting        int32   `json:"backend_waiting"`
	ActiveTokenBudgetUsed int64   `json:"active_token_budget_used"`
	ActiveTokenBudgetMax  int64   `json:"active_token_budget_max"`
	QueuedPrefillTokens   int64   `json:"queued_prefill_tokens"`
	SlotState             string  `json:"slot_state"`
	HBAgeMs               int32   `json:"hb_age_ms"`
}

func candidateFromSummary(c registry.CandidateSummary) candidateJSON {
	return candidateJSON{
		ProviderID: c.ProviderID, CostMs: c.CostMs, StateMs: c.StateMs, QueueMs: c.QueueMs,
		PendingMs: c.PendingMs, BacklogMs: c.BacklogMs, ThisReqMs: c.ThisReqMs, HealthMs: c.HealthMs,
		CapacityRateMs: c.CapacityRateMs, CacheDiscountMs: c.CacheDiscountMs, TTFTMs: c.TTFTMs,
		EffectiveTPS: c.EffectiveTPS, EffectiveQueue: c.EffectiveQueue, TotalPending: c.TotalPending,
		BackendRunning: c.BackendRunning, BackendWaiting: c.BackendWaiting,
		ActiveTokenBudgetUsed: c.ActiveTokenBudgetUsed, ActiveTokenBudgetMax: c.ActiveTokenBudgetMax,
		QueuedPrefillTokens: c.QueuedPrefillTokens, SlotState: string(c.SlotState), HBAgeMs: c.HBAgeMs,
	}
}

// decisionJSON encodes the routing context fields that are not flat columns.
func decisionJSON(d registry.RoutingDecision) (candidates, gateRejections json.RawMessage) {
	top := make([]candidateJSON, 0, len(d.Top))
	for _, c := range d.Top {
		if c.Present {
			top = append(top, candidateFromSummary(c))
		}
	}
	if len(top) > 0 {
		if b, err := json.Marshal(top); err == nil {
			candidates = b
		}
	}
	rejections := make(map[string]uint16, 8)
	for i, n := range d.GateRejections {
		if n > 0 {
			rejections[registry.GateReason(i).String()] = n
		}
	}
	if len(rejections) > 0 {
		if b, err := json.Marshal(rejections); err == nil {
			gateRejections = b
		}
	}
	return candidates, gateRejections
}
