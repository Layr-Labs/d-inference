package dispatch

import (
	"context"
	"errors"
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	inreq "github.com/eigeninference/d-inference/coordinator/api/inference/request"
	"github.com/eigeninference/d-inference/coordinator/api/promptwork"
	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	backoff "github.com/eigeninference/d-inference/coordinator/internal/inference/backoff"
	firstcontent "github.com/eigeninference/d-inference/coordinator/internal/inference/firstcontent"
	promotions "github.com/eigeninference/d-inference/coordinator/internal/inference/promotions"
	providerwire "github.com/eigeninference/d-inference/coordinator/internal/inference/providerwire"
	scangate "github.com/eigeninference/d-inference/coordinator/internal/inference/scangate"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

// dispatchWithReserver is the single prepare/encrypt/write funnel behind every
// provider dispatch: pending construction and admission stamps, the pluggable
// reservation, the billing surcharge, E2E encryption, and the
// deadline-bounded provider write, with releaseUnsentDispatch cleanup on every
// failure path. onDispatched (nil-safe) fires only after the writer confirms
// final authorization and socket handoff. Rejected preparations neither retain
// DispatchedAt nor increment providerDispatches or dispatched profile attempts.
func (s *Dispatcher) Dispatch(
	r *http.Request,
	model string,
	publicModel string,
	rawBody []byte,
	consumerKey string,
	consumerLocation *store.ProviderLocation,
	reservedMicroUSD int64,
	estimatedPromptTokens int,
	requestDeadline time.Duration,
	requestedMaxTokens int,
	tokenAdmission registry.TokenAdmission,
	requiresVision bool,
	traits registry.RequestTraits,
	allowedProviderSerials []string,
	isResponsesAPI bool,
	policy Scope,
	timing *registry.RequestTiming,
	serviceReservation bool,
	cachePlan registry.CachePlan,
	excludeProviders Exclusions,
	attempt int,
	rp *registry.RequestProfile,
	backupOf string,
	recordRoute RouteRecorder,
	onDispatched func(),
	fullScan bool,
	reserve Reserver,
) (
	provider *registry.Provider,
	pr *registry.PendingRequest,
	decision registry.RoutingDecision,
	plan *registry.DispatchPlan,
	lastErr string,
	lastErrCode int,
) {
	receivedAt := firstcontent.TimingReceivedAt(timing)
	_, dispatchable := firstcontent.FirstContentBudgetMillis(receivedAt, requestDeadline)
	if !dispatchable {
		return nil, nil, decision, nil, providerwire.DeadlineExpiredMessage, http.StatusGatewayTimeout
	}

	requestID := uuid.New().String()
	ap := rp.NewAttempt(requestID, attempt, backupOf)
	s.recordPolicy(ap, policy, requiresVision)
	ap.Mark(registry.StampAttemptStart)
	// Any failure return closes the attempt as not dispatched (terminal half; the handler half lands in finalizeProfile);
	// a dispatched attempt is left for the provider terminal / relay to close.
	defer func() {
		if provider == nil {
			s.closeAttempt(ap, lastErr, lastErrCode)
		}
	}()
	pr = &registry.PendingRequest{
		RequestID: requestID,
		Profile:   ap,
		// Attempt is stamped at construction — BEFORE the request is encrypted
		// and sent to the provider — so a fast provider that returns
		// inference_complete immediately is correlated to the right route row.
		// Setting it after the send (on the dispatch goroutine) would race the
		// provider WS reader goroutine's handleComplete read of pr.Attempt.
		Attempt:                  attempt,
		Model:                    model,
		PublicModel:              publicModel,
		ConsumerKey:              consumerKey,
		KeyID:                    access.KeyIDFromContext(r.Context()),
		KeyLimitMicroUSD:         access.KeyLimitMicroFromContext(r.Context()),
		KeyLimitReset:            access.KeyLimitResetFromContext(r.Context()),
		ConsumerLocation:         consumerLocation,
		IsResponsesAPI:           isResponsesAPI,
		EstimatedPromptTokens:    estimatedPromptTokens,
		FirstContentPromptTokens: s.calibration.ContextPromptTokens(model, estimatedPromptTokens),
		PromptWork:               promptwork.ForAttempt(r.Context(), model, rawBody, s.calibration.ContextPromptTokens(model, estimatedPromptTokens)),
		RequiresVision:           requiresVision,
		Traits:                   traits,
		RequestedMaxTokens:       requestedMaxTokens,
		TokenAdmission:           tokenAdmission,
		CachePlan:                cachePlan,
		ReservedMicroUSD:         reservedMicroUSD,
		BaseReservedMicroUSD:     reservedMicroUSD,
		ServiceReservation:       serviceReservation,
		AllowedProviderSerials:   allowedProviderSerials,
		SelfRouteOnly:            policy.SelfRouteOnly,
		PreferOwner:              policy.PreferOwner,
		OwnerAccountID:           policy.OwnerAccountID,
		FreeSelfRoute:            policy.SelfRouteOnly,
		MetadataDetails:          inreq.MetadataDetailsFromRequest(r),
		AcceptedCh:               make(chan struct{}, 1),
		ChunkCh:                  make(chan registry.ProviderChunk, ChunkBufferSize),
		CompleteCh:               make(chan protocol.UsageInfo, 1),
		ErrorCh:                  make(chan protocol.InferenceErrorMessage, 1),
		Timing:                   timing,
	}
	promotions.StampReservation(pr, promotions.Reservation(r))
	if !receivedAt.IsZero() && requestDeadline > 0 {
		pr.FirstContentDeadline = receivedAt.Add(requestDeadline)
	}

	// Selected accounts on public routes (not self-route / prefer-owner)
	// enforce the OpenRouter TTFT ceiling inside the scheduler. Exempt accounts
	// have a zero requestDeadline and therefore no predictive ceiling. This makes the preflight
	// check authoritative: the router cannot select a provider whose estimated
	// TTFT is above the threshold.
	// Routing v2 (P1 fix): only enforce the TTFT ceiling inside the scheduler when
	// the HARD gate is on. In soft mode (default) MaxTTFTMs stays 0 so the primary
	// dispatch serves the best-available provider instead of re-rejecting an
	// over-threshold request the preflight already chose to soft-serve. (Mirrors
	// queueMaxTTFTMs, which already returns 0 in soft mode.)
	if !policy.SelfRouteOnly && !policy.PreferOwner &&
		s.hardTTFTGate(requiresVision) {
		pr.MaxTTFTMs = float64(requestDeadline.Milliseconds())
	}
	// Refresh immediately before reservation: every retry spends the same
	// absolute clock, so the scheduler must never see the original ceiling.
	if !pr.RefreshFirstContentBudget(time.Now()) {
		return nil, nil, decision, nil, providerwire.DeadlineExpiredMessage, http.StatusGatewayTimeout
	}
	// Routing v2 W2: soft per-request decode floor (0 = off). Applies to all
	// routes; it only ranks providers, never rejects.
	pr.MinDecodeTPS = s.minDecodeTPS

	excludeList := excludeProviders.IDs

	// noteSelectionSample feeds the attempt-0 route-latency distress EWMA
	// behind estimateRetryAfter (2026-09-01: route p50 40ms → 4.6s while the
	// empty-queue heuristic kept answering "retry in 2s"). Anchored exactly
	// where applyTimingDecomposition anchors route_ms (MediaFetchedAt when
	// set, else ReservedAt) so a multi-second media download or slow body
	// parse can never masquerade as routing distress. Called on BOTH the
	// successful reservation (at the RoutedAt stamp) and every failed
	// attempt-0 selection (semaphore acquisition timeout, scan that yields no
	// provider): under TOTAL overload no selection ever succeeds, and an
	// EWMA fed only by successes would sit at 0 — keeping Retry-After at the
	// legacy 2s exactly when distress scaling matters most.
	noteSelectionSample := func() {
		if attempt != 0 {
			return
		}
		if anchor := backoff.RouteAnchor(timing); !anchor.IsZero() {
			s.backoff.NoteRouteLatency(time.Since(anchor))
		}
	}

	// Bound concurrent provider-selection scans (2026-09-01 congestion
	// collapse: retry-amplified inbound × a fresh full fleet scan per attempt
	// saturated every coordinator CPU). Only O(fleet) reservers take a slot —
	// the full scan, the plan REFRESH (itself a full re-scan), and the
	// speculative-backup scan. A retained-plan step (ReserveNextFromPlan)
	// revalidates at most the plan's bounded entries, so it bypasses the
	// semaphore: a held slot must never starve the cheap retry path that
	// exists precisely to avoid rescans. The wait is bounded by the request's
	// remaining first-content budget: a goroutine parks cheaply on the channel
	// and either scans as soon as a slot frees or sheds capacity-shaped
	// (errRoutingScanSaturated → one retryable 429) once the budget is gone.
	if fullScan {
		// Exempt requests still shed routing overload using the same short
		// admission slice; this is a scan wait, not a first-content timeout.
		scanBudget := scangate.PreflightWait(0)
		if requestDeadline > 0 {
			scanBudget = firstcontent.FirstTokenRemainingSince(receivedAt, requestDeadline)
		}
		if backupOf != "" {
			// Backup selection runs on the primary's stream reader. Never park
			// it behind fleet scans while healthy primary chunks accumulate.
			scanBudget = 0
		}
		switch s.gate.Acquire(
			scanBudget,
			r.Context().Done(),
		) {
		case scangate.ClientGone:
			// The caller vanished while parked for a slot: this is the
			// ordinary client-gone terminal, never the routing_saturated
			// 429/rejection row (and no distress sample — a vanished caller
			// proves nothing about selection latency).
			return nil, nil, decision, nil, ClientGoneBeforeScan,

				0
		case scangate.Timeout:
			noteSelectionSample()
			return nil, nil, decision, nil, RoutingScanSaturated,

				http.StatusTooManyRequests
		}
	}
	provider, decision, plan = reserve(pr, excludeList())
	ap.SetReservationTTFTCeiling(pr.MaxTTFTMs)
	ap.Mark(registry.StampReserveDone)
	ap.SetDecision(decision)
	if fullScan {
		s.gate.Release()
	}
	if provider == nil {
		noteSelectionSample()
		// Providers serve this model but none can physically fit it: don't make
		// the caller queue/retry for something that will never load.
		if decision.CandidateCount == 0 && decision.CapacityRejections == 0 && decision.ModelTooLargeRejections > 0 {
			return nil, nil, decision, plan, ModelTooLarge,

				http.StatusServiceUnavailable
		}
		// Providers are available but all exceed the TTFT ceiling. Fail fast
		// with a retryable 429 rather than queueing or routing to a slow
		// provider.
		if decision.TTFTRejections > 0 {
			return nil, nil, decision, plan, TTFTTooSlow,

				http.StatusTooManyRequests
		}
		return nil, nil, decision, plan, "no provider available", http.StatusServiceUnavailable
	}
	pendingCleanup := true
	cleanupPending := func() {
		if pendingCleanup {
			s.releaseUnsentDispatch(provider, pr)
			pendingCleanup = false
		}
	}
	defer cleanupPending()
	if pr.Timing != nil {
		pr.Timing.RoutedAt = time.Now()
	}
	noteSelectionSample()
	if ap != nil {
		ap.ProviderID = provider.ID
		provider.Mu().Lock()
		ap.ProviderVersion = provider.Version
		ap.ChipFamily = provider.Hardware.ChipFamily
		provider.Mu().Unlock()
		ap.KVBackend, _ = provider.SlotKVBackendTags(model)
	}
	if recordRoute != nil {
		recordRoute(provider, pr, decision)
	}

	// A request settles FREE when it's served by a machine the caller owns:
	// exclusive self-route (policy.enabled) always, OR a prefer request whose
	// SELECTED provider is the caller's own machine (settlement refunds it to
	// zero). In that case there is no payout and no reservation to top up — and
	// applying a provider custom price above the platform rate would wrongly 429
	// the free owned route, so skip both the payout warning and the top-up.
	settlesFree := policy.SelfRouteOnly
	if !settlesFree && policy.PreferOwner {
		provider.Mu().Lock()
		settlesFree = policy.OwnerAccountID != "" && provider.AccountID == policy.OwnerAccountID
		provider.Mu().Unlock()
	}

	if s.billingEnabled && !settlesFree && !ProviderHasPayoutDestination(provider) {
		s.logger.Warn("provider missing payout destination, crediting to internal ledger",
			"provider_id", provider.ID)
	}

	// Free (owned) requests are settled at zero cost (handleComplete), so there
	// is no reservation to top up for a provider's custom price.
	if s.billingEnabled && !settlesFree {
		_, err := s.reservations.ReserveAdditionalForProvider(pr, provider)
		if err != nil {
			cleanupPending()
			excludeProviders.Exclude(provider.ID)
			if errors.Is(err, store.ErrInsufficientBalance) {
				return nil, nil, decision, plan, "insufficient funds for provider price", http.StatusPaymentRequired
			}
			s.logger.Error("provider reservation failed (DB error)", "provider_id", provider.ID, "error", err)
			return nil, nil, decision, plan, "service temporarily unavailable — please retry", http.StatusServiceUnavailable
		}
	}
	ap.Mark(registry.StampTopupDone)
	// refundExtra credits back the provider-specific surcharge that
	// reserveAdditionalForProvider may have added. The caller's
	// refundReservation only covers the base reservation.
	refundExtra := func() {
		if pr.ModelTokenReservationID != "" {
			return
		}
		extra := pr.ReservedMicroUSD - reservedMicroUSD
		if extra > 0 {
			start := time.Now()
			_ = s.store.Credit(consumerKey, extra, store.LedgerRefund, "reservation_extra_refund:"+requestID)
			s.observation.Incr("billing.reservation_extra_refunds", []string{"model:" + model})
			s.observation.Histogram("store.credit.latency_ms", float64(time.Since(start).Milliseconds()), []string{"op:reservation_extra_refund"})
			pr.ReservedMicroUSD = reservedMicroUSD
		}
	}

	// E2E encryption
	if provider.PublicKey == "" {
		refundExtra()
		cleanupPending()
		excludeProviders.Exclude(provider.ID)
		return nil, nil, decision, plan, "no provider with E2E encryption", http.StatusServiceUnavailable
	}

	providerPubKey, err := e2e.ParsePublicKey(provider.PublicKey)
	if err != nil {
		refundExtra()
		cleanupPending()
		excludeProviders.Exclude(provider.ID)
		return nil, nil, decision, plan, "provider public key invalid", http.StatusServiceUnavailable
	}

	sessionKeys, err := e2e.GenerateSessionKeys()
	if err != nil {
		refundExtra()
		cleanupPending()
		return nil, nil, decision, plan, "failed to generate session keys", http.StatusInternalServerError
	}

	if err := s.registry.PrepareCacheAttempt(pr, provider); err != nil {
		s.registry.ForgetCacheAttempt(pr)
		refundExtra()
		cleanupPending()
		return nil, nil, decision, plan, "failed to prepare cache-safe request", http.StatusInternalServerError
	}
	// Protocol-0 providers get a coordinator-authored prompt_cache_key only
	// inside this sealed body.
	sealedBody, err := providerwire.BodyForCacheAttempt(rawBody, pr.LegacyCacheBustKey)
	if err != nil {
		s.registry.ForgetCacheAttempt(pr)
		refundExtra()
		cleanupPending()
		if errors.Is(err, providerwire.ErrBodyTooLarge) {
			excludeProviders.Exclude(provider.ID)
			return nil, nil, decision, plan, err.Error(), http.StatusRequestEntityTooLarge
		}
		return nil, nil, decision, plan, "failed to prepare provider request", http.StatusInternalServerError
	}
	encrypted, err := e2e.Encrypt(sealedBody, providerPubKey, sessionKeys)
	if err != nil {
		s.registry.ForgetCacheAttempt(pr)
		refundExtra()
		cleanupPending()
		return nil, nil, decision, plan, "failed to encrypt request", http.StatusInternalServerError
	}
	if pr.Timing != nil {
		pr.Timing.EncryptedAt = time.Now()
	}
	ap.Mark(registry.StampEncrypted)
	pr.SessionPrivKey = &sessionKeys.PrivateKey
	// pr.ReservedMicroUSD was already set in the struct literal and may have
	// been increased by reserveAdditionalForProvider above. Don't overwrite.

	// Bound the provider write by the request-absolute first-token clock (see
	// firstTokenWriteContext): a congested write lane must not silently eat
	// the budget while the aggregator's cancel clock keeps running.
	writeCtx, cancelWrite := firstcontent.FirstTokenWriteContextForPending(
		r.Context(), receivedAt, requestDeadline, pr)
	ap.Mark(registry.StampWriteSubmitted)
	_, writeErr := providerwire.WriteDeferred(
		writeCtx,
		provider,
		pr,
		providerwire.FrameBuilder(
			requestID, encrypted.EphemeralPublicKey, encrypted.Ciphertext, pr),
		func(metadata registry.TextFrameWriteMetadata) {
			if onDispatched != nil {
				onDispatched()
			}
			ap.MarkAt(registry.StampWriteDequeued, metadata.DequeuedAt)
		},
	)
	cancelWrite()
	if writeErr == nil {
		ap.Mark(registry.StampWriteDone)
	}
	if writeErr != nil {
		s.registry.ForgetCacheAttempt(pr)
		refundExtra()
		cleanupPending()
		excludeProviders.Exclude(provider.ID)
		if errors.Is(writeErr, context.DeadlineExceeded) ||
			errors.Is(writeErr, providerwire.ErrDeadlineExpired) {
			// The writer either discarded the frame before handoff or aborted
			// its connection during an in-flight write. Cancel defensively in
			// case the provider decoded the final bytes before disconnect.
			ap.Mark(registry.StampCancelSent)
			s.cancels.SendProviderCancel(provider, requestID)
			return nil, nil, decision, plan, providerwire.DeadlineExpiredMessage, http.StatusGatewayTimeout
		}
		if errors.Is(writeErr, registry.ErrProviderDraining) {
			return nil, nil, decision, plan, protocol.ProviderDrainingForUpdate, http.StatusServiceUnavailable
		}
		return nil, nil, decision, plan, "failed to send request to provider", http.StatusBadGateway
	}
	pendingCleanup = false

	return provider, pr, decision, plan, "", 0
}

func ProviderHasPayoutDestination(provider *registry.Provider) bool {
	if provider == nil {
		return false
	}
	provider.Mu().Lock()
	defer provider.Mu().Unlock()
	return provider.AccountID != ""
}
