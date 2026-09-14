package dispatch

import (
	"net/http"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/requestcontext"
	attemptpolicy "github.com/eigeninference/d-inference/coordinator/inference/attempt"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// routingOutcomeKey returns a stable requestID + attempt identifier used for
// telemetry updates. It prefers the explicit dispatch requestID, falling back
// to the pending request's ID when the dispatch requestID has not been set yet.
func (d *execution) routingOutcomeKey() string {
	if d.requestID != "" {
		return d.requestID
	}
	if d.pr != nil {
		return d.pr.RequestID
	}
	return ""
}

// recordRoutingDecision writes a best-effort snapshot of the scheduler decision
// for the current attempt. It never blocks inference.
func (d *execution) recordRoutingDecision(decision registry.RoutingDecision, dispatchErr, outcomeOverride string) {
	d.recordRoutingDecisionFor(d.provider, d.pr, d.routingOutcomeKey(), d.attempt, decision, dispatchErr, outcomeOverride)
}

func (d *execution) recordRoutingDecisionFor(provider *registry.Provider, pr *registry.PendingRequest, requestID string, attempt int, decision registry.RoutingDecision, dispatchErr, outcomeOverride string) {
	s := d.s
	if requestID == "" && pr != nil {
		requestID = pr.RequestID
	}

	providerID := ""
	if provider != nil {
		providerID = provider.ID
	} else if decision.ProviderID != "" {
		providerID = decision.ProviderID
	}

	outcome := outcomeOverride
	if outcome == "" {
		switch {
		case providerID != "":
			outcome = "selected"
		case dispatchErr == errModelTooLarge:
			outcome = "model_too_large"
		case dispatchErr == errTTFTTooSlow:
			outcome = "ttft_429"
		case dispatchErr == "no provider available":
			outcome = "no_provider"
		default:
			outcome = "error"
		}
	}

	keyID := ""
	if pr != nil {
		keyID = pr.KeyID
	}

	// Scans per attempt (rescans included). Plan-based retries reuse the
	// previous scan and report zero, which is not emitted.
	if decision.ScanCount > 0 {
		s.deps.Counters.Count("routing.scans", int64(decision.ScanCount), []string{"model:" + d.model, "outcome:" + outcome})
	}

	record := &store.InferenceRouteRecord{
		RequestID:               requestID,
		Attempt:                 attempt,
		ProviderID:              providerID,
		Model:                   d.model,
		PublicModel:             d.publicModel,
		ConsumerKeyHash:         store.HashKey(d.consumerKey),
		KeyID:                   keyID,
		Outcome:                 outcome,
		CostMs:                  decision.CostMs,
		StateMs:                 decision.StateMs,
		QueueMs:                 decision.QueueMs,
		PendingMs:               decision.PendingMs,
		BacklogMs:               decision.BacklogMs,
		ThisReqMs:               decision.ThisReqMs,
		HealthMs:                decision.HealthMs,
		TTFTMs:                  decision.TTFTMs,
		BestTTFTMs:              decision.BestTTFTMs,
		EffectiveQueue:          decision.EffectiveQueue,
		CandidateCount:          decision.CandidateCount,
		CapacityRejections:      decision.CapacityRejections,
		ModelTooLargeRejections: decision.ModelTooLargeRejections,
		VisionRejections:        decision.VisionRejections,
		TTFTRejections:          decision.TTFTRejections,
		EffectiveTPS:            decision.EffectiveTPS,
		StaticTPS:               decision.StaticTPS,
		EstimatedPromptTokens:   d.estimatedPromptTokens,
		RequestedMaxTokens:      d.requestedMaxTokens,
		RequiresVision:          d.requiresVision,
		HasTools:                d.hasTools,
		SelfRouteOnly:           d.policy.Enabled,
		PreferOwner:             d.policy.Prefer,
		CreatedAt:               time.Now(),
		UpdatedAt:               time.Now(),
	}

	if provider != nil {
		provider.Mu().Lock()
		record.ProviderStatus = string(provider.Status)
		record.ProviderTrustLevel = string(provider.TrustLevel)
		record.ProviderVersion = provider.Version
		record.HardwareChip = provider.Hardware.ChipName
		record.HardwareChipFamily = provider.Hardware.ChipFamily
		record.HardwareTier = provider.Hardware.ChipTier
		record.MemoryGB = provider.Hardware.MemoryGB
		record.GPUCores = provider.Hardware.GPUCores
		record.CPUCores = provider.Hardware.CPUCores.Total
		record.SystemMemoryPressure = provider.SystemMetrics.MemoryPressure
		record.SystemCPUUsage = provider.SystemMetrics.CPUUsage
		record.SystemThermalState = provider.SystemMetrics.ThermalState
		if cap := provider.BackendCapacity; cap != nil {
			record.GPUMemoryActiveGB = cap.GPUMemoryActiveGB
			record.GPUMemoryPeakGB = cap.GPUMemoryPeakGB
			record.GPUMemoryCacheGB = cap.GPUMemoryCacheGB
			for _, slot := range cap.Slots {
				if slot.Model == d.model {
					record.SlotState = slot.State
					record.BackendRunning = slot.NumRunning
					record.BackendWaiting = slot.NumWaiting
					record.ActiveTokenBudgetUsed = slot.ActiveTokenBudgetUsed
					record.ActiveTokenBudgetMax = slot.ActiveTokenBudgetMax
					record.QueuedTokenBudget = slot.QueuedTokenBudget
					break
				}
			}
		}
		provider.Mu().Unlock()
	}

	// Phase-0 shadow TTFT admission/spread metrics. No-op unless the request was
	// evaluated (admission mode != off AND a provider was selected). Emitted on
	// the synchronous path (cheap counter incr), not inside the async store write.
	s.emitTTFTShadowMetrics(d.model, decision)
	if decision.CacheDiscountMs > 0 {
		s.deps.Counters.Incr("routing.cache_evaluation", []string{
			"mode:active",
			"tier:" + LowCardinalityCacheTier(decision.CacheTier),
		})
	}

	// Off the request path: the batching sink coalesces this snapshot with its
	// neighbours into one multi-row write (route_telemetry_submit.go).
	s.deps.Observer.Route(record)
}

// errorRoutingOutcome builds an error / timeout / cancelled outcome.
func (d *execution) errorRoutingOutcome(status, class string, code int) *store.InferenceRouteOutcome {
	return d.errorRoutingOutcomeFor(d.pr, status, class, code)
}

func (d *execution) errorRoutingOutcomeFor(pr *registry.PendingRequest, status, class string, code int) *store.InferenceRouteOutcome {
	providerReason, errorText := "", ""
	if routeOutcomeUsesProviderErrorText(class) {
		providerReason = d.lastErrReason
		errorText = d.lastErr
	}
	out := attemptpolicy.RouteOutcomeWithReason(status, class, code, providerReason, errorText)
	attemptpolicy.ApplyPendingRouteTelemetry(out, pr)
	return out
}

func routeOutcomeUsesProviderErrorText(class string) bool {
	class = strings.ToLower(strings.TrimSpace(class))
	return class == attemptpolicy.ErrorReasonProviderError ||
		class == attemptpolicy.ErrorClassDeadlineUnreachable ||
		// client_error rows keep the provider-supplied reason too: a jinja_*
		// template-render failure is recorded as class client_error (not a
		// provider fault) but its reason must stay jinja_* on the row, so the
		// inference.error{reason:jinja_*} series measures real render failures
		// instead of being silenced by the reclassification. The reason is
		// still whitelisted downstream (normalizeInferenceErrorReason).
		class == attemptpolicy.ErrorClassClientError ||
		strings.HasPrefix(class, "provider_error") ||
		strings.HasPrefix(class, "provider_disconnect") ||
		strings.Contains(class, "provider_incomplete")
}

// providerFailedRoutingOutcome builds the outcome for a POST-DISPATCH provider
// failure: the request had already been admitted to a specific provider (passed
// the admission gate and was dispatched over the WebSocket) and that provider
// then reported an error — including provider-reported OOM / model-load failures
// that surface on pr.ErrorCh. It flags AdmittedButFailed to expose the
// admission-gate mismatch (coordinator said "this provider can serve" but it
// could not). It is intentionally only used from the post-dispatch wait loops;
// pre-dispatch failures (queue reservation DB error, invalid key, keygen, send
// failure) and coordinator-side timeouts are NOT flagged.
func (d *execution) providerFailedRoutingOutcome() *store.InferenceRouteOutcome {
	return d.providerFailedRoutingOutcomeFor(d.pr)
}

func (d *execution) providerFailedRoutingOutcomeFor(pr *registry.PendingRequest) *store.InferenceRouteOutcome {
	if attemptpolicy.IsDeadlineUnreachableErrorReason(d.lastErrReason) {
		// The provider declined work before execution because the coordinator's
		// remaining absolute budget could not be met. Preserve the typed reason
		// without marking the provider as admitted-but-failed.
		out := d.errorRoutingOutcomeFor(
			pr, "error", attemptpolicy.ErrorClassDeadlineUnreachable, d.lastErrCode)
		attemptpolicy.ApplyAttemptUsage(out, d.lastErrAttemptUsage)
		return out
	}
	if attemptpolicy.IsTerminalClientErrorCode(d.lastErrCode) || attemptpolicy.IsNonProviderFaultErrorReason(d.lastErrReason) {
		// Deterministic non-provider fault: a 4xx status the provider maps for
		// malformed bodies, OR a structured non-provider-fault reason (jinja_*
		// template-render failures, tool_noncompliance model-output 422s).
		// Record as client_error WITHOUT AdmittedButFailed so neither pollutes
		// the admission-mismatch gauge — keyed on the SAME vocabulary as the
		// reputation and breaker exemptions (isNonProviderFaultErrorReason).
		// The structured reason survives on the row (see
		// routeOutcomeUsesProviderErrorText). Typed partial usage (if any)
		// still lands on the row — observability only, no billing effect.
		out := d.errorRoutingOutcomeFor(pr, "error", attemptpolicy.ErrorClassClientError, d.lastErrCode)
		attemptpolicy.ApplyAttemptUsage(out, d.lastErrAttemptUsage)
		return out
	}
	class := "provider_error"
	if d.lastErrCoordinatorCause.IsProviderDisconnect() {
		class = "provider_disconnect_pre_commit"
	}
	out := d.errorRoutingOutcomeFor(pr, "error", class, d.lastErrCode)
	out.AdmittedButFailed = true
	// Pre-content typed failures on the ordinary dispatch path flow through
	// the deferred route update via this builder (not the standalone
	// preResponse/postCommit constructors), so the typed attempt_usage
	// retained by setLastInferenceError must be applied here too or the row
	// records null token counts for the most common failure path.
	attemptpolicy.ApplyAttemptUsage(out, d.lastErrAttemptUsage)
	return out
}

func dispatchErrorClass(errText string) string {
	if strings.Contains(errText, ErrProviderBodyTooLarge.Error()) {
		return attemptpolicy.ErrorClassClientError
	}
	switch errText {
	case "insufficient funds for provider price":
		return "insufficient_funds"
	case "no provider with E2E encryption":
		return "encryption_missing"
	case "provider public key invalid", "failed to encrypt request", "failed to generate session keys", "failed to marshal request":
		return "encryption_error"
	case errFirstContentDeadlineExpired:
		return "first_chunk_timeout"
	case "failed to send request to provider":
		return "provider_error"
	default:
		if errText == "" {
			return "provider_error"
		}
		return "provider_error"
	}
}

// queuedExitOutcome records the terminal route outcome of a queue-wait exit
// and mirrors its status/reason onto the placeholder attempt profile. While
// the request waits, d.pr is nil, so updateRoutingOutcome takes the request-id
// path and never reaches the attempt profile; the pair is written here, in one
// place, so the row and the profile cannot drift. It is deliberately NOT
// routed through updateInferenceRouteOutcomeForPending, which would also fire
// the cache-selection terminal for a request that never had a provider.
func (d *execution) queuedExitOutcome(ap *registry.AttemptProfile, status, reason string, code int) {
	outcome := d.errorRoutingOutcome(status, reason, code)
	// No provider attempt was dispatched: the funnel counts this exit on
	// inference.queue_outcome, never on inference.attempt_outcome.
	outcome.QueueExit = true
	d.updateRoutingOutcome(outcome)
	ap.SetOutcome(status, reason, "", "", "")
}

// closeQueuedAttempt closes the queue-path placeholder attempt when it never
// reached the wire (closeUndispatchedAttempt is a no-op for a dispatched or
// winning attempt), recording the error the failing branch left on d.
//
// AttemptProfile.SetOutcome is first-write-wins, and every queue-path exit
// has already written its final_status/error_reason on the placeholder by the
// time this runs: the pre-assignment exits (queue full, client gone, deadline,
// ttft_too_slow, tool constraint, queue timeout) write it explicitly
// (queuedExitOutcome / the queue-full SetOutcome), and the post-assignment
// exits (top-up, key, encrypt, writer timeout, write error) write it through
// the pending route-outcome funnel because d.pr is set by then. This close
// therefore contributes provider_outcome=not_dispatched, and its own
// status/class only as a fallback for an exit that recorded nothing. A status
// code of 0 means the branch had no HTTP status: the code is defaulted by how
// the wait ended, but the text only when nothing was recorded, so a real error
// text with no code (e.g. "no provider with E2E encryption") keeps its own
// class instead of collapsing to queue_rejected.
func (d *execution) closeQueuedAttempt(ap *registry.AttemptProfile) {
	errText, code := d.lastErr, d.lastErrCode
	if code == 0 {
		clientGone := d.r != nil && d.r.Context().Err() != nil
		if clientGone {
			code = 499
		} else {
			code = http.StatusTooManyRequests
		}
		if errText == "" {
			if clientGone {
				errText = "client_gone"
			} else {
				errText = "queue_rejected"
			}
		}
	}
	closeUndispatchedAttempt(ap, errText, code)
}

func (d *execution) rejection(stage, reason string, status, retryAfterMs int) Rejection {
	info := Rejection{
		Request:               d.r,
		Stage:                 stage,
		ReasonCode:            reason,
		HttpStatus:            status,
		KeyID:                 requestcontext.KeyID(d.r.Context()),
		ConsumerKeyHash:       store.HashKey(d.consumerKey),
		RequestedModel:        d.publicModel,
		ResolvedModel:         d.model,
		Stream:                d.stream,
		EstimatedPromptTokens: d.estimatedPromptTokens,
		RequestedMaxTokens:    d.requestedMaxTokens,
		RequiresVision:        d.requiresVision,
		HasTools:              d.hasTools,
		SelfRouteOnly:         d.policy.Enabled,
		PreferOwner:           d.policy.Prefer,
		RetryAfterMs:          retryAfterMs,
	}
	if reason == "payload_too_large" {
		info.ServabilityComputed = true
		if d.providerBodyTooLargeBytes > 0 {
			info.RequestBodyBytes = d.providerBodyTooLargeBytes
		}
	}
	return info
}

func (d *execution) rejectionInfoWithDecision(stage, reason string, status, retryAfterMs int, decision registry.RoutingDecision) Rejection {
	info := d.rejection(stage, reason, status, retryAfterMs)
	info.ServabilityComputed = true
	info.CandidateCount = decision.CandidateCount
	info.CapacityRejections = decision.CapacityRejections
	info.ModelTooLargeRejections = decision.ModelTooLargeRejections
	info.VisionRejections = decision.VisionRejections
	info.BestTTFTMs = decision.BestTTFTMs
	return info
}

// dispatchRoutingAttempt is immutable identity captured before a wait path can
// clear or promote mutable execution provider/request fields.
type dispatchRoutingAttempt struct {
	provider  *registry.Provider
	pending   *registry.PendingRequest
	requestID string
	attempt   int
}

func routingAttempt(provider *registry.Provider, pr *registry.PendingRequest, requestID string, attempt int) dispatchRoutingAttempt {
	return dispatchRoutingAttempt{provider: provider, pending: pr, requestID: requestID, attempt: attempt}
}

func (d *execution) currentOrCapturedRoutingAttempt(captured dispatchRoutingAttempt) dispatchRoutingAttempt {
	if d.pr == nil {
		// A cleared request ID is an intentional no-op sentinel: speculative
		// sub-waits clear all three fields after recording each racer's terminal
		// outcome themselves. Restoring captured here would attribute the
		// surviving racer's later failure or timeout to the already-finalized
		// primary. Ordinary single-attempt fallbacks retain requestID and still
		// use captured below.
		if d.requestID == "" {
			return dispatchRoutingAttempt{}
		}
		return captured
	}
	return routingAttempt(d.provider, d.pr, d.routingOutcomeKey(), d.attempt)
}

func (d *execution) updateRoutingOutcomeForAttempt(target dispatchRoutingAttempt, outcome *store.InferenceRouteOutcome) {
	requestID, attempt := target.requestID, target.attempt
	if requestID == "" {
		return
	}
	providerMatches := target.provider == nil ||
		(target.pending != nil && target.pending.ProviderID != "" && target.pending.ProviderID == target.provider.ID)
	if target.pending != nil && target.pending.RequestID == requestID && target.pending.Attempt == attempt && providerMatches {
		d.s.deps.Observer.PendingOutcome(target.pending, outcome)
		return
	}
	d.s.deps.Observer.RouteOutcome(requestID, attempt, d.model, outcome)
}

// updateRoutingOutcome writes an outcome update for the current attempt. It is
// a no-op when there is no request ID to correlate.
func (d *execution) updateRoutingOutcome(outcome *store.InferenceRouteOutcome) {
	requestID := d.routingOutcomeKey()
	if requestID == "" {
		return
	}
	// Capture attempt on the dispatch goroutine: the closure runs on a telemetry
	// sink worker, while run()'s retry loop concurrently advances d.attempt.
	attempt := d.attempt
	d.updateRoutingOutcomeForAttempt(routingAttempt(d.provider, d.pr, requestID, attempt), outcome)
}

func (d *execution) markSpeculativeLoser(pr *registry.PendingRequest) {
	if pr == nil {
		return
	}
	pr.UsedBackup.Store(true)
	d.s.deps.Observer.PendingOutcome(pr, attemptpolicy.SpeculativeLoserOutcome(pr))
}

func (d *execution) updateSpeculativeFailure(pr *registry.PendingRequest, msg protocol.InferenceErrorMessage) {
	if pr == nil {
		return
	}
	pr.UsedBackup.Store(true)
	d.s.deps.Observer.PendingOutcome(pr, attemptpolicy.PreCommitProviderErrorOutcome(pr, msg))
}

func (d *execution) updateSpeculativeTimeout(pr *registry.PendingRequest, class string) {
	if pr == nil {
		return
	}
	pr.UsedBackup.Store(true)
	d.s.deps.Observer.PendingOutcome(pr, attemptpolicy.PendingRouteOutcome(pr, "timeout", class, http.StatusGatewayTimeout))
}

func (d *execution) updateSpeculativeClientGone(pr *registry.PendingRequest) {
	if pr == nil {
		return
	}
	pr.UsedBackup.Store(true)
	d.s.deps.Observer.PendingOutcome(pr, attemptpolicy.PendingRouteOutcome(pr, "cancelled", "client_gone", 0))
}

// emitClientGone records a before-first-token cancellation on the
// d_inference.routing.client_gone counter for this attempt. It reads
// the current candidate's chip family (or "unknown" when no provider is selected
// yet, e.g. a queue-wait cancel) and the estimated prompt-token bucket. Called
// once per logical client_gone at the central classification sites so speculative
// backup bookkeeping (updateSpeculativeClientGone) never double-counts.
func (d *execution) emitClientGone(phase string) {
	d.stampClientGone(phase)
	// deadline_bucket: elapsed on the request clock vs the first-content
	// budget. At/past ~the budget the upstream timed out on us (its 504), so
	// the OR-view outcome is `timeout`; earlier it is an excluded client abort.
	bucket := d.clientGoneDeadlineBucket()
	d.s.deps.Observer.ClientGone(d.model, d.estimatedPromptTokens, ProviderChipFamily(d.provider), phase, bucket)
	d.recordRequestOutcomeORView(orViewClassForClientGone(bucket))
}
