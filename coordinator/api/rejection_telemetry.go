package api

import (
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/inference/dispatch"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// recordRejection persists a rejected-request record asynchronously, computing
// the counterfactual servability ("could the fleet have served it?") off the
// request path when the caller did not already do so. Best-effort: it never
// blocks or fails the request.
func (s *Server) recordRejection(info rejectionInfo) {
	annotateOutcomeRejection(info)
	if s == nil || s.store == nil {
		return
	}

	rec := &store.RejectionRecord{
		Stage:                 info.Stage,
		ReasonCode:            info.ReasonCode,
		HTTPStatus:            info.HttpStatus,
		KeyID:                 info.KeyID,
		ConsumerKeyHash:       info.ConsumerKeyHash,
		RequestedModel:        info.RequestedModel,
		ResolvedModel:         info.ResolvedModel,
		Stream:                info.Stream,
		N:                     info.N,
		EstimatedPromptTokens: info.EstimatedPromptTokens,
		RequestedMaxTokens:    info.RequestedMaxTokens,
		RequiresVision:        info.RequiresVision,
		HasImage:              info.HasImage,
		HasAudio:              info.HasAudio,
		HasTools:              info.HasTools,
		ToolCount:             info.ToolCount,
		ResponseFormat:        info.ResponseFormat,
		SelfRouteOnly:         info.SelfRouteOnly,
		PreferOwner:           info.PreferOwner,
		Params:                info.Params,
		RequestBodyBytes:      info.RequestBodyBytes,
		RetryAfterMs:          info.RetryAfterMs,
		ShortfallMicroUSD:     info.ShortfallMicroUSD,
		LimitKind:             info.LimitKind,
		OverBy:                info.OverBy,
		CreatedAt:             time.Now(),
	}
	if info.Request != nil {
		rec.RequestID = coordRequestIDFromContext(info.Request.Context())
		rec.Endpoint = info.Request.URL.Path
		rec.ClientClass = clientClassFromUserAgent(info.Request.UserAgent())
		if rec.RequestBodyBytes == 0 && info.Request.ContentLength > 0 {
			rec.RequestBodyBytes = int(info.Request.ContentLength)
		}
	}

	// OR-uptime outcome for PRE-dispatch rejections. The dispatch-stage
	// exhausted rejection is skipped here because dispatch.go run()'s tail already
	// counts that request exactly once; every other (pre-dispatch) stage has no
	// route-outcome terminal, so it contributes its single outcome here.
	//
	// No KV backend: a pre-dispatch rejection never reached a slot, so there is
	// nothing to attribute it to. The zero attribution normalizes to
	// kv_backend:unknown / kv_backend_fallback:unknown — booking it to a real
	// backend, or to "did not degrade", would invent a data point.
	if info.Stage != "dispatch" {
		model := info.ResolvedModel
		if model == "" {
			model = info.RequestedModel
		}
		s.recordRequestOutcome(model, dispatch.NewUnknownKVBackendAttribution(), orUptimeClassForRejection(info.HttpStatus))
		// OR-view mirror of the pre-dispatch arm (the dispatch-stage exhausted
		// rejection is counted by run()'s tail). Resolved model only: the raw
		// requested name is client-controlled and must not mint tag values.
		s.recordRequestOutcomeORView(info.ResolvedModel, orUptimeClassForRejection(info.HttpStatus))
	}

	// Seed the counterfactual from whatever the caller already computed.
	rec.CandidateCount = info.CandidateCount
	rec.CapacityRejections = info.CapacityRejections
	rec.ModelTooLargeRejections = info.ModelTooLargeRejections
	rec.VisionRejections = info.VisionRejections
	rec.BestTTFTMs = info.BestTTFTMs

	// Decide whether we still need to compute servability inside the goroutine.
	computeServability := !info.SkipServability && !info.ServabilityComputed && info.ResolvedModel != "" && s.registry != nil
	reg := s.registry
	resolvedModel := info.ResolvedModel
	estPrompt := info.EstimatedPromptTokens
	reqMax := info.RequestedMaxTokens
	requiresVision := info.RequiresVision
	hasTools := info.HasTools

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
		if info.ServabilityComputed || computeServability {
			couldHaveServed := rec.CandidateCount > 0
			rec.CouldHaveServed = &couldHaveServed
		}
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
