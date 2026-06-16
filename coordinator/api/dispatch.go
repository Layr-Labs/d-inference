package api

// Per-request dispatch state machine for the consumer inference path.
//
// This file holds the speculative TTFT-aware dispatch loop that handleChatCompletions
// drives: it picks a provider (or queues), waits for the first CONTENT chunk with a
// speculative backup race, fails over invisibly on provider error/timeout up to
// maxDispatchAttempts, and commits exactly once. It is a PURELY STRUCTURAL extraction
// of what previously lived inline in consumer.go — every select arm, timer Stop/Reset,
// channel-close+ErrorCh grace window, heldChunks cap, liveness extension, speculative
// race (backup dispatch / cancel-loser / skipBackup), refund-exactly-once, breaker
// call, DD metric, and status code is preserved exactly.
//
// Control-flow mapping (former labeled blocks → methods):
//
//	for attempt := range maxDispatchAttempts   → dispatchState.run (the orchestrator)
//	dispatch-primary block (incl. queue path)  → dispatchState.dispatchPrimary
//	firstChunkWait + speculative race          → dispatchState.waitFirstChunk
//	  noBackupWait                             →   dispatchState.waitNoBackup
//	  race + sub-waits                         →   dispatchState.runRace
//	    backupFailedPrimaryWait                →     dispatchState.raceBackupFailedWaitPrimary
//	    primaryFailedBackupWait                →     dispatchState.racePrimaryFailedWaitBackup
//	    backupFailedWaitPrimary                →     dispatchState.raceBackupErrWaitPrimary
//	acceptedWait                               → dispatchState.waitAccepted
//
// The former labeled jumps become method returns: `continue dispatch` → outcomeRetry,
// `break`/commit → outcomeCommitted, `break <label>` into the accepted wait →
// outcomeAccepted, `return` (client gone, after refund) → outcomeClientGone, and the
// queue-rejection `writeJSON; return` paths → outcomeResponseWritten. The orchestrator
// switches on the outcome, exactly reproducing the original flow.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
	"nhooyr.io/websocket"
)

// dispatchOutcome is the result of a per-attempt dispatch phase (provider
// selection, first-chunk wait, accepted wait). The orchestrator (dispatchState.run)
// switches on it to reproduce the original loop's continue/break/return flow.
type dispatchOutcome int

const (
	// outcomeCommitted: a content chunk (or a clean close) committed the attempt.
	// The orchestrator stops the loop and streams the response.
	outcomeCommitted dispatchOutcome = iota
	// outcomeAccepted: the provider signalled AcceptedCh / preamble liveness but
	// has not produced content yet. The orchestrator proceeds to waitAccepted.
	outcomeAccepted
	// outcomeRetry: the attempt failed (provider error / timeout). Equivalent to
	// the original `continue dispatch` — the orchestrator advances to the next attempt.
	outcomeRetry
	// outcomeFailFast: the loop must stop without a committed provider (e.g.
	// model-too-large, or no-provider on a retry attempt). Equivalent to `break`.
	outcomeFailFast
	// outcomeClientGone: the request context was cancelled; the reservation was
	// already refunded and the handler must return with no response body.
	outcomeClientGone
	// outcomeResponseWritten: a terminal HTTP response was already written
	// (queue rejection / queue timeout / queue insufficient funds 402 etc.) and
	// the handler must return immediately.
	outcomeResponseWritten
	// outcomeProceed: provider selection succeeded; the orchestrator continues
	// to the first-chunk wait for this attempt.
	outcomeProceed
)

// dispatchState carries everything the per-request dispatch loop needs. The
// immutable inputs are set once by runDispatch; the mutable fields track the
// in-flight attempt (selected provider, held preamble, commit/accept flags,
// last error for the exhaustion ladder, and the version to steer retries away from).
type dispatchState struct {
	s *Server

	// ---- immutable inputs (set once) ----
	w                      http.ResponseWriter
	r                      *http.Request
	model                  string
	publicModel            string
	rawBody                []byte
	consumerKey            string
	consumerLocation       *store.ProviderLocation
	reservedMicroUSD       int64
	serviceReservation     bool
	estimatedPromptTokens  int
	requestedMaxTokens     int
	tokenAdmission         registry.TokenAdmission
	requiresVision         bool
	hasTools               bool
	isResponsesAPI         bool
	stream                 bool
	policy                 selfRoutePolicy
	allowedProviderSerials []string
	cacheAffinityKey       string
	timing                 *registry.RequestTiming
	deadline               time.Duration
	speculativeAt          time.Duration
	// refundReservation refunds the shared base reservation (the caller's closure).
	refundReservation func()

	// ---- mutable per-request state ----
	provider          *registry.Provider
	pr                *registry.PendingRequest
	requestID         string
	firstChunk        string
	heldChunks        []string
	lastErr           string
	lastErrCode       int
	committed         bool
	lastFailedVersion string
	excludeProviders  map[string]struct{}

	// ---- per-attempt scratch (reset each attempt) ----
	attempt          int
	accepted         bool
	preambleLiveness bool
}

// traits builds the routing traits for the current attempt, steering away from
// the most recently failed provider's binary version.
func (d *dispatchState) traits() registry.RequestTraits {
	return registry.RequestTraits{HasTools: d.hasTools, AvoidVersion: d.lastFailedVersion}
}

// queueMaxTTFTMs returns the TTFT ceiling for queued requests. Public routes
// inherit the prompt-scaled admission threshold; self-route / prefer-owner paths
// are not subject to the public SLA ceiling.
func queueMaxTTFTMs(policy selfRoutePolicy, deadline time.Duration) float64 {
	if policy.enabled || policy.prefer {
		return 0
	}
	return float64(deadline.Milliseconds())
}

// dispatchPrimary selects (and, when no idle provider exists on the first
// attempt, queues + dispatches) the primary provider for this attempt. It is the
// extraction of the original loop's dispatch-primary block (incl. the queue path).
// On success it leaves d.provider/d.pr set and returns outcomeProceed.
func (d *dispatchState) dispatchPrimary() dispatchOutcome {
	s := d.s
	r, w := d.r, d.w
	attempt := d.attempt

	// Dispatch the primary provider.
	var dispatchErr string
	var dispatchErrCode int
	var decision registry.RoutingDecision
	d.provider, d.pr, decision, dispatchErr, dispatchErrCode = s.dispatchOneProvider(
		r, d.model, d.publicModel, d.rawBody, d.consumerKey, d.consumerLocation, d.reservedMicroUSD,
		d.estimatedPromptTokens, d.requestedMaxTokens, d.tokenAdmission, d.requiresVision,
		d.traits(),
		d.allowedProviderSerials, d.isResponsesAPI, d.policy, d.timing, d.serviceReservation, d.cacheAffinityKey, d.excludeProviders,
	)
	if d.provider == nil {
		// No online provider has enough memory to ever fit this model.
		// Retrying and queueing are both pointless — reject immediately
		// with a clear, non-retryable error.
		if dispatchErr == errModelTooLarge {
			s.ddIncr("routing.decisions", []string{"model:" + d.model, "model_type:" + s.registry.ModelType(d.model), "outcome:model_too_large"})
			d.lastErr = dispatchErr
			d.lastErrCode = dispatchErrCode
			return outcomeFailFast
		}

		// Providers are available but all exceed the TTFT ceiling. On the
		// first attempt, fail fast with a retryable 429 instead of queueing
		// for a provider that would miss the OpenRouter SLA target. On retry
		// attempts, fall through to normal retry logic so we don't abort an
		// in-flight stream mid-way.
		if dispatchErr == errTTFTTooSlow && attempt == 0 {
			bestTTFT := time.Duration(decision.BestTTFTMs * float64(time.Millisecond))
			d.refundReservation()
			s.writeTTFTTooSlow(w, d.model, d.publicModel, bestTTFT, d.deadline)
			return outcomeResponseWritten
		}

		// dispatchOneProvider may have found a provider but rejected it
		// (payout destination missing, insufficient funds, encryption
		// missing). In that case it already added the provider to
		// excludeProviders. If there may be more providers to try,
		// continue to the next attempt.
		providerWasRejected := dispatchErr != "no provider available"
		if providerWasRejected {
			d.lastErr = dispatchErr
			d.lastErrCode = dispatchErrCode
			return outcomeRetry
		}

		// On retry attempts, don't queue — if the only available
		// providers already failed, waiting 120s for one of them
		// to come back won't help. Break and return the last error.
		// Don't overwrite lastErr/lastErrCode from the real provider
		// error — preserve the original status code.
		if attempt > 0 {
			if d.lastErr == "" {
				d.lastErr = dispatchErr
				d.lastErrCode = dispatchErrCode
			}
			return outcomeFailFast
		}
		// No idle provider — try queueing.
		d.requestID = uuid.New().String()
		queuePR := &registry.PendingRequest{
			RequestID:              d.requestID,
			Model:                  d.model,
			PublicModel:            d.publicModel,
			ConsumerKey:            d.consumerKey,
			KeyID:                  keyIDFromContext(r.Context()),
			KeyLimitMicroUSD:       keyLimitMicroFromContext(r.Context()),
			KeyLimitReset:          keyLimitResetFromContext(r.Context()),
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
			CacheAffinityKey:       d.cacheAffinityKey,
			SelfRouteOnly:          d.policy.enabled,
			PreferOwner:            d.policy.prefer,
			OwnerAccountID:         d.policy.ownerAccountID,
			FreeSelfRoute:          d.policy.enabled,
			MaxTTFTMs:              queueMaxTTFTMs(d.policy, d.deadline),
			AcceptedCh:             make(chan struct{}, 1),
			ChunkCh:                make(chan string, chunkBufferSize),
			CompleteCh:             make(chan protocol.UsageInfo, 1),
			ErrorCh:                make(chan protocol.InferenceErrorMessage, 1),
			Timing:                 d.timing,
		}
		queuedReq := &registry.QueuedRequest{
			RequestID:  d.requestID,
			Model:      d.model,
			Pending:    queuePR,
			ResponseCh: make(chan *registry.Provider, 1),
		}
		queuePR.Timing.QueuedAt = time.Now()
		if err := s.registry.Queue().Enqueue(queuedReq); err != nil {
			s.ddIncr("routing.decisions", []string{"model:" + d.model, "model_type:" + s.registry.ModelType(d.model), "outcome:over_capacity"})
			retryAfter := s.estimateRetryAfter(d.model)
			w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
			d.refundReservation()
			if d.policy.enabled {
				writeJSON(w, http.StatusTooManyRequests, errorResponse("machine_busy",
					"your machine is at capacity — retry shortly", withCode("machine_busy")))
			} else {
				writeJSON(w, http.StatusTooManyRequests, errorResponse("rate_limit_exceeded",
					fmt.Sprintf("all providers for model %q are at capacity and queue is full", d.publicModel),
					withCode("rate_limit_exceeded")))
			}
			return outcomeResponseWritten
		}
		s.recordWarmPoolQueueState(d.model)
		s.ddIncr("routing.decisions", []string{"model:" + d.model, "model_type:" + s.registry.ModelType(d.model), "outcome:queued"})

		s.logger.Info("request queued, waiting for provider",
			"model", d.model,
			"attempt", attempt+1,
		)

		var err error
		d.provider, err = s.registry.Queue().WaitForProviderContext(r.Context(), queuedReq)
		if err != nil {
			if errors.Is(err, context.Canceled) {
				s.recordWarmPoolQueueState(d.model)
				d.refundReservation()
				return outcomeClientGone
			}
			d.refundReservation()
			s.ddIncr("request_queue.timeout", []string{"model:" + d.model, "model_type:" + s.registry.ModelType(d.model)})
			s.registry.RecordWarmPoolQueueTimeout(d.model, time.Since(queuedReq.EnqueuedAt))
			retryAfter := s.estimateRetryAfter(d.model)
			w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
			if d.policy.enabled {
				writeJSON(w, http.StatusTooManyRequests, errorResponse("machine_busy",
					"your machine is at capacity (timed out waiting for a free slot) — retry shortly", withCode("machine_busy")))
			} else {
				writeJSON(w, http.StatusTooManyRequests, errorResponse("rate_limit_exceeded",
					fmt.Sprintf("all providers for model %q are at capacity (queue timeout)", d.publicModel),
					withCode("rate_limit_exceeded")))
			}
			return outcomeResponseWritten
		}
		s.recordWarmPoolQueueState(d.model)
		// Queue assigned a provider; still need to dispatch.
		// Use the queue PR's channels.
		d.pr = queuePR
		d.requestID = d.pr.RequestID
		d.timing.RoutedAt = time.Now()

		// Log missing payout destination but don't skip — earnings
		// are credited to the provider's internal ledger and can be
		// withdrawn once they complete Stripe Connect onboarding.
		// A queued request settles FREE when its drained provider is the
		// caller's own machine: exclusive self-route always, OR a prefer
		// request whose selected provider is owned (settlement refunds to
		// zero). Skip the payout warning and the custom-price top-up then
		// (the top-up could otherwise 429 the free owned route).
		queuedSettlesFree := d.policy.enabled
		if !queuedSettlesFree && d.policy.prefer {
			d.provider.Mu().Lock()
			queuedSettlesFree = d.policy.ownerAccountID != "" && d.provider.AccountID == d.policy.ownerAccountID
			d.provider.Mu().Unlock()
		}

		if s.billing != nil && !queuedSettlesFree && !providerHasPayoutDestination(d.provider) {
			s.logger.Warn("queued provider missing payout destination, crediting to internal ledger",
				"request_id", d.requestID,
				"provider_id", d.provider.ID,
			)
		}

		// Custom pricing check — provider may charge more than the
		// platform rate. Reserve the additional amount now. Skipped for
		// free self-route, which settles at zero cost.
		if s.billing != nil && !queuedSettlesFree {
			if _, err := s.reserveAdditionalForProvider(d.pr, d.provider); err != nil {
				d.provider.RemovePending(d.requestID)
				s.registry.SetProviderIdle(d.provider.ID)
				d.excludeProviders[d.provider.ID] = struct{}{}
				if errors.Is(err, store.ErrInsufficientBalance) {
					s.logger.Warn("queued provider pricing exceeds balance, skipping",
						"request_id", d.requestID,
						"provider_id", d.provider.ID,
						"error", err,
					)
					d.lastErr = "insufficient funds for provider price"
					d.lastErrCode = http.StatusPaymentRequired
				} else {
					s.logger.Error("queued provider reservation failed (DB error)",
						"request_id", d.requestID,
						"provider_id", d.provider.ID,
						"error", err,
					)
					d.lastErr = "service temporarily unavailable — please retry"
					d.lastErrCode = http.StatusServiceUnavailable
				}
				return outcomeRetry
			}
		}
		// Perform E2E encryption and send the request.
		if d.provider.PublicKey == "" {
			d.provider.RemovePending(d.requestID)
			s.registry.SetProviderIdle(d.provider.ID)
			s.refundProviderExtra(d.pr)
			d.excludeProviders[d.provider.ID] = struct{}{}
			d.lastErr = "no provider with E2E encryption"
			return outcomeRetry
		}
		providerPubKey, err := e2e.ParsePublicKey(d.provider.PublicKey)
		if err != nil {
			d.provider.RemovePending(d.requestID)
			s.registry.SetProviderIdle(d.provider.ID)
			s.refundProviderExtra(d.pr)
			d.excludeProviders[d.provider.ID] = struct{}{}
			d.lastErr = "provider public key invalid"
			return outcomeRetry
		}
		sessionKeys, err := e2e.GenerateSessionKeys()
		if err != nil {
			d.provider.RemovePending(d.requestID)
			s.registry.SetProviderIdle(d.provider.ID)
			s.refundProviderExtra(d.pr)
			d.lastErr = "failed to generate session keys"
			return outcomeRetry
		}
		// Version-gated penalty strip (see bodyForProvider). The queued path seals
		// here, separately from dispatchOneProvider.
		sealedBody := bodyForProvider(d.rawBody, d.requiresVision, d.provider)
		encrypted, err := e2e.Encrypt(sealedBody, providerPubKey, sessionKeys)
		if err != nil {
			d.provider.RemovePending(d.requestID)
			s.registry.SetProviderIdle(d.provider.ID)
			s.refundProviderExtra(d.pr)
			d.lastErr = "failed to encrypt request"
			return outcomeRetry
		}
		d.timing.EncryptedAt = time.Now()
		wireMsg := map[string]any{
			"type":       protocol.TypeInferenceRequest,
			"request_id": d.requestID,
			"encrypted_body": map[string]string{
				"ephemeral_public_key": encrypted.EphemeralPublicKey,
				"ciphertext":           encrypted.Ciphertext,
			},
		}
		d.pr.SessionPrivKey = &sessionKeys.PrivateKey
		// pr.ReservedMicroUSD was already set in the struct literal and may
		// have been increased by reserveAdditionalForProvider. Don't overwrite.
		data, _ := json.Marshal(wireMsg)
		if err := d.provider.Conn.Write(r.Context(), websocket.MessageText, data); err != nil {
			d.provider.RemovePending(d.requestID)
			s.registry.SetProviderIdle(d.provider.ID)
			s.refundProviderExtra(d.pr)
			d.excludeProviders[d.provider.ID] = struct{}{}
			d.lastErr = "failed to send request to provider"
			return outcomeRetry
		}
		d.pr.Timing.DispatchedAt = time.Now()
	}
	return outcomeProceed
}

// noteDispatchRetry feeds the inference-error breaker + refund for a pre-commit
// provider error and, unless held boilerplate was discarded (which emits its own
// pre-content failover counter), emits the generic retry counter. This is the
// exact `if !s.noteDispatchProviderError(...) { s.ddIncr(retry) }` pattern.
func (d *dispatchState) noteDispatchRetry(provider *registry.Provider, pr *registry.PendingRequest, statusCode int, held *[]string) {
	if !d.s.noteDispatchProviderError(provider, pr, statusCode, held) {
		d.s.ddIncr("inference.dispatches", []string{"status:retry"})
	}
}

// waitFirstChunk runs the speculative TTFT-aware first-chunk wait (the former
// `firstChunkWait` labeled loop). It holds preamble chunks, commits on first
// content, extends on AcceptedCh / preamble liveness, retries invisibly on
// provider error/timeout, and launches the speculative backup race when the
// primary is slow. Returns outcomeCommitted (content / clean close), outcomeAccepted
// (cold-load or preamble liveness — proceed to waitAccepted), outcomeRetry
// (advance to the next attempt), or outcomeClientGone (context cancelled, refunded).
func (d *dispatchState) waitFirstChunk() dispatchOutcome {
	s := d.s
	r := d.r
	provider, pr := d.provider, d.pr

	speculativeTimer := time.NewTimer(d.speculativeAt)
	deadlineTimer := time.NewTimer(d.deadline)
	d.accepted = false
	// preambleLiveness distinguishes WHY the extended first-content wait was
	// entered: a genuine AcceptedCh (cold model load — keeps the full
	// inferenceTimeout) vs a held-boilerplate liveness extension past an
	// expired TTFT deadline (zero bytes written to the client — bounded by
	// preambleContentTimeout so a role-then-stall zombie fails over).
	d.preambleLiveness = false

	for {
		select {
		case chunk, ok := <-pr.ChunkCh:
			if ok && len(d.heldChunks) < maxHeldBoilerplate && isBoilerplateChunk(chunk) {
				d.heldChunks = append(d.heldChunks, chunk)
				if pr.Timing.FirstChunkAt.IsZero() {
					pr.Timing.FirstChunkAt = time.Now()
				}
				continue
			}
			speculativeTimer.Stop()
			deadlineTimer.Stop()
			if ok {
				d.firstChunk = chunk
				if pr.Timing.FirstChunkAt.IsZero() {
					pr.Timing.FirstChunkAt = time.Now()
				}
				d.committed = true
			} else {
				select {
				case errMsg := <-pr.ErrorCh:
					d.excludeProviders[provider.ID] = struct{}{}
					s.cancelDispatch(provider, pr)
					d.lastErr = errMsg.Error
					d.lastErrCode = errMsg.StatusCode
					d.lastFailedVersion = failedProviderVersion(provider)
					d.noteDispatchRetry(provider, pr, errMsg.StatusCode, &d.heldChunks)
					d.provider = nil
					d.pr = nil
					return outcomeRetry
				default:
					// Closed without error — commit (held chunks only is
					// fine: a preamble-then-complete stream is empty output).
					d.committed = true
				}
			}
			return outcomeCommitted

		case <-pr.AcceptedCh:
			speculativeTimer.Stop()
			deadlineTimer.Stop()
			d.accepted = true
			return outcomeAccepted

		case errMsg := <-pr.ErrorCh:
			speculativeTimer.Stop()
			deadlineTimer.Stop()
			d.excludeProviders[provider.ID] = struct{}{}
			s.cancelDispatch(provider, pr)
			d.lastErr = errMsg.Error
			d.lastErrCode = errMsg.StatusCode
			d.lastFailedVersion = failedProviderVersion(provider)
			s.logger.Warn("provider failed, retrying",
				"request_id", d.requestID,
				"provider_id", provider.ID,
				"attempt", d.attempt+1,
				"error", errMsg.Error,
			)
			s.emitRequest(r.Context(), protocol.SeverityWarn, d.requestID,
				"provider failed, retrying",
				map[string]any{
					"provider_id": provider.ID,
					"attempt":     d.attempt + 1,
					"reason":      "provider_error",
					"status_code": errMsg.StatusCode,
				})
			if s.metrics != nil {
				s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "retry"})
			}
			d.noteDispatchRetry(provider, pr, errMsg.StatusCode, &d.heldChunks)
			d.provider = nil
			d.pr = nil
			return outcomeRetry

		case <-speculativeTimer.C:
			deadlineTimer.Stop()
			return d.runSpeculative()

		case <-deadlineTimer.C:
			speculativeTimer.Stop()
			if len(d.heldChunks) > 0 {
				// Preamble liveness — the provider is alive but still in its
				// pre-content phase. Fall through to the extended
				// (preambleContentTimeout) wait instead of failing the attempt.
				d.accepted = true
				d.preambleLiveness = true
				return outcomeAccepted
			}
			d.excludeProviders[provider.ID] = struct{}{}
			s.registry.RecordWarmPoolTTFTMiss(d.model, d.deadline)
			s.cancelDispatch(provider, pr)
			d.lastErr = "timeout waiting for first response"
			d.lastErrCode = http.StatusGatewayTimeout
			s.logger.Warn("provider timeout (full deadline), retrying",
				"request_id", d.requestID,
				"provider_id", provider.ID,
				"attempt", d.attempt+1,
			)
			s.emitRequest(r.Context(), protocol.SeverityWarn, d.requestID,
				"provider first-chunk timeout",
				map[string]any{
					"provider_id": provider.ID,
					"attempt":     d.attempt + 1,
					"reason":      "first_chunk_timeout",
				})
			if s.metrics != nil {
				s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "timeout"})
			}
			s.ddIncr("inference.dispatches", []string{"status:timeout"})
			d.provider = nil
			d.pr = nil
			return outcomeRetry

		case <-r.Context().Done():
			speculativeTimer.Stop()
			deadlineTimer.Stop()
			s.cancelDispatch(provider, pr)
			d.refundReservation()
			return outcomeClientGone
		}
	}
}

// runSpeculative is the speculativeTimer.C arm of waitFirstChunk: the primary is
// slow, so dispatch a speculative backup (unless this is a prefer request being
// served by the caller's own machine) and either keep waiting for the primary
// alone (no backup available) or race primary vs backup. Returns the same outcome
// set as waitFirstChunk.
func (d *dispatchState) runSpeculative() dispatchOutcome {
	s := d.s
	r := d.r
	provider := d.provider

	// Primary is slow. Attempt speculative backup dispatch.
	s.ddIncr("inference.speculative_dispatch", []string{"model:" + d.model})
	s.registry.RecordWarmPoolSpeculativeStarted(d.model)

	var backupProvider *registry.Provider
	var backupPR *registry.PendingRequest

	// Do NOT speculatively race a paid PUBLIC backup against a prefer
	// request that is being served by the caller's OWN machine: the user
	// opted into "prefer my machine (free)", so a slow owned machine must
	// be waited on, not raced (and billed) by the public fleet. (Exclusive
	// self-route is already safe — its backup selection is owned-only and
	// returns nil when there's no other owned machine.) When the prefer
	// primary is itself a public provider (the owner owns nothing / fell
	// back), normal speculative behaviour applies.
	skipBackup := false
	if d.policy.prefer {
		provider.Mu().Lock()
		skipBackup = d.policy.ownerAccountID != "" && provider.AccountID == d.policy.ownerAccountID
		provider.Mu().Unlock()
	}

	if !skipBackup {
		backupExclude := make(map[string]struct{}, len(d.excludeProviders)+1)
		for id := range d.excludeProviders {
			backupExclude[id] = struct{}{}
		}
		backupExclude[provider.ID] = struct{}{}

		backupProvider, backupPR, _, _, _ = s.dispatchOneProvider(
			r, d.model, d.publicModel, d.rawBody, d.consumerKey, d.consumerLocation, d.reservedMicroUSD,
			d.estimatedPromptTokens, d.requestedMaxTokens, d.tokenAdmission, d.requiresVision,
			d.traits(),
			d.allowedProviderSerials, d.isResponsesAPI, d.policy,
			&registry.RequestTiming{ReceivedAt: d.timing.ReceivedAt},
			d.serviceReservation,
			d.cacheAffinityKey,
			backupExclude,
		)
	}

	if backupProvider == nil {
		// No backup available. Keep waiting for primary with remaining deadline.
		s.logger.Info("speculative_dispatch_no_backup",
			"request_id", d.requestID,
			"primary_provider", provider.ID,
		)
		return d.waitNoBackup()
	}
	// Backup dispatched — race primary vs backup.
	s.logger.Info("speculative_dispatch",
		"request_id", d.requestID,
		"primary_provider", provider.ID,
		"backup_provider", backupProvider.ID,
		"ttft_deadline_ms", d.deadline.Milliseconds(),
		"speculative_at_ms", d.speculativeAt.Milliseconds(),
	)
	return d.runRace(backupProvider, backupPR)
}

// waitNoBackup is the speculative-no-backup branch (`noBackupWait`): keep waiting
// for the primary alone with the remaining deadline. d.provider / d.pr are the primary.
func (d *dispatchState) waitNoBackup() dispatchOutcome {
	s := d.s
	r := d.r
	provider, pr := d.provider, d.pr

	remainingDeadline := time.NewTimer(d.deadline - d.speculativeAt)
	for {
		select {
		case chunk, ok := <-pr.ChunkCh:
			if ok && len(d.heldChunks) < maxHeldBoilerplate && isBoilerplateChunk(chunk) {
				d.heldChunks = append(d.heldChunks, chunk)
				if pr.Timing.FirstChunkAt.IsZero() {
					pr.Timing.FirstChunkAt = time.Now()
				}
				continue
			}
			remainingDeadline.Stop()
			if ok {
				d.firstChunk = chunk
				if pr.Timing.FirstChunkAt.IsZero() {
					pr.Timing.FirstChunkAt = time.Now()
				}
				d.committed = true
			} else {
				select {
				case errMsg := <-pr.ErrorCh:
					d.excludeProviders[provider.ID] = struct{}{}
					s.cancelDispatch(provider, pr)
					d.lastErr = errMsg.Error
					d.lastErrCode = errMsg.StatusCode
					d.lastFailedVersion = failedProviderVersion(provider)
					d.noteDispatchRetry(provider, pr, errMsg.StatusCode, &d.heldChunks)
					d.provider = nil
					d.pr = nil
					return outcomeRetry
				default:
					d.committed = true
				}
			}
			return outcomeCommitted
		case <-pr.AcceptedCh:
			remainingDeadline.Stop()
			d.accepted = true
			return outcomeAccepted
		case errMsg := <-pr.ErrorCh:
			remainingDeadline.Stop()
			d.excludeProviders[provider.ID] = struct{}{}
			s.cancelDispatch(provider, pr)
			d.lastErr = errMsg.Error
			d.lastErrCode = errMsg.StatusCode
			d.lastFailedVersion = failedProviderVersion(provider)
			if s.metrics != nil {
				s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "retry"})
			}
			d.noteDispatchRetry(provider, pr, errMsg.StatusCode, &d.heldChunks)
			d.provider = nil
			d.pr = nil
			return outcomeRetry
		case <-remainingDeadline.C:
			if len(d.heldChunks) > 0 {
				// Liveness: the provider already produced its preamble —
				// vision prefill / template render may legitimately
				// exceed the TTFT deadline. Fall through to the
				// extended (preambleContentTimeout) wait for first
				// content, with ErrorCh still armed for retry.
				d.accepted = true
				d.preambleLiveness = true
				return outcomeAccepted
			}
			d.excludeProviders[provider.ID] = struct{}{}
			s.registry.RecordWarmPoolTTFTMiss(d.model, d.deadline)
			s.cancelDispatch(provider, pr)
			d.lastErr = "timeout waiting for first response"
			d.lastErrCode = http.StatusGatewayTimeout
			s.logger.Warn("provider timeout (no backup), retrying",
				"request_id", d.requestID,
				"provider_id", provider.ID,
				"attempt", d.attempt+1,
			)
			s.emitRequest(r.Context(), protocol.SeverityWarn, d.requestID,
				"provider first-chunk timeout",
				map[string]any{
					"provider_id": provider.ID,
					"attempt":     d.attempt + 1,
					"reason":      "first_chunk_timeout",
				})
			if s.metrics != nil {
				s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "timeout"})
			}
			s.ddIncr("inference.dispatches", []string{"status:timeout"})
			d.provider = nil
			d.pr = nil
			return outcomeRetry
		case <-r.Context().Done():
			remainingDeadline.Stop()
			s.cancelDispatch(provider, pr)
			d.refundReservation()
			return outcomeClientGone
		}
	}
}

// runRace is the speculative `race` loop: primary (d.provider/d.pr) vs backup,
// first CONTENT chunk wins; the loser is cancelled. Preamble from each racer is
// buffered separately (held chunks must never mix providers). On a racer error the
// surviving racer is waited on via a sub-loop. Returns the waitFirstChunk outcome
// set; on a backup win d.provider/d.pr/d.requestID/d.heldChunks are swapped to the backup.
func (d *dispatchState) runRace(backupProvider *registry.Provider, backupPR *registry.PendingRequest) dispatchOutcome {
	s := d.s
	r := d.r
	provider, pr := d.provider, d.pr

	raceDeadline := time.NewTimer(d.deadline - d.speculativeAt)
	// One-shot extension: when the race deadline expires but a racer
	// has shown liveness (preamble received), the race continues for
	// the full inference window instead of failing the request.
	raceExtended := false
	// Preamble chunks from the backup are buffered separately —
	// held chunks must never mix providers.
	var backupHeld []string

	for {
		select {
		case chunk, ok := <-pr.ChunkCh:
			if ok && len(d.heldChunks) < maxHeldBoilerplate && isBoilerplateChunk(chunk) {
				// Preamble only — the primary hasn't proven it can
				// generate; keep the backup racing for first content.
				d.heldChunks = append(d.heldChunks, chunk)
				if pr.Timing.FirstChunkAt.IsZero() {
					pr.Timing.FirstChunkAt = time.Now()
				}
				continue
			}
			// Primary wins!
			raceDeadline.Stop()
			s.cancelDispatch(backupProvider, backupPR)
			if ok {
				d.firstChunk = chunk
				if pr.Timing.FirstChunkAt.IsZero() {
					pr.Timing.FirstChunkAt = time.Now()
				}
				d.committed = true
			} else {
				select {
				case errMsg := <-pr.ErrorCh:
					// Primary failed but we already cancelled backup.
					d.excludeProviders[provider.ID] = struct{}{}
					s.cancelDispatch(provider, pr)
					d.lastErr = errMsg.Error
					d.lastErrCode = errMsg.StatusCode
					d.lastFailedVersion = failedProviderVersion(provider)
					d.noteDispatchRetry(provider, pr, errMsg.StatusCode, &d.heldChunks)
					d.provider = nil
					d.pr = nil
					return outcomeRetry
				default:
					d.committed = true
				}
			}
			return outcomeCommitted

		case chunk, ok := <-backupPR.ChunkCh:
			if ok && len(backupHeld) < maxHeldBoilerplate && isBoilerplateChunk(chunk) {
				// Backup preamble doesn't win the race — first CONTENT does.
				backupHeld = append(backupHeld, chunk)
				if backupPR.Timing.FirstChunkAt.IsZero() {
					backupPR.Timing.FirstChunkAt = time.Now()
				}
				continue
			}
			// Backup wins!
			raceDeadline.Stop()
			s.cancelDispatch(provider, pr)
			s.ddIncr("inference.speculative_win", []string{"model:" + d.model})
			s.registry.RecordWarmPoolSpeculativeWon(d.model)
			if ok {
				d.provider = backupProvider
				d.pr = backupPR
				d.requestID = d.pr.RequestID
				d.heldChunks = backupHeld
				d.firstChunk = chunk
				if d.pr.Timing.FirstChunkAt.IsZero() {
					d.pr.Timing.FirstChunkAt = time.Now()
				}
				d.committed = true
			} else {
				select {
				case errMsg := <-backupPR.ErrorCh:
					// Backup failed too. Keep primary context for retry.
					d.excludeProviders[backupProvider.ID] = struct{}{}
					d.lastFailedVersion = failedProviderVersion(backupProvider)
					s.noteDispatchProviderError(backupProvider, backupPR, errMsg.StatusCode, &backupHeld)
					// Wait remaining deadline for primary.
					return d.raceBackupChunkClosedWaitPrimary(provider, pr)
				default:
					// Backup channel closed with no error — treat as committed.
					s.cancelDispatch(provider, pr)
					d.provider = backupProvider
					d.pr = backupPR
					d.requestID = d.pr.RequestID
					d.heldChunks = backupHeld
					d.committed = true
				}
			}
			return outcomeCommitted

		case <-pr.AcceptedCh:
			// Primary accepted (model reload). Cancel backup, extend deadline.
			raceDeadline.Stop()
			s.cancelDispatch(backupProvider, backupPR)
			d.accepted = true
			return outcomeAccepted

		case <-backupPR.AcceptedCh:
			// Backup accepted (model reload). Cancel primary, extend deadline.
			raceDeadline.Stop()
			s.cancelDispatch(provider, pr)
			d.provider = backupProvider
			d.pr = backupPR
			d.requestID = d.pr.RequestID
			d.heldChunks = backupHeld
			d.accepted = true
			return outcomeAccepted

		case errMsg := <-pr.ErrorCh:
			// Primary failed. Keep waiting for backup.
			raceDeadline.Stop()
			d.excludeProviders[provider.ID] = struct{}{}
			s.cancelDispatch(provider, pr)
			d.lastFailedVersion = failedProviderVersion(provider)
			s.noteDispatchProviderError(provider, pr, errMsg.StatusCode, &d.heldChunks)
			return d.racePrimaryFailedWaitBackup(backupProvider, backupPR, backupHeld)

		case errMsg := <-backupPR.ErrorCh:
			// Backup failed. Keep waiting for primary.
			raceDeadline.Stop()
			d.excludeProviders[backupProvider.ID] = struct{}{}
			s.cancelDispatch(backupProvider, backupPR)
			d.lastFailedVersion = failedProviderVersion(backupProvider)
			s.noteDispatchProviderError(backupProvider, backupPR, errMsg.StatusCode, &backupHeld)
			return d.raceBackupErrWaitPrimary(provider, pr)

		case <-raceDeadline.C:
			if !raceExtended && (len(d.heldChunks) > 0 || len(backupHeld) > 0) {
				// Liveness from at least one racer: don't fail at the
				// TTFT deadline — extend once by the preamble-to-content
				// budget (zero bytes have reached the client; a genuine
				// cold load would have signalled AcceptedCh) and keep both
				// racing for first content, with both error channels still
				// armed for retry.
				raceExtended = true
				raceDeadline = time.NewTimer(preambleContentTimeout)
				continue
			}
			// Both missed deadline. A racer that held preamble (role
			// then stall) is a 504-shaped sickness — feed the breaker
			// before cancelling, mirroring the single-provider
			// acceptedWait timeout path so a stalling provider/model
			// (shape-keyed) trips its cooldown.
			if len(d.heldChunks) > 0 {
				s.noteInferenceError(provider.ID, pr, http.StatusGatewayTimeout)
			}
			if len(backupHeld) > 0 {
				s.noteInferenceError(backupProvider.ID, backupPR, http.StatusGatewayTimeout)
			}
			s.cancelDispatch(provider, pr)
			s.registry.RecordWarmPoolTTFTMiss(d.model, d.deadline)
			s.cancelDispatch(backupProvider, backupPR)
			d.excludeProviders[provider.ID] = struct{}{}
			d.excludeProviders[backupProvider.ID] = struct{}{}
			d.lastErr = "timeout waiting for first response (both providers)"
			d.lastErrCode = http.StatusGatewayTimeout
			if s.metrics != nil {
				s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "timeout"})
			}
			s.ddIncr("inference.dispatches", []string{"status:timeout"})
			d.provider = nil
			d.pr = nil
			return outcomeRetry

		case <-r.Context().Done():
			raceDeadline.Stop()
			s.cancelDispatch(provider, pr)
			s.cancelDispatch(backupProvider, backupPR)
			d.refundReservation()
			return outcomeClientGone
		}
	}
}

// raceBackupChunkClosedWaitPrimary handles the race sub-case where the backup's
// ChunkCh closed with an error (already recorded by the caller): wait the
// remaining deadline for the primary. This is the former `backupFailedPrimaryWait`
// loop. d.provider/d.pr remain the primary throughout (the backup already lost).
func (d *dispatchState) raceBackupChunkClosedWaitPrimary(provider *registry.Provider, pr *registry.PendingRequest) dispatchOutcome {
	s := d.s
	r := d.r
	remainingPrimary := time.NewTimer(d.deadline - d.speculativeAt)
	for {
		select {
		case chunk, ok := <-pr.ChunkCh:
			if ok && len(d.heldChunks) < maxHeldBoilerplate && isBoilerplateChunk(chunk) {
				d.heldChunks = append(d.heldChunks, chunk)
				if pr.Timing.FirstChunkAt.IsZero() {
					pr.Timing.FirstChunkAt = time.Now()
				}
				continue
			}
			remainingPrimary.Stop()
			if ok {
				d.firstChunk = chunk
				if pr.Timing.FirstChunkAt.IsZero() {
					pr.Timing.FirstChunkAt = time.Now()
				}
				d.committed = true
			} else {
				select {
				case errMsg2 := <-pr.ErrorCh:
					d.excludeProviders[provider.ID] = struct{}{}
					s.cancelDispatch(provider, pr)
					d.lastErr = errMsg2.Error
					d.lastErrCode = errMsg2.StatusCode
					d.lastFailedVersion = failedProviderVersion(provider)
					d.noteDispatchRetry(provider, pr, errMsg2.StatusCode, &d.heldChunks)
					d.provider = nil
					d.pr = nil
					return outcomeRetry
				default:
					d.committed = true
				}
			}
			return outcomeCommitted
		case <-pr.AcceptedCh:
			remainingPrimary.Stop()
			d.accepted = true
			return outcomeAccepted
		case errMsg2 := <-pr.ErrorCh:
			// Defensive: both ErrorCh senders currently send before
			// closing ChunkCh (the closed-ChunkCh check above catches
			// them), but a direct arm keeps this loop correct if that
			// ordering ever changes — mirroring its sibling wait loops.
			remainingPrimary.Stop()
			d.excludeProviders[provider.ID] = struct{}{}
			s.cancelDispatch(provider, pr)
			d.lastErr = errMsg2.Error
			d.lastErrCode = errMsg2.StatusCode
			d.lastFailedVersion = failedProviderVersion(provider)
			d.noteDispatchRetry(provider, pr, errMsg2.StatusCode, &d.heldChunks)
			d.provider = nil
			d.pr = nil
			return outcomeRetry
		case <-remainingPrimary.C:
			if len(d.heldChunks) > 0 {
				// Primary preamble liveness — extend to the
				// preamble-to-content budget instead of failing.
				d.accepted = true
				d.preambleLiveness = true
				return outcomeAccepted
			}
			// The PRIMARY timed out here (the backup's earlier error
			// is already recorded); report the timeout, not the
			// backup's stale error text.
			d.excludeProviders[provider.ID] = struct{}{}
			s.registry.RecordWarmPoolTTFTMiss(d.model, d.deadline)
			s.cancelDispatch(provider, pr)
			d.lastErr = "timeout waiting for first response"
			d.lastErrCode = http.StatusGatewayTimeout
			if s.metrics != nil {
				s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "timeout"})
			}
			s.ddIncr("inference.dispatches", []string{"status:timeout"})
			d.provider = nil
			d.pr = nil
			return outcomeRetry
		case <-r.Context().Done():
			remainingPrimary.Stop()
			s.cancelDispatch(provider, pr)
			d.refundReservation()
			return outcomeClientGone
		}
	}
}

// racePrimaryFailedWaitBackup handles the race sub-case where the primary errored
// (already recorded): wait the remaining deadline for the backup, promoting it to
// the committed/accepted provider on success. This is the former
// `primaryFailedBackupWait` loop.
func (d *dispatchState) racePrimaryFailedWaitBackup(backupProvider *registry.Provider, backupPR *registry.PendingRequest, backupHeld []string) dispatchOutcome {
	s := d.s
	r := d.r
	backupDeadline := time.NewTimer(d.deadline - d.speculativeAt)
	for {
		select {
		case chunk, ok := <-backupPR.ChunkCh:
			if ok && len(backupHeld) < maxHeldBoilerplate && isBoilerplateChunk(chunk) {
				backupHeld = append(backupHeld, chunk)
				if backupPR.Timing.FirstChunkAt.IsZero() {
					backupPR.Timing.FirstChunkAt = time.Now()
				}
				continue
			}
			backupDeadline.Stop()
			if ok {
				d.provider = backupProvider
				d.pr = backupPR
				d.requestID = d.pr.RequestID
				d.heldChunks = backupHeld
				d.firstChunk = chunk
				if d.pr.Timing.FirstChunkAt.IsZero() {
					d.pr.Timing.FirstChunkAt = time.Now()
				}
				d.committed = true
			} else {
				select {
				case errMsg2 := <-backupPR.ErrorCh:
					d.excludeProviders[backupProvider.ID] = struct{}{}
					s.cancelDispatch(backupProvider, backupPR)
					d.lastErr = errMsg2.Error
					d.lastErrCode = errMsg2.StatusCode
					d.lastFailedVersion = failedProviderVersion(backupProvider)
					d.noteDispatchRetry(backupProvider, backupPR, errMsg2.StatusCode, &backupHeld)
					d.provider = nil
					d.pr = nil
					return outcomeRetry
				default:
					d.provider = backupProvider
					d.pr = backupPR
					d.requestID = d.pr.RequestID
					d.heldChunks = backupHeld
					d.committed = true
				}
			}
			return outcomeCommitted
		case <-backupPR.AcceptedCh:
			backupDeadline.Stop()
			d.provider = backupProvider
			d.pr = backupPR
			d.requestID = d.pr.RequestID
			d.heldChunks = backupHeld
			d.accepted = true
			return outcomeAccepted
		case errMsg2 := <-backupPR.ErrorCh:
			backupDeadline.Stop()
			d.excludeProviders[backupProvider.ID] = struct{}{}
			s.cancelDispatch(backupProvider, backupPR)
			d.lastErr = errMsg2.Error
			d.lastErrCode = errMsg2.StatusCode
			d.lastFailedVersion = failedProviderVersion(backupProvider)
			s.noteDispatchProviderError(backupProvider, backupPR, errMsg2.StatusCode, &backupHeld)
			d.provider = nil
			d.pr = nil
			return outcomeRetry
		case <-backupDeadline.C:
			if len(backupHeld) > 0 {
				// Backup preamble liveness — promote it and extend
				// by the preamble-to-content budget for first content.
				d.provider = backupProvider
				d.pr = backupPR
				d.requestID = d.pr.RequestID
				d.heldChunks = backupHeld
				d.accepted = true
				d.preambleLiveness = true
				return outcomeAccepted
			}
			d.excludeProviders[backupProvider.ID] = struct{}{}
			s.registry.RecordWarmPoolTTFTMiss(d.model, d.deadline)
			s.cancelDispatch(backupProvider, backupPR)
			d.lastErr = "timeout waiting for first response (backup)"
			d.lastErrCode = http.StatusGatewayTimeout
			if s.metrics != nil {
				s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "timeout"})
			}
			s.ddIncr("inference.dispatches", []string{"status:timeout"})
			d.provider = nil
			d.pr = nil
			return outcomeRetry
		case <-r.Context().Done():
			backupDeadline.Stop()
			s.cancelDispatch(backupProvider, backupPR)
			d.refundReservation()
			return outcomeClientGone
		}
	}
}

// raceBackupErrWaitPrimary handles the race sub-case where the backup errored
// (already recorded): wait the remaining deadline for the primary. This is the
// former `backupFailedWaitPrimary` loop. d.provider/d.pr remain the primary.
func (d *dispatchState) raceBackupErrWaitPrimary(provider *registry.Provider, pr *registry.PendingRequest) dispatchOutcome {
	s := d.s
	r := d.r
	primaryDeadline := time.NewTimer(d.deadline - d.speculativeAt)
	for {
		select {
		case chunk, ok := <-pr.ChunkCh:
			if ok && len(d.heldChunks) < maxHeldBoilerplate && isBoilerplateChunk(chunk) {
				d.heldChunks = append(d.heldChunks, chunk)
				if pr.Timing.FirstChunkAt.IsZero() {
					pr.Timing.FirstChunkAt = time.Now()
				}
				continue
			}
			primaryDeadline.Stop()
			if ok {
				d.firstChunk = chunk
				if pr.Timing.FirstChunkAt.IsZero() {
					pr.Timing.FirstChunkAt = time.Now()
				}
				d.committed = true
			} else {
				select {
				case errMsg2 := <-pr.ErrorCh:
					d.excludeProviders[provider.ID] = struct{}{}
					s.cancelDispatch(provider, pr)
					d.lastErr = errMsg2.Error
					d.lastErrCode = errMsg2.StatusCode
					d.lastFailedVersion = failedProviderVersion(provider)
					d.noteDispatchRetry(provider, pr, errMsg2.StatusCode, &d.heldChunks)
					d.provider = nil
					d.pr = nil
					return outcomeRetry
				default:
					d.committed = true
				}
			}
			return outcomeCommitted
		case <-pr.AcceptedCh:
			primaryDeadline.Stop()
			d.accepted = true
			return outcomeAccepted
		case errMsg2 := <-pr.ErrorCh:
			primaryDeadline.Stop()
			d.excludeProviders[provider.ID] = struct{}{}
			s.cancelDispatch(provider, pr)
			d.lastErr = errMsg2.Error
			d.lastErrCode = errMsg2.StatusCode
			d.lastFailedVersion = failedProviderVersion(provider)
			s.noteDispatchProviderError(provider, pr, errMsg2.StatusCode, &d.heldChunks)
			d.provider = nil
			d.pr = nil
			return outcomeRetry
		case <-primaryDeadline.C:
			if len(d.heldChunks) > 0 {
				// Primary preamble liveness — extend by the
				// preamble-to-content budget instead of failing.
				d.accepted = true
				d.preambleLiveness = true
				return outcomeAccepted
			}
			d.excludeProviders[provider.ID] = struct{}{}
			s.registry.RecordWarmPoolTTFTMiss(d.model, d.deadline)
			s.cancelDispatch(provider, pr)
			d.lastErr = "timeout waiting for first response"
			d.lastErrCode = http.StatusGatewayTimeout
			if s.metrics != nil {
				s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "timeout"})
			}
			s.ddIncr("inference.dispatches", []string{"status:timeout"})
			d.provider = nil
			d.pr = nil
			return outcomeRetry
		case <-r.Context().Done():
			primaryDeadline.Stop()
			s.cancelDispatch(provider, pr)
			d.refundReservation()
			return outcomeClientGone
		}
	}
}

// waitAccepted runs the post-accept wait for first content (the former
// `acceptedWait` loop). It is entered when the committed provider accepted or held
// preamble but hasn't produced content yet. The budget depends on WHY we're here:
// a genuine AcceptedCh (model reload — legitimately minutes) keeps the full
// inferenceTimeout; a boilerplate-liveness extension past an expired TTFT deadline
// gets only preambleContentTimeout (zero bytes written to the client, so a
// preamble-then-stall provider must fail over instead of pinning for 10 minutes).
func (d *dispatchState) waitAccepted() dispatchOutcome {
	s := d.s
	r := d.r
	provider, pr := d.provider, d.pr

	firstContentBudget := inferenceTimeout
	if d.preambleLiveness {
		firstContentBudget = preambleContentTimeout
	}
	chunkTimer := time.NewTimer(firstContentBudget)
	for {
		select {
		case chunk, ok := <-pr.ChunkCh:
			if ok && len(d.heldChunks) < maxHeldBoilerplate && isBoilerplateChunk(chunk) {
				d.heldChunks = append(d.heldChunks, chunk)
				if pr.Timing.FirstChunkAt.IsZero() {
					pr.Timing.FirstChunkAt = time.Now()
				}
				continue
			}
			chunkTimer.Stop()
			if ok {
				d.firstChunk = chunk
				if pr.Timing.FirstChunkAt.IsZero() {
					pr.Timing.FirstChunkAt = time.Now()
				}
				d.committed = true
			} else {
				// Closed — check for error. Use a short grace
				// period instead of a non-blocking default to
				// close the race where Go's select picks the
				// ChunkCh close before the ErrorCh value (sent
				// by the provider handler before closing ChunkCh).
				select {
				case errMsg := <-pr.ErrorCh:
					d.excludeProviders[provider.ID] = struct{}{}
					s.cancelDispatch(provider, pr)
					d.lastErr = errMsg.Error
					d.lastErrCode = errMsg.StatusCode
					d.lastFailedVersion = failedProviderVersion(provider)
					s.logger.Warn("provider failed after accepting request, retrying",
						"request_id", d.requestID,
						"provider_id", provider.ID,
						"attempt", d.attempt+1,
						"error", errMsg.Error,
					)
					s.emitRequest(r.Context(), protocol.SeverityWarn, d.requestID,
						"provider failed after accepting request, retrying",
						map[string]any{
							"provider_id": provider.ID,
							"attempt":     d.attempt + 1,
							"reason":      "provider_error",
							"status_code": errMsg.StatusCode,
						})
					if s.metrics != nil {
						s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "retry"})
					}
					d.noteDispatchRetry(provider, pr, errMsg.StatusCode, &d.heldChunks)
					d.provider = nil
					d.pr = nil
					return outcomeRetry
				case <-time.After(50 * time.Millisecond):
					d.committed = true
				}
			}
			return outcomeCommitted
		case errMsg := <-pr.ErrorCh:
			chunkTimer.Stop()
			d.excludeProviders[provider.ID] = struct{}{}
			s.cancelDispatch(provider, pr)
			d.lastErr = errMsg.Error
			d.lastErrCode = errMsg.StatusCode
			d.lastFailedVersion = failedProviderVersion(provider)
			s.logger.Warn("provider failed after accepting request, retrying",
				"request_id", d.requestID,
				"provider_id", provider.ID,
				"attempt", d.attempt+1,
				"error", errMsg.Error,
			)
			s.emitRequest(r.Context(), protocol.SeverityWarn, d.requestID,
				"provider failed after accepting request, retrying",
				map[string]any{
					"provider_id": provider.ID,
					"attempt":     d.attempt + 1,
					"reason":      "provider_error",
					"status_code": errMsg.StatusCode,
				})
			if s.metrics != nil {
				s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "retry"})
			}
			d.noteDispatchRetry(provider, pr, errMsg.StatusCode, &d.heldChunks)
			d.provider = nil
			d.pr = nil
			return outcomeRetry
		case <-chunkTimer.C:
			d.excludeProviders[provider.ID] = struct{}{}
			s.registry.RecordWarmPoolTTFTMiss(d.model, firstContentBudget)
			s.cancelDispatch(provider, pr)
			// Accepted-then-silent (or preamble-then-stall) is a
			// provider-at-fault 504 — feed the breaker so a provider
			// that repeatedly acks and stalls enters cooldown instead
			// of soaking retries forever. (504 is one of the breaker's
			// counted codes; this arm is where those 504s originate.)
			s.noteInferenceError(provider.ID, pr, http.StatusGatewayTimeout)
			d.lastErr = "provider accepted but timed out before first chunk"
			if d.preambleLiveness {
				d.lastErr = "provider sent preamble but stalled before first content"
			}
			d.lastErrCode = http.StatusGatewayTimeout
			s.logger.Warn("provider timed out after accepting request, retrying",
				"request_id", d.requestID,
				"provider_id", provider.ID,
				"attempt", d.attempt+1,
				"preamble_liveness", d.preambleLiveness,
			)
			s.emitRequest(r.Context(), protocol.SeverityWarn, d.requestID,
				"provider accepted timeout",
				map[string]any{
					"provider_id": provider.ID,
					"attempt":     d.attempt + 1,
					"reason":      "accepted_timeout",
				})
			if s.metrics != nil {
				s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "timeout"})
			}
			s.ddIncr("inference.dispatches", []string{"status:timeout"})
			d.provider = nil
			d.pr = nil
			return outcomeRetry
		case <-r.Context().Done():
			s.cancelDispatch(provider, pr)
			d.refundReservation()
			return outcomeClientGone
		}
	}
}

// run is the dispatch orchestrator. It replaces the giant inline `for attempt :=
// range maxDispatchAttempts { ... }` block plus the post-loop !committed ladder,
// attestation headers, timing header, settlement defer, and final response handoff.
func (d *dispatchState) run() {
	s := d.s
	w, r := d.w, d.r

	for attempt := range maxDispatchAttempts {
		d.attempt = attempt
		// Each attempt holds preamble chunks from its own provider only.
		d.heldChunks = nil

		switch d.dispatchPrimary() {
		case outcomeRetry:
			continue
		case outcomeFailFast:
			goto exhausted
		case outcomeResponseWritten, outcomeClientGone:
			return
		case outcomeProceed:
			// fall through to the first-chunk wait below
		}

		d.requestID = d.pr.RequestID
		if d.timing.RoutedAt.IsZero() {
			d.timing.RoutedAt = time.Now()
		}
		s.ddIncr("routing.decisions", []string{"model:" + d.model, "outcome:selected"})
		s.ddIncr("routing.provider_selected", []string{"provider_id:" + d.provider.ID, "model:" + d.model})

		s.logger.Info("inference request dispatched",
			"trace_id", requestIDFromContext(r.Context()),
			"request_id", d.requestID,
			"model", d.model,
			"provider_id", d.provider.ID,
			"stream", d.stream,
			"attempt", attempt+1,
		)

		s.logger.Info("dispatch_pool",
			"model", d.model,
			"ttft_deadline_ms", d.deadline.Milliseconds(),
			"speculative_at_ms", d.speculativeAt.Milliseconds(),
		)

		// ---- Speculative TTFT-aware first-chunk wait ----
		switch d.waitFirstChunk() {
		case outcomeRetry:
			continue
		case outcomeClientGone:
			return
		case outcomeAccepted:
			// Provider accepted or held preamble but hasn't produced content.
			switch d.waitAccepted() {
			case outcomeRetry:
				continue
			case outcomeClientGone:
				return
			}
		}

		break
	}

exhausted:
	if !d.committed {
		d.refundReservation()
		statusCode := d.lastErrCode
		if statusCode == 0 {
			// Distinguish capacity exhaustion (429) from genuine unavailability (503).
			// A quick capacity check tells us if providers exist but are full.
			_, capRej, _ := s.registry.QuickCapacityCheckForRequest(d.model, d.estimatedPromptTokens, d.requestedMaxTokens, registry.RequestTraits{HasTools: d.hasTools}, d.requiresVision, d.allowedProviderSerials...)
			if capRej > 0 {
				statusCode = http.StatusTooManyRequests
			} else {
				statusCode = http.StatusServiceUnavailable
			}
		}
		s.emitRequest(r.Context(), protocol.SeverityError, d.requestID,
			fmt.Sprintf("inference failed after %d attempt(s)", maxDispatchAttempts),
			map[string]any{
				"reason":      "dispatch_exhausted",
				"attempt":     maxDispatchAttempts,
				"status_code": statusCode,
				"last_error":  d.lastErr,
			})
		if s.metrics != nil {
			s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "failure"})
		}
		s.ddIncr("inference.dispatches", []string{"status:failure"})
		if statusCode == http.StatusTooManyRequests || statusCode == http.StatusServiceUnavailable {
			w.Header().Set("Retry-After", strconv.Itoa(s.estimateRetryAfter(d.model)))
		}
		if statusCode == http.StatusTooManyRequests {
			writeJSON(w, statusCode, errorResponse("rate_limit_exceeded",
				fmt.Sprintf("all providers at capacity after %d attempt(s): %s", maxDispatchAttempts, d.lastErr),
				withCode("rate_limit_exceeded")))
		} else {
			writeJSON(w, statusCode, errorResponse("provider_error",
				fmt.Sprintf("inference failed after %d attempt(s): %s", maxDispatchAttempts, d.lastErr)))
		}
		return
	}
	if s.metrics != nil {
		s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "success"})
	}
	s.ddIncr("inference.dispatches", []string{"status:success"})

	d.writeCommittedResponse()
}

// writeCommittedResponse writes the provider attestation + timing headers, installs
// the park-before-remove settlement defer, and hands off to the streaming /
// non-streaming response writer. Extracted verbatim from the committed tail of the
// original handler.
// contentLatency is the time from dispatch to the first CONTENT chunk delivered
// to the client (FirstContentAt). It deliberately does NOT fall back to
// FirstChunkAt — that timestamp is also stamped on held role-only / lifecycle
// preamble, so using it would let a fast-preamble-then-stall provider (or a
// preamble-only clean close that produced no content) look artificially
// responsive. Returns 0 when no content was delivered or the timing is
// incomplete, which the caller treats as "no sample".
func contentLatency(t *registry.RequestTiming) time.Duration {
	if t == nil || t.DispatchedAt.IsZero() || t.FirstContentAt.IsZero() {
		return 0
	}
	if d := t.FirstContentAt.Sub(t.DispatchedAt); d > 0 {
		return d
	}
	return 0
}

// adjustLatencyForPrefill turns a raw time-to-first-content into the reputation
// latency sample by removing the prompt-size-dependent prefill. Time-to-first-
// token grows with the input length, so a provider serving long prompts would
// otherwise look slow purely because of its workload. Using the provider's own
// benchmarked prefill rate keeps the correction per-provider and free of
// hard-coded constants; what remains approximates queueing, scheduling,
// model-load and first-decode overhead. Returns 0 when there is no usable sample
// (which RecordLatency ignores), including when the prefill estimate exceeds the
// measured latency.
func adjustLatencyForPrefill(raw time.Duration, promptTokens int, prefillTPS float64) time.Duration {
	if raw <= 0 {
		return 0
	}
	if promptTokens > 0 && prefillTPS > 0 {
		raw -= time.Duration(float64(promptTokens) / prefillTPS * float64(time.Second))
	}
	if raw <= 0 {
		return 0
	}
	return raw
}

func (d *dispatchState) writeCommittedResponse() {
	s := d.s
	w, r := d.w, d.r
	provider, pr, requestID := d.provider, d.pr, d.requestID

	// Record the provider responsiveness sample here, in the goroutine that OWNS
	// pr.Timing. handleComplete runs in the provider read-loop goroutine and could
	// race this goroutine's timing writes, so the latency must be recorded from
	// here rather than handed across. d.firstChunk is non-empty only when an actual
	// content chunk was received — a preamble-then-clean-close commits with no
	// content, so FirstContentAt stays zero and no sample is recorded. The
	// prompt-size prefill is removed using the coordinator-side prompt estimate
	// (known up front, adequate for normalization) and the provider's benchmarked
	// PrefillTPS (set once at registration, read-only thereafter).
	if pr.Timing != nil && d.firstChunk != "" {
		if pr.Timing.FirstContentAt.IsZero() {
			pr.Timing.FirstContentAt = time.Now()
		}
		sample := adjustLatencyForPrefill(contentLatency(pr.Timing), pr.EstimatedPromptTokens, provider.PrefillTPS)
		s.registry.RecordLatency(provider.ID, sample)
	}

	// Write provider attestation headers now that we're committed.
	provider.Mu().Lock()
	pubKey := provider.PublicKey
	attested := provider.Attested
	trustLevel := provider.TrustLevel
	attestResult := provider.AttestationResult
	mdaVerified := provider.MDAVerified
	provider.Mu().Unlock()

	providerID := provider.ID
	chipName := provider.Hardware.ChipName
	machineModel := provider.Hardware.MachineModel
	s.registry.RecordCacheAffinity(pr.ConsumerKey, pr.Model, pr.CacheAffinityKey, providerID)

	if pubKey != "" {
		w.Header().Set("X-Provider-Encrypted", "true")
	}
	if attested {
		w.Header().Set("X-Provider-Attested", "true")
	} else {
		w.Header().Set("X-Provider-Attested", "false")
	}
	w.Header().Set("X-Provider-Trust-Level", string(trustLevel))
	w.Header().Set("X-Provider-Id", providerID)
	w.Header().Set("X-Provider-Chip", chipName)
	w.Header().Set("X-Provider-Model", machineModel)
	if attestResult != nil {
		w.Header().Set("X-Provider-Serial", attestResult.SerialNumber)
		if attestResult.SecureEnclaveAvailable {
			w.Header().Set("X-Provider-Secure-Enclave", "true")
		} else {
			w.Header().Set("X-Provider-Secure-Enclave", "false")
		}
	}
	if mdaVerified {
		w.Header().Set("X-Provider-Mda-Verified", "true")
	}
	// SE public key for attestation receipt verification.
	// Consumers can use this to verify SE signatures on response hashes.
	if attestResult != nil && attestResult.PublicKey != "" {
		w.Header().Set("X-Attestation-Se-Public-Key", attestResult.PublicKey)
		w.Header().Set("X-Attestation-Device-Serial", attestResult.SerialNumber)
	}

	// Latency decomposition header for observability.
	if timing := pr.Timing; timing != nil {
		type timingJSON struct {
			ParseUs    int64 `json:"parse_us"`
			ReserveUs  int64 `json:"reserve_us"`
			RouteUs    int64 `json:"route_us"`
			QueueUs    int64 `json:"queue_us"`
			EncryptUs  int64 `json:"encrypt_us"`
			DispatchUs int64 `json:"dispatch_us"`
			ProviderUs int64 `json:"provider_us"`
		}
		tj := timingJSON{}
		if !timing.ParsedAt.IsZero() {
			tj.ParseUs = timing.ParsedAt.Sub(timing.ReceivedAt).Microseconds()
		}
		if !timing.ReservedAt.IsZero() && !timing.ParsedAt.IsZero() {
			tj.ReserveUs = timing.ReservedAt.Sub(timing.ParsedAt).Microseconds()
		}
		if !timing.RoutedAt.IsZero() && !timing.ReservedAt.IsZero() {
			tj.RouteUs = timing.RoutedAt.Sub(timing.ReservedAt).Microseconds()
		}
		if !timing.QueuedAt.IsZero() && !timing.DispatchedAt.IsZero() {
			tj.QueueUs = timing.DispatchedAt.Sub(timing.QueuedAt).Microseconds()
		}
		if !timing.EncryptedAt.IsZero() && !timing.RoutedAt.IsZero() {
			tj.EncryptUs = timing.EncryptedAt.Sub(timing.RoutedAt).Microseconds()
		}
		if !timing.DispatchedAt.IsZero() && !timing.EncryptedAt.IsZero() {
			tj.DispatchUs = timing.DispatchedAt.Sub(timing.EncryptedAt).Microseconds()
		}
		if !timing.FirstChunkAt.IsZero() && !timing.DispatchedAt.IsZero() {
			tj.ProviderUs = timing.FirstChunkAt.Sub(timing.DispatchedAt).Microseconds()
		}
		if tjJSON, err := json.Marshal(tj); err == nil {
			w.Header().Set("X-Timing", string(tjJSON))
		}
	}

	// On return (disconnect/timeout/completion): free the slot, tell the
	// provider to stop, and preserve billing for a mid-stream disconnect.
	// Park BEFORE RemovePending so a racing provider terminal always finds the
	// record in pending or the holder — never neither (which would drop it and
	// mis-refund). GetPending is nil if a terminal already settled it (normal
	// completion), so nothing is parked then. Both settle paths are
	// FinalizeReservation-guarded, so the park-then-remove overlap can't double-bill.
	defer func() {
		if stale := provider.GetPending(requestID); stale != nil {
			s.holdForSettlement(stale)
		} else {
			// A terminal already claimed the pending. In every normal path the
			// reservation is finalized by now (completion billed it, the relay
			// error/timeout branches refunded it) and this is a no-op. The one
			// exception is a provider error landing in the gap between this
			// handler abandoning its channels and this defer running: that
			// terminal pushed into an unread ErrorCh and nobody settled — sweep
			// it here. Post-commit only, so it can never finalize a reservation
			// the dispatch loop still needs for a retry attempt.
			refundPr := pr
			saferun.Go(s.logger, "api.postTerminalSweep", func() {
				s.refundReservedBalance(refundPr, "post_terminal_sweep:"+requestID)
			})
		}
		provider.RemovePending(requestID) // then remove so SetProviderIdle frees the slot
		s.registry.SetProviderIdle(provider.ID)
		s.sendProviderCancel(provider, requestID)
	}()

	// The committed provider's held preamble chunks stream out first, in
	// arrival order, ahead of the content chunk that committed the dispatch.
	firstChunks := d.heldChunks
	if d.firstChunk != "" {
		firstChunks = append(firstChunks, d.firstChunk)
	}
	if d.stream {
		s.handleStreamingResponseWithFirstChunk(w, r, pr, firstChunks)
	} else {
		s.handleNonStreamingResponseWithFirstChunk(w, r, pr, firstChunks)
	}
}
