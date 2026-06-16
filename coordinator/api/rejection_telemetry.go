package api

import (
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// rejectionInfo carries everything known about a rejected inbound inference
// request at a 4xx/5xx exit point. Callers populate what they have; zero values
// are fine. It is the single contract the consumer/handler code uses to feed the
// rejection ledger (see docs/architecture/routing-telemetry-and-calibration.md §4.9).
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
func (s *Server) recordRejection(info rejectionInfo) {
	if s == nil || s.store == nil {
		return
	}

	rec := &store.RejectionRecord{
		Stage:                 info.stage,
		ReasonCode:            info.reasonCode,
		HTTPStatus:            info.httpStatus,
		KeyID:                 info.keyID,
		ConsumerKeyHash:       info.consumerKeyHash,
		RequestedModel:        info.requestedModel,
		ResolvedModel:         info.resolvedModel,
		Stream:                info.stream,
		N:                     info.n,
		EstimatedPromptTokens: info.estimatedPromptTokens,
		RequestedMaxTokens:    info.requestedMaxTokens,
		RequiresVision:        info.requiresVision,
		HasImage:              info.hasImage,
		HasAudio:              info.hasAudio,
		HasTools:              info.hasTools,
		ToolCount:             info.toolCount,
		ResponseFormat:        info.responseFormat,
		SelfRouteOnly:         info.selfRouteOnly,
		PreferOwner:           info.preferOwner,
		Params:                info.params,
		RequestBodyBytes:      info.requestBodyBytes,
		RetryAfterMs:          info.retryAfterMs,
		ShortfallMicroUSD:     info.shortfallMicroUSD,
		LimitKind:             info.limitKind,
		OverBy:                info.overBy,
		CreatedAt:             time.Now(),
	}
	if info.r != nil {
		rec.Endpoint = info.r.URL.Path
		rec.ClientClass = clientClassFromUserAgent(info.r.UserAgent())
		if rec.RequestBodyBytes == 0 && info.r.ContentLength > 0 {
			rec.RequestBodyBytes = int(info.r.ContentLength)
		}
	}

	// Seed the counterfactual from whatever the caller already computed.
	rec.CandidateCount = info.candidateCount
	rec.CapacityRejections = info.capacityRejections
	rec.ModelTooLargeRejections = info.modelTooLargeRejections
	rec.VisionRejections = info.visionRejections
	rec.BestTTFTMs = info.bestTTFTMs

	// Decide whether we still need to compute servability inside the goroutine.
	computeServability := !info.servabilityComputed && info.resolvedModel != "" && s.registry != nil
	reg := s.registry
	resolvedModel := info.resolvedModel
	estPrompt := info.estimatedPromptTokens
	reqMax := info.requestedMaxTokens
	requiresVision := info.requiresVision
	hasTools := info.hasTools

	s.submitTelemetry("recordRejection", func() {
		if computeServability {
			traits := registry.RequestTraits{HasTools: hasTools}
			cc, capRej, tooLarge, bestTTFT, hasTTFT := reg.QuickCapacityCheckWithTTFTForRequest(
				resolvedModel, estPrompt, reqMax, traits, requiresVision,
			)
			rec.CandidateCount = cc
			rec.CapacityRejections = capRej
			rec.ModelTooLargeRejections = tooLarge
			if hasTTFT {
				rec.BestTTFTMs = float64(bestTTFT.Milliseconds())
			}
		}
		// A request could have produced output iff at least one provider could
		// serve it right now. This is the headline "was the 'no' necessary?" flag.
		rec.CouldHaveServed = rec.CandidateCount > 0
		_ = s.store.RecordRejection(rec)
	})
}

// clientClassFromUserAgent buckets the caller into a coarse, non-private class so
// we can compare rejection patterns across integrations (e.g. OpenRouter vs
// direct API users) without storing the raw user agent.
func clientClassFromUserAgent(ua string) string {
	if ua == "" {
		return "unknown"
	}
	// Bound work on this untrusted header: only the prefix is needed to classify
	// the client, so cap the length before lowercasing to avoid spending effort
	// on a maliciously long User-Agent.
	if len(ua) > 256 {
		ua = ua[:256]
	}
	lc := strings.ToLower(ua)
	switch {
	case strings.Contains(lc, "openrouter"):
		return "openrouter"
	case strings.Contains(lc, "darkbloom"):
		return "darkbloom"
	case strings.Contains(lc, "python"), strings.Contains(lc, "openai"):
		return "openai-sdk"
	case strings.Contains(lc, "node"), strings.Contains(lc, "axios"), strings.Contains(lc, "fetch"):
		return "js-sdk"
	case strings.Contains(lc, "curl"):
		return "curl"
	default:
		return "direct"
	}
}
