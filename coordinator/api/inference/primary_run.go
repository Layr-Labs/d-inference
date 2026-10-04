package inference

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	"github.com/eigeninference/d-inference/coordinator/api/promptwork"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/attempt"
	providerdispatch "github.com/eigeninference/d-inference/coordinator/internal/inference/dispatch"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/firstcontent"
	infermetrics "github.com/eigeninference/d-inference/coordinator/internal/inference/metrics"
	routeoutcome "github.com/eigeninference/d-inference/coordinator/internal/inference/outcome"
	profilepolicy "github.com/eigeninference/d-inference/coordinator/internal/inference/profile"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/providerwire"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/retry"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

// Run owns the complete primary attempt, including the queue placeholder's
// terminal defer. A queued reservation never re-enters ordinary selection.
func (p *Primary) Run(in PrimaryRequest) (result PrimaryResult) {
	s, d := p.s, in.Dispatch
	result = PrimaryResult{History: in.History, RequestID: in.RequestID}
	if d.Exclusions == nil {
		d.Exclusions = providerdispatch.NewExclusions()
	}
	if d.Forecast == nil {
		d.Forecast = firstcontent.NewForecast(contextCalibration, d.Exclusions.Exclude)
	}
	d.OnDispatched = p.resources.Accounting.Commit
	probe := providerdispatch.ProbeInput{
		Model: d.Model, PromptWork: func() int {
			return d.Forecast.PromptWork(d.Request, d.Model, d.Body, d.EstimatedPromptTokens, d.CachePlan.PromptTokenCount)
		},
		MaxOutputTokens: d.RequestedMaxTokens, RequiresVision: d.RequiresVision, VisionImageCount: in.VisionImageCount,
		ReceivedAt: firstcontent.TimingReceivedAt(d.Timing), Deadline: d.Deadline, SpeculativeAt: in.SpeculativeAt, Scope: d.Scope,
	}
	// Refresh evidence after repeated predictive refusals before any reservation.
	p.resources.Plan.RefreshQuotes(d.Request, probe, in.PredictiveRefusals, d.Exclusions.IDs())
	setFailure := func(text string, code int) {
		result.History.Failure = retry.CoordinatorFailure(text, code)
		result.History.DeadlineFailure = false
	}
	finish := func(out attempt.Outcome) PrimaryResult { result.Outcome = out; return result }
	update := func(out *store.InferenceRouteOutcome) {
		routeoutcome.CaptureAttempt(result.Provider, result.Pending, result.RequestID, d.Attempt).
			Record(s.NewRouteRecorder(), d.Model, func(*registry.PendingRequest) *store.InferenceRouteOutcome { return out })
	}
	errorOutcome := func(status, class string, code int) *store.InferenceRouteOutcome {
		msg := result.History.Failure.Message
		msg.StatusCode = code
		return retry.ErrorRouteOutcome(result.Pending, status, class, msg)
	}
	queueExit := func(ap *registry.AttemptProfile, status, reason string, code int) {
		out := errorOutcome(status, reason, code)
		out.QueueExit = true
		update(out)
		ap.SetOutcome(status, reason, "", "", "")
	}
	routeRecorded, routeRequestID, routeAttempt := false, "", d.Attempt
	var routeProvider *registry.Provider
	d.RecordRoute = func(provider *registry.Provider, pr *registry.PendingRequest, decision registry.RoutingDecision) {
		routeProvider, routeRecorded = provider, true
		if pr != nil {
			providerdispatch.ConfigurePending(pr, d.Request, in.Metadata)
			routeRequestID, routeAttempt = pr.RequestID, pr.Attempt
		}
		s.recordRoutingDecision(d, provider, pr, routeRequestID, routeAttempt, decision, "", "")
	}
	var selected providerdispatch.Result
	var selection providerdispatch.PlanSelection
	if d.Attempt > 0 {
		selected, selection = p.resources.Plan.Next(d)
	}
	if !selection.Tried() {
		selected = p.resources.Plan.Scan(d)
	}
	result.Provider, result.Pending = selected.Provider, selected.Pending
	dispatchErr, dispatchCode, decision := selected.Error, selected.ErrorCode, selected.Decision
	result.DispatchError, result.DispatchCode = dispatchErr, dispatchCode
	if !routeRecorded {
		key := result.RequestID
		if key == "" && result.Pending != nil {
			key = result.Pending.RequestID
		}
		s.recordRoutingDecision(d, result.Provider, result.Pending, key, d.Attempt, decision, dispatchErr, "")
	}
	if result.Provider == nil {
		if dispatchCode == http.StatusRequestEntityTooLarge && routeProvider != nil {
			result.History = result.History.ProviderBodyRejected(d.Body, routeProvider, dispatchErr, d.Exclusions)
		}
		if routeRecorded {
			s.updateInferenceRouteOutcomeWithModel(routeRequestID, routeAttempt, d.Model, errorOutcome("error", dispatchErrorClass(dispatchErr), dispatchCode))
		}
		if dispatchErr == errModelTooLarge {
			s.observation.Incr("routing.decisions", []string{"model:" + d.Model, "model_type:" + s.registry.ModelType(d.Model), "outcome:model_too_large"})
			setFailure(dispatchErr, dispatchCode)
			return finish(attempt.FailFast)
		}
		if dispatchCode == http.StatusRequestEntityTooLarge {
			return finish(attempt.Retry)
		}
		if dispatchErr == providerwire.DeadlineExpiredMessage {
			setFailure("timeout waiting for first response", http.StatusGatewayTimeout)
			return finish(attempt.FailFast)
		}
		if dispatchErr == errClientGoneBeforeScan {
			s.primaryClientGone(in, result.Provider)
			update(errorOutcome("cancelled", "client_gone", 0))
			in.Refund()
			return finish(attempt.ClientGone)
		}
		if dispatchErr == errRoutingScanSaturated {
			s.observation.Incr("routing.scan_admission_timeout", []string{"model:" + d.Model})
			setFailure(dispatchErr, http.StatusTooManyRequests)
			result.History.Terminal.UnservableReason = rejectionReasonRoutingSaturated
			return finish(attempt.FailFast)
		}
		if result.History.DeadlineFailure && dispatchErr == errTTFTTooSlow {
			return finish(attempt.FailFast)
		}
		if dispatchErr == errTTFTTooSlow && (d.Attempt == 0 || ttftTerminalRejectEnabled()) {
			bestTTFT := time.Duration(decision.BestTTFTMs * float64(time.Millisecond))
			in.Refund()
			if d.Attempt > 0 {
				retryAfter := s.estimateTTFTRetryAfter(d.Model, bestTTFT, d.Deadline)
				info := in.rejectionInfo("dispatch", "ttft_too_slow", http.StatusTooManyRequests, retryAfter*1000, decision)
				s.NewRejectionRecorder().Record(d.Request, info.Record, info.Servability)
				if infermetrics.IsOpenRouterScoredDispatchEndpoint(in.Metadata.Endpoint) {
					s.recordRequestOutcome(d.Model, p.resources.Slots.Resolve(result.Pending, in.AttributionFrozen, in.StickyFault), infermetrics.ClassifyOutcomeByCode(http.StatusTooManyRequests))
				}
			}
			s.NewMetrics().RecordORView(d.Model, infermetrics.ClassifyOutcomeByCode(http.StatusTooManyRequests))
			s.writeTTFTTooSlow(in.Writer, d.Model, d.PublicModel, bestTTFT, d.Deadline)
			return finish(attempt.ResponseWritten)
		}
		if dispatchErr != "no provider available" {
			setFailure(dispatchErr, dispatchCode)
			return finish(attempt.Retry)
		}
		overflow := result.History.Overflow
		compatibleOverflow := overflow.Message != "" && result.History.Failure.Message.StatusCode == http.StatusRequestEntityTooLarge
		if compatibleOverflow && decision.CapacityRejections == 0 {
			result.History = result.History.RejectBodyOverflow(overflow.Message)
			return finish(attempt.FailFast)
		}
		if d.Attempt > 0 && !result.History.QueueCompatible(decision) {
			if result.History.Failure.Message.Error == "" {
				setFailure(dispatchErr, dispatchCode)
			}
			return finish(attempt.FailFast)
		}
		if p.RejectUnforecastable(in, decision) {
			return finish(attempt.ResponseWritten)
		}

		result.RequestID = uuid.New().String()
		queuePR := &registry.PendingRequest{
			RequestID: result.RequestID, Attempt: d.Attempt, Model: d.Model, PublicModel: d.PublicModel,
			ConsumerKey: d.ConsumerKey, KeyID: access.KeyIDFromContext(d.Request.Context()),
			KeyLimitMicroUSD: access.KeyLimitMicroFromContext(d.Request.Context()), KeyLimitReset: access.KeyLimitResetFromContext(d.Request.Context()),
			ConsumerLocation: d.ConsumerLocation, IsResponsesAPI: d.IsResponsesAPI,
			EstimatedPromptTokens:    d.EstimatedPromptTokens,
			FirstContentPromptTokens: calibratedContextPromptTokens(d.Model, d.EstimatedPromptTokens),
			PromptWork:               promptwork.ForAttempt(d.Request.Context(), d.Model, d.Body, calibratedContextPromptTokens(d.Model, d.EstimatedPromptTokens)),
			RequiresVision:           d.RequiresVision, Traits: d.Traits, RequestedMaxTokens: d.RequestedMaxTokens, TokenAdmission: d.TokenAdmission,
			ReservedMicroUSD: d.ReservedMicroUSD, BaseReservedMicroUSD: d.ReservedMicroUSD, ServiceReservation: d.ServiceReservation,
			AllowedProviderSerials: d.AllowedProviderSerials, ExcludedProviderIDs: d.Exclusions.IDs(), CachePlan: d.CachePlan,
			SelfRouteOnly: d.Scope.SelfRouteOnly, PreferOwner: d.Scope.PreferOwner, OwnerAccountID: d.Scope.OwnerAccountID,
			FreeSelfRoute: d.Scope.SelfRouteOnly, MetadataDetails: in.Metadata.Details,
			MaxTTFTMs:    queueMaxTTFTMs(selfRoutePolicy{enabled: d.Scope.SelfRouteOnly, prefer: d.Scope.PreferOwner}, d.Deadline, s.hardTTFTGateApplies(d.RequiresVision)),
			MinDecodeTPS: s.minDecodeTPS, AcceptedCh: make(chan struct{}, 1), ChunkCh: make(chan registry.ProviderChunk, chunkBufferSize),
			CompleteCh: make(chan protocol.UsageInfo, 1), ErrorCh: make(chan protocol.InferenceErrorMessage, 1), Timing: d.Timing,
		}
		providerdispatch.ConfigurePending(queuePR, d.Request, in.Metadata)
		d.ConfigureDeadlines(queuePR)
		d.Forecast.Configure(queuePR, d.Model, d.EstimatedPromptTokens, d.Deadline, false)
		if receivedAt := firstcontent.TimingReceivedAt(d.Timing); d.DeadlineForWork == nil && !receivedAt.IsZero() && d.Deadline > 0 {
			queuePR.FirstContentDeadline = receivedAt.Add(d.Deadline)
		}
		if !queuePR.RefreshFirstContentBudget(time.Now()) {
			setFailure("timeout waiting for first response", http.StatusGatewayTimeout)
			return finish(attempt.FailFast)
		}
		queuedReq := &registry.QueuedRequest{RequestID: result.RequestID, Model: d.Model, Pending: queuePR, ResponseCh: make(chan *registry.Provider, 1)}
		queuePR.Timing.QueuedAt = time.Now()
		queuePR.Profile = d.Profile.NewAttempt(result.RequestID, d.Attempt, "")
		s.recordPredictivePolicy(queuePR.Profile, selfRoutePolicy{enabled: d.Scope.SelfRouteOnly, prefer: d.Scope.PreferOwner, ownerAccountID: d.Scope.OwnerAccountID}, d.RequiresVision)
		queuePR.Profile.Mark(registry.StampAttemptStart)
		queuePR.Profile.Mark(registry.StampQueued)
		// This defer belongs to Primary.Run, not the surrounding retry loop.
		// A pending assignment is not proof that a frame reached the wire.
		defer func() {
			profilepolicy.CloseQueued(d.Request.Context(), queuePR.Profile, result.History.Failure.Message.Error, result.History.Failure.Message.StatusCode)
		}()
		if err := s.registry.Queue().Enqueue(queuedReq); err != nil {
			s.observation.Incr("routing.decisions", []string{"model:" + d.Model, "model_type:" + s.registry.ModelType(d.Model), "outcome:over_capacity"})
			queuePR.Profile.SetOutcome("rejected", "queue_full", "", "", "")
			retryAfter := s.estimateRetryAfter(d.Model)
			in.Refund()
			info := in.rejectionInfo("queue", "queue_full", http.StatusTooManyRequests, retryAfter*1000, decision)
			if d.Scope.SelfRouteOnly {
				p.terminal(in, info, retryAfter, "machine_busy", "your machine is at capacity \u2014 retry shortly", "machine_busy")
			} else {
				p.terminal(in, info, retryAfter, "rate_limit_exceeded", fmt.Sprintf("all providers for model %q are at capacity and queue is full", d.PublicModel), "rate_limit_exceeded")
			}
			return finish(attempt.ResponseWritten)
		}
		s.recordWarmPoolQueueState(d.Model)
		s.kickColdDispatch(d.Model)
		s.observation.Incr("routing.decisions", []string{"model:" + d.Model, "model_type:" + s.registry.ModelType(d.Model), "outcome:queued"})
		s.recordRoutingDecision(d, result.Provider, result.Pending, result.RequestID, d.Attempt, decision, "", "queued")
		s.logger.Info("request queued, waiting for provider", "model", d.Model, "attempt", d.Attempt+1)
		queueCtx, cancelQueue := firstcontent.FirstTokenWriteContext(d.Request.Context(), firstcontent.TimingReceivedAt(d.Timing), d.Deadline)
		var err error
		result.Provider, err = s.registry.Queue().WaitForProviderContext(queueCtx, queuedReq)
		cancelQueue()
		if err != nil {
			if errors.Is(err, context.Canceled) {
				s.recordWarmPoolQueueState(d.Model)
				s.primaryClientGone(in, result.Provider)
				queueExit(queuePR.Profile, "cancelled", "client_gone", 0)
				in.Refund()
				return finish(attempt.ClientGone)
			}
			if errors.Is(err, context.DeadlineExceeded) || errors.Is(err, registry.ErrQueueFirstContentDeadline) {
				s.recordWarmPoolQueueState(d.Model)
				queueExit(queuePR.Profile, "timeout", rejectionReasonQueueDeadline, http.StatusGatewayTimeout)
				setFailure(errQueueDeadlineExpired, http.StatusGatewayTimeout)
				return finish(attempt.FailFast)
			}
			if errors.Is(err, registry.ErrQueueTTFTTooSlow) {
				s.recordWarmPoolQueueState(d.Model)
				queueExit(queuePR.Profile, "error", "ttft_too_slow", http.StatusTooManyRequests)
				in.Refund()
				s.registry.RecordWarmPoolTTFTMiss(d.Model, d.Deadline)
				s.triggerWarmPool()
				bestTTFT := time.Duration(queuedReq.Decision.BestTTFTMs * float64(time.Millisecond))
				retryAfter := s.estimateTTFTRetryAfter(d.Model, bestTTFT, d.Deadline)
				s.observation.Incr("routing.decisions", []string{"model:" + d.Model, "model_type:" + s.registry.ModelType(d.Model), "outcome:ttft_429"})
				p.terminal(in, in.rejectionInfo("queue", "ttft_too_slow", http.StatusTooManyRequests, retryAfter*1000, queuedReq.Decision), retryAfter,
					"rate_limit_exceeded", ttftTooSlowMessage(d.PublicModel, bestTTFT, d.Deadline, retryAfter), "rate_limit_exceeded")
				return finish(attempt.ResponseWritten)
			}
			if errors.Is(err, registry.ErrQueueToolConstraintUnavailable) {
				s.recordWarmPoolQueueState(d.Model)
				queueExit(queuePR.Profile, "error", "model_capability_unsupported", http.StatusServiceUnavailable)
				in.Refund()
				p.terminal(in, in.rejectionInfo("queue", "model_capability_unsupported", http.StatusServiceUnavailable, 0, queuedReq.Decision), 0,
					"model_unavailable", fmt.Sprintf("no online provider for model %q supports inference-time tool_choice enforcement", d.PublicModel), "model_unavailable")
				return finish(attempt.ResponseWritten)
			}
			queueExit(queuePR.Profile, "timeout", "queue_timeout", http.StatusTooManyRequests)
			in.Refund()
			s.observation.Incr("request_queue.timeout", []string{"model:" + d.Model, "model_type:" + s.registry.ModelType(d.Model)})
			s.registry.RecordWarmPoolQueueTimeout(d.Model, time.Since(queuedReq.EnqueuedAt))
			retryAfter := s.estimateRetryAfter(d.Model)
			info := in.rejectionInfo("queue", "queue_timeout", http.StatusTooManyRequests, retryAfter*1000, decision)
			if d.Scope.SelfRouteOnly {
				p.terminal(in, info, retryAfter, "machine_busy", "your machine is at capacity (timed out waiting for a free slot) \u2014 retry shortly", "machine_busy")
			} else {
				p.terminal(in, info, retryAfter, "rate_limit_exceeded", fmt.Sprintf("all providers for model %q are at capacity (queue timeout)", d.PublicModel), "rate_limit_exceeded")
			}
			return finish(attempt.ResponseWritten)
		}
		s.recordWarmPoolQueueState(d.Model)
		result.Pending, result.RequestID = queuePR, queuePR.RequestID
		d.Timing.RoutedAt = time.Now()
		if ap := queuePR.Profile; ap != nil {
			ap.Mark(registry.StampDequeued)
			ap.Mark(registry.StampReserveDone)
			ap.SetDecision(queuedReq.Decision)
			ap.SetReservationTTFTCeiling(queuePR.MaxTTFTMs)
			ap.ProviderID = result.Provider.ID
			result.Provider.Mu().Lock()
			ap.ProviderVersion, ap.ChipFamily = result.Provider.Version, result.Provider.Hardware.ChipFamily
			result.Provider.Mu().Unlock()
			ap.KVBackend, _ = result.Provider.SlotKVBackendTags(d.Model)
		}
		s.recordRoutingDecision(d, result.Provider, result.Pending, result.RequestID, queuePR.Attempt, queuedReq.Decision, "", "selected")
		handoff := s.handoffQueuedProvider(d, result.Provider, result.Pending, p.resources.Accounting)
		if handoff.Failure != nil {
			result.History.Failure, result.History.DeadlineFailure = *handoff.Failure, false
		}
		if handoff.BodyOverflow {
			result.History = result.History.WithBodyOverflow(handoff.Failure.Message.Error, handoff.BodyBytes)
		}
		if handoff.RouteOutcome != nil {
			update(handoff.RouteOutcome)
		}
		if handoff.Outcome != attempt.Proceed {
			return finish(handoff.Outcome)
		}
	}
	result.RequestID = result.Pending.RequestID
	p.resources.Slots.Note(result.Provider, result.Pending, in.AttributionFrozen)
	result.HedgeAdvance, _ = p.resources.Plan.Probe(probe)
	return finish(attempt.Proceed)
}
