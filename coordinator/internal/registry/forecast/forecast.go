// Package forecast prices bounded first-content work from detached evidence.
// It owns no registry, provider, cache proof, admission state or request content.
package forecast

import (
	"math"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/capacityvalue"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/measurements"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/performance"
)

const (
	Feasible              = "feasible"
	Unknown               = "unknown"
	PredictedLate         = "predicted_late"
	CapacityFreshness     = 5 * time.Second
	PerformanceFreshness  = 2 * time.Minute
	HandoffMS             = 150.0
	ConservativeHandoffMS = 1000.0
	DecodeAllowance       = 33
)

type Estimate struct {
	PredictionSource string  `json:"prediction_source,omitempty"`
	TransportMs      float64 `json:"transport_ms,omitempty"`
	TransportAgeMs   int32   `json:"transport_age_ms"`
	Status           string  `json:"status"`
	Reason           string  `json:"reason,omitempty"`
	ExpectedMs       float64 `json:"expected_ms"`
	ConservativeMs   float64 `json:"conservative_ms"`
	BudgetMs         float64 `json:"budget_ms,omitempty"`
	CapacityAgeMs    int32   `json:"capacity_age_ms"`
	PerformanceAgeMs int32   `json:"performance_age_ms"`
	PromptTokens     int     `json:"prompt_tokens"`
	CachedTokens     float64 `json:"cached_tokens,omitempty"`
	RestoreMs        float64 `json:"restore_ms,omitempty"`
	ServiceMs        float64 `json:"service_ms"`
}

type Transport struct {
	ExpectedMS, ConservativeMS float64
	AgeMS                      int32
}

type Workload struct {
	PrefillAhead, PendingRestoreMS, ModelLoadMS, ServiceMS float64
	OtherModelOccupancy, PartialPrefillRows                int
	WholeMacKnown, WholeMacBusy                            bool
}

type Evidence struct {
	Calibration                       performance.CalibrationEvidence
	CapacityAcceptedAt                time.Time
	ObservedDecodeTPS                 float64
	PrefillTPS, DecodeTPS, LoadFactor float64
	Workload                          Workload
	Transport                         Transport
	WorkloadRates                     []measurements.WorkloadRate
}

// Request carries validated work counts and authenticated cache benefit. Proof
// identity and generation checks remain on the registry's owner before evaluation.
type Request struct {
	Incoming                       performance.IncomingWork
	PromptTokens, UpperBoundTokens int
	CachedTokens, RestoreMS        float64
	Deadline, FreshAfter           time.Time
	MaxTTFTMS                      float64
	Hedge, RequireFreshFeasible    bool
	PlanningHorizon                time.Duration
}

type Result struct {
	Estimate                      Estimate
	Calibrated, EvidenceQualified bool
}

// Evaluate borrows non-nil detached evidence for this call. It neither mutates
// nor retains the evidence or its nested inputs; callers must keep them immutable.
func Evaluate(evidence *Evidence, request Request, now time.Time) Result {
	history, work, transport := &evidence.Calibration, &evidence.Workload, &evidence.Transport
	e := Estimate{Status: Unknown, CapacityAgeMs: history.CapacityAgeMS, PerformanceAgeMs: history.PerformanceAgeMS,
		ServiceMs: work.ServiceMS, TransportMs: transport.ExpectedMS, TransportAgeMs: transport.AgeMS,
		PromptTokens: request.PromptTokens, CachedTokens: request.CachedTokens, RestoreMs: request.RestoreMS}
	prefill, decode := evidence.PrefillTPS, evidence.DecodeTPS
	if !capacityvalue.FinitePositive(prefill) {
		prefill = 1
	}
	if !capacityvalue.FinitePositive(decode) {
		decode = 1
	}
	competition := 1 + evidence.LoadFactor*float64(work.OtherModelOccupancy)
	e.ExpectedMs = HandoffMS + transport.ExpectedMS + work.ModelLoadMS + e.RestoreMs + work.PendingRestoreMS +
		(work.PrefillAhead+max(0, float64(request.PromptTokens)-e.CachedTokens))/prefill*1000*competition + 1000/decode
	conservativeRate := prefill
	if history.IsolatedInitialized && capacityvalue.FinitePositive(history.IsolatedPrefillTPS) {
		conservativeRate = min(conservativeRate, history.IsolatedPrefillTPS)
	}
	conservativeRate = measurements.CapPrefillByWorkload(conservativeRate, request.UpperBoundTokens, evidence.WorkloadRates, now, PerformanceFreshness)
	decodeTokens := DecodeAllowance
	if request.Incoming.RequestedMaxTokens > 0 {
		decodeTokens = min(decodeTokens, request.Incoming.RequestedMaxTokens)
	}
	e.ConservativeMs = ConservativeHandoffMS + transport.ConservativeMS + work.ModelLoadMS + e.RestoreMs + work.PendingRestoreMS +
		(work.PrefillAhead+max(0, float64(request.UpperBoundTokens)-e.CachedTokens))/conservativeRate*1000*competition +
		float64(decodeTokens)/decode*1000
	e.ConservativeMs = max(e.ConservativeMs, e.ExpectedMs)
	result := Result{}
	incoming := request.Incoming
	incoming.PromptTokens, incoming.CachedTokens = request.UpperBoundTokens, e.CachedTokens
	if prediction, age, ok := performance.PredictCalibrated(history, incoming, CapacityFreshness, PerformanceFreshness, DecodeAllowance); ok {
		e.ExpectedMs = HandoffMS + transport.ExpectedMS + e.RestoreMs + work.PendingRestoreMS + prediction.ExpectedMS
		e.ConservativeMs = ConservativeHandoffMS + transport.ConservativeMS + e.RestoreMs + work.PendingRestoreMS + prediction.ConservativeMS
		e.ConservativeMs = max(e.ConservativeMs, e.ExpectedMs)
		e.PredictionSource, e.PerformanceAgeMs = "qualified_calibration", age
		result.Calibrated = true
	}
	result.EvidenceQualified = UnknownReason(evidence, request, result.Calibrated, true) == ""
	e.Reason = UnknownReason(evidence, request, result.Calibrated, false)
	if request.Deadline.IsZero() && request.MaxTTFTMS <= 0 && (!(request.Hedge || request.RequireFreshFeasible) || request.PlanningHorizon <= 0) {
		e.Reason = "no_deadline"
	}
	if e.Reason == "" {
		e.Status = Feasible
	}
	if !request.Deadline.IsZero() {
		e.BudgetMs = max(0, float64(request.Deadline.Sub(now))/float64(time.Millisecond))
	} else if request.MaxTTFTMS > 0 {
		e.BudgetMs = request.MaxTTFTMS
	} else if (request.Hedge || request.RequireFreshFeasible) && request.PlanningHorizon > 0 {
		e.BudgetMs = float64(request.PlanningHorizon) / float64(time.Millisecond)
	}
	if e.Status == Feasible && e.ConservativeMs > e.BudgetMs {
		e.Status = PredictedLate
	}
	if !capacityvalue.FinitePositive(e.ExpectedMs) || !capacityvalue.FinitePositive(e.ConservativeMs) {
		e.Status, e.Reason = Unknown, "invalid_forecast"
		e.ExpectedMs, e.ConservativeMs = math.MaxFloat64, math.MaxFloat64
	}
	result.Estimate = e
	return result
}

// UnknownReason is also consumed by actual quote revalidation. Fresh quotes do
// not create recency or workload identity for historical measurements.
// It borrows non-nil evidence without mutating or retaining it.
func UnknownReason(evidence *Evidence, request Request, calibrated, ignoreRefusalCutoff bool) string {
	history, work := &evidence.Calibration, &evidence.Workload
	switch {
	case !history.HasCapacity:
		return "capacity_missing"
	case history.CapacityAgeMS < 0 || time.Duration(history.CapacityAgeMS)*time.Millisecond > CapacityFreshness:
		return "capacity_stale"
	case !ignoreRefusalCutoff && !request.FreshAfter.IsZero() && !evidence.CapacityAcceptedAt.After(request.FreshAfter):
		return "capacity_before_refusal"
	case calibrated:
		return ""
	case history.PerformanceAgeMS < 0 || time.Duration(history.PerformanceAgeMS)*time.Millisecond > PerformanceFreshness:
		return "performance_age_unknown_or_stale"
	case !history.IsolatedInitialized || !capacityvalue.FinitePositive(history.IsolatedPrefillTPS) || !capacityvalue.FinitePositive(evidence.ObservedDecodeTPS):
		return "performance_missing"
	case request.Incoming.RequiresVision:
		return "vision_work_unknown"
	case !history.ModelLoaded:
		return "load_work_unknown"
	case !work.WholeMacKnown || work.WholeMacBusy || work.PartialPrefillRows > 0:
		return "competing_work_unknown"
	case request.PromptTokens <= 0:
		return "prompt_unknown"
	default:
		return ""
	}
}
