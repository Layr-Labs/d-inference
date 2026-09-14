package dispatch

import (
	"encoding/json"
	"net/http"
)

// Rejection carries everything known about a rejected inbound inference
// request at a 4xx/5xx exit point. Callers populate what they have; zero values
// are fine. It is the single contract the consumer/handler code uses to feed the
// rejection ledger (see docs/design/routing-telemetry-and-calibration.md §4.9).
type Rejection struct {
	Request    *http.Request
	Stage      string // auth, validation, model_resolution, balance, rate_limit, preflight_capacity, routing_ttft
	ReasonCode string // e.g. model_not_found, machine_busy, insufficient_funds
	HttpStatus int

	KeyID           string
	ConsumerKeyHash string

	RequestedModel string // raw, as the client sent it
	ResolvedModel  string // after alias resolution, when known

	Stream                bool
	N                     int
	EstimatedPromptTokens int
	RequestedMaxTokens    int
	RequiresVision        bool
	HasImage              bool
	HasAudio              bool
	HasTools              bool
	ToolCount             int
	ResponseFormat        string
	SelfRouteOnly         bool
	PreferOwner           bool
	Params                json.RawMessage // non-content knobs (temperature, top_p, …)
	RequestBodyBytes      int
	RetryAfterMs          int

	// 402 / 429 extras.
	ShortfallMicroUSD int64
	LimitKind         string
	OverBy            int64

	// Counterfactual. When servabilityComputed is true the caller already ran the
	// capacity check (e.g. the pre-flight) and the candidate*/bestTTFTMs fields
	// below are authoritative — recordRejection will NOT recompute. Otherwise, when
	// a resolvedModel is set, recordRejection computes servability itself.
	ServabilityComputed     bool
	SkipServability         bool // shedding under saturation must not start another fleet scan
	CandidateCount          int
	CapacityRejections      int
	ModelTooLargeRejections int
	VisionRejections        int
	BestTTFTMs              float64
}
