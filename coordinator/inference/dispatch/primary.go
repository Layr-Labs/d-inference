package dispatch

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/requestcontext"
	attemptpolicy "github.com/eigeninference/d-inference/coordinator/inference/attempt"
	"github.com/eigeninference/d-inference/coordinator/inference/settlement"
	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

// dispatchPrimary selects (and, when no idle provider exists on the first
// attempt, queues + dispatches) the primary provider for this attempt. It is the
// extraction of the original loop's dispatch-primary block (incl. the queue path).
// On success it leaves d.provider/d.pr set and returns outcomeProceed.
func (d *execution) dispatchPrimary() dispatchOutcome {
	s := d.s
	r, w := d.r, d.w
	attempt := d.attempt

	// Dispatch the primary provider.
	var dispatchErr string
	var dispatchErrCode int
	var decision registry.RoutingDecision
	routeRecorded := false
	routeRequestID := ""
	routeAttempt := attempt
	var routeProvider *registry.Provider
	recordRoute := func(provider *registry.Provider, pr *registry.PendingRequest, decision registry.RoutingDecision) {
		routeProvider = provider
		routeRecorded = true
		if pr != nil {
			d.configurePending(pr)
			routeRequestID = pr.RequestID
			routeAttempt = pr.Attempt
		}
		d.recordRoutingDecisionFor(provider, pr, routeRequestID, routeAttempt, decision, "", "")
	}
	// Routing v2 W2: retry attempts consume the retained plan — the next
	// revalidated entry, then the request's single refresh — BEFORE any full
	// rescan (identity retention; the rescan herd is the failure the plan
	// exists to end). The machinery only changes WHERE the next provider
	// comes from: when it yields nothing, the legacy scan below runs
	// unchanged, keeping every terminal classification (model_too_large,
	// ttft_too_slow, queueing) byte-identical.
	planTried := false
	if attempt > 0 {
		d.provider, d.pr, decision, dispatchErr, dispatchErrCode, planTried =
			d.dispatchFromPlanMachinery(d.timing, d.excludeProviders, "", recordRoute)
	}
	if !planTried {
		var plan *registry.DispatchPlan
		d.provider, d.pr, decision, plan, dispatchErr, dispatchErrCode = s.dispatchOneProvider(
			r, d.model, d.publicModel, d.rawBody, d.consumerKey, d.consumerLocation, d.reservedMicroUSD,
			d.estimatedPromptTokens, d.deadline, d.requestedMaxTokens, d.tokenAdmission, d.requiresVision,
			d.traits(),
			d.allowedProviderSerials, d.isResponsesAPI, d.policy, d.timing, d.serviceReservation, d.cachePlan, d.excludeProviders,
			d.attempt, d.profile, "",
			recordRoute,
			d.noteProviderDispatched,
		)
		if d.plan == nil {
			// Adopt the FIRST retained plan only. Once the plan chain
			// (entries + one refresh) is spent, later fallback scans stay
			// pure legacy — adopting their plans would resurrect the
			// machinery past its bounded refresh.
			d.plan = plan
		}
	}
	d.dispatchErr = dispatchErr
	d.dispatchErrCode = dispatchErrCode
	if !routeRecorded {
		d.recordRoutingDecision(decision, dispatchErr, "")
	}
	if d.provider == nil {
		if dispatchErrCode == http.StatusRequestEntityTooLarge {
			d.noteProviderBodyTooLargeFor(routeProvider, dispatchErr)
		}
		if routeRecorded {
			d.s.deps.Observer.RouteOutcome(routeRequestID, routeAttempt, d.model, d.errorRoutingOutcome("error", dispatchErrorClass(dispatchErr), dispatchErrCode))
		}
		// No online provider has enough memory to ever fit this model.
		// Retrying and queueing are both pointless — reject immediately
		// with a clear, non-retryable error.
		if dispatchErr == errModelTooLarge {
			s.deps.Counters.Incr("routing.decisions", []string{"model:" + d.model, "model_type:" + s.deps.Registry().ModelType(d.model), "outcome:model_too_large"})
			d.setLastError(dispatchErr, dispatchErrCode)
			return outcomeFailFast
		}
		if dispatchErrCode == http.StatusRequestEntityTooLarge {
			return outcomeRetry
		}
		if dispatchErr == errFirstContentDeadlineExpired {
			// The request clock expired before the selected frame reached the
			// wire. This is coordinator-owned deadline exhaustion, not a
			// provider send fault, and another attempt cannot regain time.
			d.setLastError("timeout waiting for first response", http.StatusGatewayTimeout)
			return outcomeFailFast
		}
		if dispatchErr == errClientGoneBeforeScan {
			// The caller's context fired while parked for a scan slot. Mirror
			// the queue-wait cancellation arm exactly: cancelled route
			// outcome, refund, no response body — NEVER the routing_saturated
			// 429 or a rejection-ledger row (the client is not retrying; the
			// ledger must not count a shed that never happened).
			d.emitClientGone(phaseBeforeFirstToken)
			d.updateRoutingOutcome(d.errorRoutingOutcome("cancelled", "client_gone", 0))
			d.refundReservation()
			return outcomeClientGone
		}
		if dispatchErr == errRoutingScanSaturated {
			// No provider-selection scan slot freed up within the request's
			// whole remaining first-content budget — the coordinator itself is
			// saturated (2026-09-01 collapse). Zero providers were scanned or
			// contacted, so latch the capacity-shaped verdict: the exhausted
			// ladder emits ONE uptime-neutral retryable 429 (whose Retry-After
			// scales with the route-latency distress EWMA) and never scans
			// again for this request.
			s.deps.Counters.Incr("routing.scan_admission_timeout", []string{"model:" + d.model})
			d.setLastError(dispatchErr, http.StatusTooManyRequests)
			d.unservable = true
			d.unservableReason = RejectionReasonRoutingSaturated
			return outcomeFailFast
		}
		if d.lastFailureDeadline && dispatchErr == errTTFTTooSlow {
			// At least one provider already refused this exact remaining
			// deadline, and the rest cannot pass hard TTFT admission. Candidate
			// exhaustion belongs to the deadline_unreachable terminal below,
			// not a fresh ttft_too_slow response that hides the refusal.
			return outcomeFailFast
		}

		// Providers are available but all exceed the TTFT ceiling. This
		// rejection is deterministic — the scheduler computes it from the same
		// fleet-wide estimate on every scan — so retrying the reservation
		// within this request cannot succeed. Fail fast with a retryable 429
		// on ANY attempt (kill switch: EIGENINFERENCE_TTFT_TERMINAL_REJECT=
		// false restores the legacy attempt-0-only fast path, under which a
		// mid-ladder rejection looped to maxDispatchAttempts re-running the
		// doomed scan). Deferred HTTP commitment guarantees this rejection can
		// still carry its correct status.
		if dispatchErr == errTTFTTooSlow && (attempt == 0 || ttftTerminalRejectEnabled()) {
			bestTTFT := time.Duration(decision.BestTTFTMs * float64(time.Millisecond))
			d.refundReservation()
			if attempt > 0 {
				// The legacy loop's exhausted ladder wrote ONE request_rejections
				// row and ONE OR-uptime outcome for a mid-ladder TTFT storm; keep
				// the rejection row and legacy dispatched-request metric.
				retryAfter := s.estimateTTFTRetryAfter(d.model, bestTTFT, d.deadline)
				s.deps.Observer.Rejection(d.rejectionInfoWithDecision("dispatch", "ttft_too_slow", http.StatusTooManyRequests, retryAfter*1000, decision))
				d.recordDispatchedRequestOutcome(
					d.KVBackendAttribution(), ClassifyOutcomeByCode(http.StatusTooManyRequests))
			}
			d.recordRequestOutcomeORView(ClassifyOutcomeByCode(http.StatusTooManyRequests))
			s.WriteTTFTTooSlow(w, d.model, d.publicModel, bestTTFT, d.deadline)
			return outcomeResponseWritten
		}

		// dispatchOneProvider may have found a provider but rejected it
		// (payout destination missing, insufficient funds, encryption
		// missing). In that case it already added the provider to
		// excludeProviders. If there may be more providers to try,
		// continue to the next attempt.
		providerWasRejected := dispatchErr != "no provider available"
		if providerWasRejected {
			d.setLastError(dispatchErr, dispatchErrCode)
			return outcomeRetry
		}

		// On retry attempts, don't queue — if the only available
		// providers already failed, waiting 120s for one of them
		// to come back won't help. Break and return the last error.
		// Don't overwrite lastErr/lastErrCode from the real provider
		// error — preserve the original status code.
		if d.providerBodyTooLargeErr != "" &&
			d.lastErrCode == http.StatusRequestEntityTooLarge &&
			decision.CapacityRejections == 0 {
			d.latchProviderBodyTooLarge(d.providerBodyTooLargeErr)
			return outcomeFailFast
		}
		if attempt > 0 && !d.shouldQueueCompatibleProvider(decision) {
			if d.lastErr == "" {
				d.setLastError(dispatchErr, dispatchErrCode)
			}
			return outcomeFailFast
		}
		// No idle provider — try queueing.
		d.requestID = uuid.New().String()
		queuePR := &registry.PendingRequest{
			RequestID:              d.requestID,
			Attempt:                d.attempt,
			Model:                  d.model,
			PublicModel:            d.publicModel,
			ConsumerKey:            d.consumerKey,
			KeyID:                  requestcontext.KeyID(r.Context()),
			KeyLimitMicroUSD:       requestcontext.KeyLimitMicroUSD(r.Context()),
			KeyLimitReset:          requestcontext.KeyLimitReset(r.Context()),
			ConsumerLocation:       d.consumerLocation,
			IsResponsesAPI:         d.isResponsesAPI,
			EstimatedPromptTokens:  d.estimatedPromptTokens,
			RequiresVision:         d.requiresVision,
			Traits:                 d.traits(),
			RequestedMaxTokens:     d.requestedMaxTokens,
			TokenAdmission:         d.tokenAdmission,
			ReservedMicroUSD:       d.reservedMicroUSD,
			BaseReservedMicroUSD:   d.reservedMicroUSD,
			ServiceReservation:     d.serviceReservation,
			AllowedProviderSerials: d.allowedProviderSerials,
			ExcludedProviderIDs:    d.excludedProviderIDs(),
			CachePlan:              d.cachePlan,
			SelfRouteOnly:          d.policy.Enabled,
			PreferOwner:            d.policy.Prefer,
			OwnerAccountID:         d.policy.OwnerAccountID,
			FreeSelfRoute:          d.policy.Enabled,
			MetadataDetails:        d.metadataDetails,
			MaxTTFTMs: queueMaxTTFTMs(
				d.policy, d.deadline, d.s.HardTTFTGateApplies(d.requiresVision)),
			MinDecodeTPS: d.s.deps.MinDecodeTPS(),
			AcceptedCh:   make(chan struct{}, 1),
			ChunkCh:      make(chan registry.ProviderChunk, chunkBufferSize),
			CompleteCh:   make(chan protocol.UsageInfo, 1),
			ErrorCh:      make(chan protocol.InferenceErrorMessage, 1),
			Timing:       d.timing,
		}
		d.configurePending(queuePR)
		if receivedAt := TimingReceivedAt(d.timing); !receivedAt.IsZero() {
			queuePR.FirstContentDeadline = receivedAt.Add(d.deadline)
		}
		if !queuePR.RefreshFirstContentBudget(time.Now()) {
			d.setLastError("timeout waiting for first response", http.StatusGatewayTimeout)
			return outcomeFailFast
		}
		queuedReq := &registry.QueuedRequest{
			RequestID:  d.requestID,
			Model:      d.model,
			Pending:    queuePR,
			ResponseCh: make(chan *registry.Provider, 1),
		}
		queuePR.Timing.QueuedAt = time.Now()
		queuePR.Profile = d.profile.NewAttempt(d.requestID, d.attempt, "")
		d.s.recordPredictivePolicy(queuePR.Profile, d.policy, d.requiresVision)
		queuePR.Profile.Mark(registry.StampAttemptStart)
		queuePR.Profile.Mark(registry.StampQueued)
		// Every exit of the queue path that never reached the wire (queue full,
		// wait cancelled/expired, TTFT/tool refusals, and a pre-wire failure
		// after the queue handed over a provider: top-up, key, encrypt, writer
		// timeout, write error) closes the placeholder attempt here so it never
		// waits on a provider terminal that cannot come. Keyed on the attempt's
		// own write-done stamp inside closeUndispatchedAttempt, never on d.pr:
		// d.pr is assigned before the write, so a failure between assignment
		// and the wire is still undispatched.
		defer d.closeQueuedAttempt(queuePR.Profile)
		if err := s.deps.Registry().Queue().Enqueue(queuedReq); err != nil {
			s.deps.Counters.Incr("routing.decisions", []string{"model:" + d.model, "model_type:" + s.deps.Registry().ModelType(d.model), "outcome:over_capacity"})
			// No route row exists for a request the queue refused (the routing
			// decision is recorded only after a successful enqueue); the
			// placeholder carries the rejection vocabulary directly.
			queuePR.Profile.SetOutcome("rejected", "queue_full", "", "", "")
			retryAfter := s.EstimateRetryAfter(d.model)
			d.refundReservation()
			info := d.rejectionInfoWithDecision("queue", "queue_full", http.StatusTooManyRequests, retryAfter*1000, decision)
			if d.policy.Enabled {
				d.preContentTerminal(info, retryAfter, "machine_busy",
					"your machine is at capacity — retry shortly", "machine_busy")
			} else {
				d.preContentTerminal(info, retryAfter, "rate_limit_exceeded",
					fmt.Sprintf("all providers for model %q are at capacity and queue is full", d.publicModel),
					"rate_limit_exceeded")
			}
			return outcomeResponseWritten
		}
		s.recordWarmPoolQueueState(d.model)
		// Routing v2 W3: the model now has queued demand — proactively warm a cold
		// provider for it (TriggerModelSwaps) instead of waiting for the next
		// heartbeat, so the queued request drains onto it sooner.
		s.kickColdDispatch(d.model)
		s.deps.Counters.Incr("routing.decisions", []string{"model:" + d.model, "model_type:" + s.deps.Registry().ModelType(d.model), "outcome:queued"})
		d.recordRoutingDecision(decision, "", "queued")

		s.deps.Logger().Info("request queued, waiting for provider",
			"model", d.model,
			"attempt", attempt+1,
		)

		var err error
		queueCtx, cancelQueue := firstTokenWriteContext(
			r.Context(), TimingReceivedAt(d.timing), d.deadline)
		d.provider, err = s.deps.Registry().Queue().WaitForProviderContext(queueCtx, queuedReq)
		cancelQueue()
		if err != nil {
			if errors.Is(err, context.Canceled) {
				s.recordWarmPoolQueueState(d.model)
				d.emitClientGone(phaseBeforeFirstToken)
				d.queuedExitOutcome(queuePR.Profile, "cancelled", "client_gone", 0)
				d.refundReservation()
				return outcomeClientGone
			}
			if errors.Is(err, context.DeadlineExceeded) ||
				errors.Is(err, registry.ErrQueueFirstContentDeadline) {
				// The first-content clock ran out while the request was still
				// queued: nothing was dispatched, so this is the queue's own
				// terminal (queue_deadline), not a provider that went silent
				// (first_chunk_timeout). Same synthetic 504 → retryable 429
				// path; the distinct latched text is what
				// resolveDominantExhaustedStatus keys the reason on. The route
				// row and the attempt profile carry queue_deadline as well.
				s.recordWarmPoolQueueState(d.model)
				d.queuedExitOutcome(queuePR.Profile,
					"timeout", RejectionReasonQueueDeadline, http.StatusGatewayTimeout)
				d.setLastError(errQueueDeadlineExpired, http.StatusGatewayTimeout)
				return outcomeFailFast
			}
			if errors.Is(err, registry.ErrQueueTTFTTooSlow) {
				// The drain proved every eligible provider fails ONLY the TTFT
				// ceiling — deterministic, so answer with the standard
				// ttft_too_slow 429 instead of waiting out the queue.
				s.recordWarmPoolQueueState(d.model)
				d.queuedExitOutcome(queuePR.Profile, "error", "ttft_too_slow", http.StatusTooManyRequests)
				d.refundReservation()
				s.deps.Registry().RecordWarmPoolTTFTMiss(d.model, d.deadline)
				s.TriggerWarmPool()
				bestTTFT := time.Duration(queuedReq.Decision.BestTTFTMs * float64(time.Millisecond))
				retryAfter := s.estimateTTFTRetryAfter(d.model, bestTTFT, d.deadline)
				d.ttftTooSlowTerminal(
					d.rejectionInfoWithDecision("queue", "ttft_too_slow", http.StatusTooManyRequests, retryAfter*1000, queuedReq.Decision),
					retryAfter,
					ttftTooSlowMessage(d.publicModel, bestTTFT, d.deadline, retryAfter))
				return outcomeResponseWritten
			}
			if errors.Is(err, registry.ErrQueueToolConstraintUnavailable) {
				s.recordWarmPoolQueueState(d.model)
				d.queuedExitOutcome(queuePR.Profile,
					"error", "model_capability_unsupported",
					http.StatusServiceUnavailable)
				d.refundReservation()
				d.preContentTerminal(
					d.rejectionInfoWithDecision(
						"queue", "model_capability_unsupported",
						http.StatusServiceUnavailable, 0, queuedReq.Decision),
					0,
					"model_unavailable",
					fmt.Sprintf(
						"no online provider for model %q supports inference-time tool_choice enforcement",
						d.publicModel),
					"model_unavailable")
				return outcomeResponseWritten
			}
			d.queuedExitOutcome(queuePR.Profile, "timeout", "queue_timeout", http.StatusTooManyRequests)
			d.refundReservation()
			s.deps.Counters.Incr("request_queue.timeout", []string{"model:" + d.model, "model_type:" + s.deps.Registry().ModelType(d.model)})
			s.deps.Registry().RecordWarmPoolQueueTimeout(d.model, time.Since(queuedReq.EnqueuedAt))
			retryAfter := s.EstimateRetryAfter(d.model)
			info := d.rejectionInfoWithDecision("queue", "queue_timeout", http.StatusTooManyRequests, retryAfter*1000, decision)
			if d.policy.Enabled {
				d.preContentTerminal(info, retryAfter, "machine_busy",
					"your machine is at capacity (timed out waiting for a free slot) — retry shortly",
					"machine_busy")
			} else {
				d.preContentTerminal(info, retryAfter, "rate_limit_exceeded",
					fmt.Sprintf("all providers for model %q are at capacity (queue timeout)", d.publicModel),
					"rate_limit_exceeded")
			}
			return outcomeResponseWritten
		}
		s.recordWarmPoolQueueState(d.model)
		// Queue assigned a provider; still need to dispatch.
		// Use the queue PR's channels.
		d.pr = queuePR
		d.requestID = d.pr.RequestID
		d.timing.RoutedAt = time.Now()
		if ap := d.pr.Profile; ap != nil {
			ap.Mark(registry.StampDequeued)
			ap.Mark(registry.StampReserveDone)
			ap.SetDecision(queuedReq.Decision)
			ap.SetReservationTTFTCeiling(d.pr.MaxTTFTMs)
			ap.ProviderID = d.provider.ID
			d.provider.Mu().Lock()
			ap.ProviderVersion = d.provider.Version
			ap.ChipFamily = d.provider.Hardware.ChipFamily
			d.provider.Mu().Unlock()
			ap.KVBackend, _ = d.provider.SlotKVBackendTags(d.model)
		}
		d.recordRoutingDecisionFor(d.provider, d.pr, d.requestID, d.pr.Attempt, queuedReq.Decision, "", "selected")

		// Log missing payout destination but don't skip — earnings
		// are credited to the provider's internal ledger and can be
		// withdrawn once they complete Stripe Connect onboarding.
		// A queued request settles FREE when its drained provider is the
		// caller's own machine: exclusive self-route always, OR a prefer
		// request whose selected provider is owned (settlement refunds to
		// zero). Skip the payout warning and the custom-price top-up then
		// (the top-up could otherwise 429 the free owned route).
		queuedSettlesFree := d.policy.Enabled
		if !queuedSettlesFree && d.policy.Prefer {
			d.provider.Mu().Lock()
			queuedSettlesFree = d.policy.OwnerAccountID != "" && d.provider.AccountID == d.policy.OwnerAccountID
			d.provider.Mu().Unlock()
		}

		if s.deps.BillingConfigured() && !queuedSettlesFree && !settlement.HasPayoutDestination(d.provider) {
			s.deps.Logger().Warn("queued provider missing payout destination, crediting to internal ledger",
				"request_id", d.requestID,
				"provider_id", d.provider.ID,
			)
		}

		// Custom pricing check — provider may charge more than the
		// platform rate. Reserve the additional amount now. Skipped for
		// free self-route, which settles at zero cost.
		if s.deps.BillingConfigured() && !queuedSettlesFree {
			if _, err := s.deps.Settlement().ReserveForProvider(d.pr, d.provider); err != nil {
				d.provider.RemovePending(d.requestID)
				s.deps.Registry().SetProviderIdle(d.provider.ID)
				d.excludeProviders[d.provider.ID] = struct{}{}
				if errors.Is(err, store.ErrInsufficientBalance) {
					s.deps.Logger().Warn("queued provider pricing exceeds balance, skipping",
						"request_id", d.requestID,
						"provider_id", d.provider.ID,
						"error", err,
					)
					d.setLastError("insufficient funds for provider price", http.StatusPaymentRequired)
					d.updateRoutingOutcome(d.errorRoutingOutcome("error", "insufficient_funds", d.lastErrCode))
				} else {
					s.deps.Logger().Error("queued provider reservation failed (DB error)",
						"request_id", d.requestID,
						"provider_id", d.provider.ID,
						"error", err,
					)
					d.setLastError("service temporarily unavailable — please retry", http.StatusServiceUnavailable)
					d.updateRoutingOutcome(d.errorRoutingOutcome("error", "provider_error", d.lastErrCode))
				}
				return outcomeRetry
			}
		}
		// Perform E2E encryption and send the request.
		if d.provider.PublicKey == "" {
			d.provider.RemovePending(d.requestID)
			s.deps.Registry().SetProviderIdle(d.provider.ID)
			s.deps.Settlement().RefundProviderExtra(d.pr)
			d.excludeProviders[d.provider.ID] = struct{}{}
			d.setLastError("no provider with E2E encryption", 0)
			d.updateRoutingOutcome(d.errorRoutingOutcome("error", "encryption_missing", 0))
			return outcomeRetry
		}
		providerPubKey, err := e2e.ParsePublicKey(d.provider.PublicKey)
		if err != nil {
			d.provider.RemovePending(d.requestID)
			s.deps.Registry().SetProviderIdle(d.provider.ID)
			s.deps.Settlement().RefundProviderExtra(d.pr)
			d.excludeProviders[d.provider.ID] = struct{}{}
			d.setLastError("provider public key invalid", 0)
			d.updateRoutingOutcome(d.errorRoutingOutcome("error", "provider_error", 0))
			return outcomeRetry
		}
		sessionKeys, err := e2e.GenerateSessionKeys()
		if err != nil {
			d.provider.RemovePending(d.requestID)
			s.deps.Registry().SetProviderIdle(d.provider.ID)
			s.deps.Settlement().RefundProviderExtra(d.pr)
			d.setLastError("failed to generate session keys", 0)
			d.updateRoutingOutcome(d.errorRoutingOutcome("error", "provider_error", 0))
			return outcomeRetry
		}
		if err := s.deps.Registry().PrepareCacheAttempt(d.pr, d.provider); err != nil {
			s.deps.Registry().ForgetCacheAttempt(d.pr)
			d.provider.RemovePending(d.requestID)
			s.deps.Registry().SetProviderIdle(d.provider.ID)
			s.deps.Settlement().RefundProviderExtra(d.pr)
			d.setLastError("failed to prepare cache-safe request", http.StatusInternalServerError)
			d.updateRoutingOutcome(d.errorRoutingOutcome("error", "provider_error", http.StatusInternalServerError))
			return outcomeRetry
		}
		// Version-gated penalty strip plus protocol-0 cache isolation. The queued
		// path seals here, separately from dispatchOneProvider.
		sealedBody, err := bodyForCacheAttempt(d.rawBody, d.requiresVision, d.provider, d.pr)
		if err != nil {
			s.deps.Registry().ForgetCacheAttempt(d.pr)
			d.provider.RemovePending(d.requestID)
			s.deps.Registry().SetProviderIdle(d.provider.ID)
			s.deps.Settlement().RefundProviderExtra(d.pr)
			if errors.Is(err, ErrProviderBodyTooLarge) {
				d.excludeProviders[d.provider.ID] = struct{}{}
				d.noteProviderBodyTooLarge(err.Error(), OversizedProviderBodyBytes(err))
				d.updateRoutingOutcome(d.errorRoutingOutcome(
					"error", attemptpolicy.ErrorClassClientError, http.StatusRequestEntityTooLarge))
				return outcomeRetry
			}
			d.setLastError("failed to prepare provider request", http.StatusInternalServerError)
			d.updateRoutingOutcome(d.errorRoutingOutcome(
				"error", "provider_error", http.StatusInternalServerError))
			return outcomeRetry
		}
		encrypted, err := e2e.Encrypt(sealedBody, providerPubKey, sessionKeys)
		if err != nil {
			s.deps.Registry().ForgetCacheAttempt(d.pr)
			d.provider.RemovePending(d.requestID)
			s.deps.Registry().SetProviderIdle(d.provider.ID)
			s.deps.Settlement().RefundProviderExtra(d.pr)
			d.setLastError("failed to encrypt request", 0)
			d.updateRoutingOutcome(d.errorRoutingOutcome("error", "encryption_missing", 0))
			return outcomeRetry
		}
		d.timing.EncryptedAt = time.Now()
		d.pr.Profile.Mark(registry.StampEncrypted)
		d.pr.SessionPrivKey = &sessionKeys.PrivateKey
		// pr.ReservedMicroUSD was already set in the struct literal and may
		// have been increased by Service.ReserveForProvider. Don't overwrite.
		// Bound the provider write by the request-absolute first-token clock:
		// WriteText blocks until the frame is on the wire (write watchdog
		// allows 5-30s per frame), so an unbounded write could eat the budget
		// while the aggregator's cancel clock keeps running.
		writeCtx, cancelWrite := firstTokenWriteContext(r.Context(), TimingReceivedAt(d.timing), d.deadline)
		d.pr.Profile.Mark(registry.StampWriteSubmitted)
		_, writeErr := writeProviderInferenceRequestDeferred(
			writeCtx,
			d.provider,
			providerInferenceFrameBuilder(
				d.requestID, encrypted.EphemeralPublicKey, encrypted.Ciphertext, d.pr),
			func(metadata registry.TextFrameWriteMetadata) {
				d.timing.DispatchedAt = metadata.DequeuedAt
				d.noteProviderDispatched()
				d.pr.Profile.MarkAt(registry.StampWriteDequeued, metadata.DequeuedAt)
			},
		)
		cancelWrite()
		if writeErr == nil {
			d.pr.Profile.Mark(registry.StampWriteDone)
		}
		if writeErr != nil {
			s.deps.Registry().ForgetCacheAttempt(d.pr)
			d.provider.RemovePending(d.requestID)
			s.deps.Registry().SetProviderIdle(d.provider.ID)
			s.deps.Settlement().RefundProviderExtra(d.pr)
			d.excludeProviders[d.provider.ID] = struct{}{}
			if errors.Is(writeErr, context.DeadlineExceeded) ||
				errors.Is(writeErr, errFirstContentDeadlineAtWriter) {
				d.pr.Profile.Mark(registry.StampCancelSent)
				s.deps.Attempts().SendCancel(d.provider, d.requestID)
				d.setLastError("timeout waiting for first response", http.StatusGatewayTimeout)
				d.updateRoutingOutcome(d.errorRoutingOutcome(
					"timeout", "first_chunk_timeout", http.StatusGatewayTimeout))
				return outcomeFailFast
			}
			d.setLastError("failed to send request to provider", 0)
			d.updateRoutingOutcome(d.errorRoutingOutcome("error", "provider_error", 0))
			return outcomeRetry
		}
	}
	// The request is now on a slot. Latch that slot's KV backend so the
	// exhaustion ladder can still attribute the outcome after a failover has
	// cleared d.provider/d.pr (v0.8.0 paged rollout, Gate G5).
	d.noteServingSlot()
	// Routing v2 W2: the primary frame is handed off — confirm the retained
	// alternates in parallel with the in-flight prompt (one probe round per
	// request; zero added primary latency by construction).
	d.maybeProbePlanCandidates()
	return outcomeProceed
}
