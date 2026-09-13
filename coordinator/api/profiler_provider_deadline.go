package api

import (
	"math"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

const maxProfileTPS = 1_000_000_000.0

// StoredDeadlineDecision is a field-by-field allowlist separate from the wire
// type. It keeps missing values absent and folds every provider string.
type StoredDeadlineDecision struct {
	Verdict                protocol.DeadlineVerdict          `json:"verdict,omitempty"`
	Continuation           protocol.DeadlineContinuation     `json:"continuation,omitempty"`
	Projection             protocol.DeadlineProjection       `json:"projection,omitempty"`
	ProjectionReason       protocol.DeadlineProjectionReason `json:"projection_reason,omitempty"`
	ObservedUS             *int64                            `json:"observed_us,omitempty"`
	RemainingUS            *int64                            `json:"remaining_us,omitempty"`
	SubmitRemainingUS      *int64                            `json:"submit_remaining_us,omitempty"`
	ProjectedServiceUS     *int64                            `json:"projected_service_us,omitempty"`
	ProjectedPrefillTokens *int                              `json:"projected_prefill_tokens,omitempty"`
	ProjectedDecodeTokens  *int                              `json:"projected_decode_tokens,omitempty"`
	PrefillTPS             *float64                          `json:"prefill_tps,omitempty"`
	DecodeTPS              *float64                          `json:"decode_tps,omitempty"`
}

func (b *profileBounds) tps(p *float64) *float64 {
	if p == nil {
		return nil
	}
	v := *p
	switch {
	case math.IsNaN(v) || v < 0:
		v, b.violated = 0, true
	case v > maxProfileTPS:
		v, b.violated = maxProfileTPS, true
	}
	return &v
}

func storeDeadlineDecision(w *protocol.DeadlineDecision, b *profileBounds) (*StoredDeadlineDecision, bool) {
	if w == nil {
		return nil, false
	}
	s := &StoredDeadlineDecision{
		Verdict:                w.Verdict.Fold(),
		Continuation:           w.Continuation.Fold(),
		Projection:             w.Projection.Fold(),
		ProjectionReason:       w.ProjectionReason.Fold(),
		ObservedUS:             b.us(w.ObservedUS),
		RemainingUS:            b.us(w.RemainingUS),
		SubmitRemainingUS:      b.us(w.SubmitRemainingUS),
		ProjectedServiceUS:     b.us(w.ProjectedServiceUS),
		ProjectedPrefillTokens: b.count(w.ProjectedPrefillTokens),
		ProjectedDecodeTokens:  b.count(w.ProjectedDecodeTokens),
		PrefillTPS:             b.tps(w.PrefillTPS),
		DecodeTPS:              b.tps(w.DecodeTPS),
	}
	folded := s.Verdict != w.Verdict || s.Continuation != w.Continuation ||
		s.Projection != w.Projection || s.ProjectionReason != w.ProjectionReason
	return s, folded
}

func storedDeadlineDecisionOrdered(p *StoredInferenceProfile) bool {
	d := p.DeadlineDecision
	if d == nil {
		return true
	}
	if !nonDecreasing(d.ObservedUS, p.TotalUS) || !nonDecreasing(d.RemainingUS, d.SubmitRemainingUS) {
		return false
	}
	// An expiry check can run before submission. Do not interpret a missing
	// stamp or a future verdict vocabulary as proof an engine call occurred.
	return d.Verdict != protocol.DeadlineVerdictAccepted && d.Verdict != protocol.DeadlineVerdictUnreachable ||
		nonDecreasing(p.EngineSubmitUS, d.ObservedUS)
}
