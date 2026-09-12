package registry

import "math"

// PredictiveBypass names a request-level exclusion from the public prediction
// ceiling. It does not describe the independent absolute deadline.
type PredictiveBypass string

const (
	PredictiveBypassNone        PredictiveBypass = "none"
	PredictiveBypassSelfRoute   PredictiveBypass = "self_route"
	PredictiveBypassPreferOwner PredictiveBypass = "prefer_owner"
	PredictiveBypassMedia       PredictiveBypass = "media"
)

// SetPredictivePolicy records the actual coordinator switch and request
// exception, independently of the unrelated shadow-prediction mode.
func (ap *AttemptProfile) SetPredictivePolicy(hard bool, bypass PredictiveBypass) {
	if ap == nil {
		return
	}
	ap.mu.Lock()
	defer ap.mu.Unlock()
	if ap.predictiveMode != "" {
		return
	}
	ap.predictiveMode = "soft"
	if hard {
		ap.predictiveMode = "hard"
	}
	switch bypass {
	case PredictiveBypassNone, PredictiveBypassSelfRoute, PredictiveBypassPreferOwner, PredictiveBypassMedia:
		ap.predictiveBypass = bypass
	}
}

// SetReservationTTFTCeiling records the ceiling left by reservation. Zero
// explicitly means no predictive ceiling; absence means it was not observed.
func (ap *AttemptProfile) SetReservationTTFTCeiling(ms float64) {
	if ap == nil || math.IsNaN(ms) || math.IsInf(ms, 0) || ms < 0 {
		return
	}
	ap.mu.Lock()
	defer ap.mu.Unlock()
	if ap.reservationTTFTCeilingMs == nil {
		ap.reservationTTFTCeilingMs = &ms
	}
}

// RecordDispatchBudget stores the exact positive value encoded by the data
// lane writer. This proves frame construction, not socket or remote receipt.
func (ap *AttemptProfile) RecordDispatchBudget(ms int64) {
	if ap == nil || ms <= 0 {
		return
	}
	ap.mu.Lock()
	defer ap.mu.Unlock()
	if ap.dispatchBudgetMs == nil {
		ap.dispatchBudgetMs = &ms
	}
}

// PredictionObservation returns detached optional values so finalization can
// safely overlap the writer and cannot change the original observation.
func (ap *AttemptProfile) PredictionObservation() (mode string, bypass PredictiveBypass, ceiling *float64, budget *int64) {
	if ap == nil {
		return
	}
	ap.mu.Lock()
	defer ap.mu.Unlock()
	mode, bypass = ap.predictiveMode, ap.predictiveBypass
	if ap.reservationTTFTCeilingMs != nil {
		v := *ap.reservationTTFTCeilingMs
		ceiling = &v
	}
	if ap.dispatchBudgetMs != nil {
		v := *ap.dispatchBudgetMs
		budget = &v
	}
	return
}
