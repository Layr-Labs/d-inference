package inference

import (
	"encoding/json"
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/rejection"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// rejectionInfo carries everything known about a rejected inbound inference
// request at a 4xx/5xx exit point. Callers populate what they have; zero values
// are fine. It is the single contract the consumer/handler code uses to feed the
// rejection ledger (see docs/design/routing-telemetry-and-calibration.md §4.9).
type rejectionInfo struct {
	r          *http.Request
	stage      string // auth, validation, model_resolution, balance, rate_limit, preflight_capacity, routing_ttft
	reasonCode string // e.g. model_not_found, machine_busy, insufficient_funds
	httpStatus int

	keyID           string
	consumerKeyHash string

	requestedModel string // raw, as the client sent it
	resolvedModel  string // after alias resolution, when known

	stream                bool
	n                     int
	estimatedPromptTokens int
	requestedMaxTokens    int
	requiresVision        bool
	hasImage              bool
	hasAudio              bool
	hasTools              bool
	toolCount             int
	responseFormat        string
	selfRouteOnly         bool
	preferOwner           bool
	params                json.RawMessage // non-content knobs (temperature, top_p, …)
	requestBodyBytes      int
	retryAfterMs          int

	// 402 / 429 extras.
	shortfallMicroUSD int64
	limitKind         string
	overBy            int64

	// Counterfactual. When servabilityComputed is true the caller already ran the
	// capacity check (e.g. the pre-flight) and the candidate*/bestTTFTMs fields
	// below are authoritative — recordRejection will NOT recompute. Otherwise, when
	// a resolvedModel is set, recordRejection computes servability itself.
	servabilityComputed     bool
	skipServability         bool // shedding under saturation must not start another fleet scan
	candidateCount          int
	capacityRejections      int
	modelTooLargeRejections int
	visionRejections        int
	bestTTFTMs              float64
}

// recordRejection persists a rejected-request record asynchronously, computing
// the counterfactual servability ("could the fleet have served it?") off the
// request path when the caller did not already do so. Best-effort: it never
// blocks or fails the request.
func (s *Owner) recordRejection(info rejectionInfo) {
	s.NewRejectionRecorder().Record(info.r, info.record(), rejection.Servability{Computed: info.servabilityComputed, Skip: info.skipServability})
}

// NewRejectionRecorder binds the live ledger and telemetry collaborators while
// retaining request annotation and outcome authority on this inference owner.
func (s *Owner) NewRejectionRecorder() *rejection.Recorder {
	d := rejection.Dependencies{
		AnnotateOutcome: func(r *http.Request, rec *store.RejectionRecord) {
			observation.AnnotateOutcomeRejection(r, rec.Stage, rec.ReasonCode, rec.ResolvedModel)
		},
		AnnotateDemand: func(r *http.Request, rec *store.RejectionRecord) {
			annotateAutopilotDemandRejection(rejectionInfo{r: r, resolvedModel: rec.ResolvedModel, reasonCode: rec.ReasonCode, httpStatus: rec.HTTPStatus})
		},
	}
	if s != nil {
		d.Store, d.Registry, d.Observation, d.Metrics = s.store, s.registry, s.observation, s.NewMetrics()
		d.RecordOutcome = func(model, class string) {
			s.recordRequestOutcome(model, newUnknownKVBackendAttribution(), class)
		}
	}
	return rejection.New(d)
}

func (info rejectionInfo) record() *store.RejectionRecord {
	return &store.RejectionRecord{
		Stage:                   info.stage,
		ReasonCode:              info.reasonCode,
		HTTPStatus:              info.httpStatus,
		KeyID:                   info.keyID,
		ConsumerKeyHash:         info.consumerKeyHash,
		RequestedModel:          info.requestedModel,
		ResolvedModel:           info.resolvedModel,
		Stream:                  info.stream,
		N:                       info.n,
		EstimatedPromptTokens:   info.estimatedPromptTokens,
		RequestedMaxTokens:      info.requestedMaxTokens,
		RequiresVision:          info.requiresVision,
		HasImage:                info.hasImage,
		HasAudio:                info.hasAudio,
		HasTools:                info.hasTools,
		ToolCount:               info.toolCount,
		ResponseFormat:          info.responseFormat,
		SelfRouteOnly:           info.selfRouteOnly,
		PreferOwner:             info.preferOwner,
		Params:                  info.params,
		RequestBodyBytes:        info.requestBodyBytes,
		RetryAfterMs:            info.retryAfterMs,
		ShortfallMicroUSD:       info.shortfallMicroUSD,
		LimitKind:               info.limitKind,
		OverBy:                  info.overBy,
		CandidateCount:          info.candidateCount,
		CapacityRejections:      info.capacityRejections,
		ModelTooLargeRejections: info.modelTooLargeRejections,
		VisionRejections:        info.visionRejections,
		BestTTFTMs:              info.bestTTFTMs,
	}
}
