package dispatch

import (
	"context"
	"errors"
	"fmt"
	"math"
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/requestcontext"
	"github.com/eigeninference/d-inference/coordinator/inference/response"
	"github.com/eigeninference/d-inference/coordinator/inference/settlement"
	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

// dispatchOneProvider encrypts and sends an inference request to a single
// provider selected by a fresh full scan. It returns the pending request and
// provider on success, or an error string on failure, plus the bounded
// DispatchPlan of provisional alternates retained from the SAME scan (nil
// whenever no provider was reserved) so retries and speculative backups can
// consume retained identities instead of rescanning the fleet (Routing v2
// Phase 3). The excludeProviders set is updated on failure. RoutePolicy
// and its resolvers live in self_route.go.
func (s *Controller) dispatchOneProvider(
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
	policy RoutePolicy,
	timing *registry.RequestTiming,
	serviceReservation bool,
	cachePlan registry.CachePlan,
	excludeProviders map[string]struct{},
	attempt int,
	rp *registry.RequestProfile,
	backupOf string,
	recordRoute routeDecisionRecorder,
	onDispatched func(),
) (
	provider *registry.Provider,
	pr *registry.PendingRequest,
	decision registry.RoutingDecision,
	plan *registry.DispatchPlan,
	lastErr string,
	lastErrCode int,
) {
	return s.dispatchWithReserver(
		r, model, publicModel, rawBody, consumerKey, consumerLocation,
		reservedMicroUSD, estimatedPromptTokens, requestDeadline,
		requestedMaxTokens, tokenAdmission, requiresVision, traits,
		allowedProviderSerials, isResponsesAPI, policy, timing,
		serviceReservation, cachePlan, excludeProviders, attempt, rp, backupOf,
		recordRoute, onDispatched,
		true, // ReserveProviderWithPlan is the O(fleet) full scan
		func(pr *registry.PendingRequest, excludeIDs []string) (*registry.Provider, registry.RoutingDecision, *registry.DispatchPlan) {
			return s.deps.Registry().ReserveProviderWithPlan(model, pr, excludeIDs...)
		},
	)
}

// dispatchWithReserver is the single prepare/encrypt/write funnel behind every
// provider dispatch: pending construction and admission stamps, the pluggable
// reservation, the billing surcharge, E2E encryption, and the
// deadline-bounded provider write, with releaseUnsentDispatch cleanup on every
// failure path. onDispatched (nil-safe) fires inside the write handoff
// callback — the same instant Timing.DispatchedAt is stamped — so
// providerDispatches counts frames that actually reached a provider, never
// loop attempts.
func (s *Controller) dispatchWithReserver(
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
	policy RoutePolicy,
	timing *registry.RequestTiming,
	serviceReservation bool,
	cachePlan registry.CachePlan,
	excludeProviders map[string]struct{},
	attempt int,
	rp *registry.RequestProfile,
	backupOf string,
	recordRoute routeDecisionRecorder,
	onDispatched func(),
	fullScan bool,
	reserve dispatchReserver,
) (
	provider *registry.Provider,
	pr *registry.PendingRequest,
	decision registry.RoutingDecision,
	plan *registry.DispatchPlan,
	lastErr string,
	lastErrCode int,
) {
	receivedAt := TimingReceivedAt(timing)
	_, dispatchable := firstContentBudgetMillis(receivedAt, requestDeadline)
	if !dispatchable {
		return nil, nil, decision, nil, errFirstContentDeadlineExpired, http.StatusGatewayTimeout
	}

	requestID := uuid.New().String()
	ap := rp.NewAttempt(requestID, attempt, backupOf)
	s.recordPredictivePolicy(ap, policy, requiresVision)
	ap.Mark(registry.StampAttemptStart)
	// Any failure return closes the attempt as not dispatched (terminal half; the handler half lands in finalizeProfile);
	// a dispatched attempt is left for the provider terminal / relay to close.
	defer func() {
		if provider == nil {
			closeUndispatchedAttempt(ap, lastErr, lastErrCode)
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
		Attempt:                attempt,
		Model:                  model,
		PublicModel:            publicModel,
		ConsumerKey:            consumerKey,
		KeyID:                  requestcontext.KeyID(r.Context()),
		KeyLimitMicroUSD:       requestcontext.KeyLimitMicroUSD(r.Context()),
		KeyLimitReset:          requestcontext.KeyLimitReset(r.Context()),
		ConsumerLocation:       consumerLocation,
		IsResponsesAPI:         isResponsesAPI,
		EstimatedPromptTokens:  estimatedPromptTokens,
		RequiresVision:         requiresVision,
		Traits:                 traits,
		RequestedMaxTokens:     requestedMaxTokens,
		TokenAdmission:         tokenAdmission,
		CachePlan:              cachePlan,
		ReservedMicroUSD:       reservedMicroUSD,
		BaseReservedMicroUSD:   reservedMicroUSD,
		ServiceReservation:     serviceReservation,
		AllowedProviderSerials: allowedProviderSerials,
		SelfRouteOnly:          policy.Enabled,
		PreferOwner:            policy.Prefer,
		OwnerAccountID:         policy.OwnerAccountID,
		FreeSelfRoute:          policy.Enabled,
		MetadataDetails:        response.MetadataDetailsFromRequest(r),
		AcceptedCh:             make(chan struct{}, 1),
		ChunkCh:                make(chan registry.ProviderChunk, chunkBufferSize),
		CompleteCh:             make(chan protocol.UsageInfo, 1),
		ErrorCh:                make(chan protocol.InferenceErrorMessage, 1),
		Timing:                 timing,
	}
	if !receivedAt.IsZero() {
		pr.FirstContentDeadline = receivedAt.Add(requestDeadline)
	}

	// Public inference routes (not self-route / prefer-owner) enforce the
	// OpenRouter TTFT ceiling inside the scheduler. This makes the preflight
	// check authoritative: the router cannot select a provider whose estimated
	// TTFT is above the threshold.
	// Routing v2 (P1 fix): only enforce the TTFT ceiling inside the scheduler when
	// the HARD gate is on. In soft mode (default) MaxTTFTMs stays 0 so the primary
	// dispatch serves the best-available provider instead of re-rejecting an
	// over-threshold request the preflight already chose to soft-serve. (Mirrors
	// queueMaxTTFTMs, which already returns 0 in soft mode.)
	if !policy.Enabled && !policy.Prefer && s.HardTTFTGateApplies(requiresVision) {
		pr.MaxTTFTMs = float64(requestDeadline.Milliseconds())
	}
	// Refresh immediately before reservation: every retry spends the same
	// absolute clock, so the scheduler must never see the original ceiling.
	if !pr.RefreshFirstContentBudget(time.Now()) {
		return nil, nil, decision, nil, errFirstContentDeadlineExpired, http.StatusGatewayTimeout
	}
	// Routing v2 W2: soft per-request decode floor (0 = off). Applies to all
	// routes; it only ranks providers, never rejects.
	pr.MinDecodeTPS = s.deps.MinDecodeTPS()

	excludeList := func() []string {
		ids := make([]string, 0, len(excludeProviders))
		for id := range excludeProviders {
			ids = append(ids, id)
		}
		return ids
	}

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
		if anchor := attempt0RouteAnchor(timing); !anchor.IsZero() {
			s.noteAttempt0RouteLatency(time.Since(anchor))
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
		switch s.AcquireRoutingScanSlot(
			FirstTokenRemainingSince(receivedAt, requestDeadline),
			r.Context().Done(),
		) {
		case ScanSlotClientGone:
			// The caller vanished while parked for a slot: this is the
			// ordinary client-gone terminal, never the routing_saturated
			// 429/rejection row (and no distress sample — a vanished caller
			// proves nothing about selection latency).
			return nil, nil, decision, nil, errClientGoneBeforeScan, 0
		case ScanSlotTimeout:
			noteSelectionSample()
			return nil, nil, decision, nil, errRoutingScanSaturated, http.StatusTooManyRequests
		}
	}
	provider, decision, plan = reserve(pr, excludeList())
	ap.SetReservationTTFTCeiling(pr.MaxTTFTMs)
	ap.Mark(registry.StampReserveDone)
	ap.SetDecision(decision)
	if fullScan {
		s.ReleaseRoutingScanSlot()
	}
	if provider == nil {
		noteSelectionSample()
		// Providers serve this model but none can physically fit it: don't make
		// the caller queue/retry for something that will never load.
		if decision.CandidateCount == 0 && decision.CapacityRejections == 0 && decision.ModelTooLargeRejections > 0 {
			return nil, nil, decision, plan, errModelTooLarge, http.StatusServiceUnavailable
		}
		// Providers are available but all exceed the TTFT ceiling. Fail fast
		// with a retryable 429 rather than queueing or routing to a slow
		// provider.
		if decision.TTFTRejections > 0 {
			return nil, nil, decision, plan, errTTFTTooSlow, http.StatusTooManyRequests
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
	// exclusive self-route (policy.Enabled) always, OR a prefer request whose
	// SELECTED provider is the caller's own machine (settlement refunds it to
	// zero). In that case there is no payout and no reservation to top up — and
	// applying a provider custom price above the platform rate would wrongly 429
	// the free owned route, so skip both the payout warning and the top-up.
	settlesFree := policy.Enabled
	if !settlesFree && policy.Prefer {
		provider.Mu().Lock()
		settlesFree = policy.OwnerAccountID != "" && provider.AccountID == policy.OwnerAccountID
		provider.Mu().Unlock()
	}

	if s.deps.BillingConfigured() && !settlesFree && !settlement.HasPayoutDestination(provider) {
		s.deps.Logger().Warn("provider missing payout destination, crediting to internal ledger",
			"provider_id", provider.ID)
	}

	// Free (owned) requests are settled at zero cost (handleComplete), so there
	// is no reservation to top up for a provider's custom price.
	if s.deps.BillingConfigured() && !settlesFree {
		_, err := s.deps.Settlement().ReserveForProvider(pr, provider)
		if err != nil {
			cleanupPending()
			excludeProviders[provider.ID] = struct{}{}
			if errors.Is(err, store.ErrInsufficientBalance) {
				return nil, nil, decision, plan, "insufficient funds for provider price", http.StatusPaymentRequired
			}
			s.deps.Logger().Error("provider reservation failed (DB error)", "provider_id", provider.ID, "error", err)
			return nil, nil, decision, plan, "service temporarily unavailable — please retry", http.StatusServiceUnavailable
		}
	}
	ap.Mark(registry.StampTopupDone)
	// refundExtra credits back the provider-specific surcharge that
	// Service.ReserveForProvider may have added. The caller's
	// refundReservation only covers the base reservation.
	refundExtra := func() {
		extra := pr.ReservedMicroUSD - reservedMicroUSD
		if extra > 0 {
			start := time.Now()
			_ = s.deps.Store().Credit(consumerKey, extra, store.LedgerRefund, "reservation_extra_refund:"+requestID)
			s.deps.Counters.Incr("billing.reservation_extra_refunds", []string{"model:" + model})
			s.deps.Counters.Histogram("store.credit.latency_ms", float64(time.Since(start).Milliseconds()), []string{"op:reservation_extra_refund"})
			pr.ReservedMicroUSD = reservedMicroUSD
		}
	}

	// E2E encryption
	if provider.PublicKey == "" {
		refundExtra()
		cleanupPending()
		excludeProviders[provider.ID] = struct{}{}
		return nil, nil, decision, plan, "no provider with E2E encryption", http.StatusServiceUnavailable
	}

	providerPubKey, err := e2e.ParsePublicKey(provider.PublicKey)
	if err != nil {
		refundExtra()
		cleanupPending()
		excludeProviders[provider.ID] = struct{}{}
		return nil, nil, decision, plan, "provider public key invalid", http.StatusServiceUnavailable
	}

	sessionKeys, err := e2e.GenerateSessionKeys()
	if err != nil {
		refundExtra()
		cleanupPending()
		return nil, nil, decision, plan, "failed to generate session keys", http.StatusInternalServerError
	}

	if err := s.deps.Registry().PrepareCacheAttempt(pr, provider); err != nil {
		s.deps.Registry().ForgetCacheAttempt(pr)
		refundExtra()
		cleanupPending()
		return nil, nil, decision, plan, "failed to prepare cache-safe request", http.StatusInternalServerError
	}
	// Pre-fix providers crash on a vision request carrying sampling penalties;
	// strip them for those providers only. Protocol-0 providers additionally get
	// a coordinator-authored prompt_cache_key only inside this sealed body.
	sealedBody, err := bodyForCacheAttempt(rawBody, requiresVision, provider, pr)
	if err != nil {
		s.deps.Registry().ForgetCacheAttempt(pr)
		refundExtra()
		cleanupPending()
		if errors.Is(err, ErrProviderBodyTooLarge) {
			excludeProviders[provider.ID] = struct{}{}
			return nil, nil, decision, plan, err.Error(), http.StatusRequestEntityTooLarge
		}
		return nil, nil, decision, plan, "failed to prepare provider request", http.StatusInternalServerError
	}
	encrypted, err := e2e.Encrypt(sealedBody, providerPubKey, sessionKeys)
	if err != nil {
		s.deps.Registry().ForgetCacheAttempt(pr)
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
	// been increased by Service.ReserveForProvider above. Don't overwrite.

	// Bound the provider write by the request-absolute first-token clock (see
	// firstTokenWriteContext): a congested write lane must not silently eat
	// the budget while the aggregator's cancel clock keeps running.
	writeCtx, cancelWrite := firstTokenWriteContext(
		r.Context(), receivedAt, requestDeadline)
	ap.Mark(registry.StampWriteSubmitted)
	_, writeErr := writeProviderInferenceRequestDeferred(
		writeCtx,
		provider,
		providerInferenceFrameBuilder(
			requestID, encrypted.EphemeralPublicKey, encrypted.Ciphertext, pr),
		func(metadata registry.TextFrameWriteMetadata) {
			if pr.Timing != nil {
				pr.Timing.DispatchedAt = metadata.DequeuedAt
			}
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
		s.deps.Registry().ForgetCacheAttempt(pr)
		refundExtra()
		cleanupPending()
		excludeProviders[provider.ID] = struct{}{}
		if errors.Is(writeErr, context.DeadlineExceeded) ||
			errors.Is(writeErr, errFirstContentDeadlineAtWriter) {
			// The writer either discarded the frame before handoff or aborted
			// its connection during an in-flight write. Cancel defensively in
			// case the provider decoded the final bytes before disconnect.
			ap.Mark(registry.StampCancelSent)
			s.deps.Attempts().SendCancel(provider, requestID)
			return nil, nil, decision, plan, errFirstContentDeadlineExpired, http.StatusGatewayTimeout
		}
		return nil, nil, decision, plan, "failed to send request to provider", http.StatusBadGateway
	}
	pendingCleanup = false

	return provider, pr, decision, plan, "", 0
}

// releaseUnsentDispatch returns a reservation after frame construction or
// socket handoff fails. Resolving speculative completion arbitration first
// guarantees a provider completion already waiting off the read loop cannot
// remain stranded after pending state is removed.
func (s *Controller) releaseUnsentDispatch(
	provider *registry.Provider,
	pr *registry.PendingRequest,
) {
	if provider == nil || pr == nil {
		return
	}
	pr.ResolveSpeculativeEmptyCompletion(false)
	provider.RemovePending(pr.RequestID)
	s.deps.Registry().SetProviderIdle(provider.ID)
}

func writeProviderInferenceRequestDeferred(
	ctx context.Context,
	provider *registry.Provider,
	builder registry.TextFrameBuilder,
	onHandoff registry.TextFrameHandoff,
) (registry.TextFrameWriteMetadata, error) {
	if provider == nil || provider.Conn == nil {
		return registry.TextFrameWriteMetadata{}, errors.New("provider websocket is not connected")
	}
	return provider.WriteTextDeferred(ctx, builder, onHandoff)
}

// failedProviderVersion reads a provider's reported binary version under its
// lock (mirroring the policy.Prefer owner reads). Captured when an attempt
// fails so the next attempt's Traits.AvoidVersion can steer the retry to a
// different build — a deterministic per-version bug must not burn every retry
// on identical binaries.
func failedProviderVersion(p *registry.Provider) string {
	if p == nil {
		return ""
	}
	p.Mu().Lock()
	defer p.Mu().Unlock()
	return p.Version
}

// errModelTooLarge is the dispatch error returned when providers serve the
// requested model but none of them has enough total memory to ever load it.
// Distinct from "no provider available" so the caller rejects fast instead of
// queuing for 120s — queueing can't help a model that will never fit.
const errModelTooLarge = "model too large for any available provider"

// errTTFTTooSlow is the dispatch error returned when providers are available
// but all of them exceed the per-request TTFT ceiling. Distinct from
// "no provider available" so the caller returns a retryable 429 instead of
// queueing for a provider that would miss the OpenRouter SLA target.
const errTTFTTooSlow = "all available providers exceed the TTFT target"

// errFirstContentDeadlineExpired is returned when the request-absolute
// first-content clock runs out before an inference_request reaches the provider
// wire. No provider work was started, so callers surface a deadline 429 without
// charging provider health.
const errFirstContentDeadlineExpired = "first-content deadline expired before provider dispatch"

// errRoutingScanSaturated is returned when no provider-selection scan slot
// (Controller.routingScanSem) freed up within the request's remaining
// first-content budget: the coordinator itself is the bottleneck (the
// 2026-09-01 congestion collapse). No provider was scanned or contacted, so
// callers shed ONE capacity-shaped retryable 429 — never a 5xx, never more
// scans.
const errRoutingScanSaturated = "routing scan capacity saturated — coordinator busy"

// errClientGoneBeforeScan is returned when the caller's context fired while
// the dispatch goroutine was parked for a provider-selection scan slot. No
// provider was scanned or contacted; the dispatch loop takes its ordinary
// client-gone terminal (cancelled route outcome, refund, no response body) —
// never the routing_saturated 429 or a rejection-ledger row.
const errClientGoneBeforeScan = "client disconnected before provider selection"

// attempt0RouteAnchor returns the instant the attempt-0 route-latency EWMA
// sample is measured from — the SAME anchor applyTimingDecomposition uses for
// route_ms (MediaFetchedAt when a remote-media fetch happened, else
// ReservedAt) — so download or parse time can never fake routing distress.
// Zero when the request never stamped a reservation (bare test fixtures):
// the caller then records no sample.
func attempt0RouteAnchor(t *registry.RequestTiming) time.Time {
	if t == nil {
		return time.Time{}
	}
	if !t.MediaFetchedAt.IsZero() {
		return t.MediaFetchedAt
	}
	return t.ReservedAt
}

// ttftTooSlowMessage is the single wording for a fleet-wide TTFT rejection.
func ttftTooSlowMessage(publicModel string, bestTTFT, threshold time.Duration, retryAfter int) string {
	return fmt.Sprintf(
		"all providers for model %q are above the %ds TTFT target (best estimate %.1fs); retry after %ds",
		publicModel, int(math.Ceil(threshold.Seconds())), bestTTFT.Seconds(), retryAfter)
}

type routeDecisionRecorder func(*registry.Provider, *registry.PendingRequest, registry.RoutingDecision)

// dispatchReserver selects and atomically reserves a provider for an
// already-constructed PendingRequest. It is the ONE seam between provider
// SELECTION and the single prepare/encrypt/write funnel in
// dispatchWithReserver: wave-2 callers plug in the retained-plan variants
// (ReserveNextFromPlan / RefreshDispatchPlan) without forking the funnel.
// The returned plan is non-nil only for scan-backed reservers that retain
// alternates.
type dispatchReserver func(pr *registry.PendingRequest, excludeIDs []string) (*registry.Provider, registry.RoutingDecision, *registry.DispatchPlan)
