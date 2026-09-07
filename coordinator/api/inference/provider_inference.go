package inference

import (
	"net/http"
	"time"

	inresp "github.com/eigeninference/d-inference/coordinator/api/inference/response"
	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	cacheusage "github.com/eigeninference/d-inference/coordinator/internal/inference/cacheusage"
	cancellation "github.com/eigeninference/d-inference/coordinator/internal/inference/cancellation"
	failure "github.com/eigeninference/d-inference/coordinator/internal/inference/failure"
	routeoutcome "github.com/eigeninference/d-inference/coordinator/internal/inference/outcome"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *Owner) HandleChunk(providerID string, provider *registry.Provider, msg *protocol.InferenceResponseChunkMessage) {
	if provider == nil {
		s.logger.Warn("chunk from unregistered provider", "provider_id", providerID)
		return
	}
	pr, receivedAt := provider.BeginPendingChunkIngress(msg.RequestID)
	if pr == nil {
		s.observation.Incr("inference.unknown_request_frames", []string{"kind:chunk"})
		s.observation.AddUnknownRequestFrames(1)
		// The provider is generating into a stream the coordinator abandoned
		// (cancelled, consumer gone, already settled) — or sent an id it never
		// owned. noteStrayChunk re-sends the cancel on the escalating zombie
		// schedule and rate-limits the log line per provider; request_id stays
		// out of the log until it matches coordinator state.
		s.noteStrayChunk(provider, providerID, msg.RequestID, receivedAt)
		return
	}
	ingressClassified := false
	defer func() {
		if !ingressClassified {
			pr.FinishProviderChunkIngress(receivedAt, false)
		}
	}()
	decryptStart := time.Now()
	chunkData, err := s.decryptTextResponseChunk(provider, pr, msg)
	if err != nil {
		s.logger.Warn("rejecting insecure response chunk",
			"provider_id", providerID,
			"request_id", msg.RequestID,
			"error", err,
		)
		s.registry.MarkUntrusted(providerID)
		// The provider is still generating: the synthesized terminal below
		// settles the request on our side, so the committed writer's exit
		// will not send a cancel for it (a settled terminal means "nothing
		// left to stop"). Stop the real work here, like the deadline and
		// overflow branches do.
		s.sendProviderCancel(provider, msg.RequestID)
		s.HandleInferenceError(providerID, provider, &protocol.InferenceErrorMessage{
			Type:        protocol.TypeInferenceError,
			RequestID:   msg.RequestID,
			Error:       "encrypted inference transport failed",
			StatusCode:  http.StatusBadGateway,
			FailureCode: protocol.FailureCodeEncryptionFailure,
		})
		return
	}
	if ap := pr.Profile; ap != nil {
		ap.ChunksIn.Add(1)
		ap.DecryptUSTotal.Add(time.Since(decryptStart).Microseconds())
		ap.MarkAt(registry.StampFirstChunkIngress, receivedAt)
	}
	if pr.Profile != nil && !pr.Profile.GeneratedContentObserved.Load() && (observation.GeneratedContentSSE([]byte(chunkData)) || observation.GeneratedContentJSON([]byte(chunkData))) {
		pr.Profile.GeneratedContentObserved.Store(true)
	}
	contentBearing := !inresp.IsBoilerplateChunk(chunkData)
	firstContent := pr.FinishProviderChunkIngress(receivedAt, contentBearing)
	ingressClassified = true
	if firstContent {
		pr.Profile.MarkAt(registry.StampFirstContentIngress, receivedAt)
	}
	deadlineExpiredWithoutContent := !pr.FirstContentDeadline.IsZero() &&
		((firstContent && receivedAt.After(pr.FirstContentDeadline)) ||
			(!contentBearing &&
				!pr.HasFirstContentIngress() &&
				time.Now().After(pr.FirstContentDeadline)))
	if deadlineExpiredWithoutContent {
		// The request-absolute SLA is defined at coordinator ingress. Reject
		// either late first content or an on-time chunk that finished
		// classification as boilerplate only after the deadline.
		s.observation.Incr("inference.first_content_after_deadline", []string{})
		s.sendAbandonCancel(provider, pr.RequestID, pr.Model, cancellation.CauseLateContent)
		s.HandleInferenceError(providerID, provider, &protocol.InferenceErrorMessage{
			Type:        protocol.TypeInferenceError,
			RequestID:   pr.RequestID,
			Error:       "first content was unavailable at the request deadline",
			StatusCode:  http.StatusServiceUnavailable,
			ErrorReason: failure.ErrorReasonDeadlineUnreachable,
			FailureCode: protocol.FailureCodeCapacity,
		})
		return
	}
	chunk := registry.ProviderChunk{Data: chunkData, ReceivedAt: receivedAt}
	// Fast path: non-blocking send — this is the provider's single read
	// goroutine, so it must not stall behind one slow consumer. A full channel
	// means the consumer is ≥256 chunks behind; silently dropping the chunk
	// (the old behavior) would deliver a corrupted stream with missing tokens
	// that is still billed. Instead, give a healthy-but-bursty consumer a
	// bounded grace window to free one slot (sendChunkWithGrace), and only
	// then fail the request: cancel the provider's generation and surface a
	// terminal error to the consumer goroutine.
	select {
	case pr.ChunkCh <- chunk:
	default:
		if sendChunkWithGrace(pr, chunk) {
			return
		}
		s.logger.Error("chunk buffer overflow — failing request instead of corrupting stream",
			"provider_id", providerID,
			"request_id", msg.RequestID,
		)
		s.observation.Incr("inference.chunk_overflow_abort", []string{})
		s.sendAbandonCancel(provider, pr.RequestID, pr.Model, cancellation.CauseOverflow)
		// 499 + "request cancelled" classifies as a consumer-side terminal in
		// handleInferenceError: no provider reputation hit for our backpressure.
		s.HandleInferenceError(providerID, provider, &protocol.InferenceErrorMessage{
			Type:        protocol.TypeInferenceError,
			RequestID:   msg.RequestID,
			Error:       "request cancelled",
			StatusCode:  499,
			FailureCode: protocol.FailureCodeCancelled,
		})
	}
}

// chunkOverflowGrace is how long handleChunk will block the provider read loop
// waiting for a full ChunkCh to free one slot before failing the request. It
// trades a bounded head-of-line stall for this provider's OTHER streams
// against killing a healthy consumer that is merely catching up after a TCP
// burst (WS stall recovery, engine batch flush, slow mobile links). A stuck
// consumer costs one grace window and is then failed; a consumer that drains
// at least one chunk per window keeps its stream alive.
const chunkOverflowGrace = 250 * time.Millisecond

// sendChunkWithGrace blocks up to chunkOverflowGrace for a slot on pr.ChunkCh
// and reports whether the chunk was delivered. The recover guard mirrors
// registry.Disconnect's own channel idiom: Disconnect can close ChunkCh from
// another goroutine while we are blocked in the send, and a closed channel
// here simply means the request is already torn down (delivered=false; the
// caller's terminal path degrades to a no-op warn).
func sendChunkWithGrace(pr *registry.PendingRequest, chunk registry.ProviderChunk) (delivered bool) {
	defer func() {
		if recover() != nil {
			delivered = false
		}
	}()
	wait := time.NewTimer(chunkOverflowGrace)
	defer wait.Stop()
	select {
	case pr.ChunkCh <- chunk:
		return true
	case <-wait.C:
		return false
	}
}

func (s *Owner) decryptTextResponseChunk(provider *registry.Provider, pr *registry.PendingRequest, msg *protocol.InferenceResponseChunkMessage) (string, error) {
	if msg.EncryptedData == nil {
		return "", errTextChunkViolation("plaintext text chunk")
	}
	if msg.Data != "" {
		return "", errTextChunkViolation("mixed plaintext and encrypted text chunk")
	}
	if provider.PublicKey == "" {
		return "", errTextChunkViolation("provider missing registered public key")
	}
	if msg.EncryptedData.EphemeralPublicKey != provider.PublicKey {
		return "", errTextChunkViolation("chunk sender key mismatch")
	}
	if pr.SessionPrivKey == nil {
		return "", errTextChunkViolation("missing coordinator session key")
	}

	payload := &e2e.EncryptedPayload{
		EphemeralPublicKey: msg.EncryptedData.EphemeralPublicKey,
		Ciphertext:         msg.EncryptedData.Ciphertext,
	}
	// The X25519 shared key is derived once per request and memoized; the
	// per-chunk cost is a single symmetric open. The sender-key check above
	// guarantees the cached key matches this chunk's ephemeral key.
	shared, err := s.chunkKeys.SharedKey(pr.SessionPrivKey, provider.PublicKey)
	if err != nil {
		return "", err
	}
	plaintext, err := e2e.DecryptWithSharedKey(payload, shared)
	if err != nil {
		return "", err
	}
	return string(plaintext), nil
}

func errTextChunkViolation(reason string) error {
	return &textChunkViolationError{reason: reason}
}

type textChunkViolationError struct {
	reason string
}

func (e *textChunkViolationError) Error() string {
	return e.reason
}

func (s *Owner) HandleInferenceAccepted(provider *registry.Provider, msg *protocol.InferenceAcceptedMessage) {
	if provider == nil {
		return
	}
	pr := provider.GetPending(msg.RequestID)
	if pr == nil {
		return
	}
	pr.Profile.Mark(registry.StampAccepted)
	// Non-blocking signal — the dispatch loop may have already committed.
	select {
	case pr.AcceptedCh <- struct{}{}:
	default:
	}
}

// maxPlausibleDecodeTPS is the sanity ceiling applied to the telemetry-only
// ActualDecodeTPS before it is persisted. Real decode throughput on the fleet's
// Apple-silicon hardware is in the tens-to-low-hundreds of tokens/sec; this
// ceiling is far above any genuine value and exists solely to stop a dishonest
// or buggy provider's unbounded CompletionTokens from writing an absurd TPS that
// could skew routing calibration. The value is advisory, never a security gate.
const maxPlausibleDecodeTPS = 10000.0

func (s *Owner) HandleCompleteAt(
	providerID string,
	provider *registry.Provider,
	msg *protocol.InferenceCompleteMessage,
	receivedAt time.Time,
) {
	if provider == nil {
		s.logger.Warn("complete from unregistered provider", "provider_id", providerID)
		return
	}
	if receivedAt.IsZero() {
		receivedAt = time.Now()
	}
	// terminalOwner is true only for the frame that claimed the attempt's
	// terminal first: concurrent duplicate completions for one request all
	// pass GetPending before one wins RemovePending, and only the owner may
	// retain usage / the profile (the others are rejected as unknown below).
	terminalOwner, terminalClaimed := false, false
	// claimed is the attempt whose terminal this frame owns. Every return
	// below must complete it: once claimed, neither the route-outcome funnel
	// nor the no-terminal fallback will, so a pending request removed by a
	// consumer-side cleanup between the claim and RemovePending would
	// otherwise never finalize.
	var claimed *registry.AttemptProfile
	if pending := provider.GetPending(msg.RequestID); pending != nil {
		if pending.Profile != nil {
			pending.Profile.ProviderCompleteObserved.Store(true)
		}
		pending.MarkCompletionIngress(receivedAt)
		pending.Profile.MarkAt(registry.StampCompleteIngress, receivedAt)
		// The claim is the single ownership token: only the frame that owns
		// the terminal proceeds to the deadline / speculative branches and to
		// RemovePending + settlement, so claim ownership and settlement
		// ownership can never diverge. A second concurrent frame for the same
		// pending request is a provider duplicate and is dropped here. Without
		// a profile (profiler off) there is no token and the pre-existing
		// RemovePending race decides, exactly as before.
		compact := observation.CompactOnlyAttempt(pending.Profile)
		terminalOwner, terminalClaimed = pending.Profile == nil || compact || pending.Profile.ClaimTerminal(), true
		if !terminalOwner {
			s.logger.Warn("duplicate complete for in-flight request", "provider_id", providerID)
			s.observation.Incr("inference.unknown_request_frames", []string{"kind:duplicate_complete"})
			s.observation.AddUnknownRequestFrames(1)
			return
		}
		if !compact {
			claimed = pending.Profile
		}
		// Usage and the provider profile are retained BEFORE any branch below
		// can discard this completion (the deadline-late conversion to an error,
		// the speculative-loser return), so a losing or late racer that sent a
		// profile is not recorded as absent. msg.Profile is cleared so the
		// claim site below no-ops for this pending (a second retain would count
		// a false duplicate); it still retains for a PARKED record, which has
		// no pending entry.
		if !compact {
			pending.Profile.SetTerminalUsage(msg.Usage.PromptTokens, msg.Usage.CompletionTokens)
		}
		s.observation.RetainProviderProfile(pending.Profile, msg.Profile)
		msg.Profile = nil
		if !pending.HasFirstContentIngress() &&
			!pending.FirstContentDeadline.IsZero() &&
			receivedAt.After(pending.FirstContentDeadline) {
			// A clean terminal without content is a valid empty completion only
			// while the first-content SLA is still live. Once the absolute deadline
			// has passed it must not race the dispatch timer into an empty HTTP 200.
			// owned: this frame already holds the claim, so the error path
			// must neither re-claim nor drop the conversion as a duplicate.
			s.handleInferenceErrorOwned(providerID, provider, &protocol.InferenceErrorMessage{
				Type:        protocol.TypeInferenceError,
				RequestID:   pending.RequestID,
				Error:       "provider completed after the first-content deadline",
				StatusCode:  http.StatusServiceUnavailable,
				ErrorReason: failure.ErrorReasonDeadlineUnreachable,
				FailureCode: protocol.FailureCodeCapacity,
			}, true)
			// handleInferenceError completes the terminal only when it still
			// found the pending request; if a consumer-side cleanup removed it
			// first, the provider still completed, so record that and close
			// the claimed terminal here (both calls are first-write / idempotent).
			claimed.SetOutcome("", "", "", "completed", "")
			claimed.CompleteTerminal()
			return
		}
		if !pending.HasFirstContentIngress() {
			if accepted, waited := pending.AwaitSpeculativeEmptyCompletionDecision(); waited && !accepted {
				// The losing racer's empty completion is discarded by the
				// dispatch loop, which classifies the attempt through the
				// route-outcome funnel (markSpeculativeLoser → cancelled /
				// speculative_loser) and completes its terminal half there.
				// Only the provider-side outcome is authoritative here — mirror
				// handleInferenceError — and the idempotent CompleteTerminal
				// covers the ordering where the funnel has not run yet.
				//
				// When the frame never reached the wire (releaseUnsentDispatch
				// resolved the loser after a write failure), the dispatch side's
				// closeUndispatchedAttempt records not_dispatched — the truthful
				// provider outcome — so "completed" is written only for an
				// attempt whose write completed. WriteDone is stamped before any
				// race can be resolved and never on the write-failure path, so
				// the check is deterministic; the close always lands because the
				// attempt cannot finalize before the handler half (finalizeProfile).
				if !compact && pending.Profile.Dispatched() {
					pending.Profile.SetOutcome("", "", "", "completed", "")
				}
				if !compact {
					pending.Profile.CompleteTerminal()
				}
				return
			}
		}
	}
	pr := provider.RemovePending(msg.RequestID)
	// Clear any parked settlement record (consumer disconnected mid-stream):
	// settles the disconnect case and stops the grace timer from no-op-refunding.
	parked := s.claimSettlement(msg.RequestID)
	// No live pending record means the attempt was abandoned (or is unknown):
	// correlate the terminal with the cancel the coordinator sent. Metric-only
	// — a parked post-commit record still settles billing below, and a
	// pre-commit attempt was refunded when it was abandoned. Only a terminal
	// that finds no live record is matched, so the coordinator's own
	// synthesized errors (raised while the record is live) never resolve one.
	var cancelled cancellation.Entry
	wasCancelled := false
	if pr == nil {
		cancelled, wasCancelled = s.resolveCancelledTerminal(
			msg.RequestID, cancellation.TerminalComplete, cancellation.OutcomeCompletePartial, receivedAt)
		pr = parked
	}
	if pr == nil {
		if wasCancelled && cancelled.Cause != cancellation.CauseStrayChunk {
			// The id matched a cancel the coordinator recorded, so it is
			// coordinator-minted and safe to log: the provider honored the
			// cancel with a partial completion.
			s.logger.Debug("complete for cancelled request",
				"request_id", msg.RequestID, "provider_id", providerID, "cause", cancelled.Cause)
		} else {
			// Until it matches pending state, request_id is provider-controlled and
			// therefore an arbitrary log-exfiltration channel.
			s.logger.Warn("complete for unknown request", "provider_id", providerID)
			s.emitUnknownFrame(cancellation.UnknownFrameKindComplete, provider)
		}
		s.observation.Incr("inference.unknown_request_frames", []string{"kind:complete"})
		s.observation.AddUnknownRequestFrames(1)
		// A claimed terminal whose pending request a consumer-side cleanup
		// removed in between: the provider completed, the coordinator lost
		// ownership; close the record rather than leak the attempt.
		claimed.SetOutcome("", "", "", "completed", "")
		claimed.CompleteTerminal()
		return
	}
	if pr.Profile != nil {
		pr.Profile.ProviderCompleteObserved.Store(true)
	}
	pr.Profile.MarkAt(registry.StampCompleteIngress, receivedAt)
	if observation.CompactOnlyAttempt(pr.Profile) {
		// With heavy profiling off, RemovePending/claimSettlement is the
		// existing arbitration. Only its actual winner claims compact
		// evidence, after removal; receipt never gates another terminal.
		pr.Profile.ClaimTerminal()
		terminalOwner = true
	}
	if !terminalClaimed { // parked record (mutex single-winner): no pending entry above
		terminalOwner = pr.Profile == nil || observation.CompactOnlyAttempt(pr.Profile) || pr.Profile.ClaimTerminal()
	}
	// Terminal usage is recorded at ingress, outside the billing gate, so a
	// completion whose reservation was already finalized (a late terminal after
	// a consumer-side refund, or any path that skips billing) still carries the
	// provider's token counts for the profile consistency check. Only the
	// terminal owner writes; msg.Profile is already nil when the pending block
	// above retained it.
	if terminalOwner {
		pr.Profile.SetTerminalUsage(msg.Usage.PromptTokens, msg.Usage.CompletionTokens)
		s.observation.RetainProviderProfile(pr.Profile, msg.Profile)
		// The provider outcome is written here, OUTSIDE the billing gate: a
		// consumer-side timeout can finalize (refund) the reservation after
		// this frame claimed but before settlement, in which case the gate
		// below is skipped and its own (idempotent) write never runs — the
		// deferred CompleteTerminal would then close the record with an empty
		// provider_outcome. Every branch that must not read "completed" (the
		// deadline-late conversion, the losing racer) returned above.
		pr.Profile.SetOutcome("", "", "", "completed", "")
	}
	msg.Profile = nil
	// The terminal half completes when this handler returns, on every branch:
	// after billing has settled and the settle_db_us stamp has landed, and after
	// the consumer has been signalled. It completes regardless of billing state
	// too — a reservation finalized earlier by a consumer-side path must not
	// leave the record waiting on the (now suppressed) fallback. Deferred at the
	// claim site (not inside the billing gate) so a PARKED completion, whose
	// consumer is already gone, cannot enqueue its record before the settlement
	// stamp is written.
	defer pr.Profile.CompleteTerminal()
	// The request is terminal — drop its memoized chunk-decryption key.
	s.chunkKeys.Forget(pr.SessionPrivKey)
	// A parked record means the consumer handler already returned: there is no
	// channel reader, and registry.Disconnect may have already CLOSED the
	// channels (park-before-remove leaves a window where the record is in both
	// the pending map and the holder) — sending would panic. Billing still
	// settles below; only the consumer signaling is skipped.
	consumerGone := parked != nil
	// After-commit client cancellation telemetry. The provider finished
	// but the consumer had already disconnected mid-stream (partial_success /
	// client_gone_after_commit). Metric-emit only — billing/settlement below is
	// unchanged.
	if consumerGone {
		s.NewMetrics().ClientGone(pr.Model, pr.EstimatedPromptTokens, observation.ProviderChipFamily(provider), phaseAfterCommit)
		// A parked (after-commit client-gone) completion is still a SERVED
		// provider dispatch, so it owes its one capacity-503 rate-window outcome
		// (capacity_rate.go denominator). On the clean-completion path
		// noteInferenceSuccess re-offers it, but that never runs here — the
		// consumer handler already returned. Re-offer it now, keyed on the
		// recorded outcome exactly as noteInferenceSuccess does. Commit-time
		// accepts are retained even before the first reject; a commit that already
		// recorded passes countRateOutcome=false and cannot double-count. A path
		// without a recorded commit contributes its sole outcome here. Uses
		// pr.ProviderID (the committed attempt's provider) to match the commit key.
		s.registry.RecordCapacityAcceptOutcome(pr.ProviderID, pr.Model, !pr.RateOutcomeCountedSafe())
	}

	// Store SE signature for the consumer response headers.
	pr.SESignature = msg.SESignature
	pr.ResponseHash = msg.ResponseHash
	pr.MatchedStopSequence = inresp.AllowedMatchedStopSequence(
		pr.RequestedStopSequences, msg.StopSequence)
	if msg.StopSequence != "" && pr.MatchedStopSequence == "" {
		s.logger.Warn("provider reported an unrequested stop sequence",
			"provider_id", providerID,
			"request_id", msg.RequestID,
		)
		s.observation.Incr("inference.invalid_stop_sequence", nil)
	}

	// Billing-zero observability: a COMPLETED request that reports zero tokens
	// is billed $0 (and fully refunded). The provider-side fix (EngineBridge
	// max + content-frame floor) should prevent this, but emit a metric so any
	// residual leak is visible on the dashboard rather than silent.
	if msg.Usage.CompletionTokens == 0 {
		s.observation.Incr("billing.zero_usage_complete", []string{"model:" + pr.Model})
		s.logger.Warn("completed request reported zero completion tokens — billed $0",
			"provider_id", providerID,
			"request_id", msg.RequestID,
			"model", pr.Model,
			"prompt_tokens", msg.Usage.PromptTokens,
		)
	}
	cacheUsagePresent := cacheusage.Has(msg.Usage)
	cacheUsageValid := cacheusage.Valid(msg.Usage)
	if cacheUsagePresent && !cacheUsageValid {
		s.observation.Incr("routing.cache_usage_rejected", nil)
		cacheusage.Clear(&msg.Usage)
	}
	if cacheUsageValid {
		tags := []string{"outcome:" + msg.Usage.CacheOutcome, "tier:" + cacheusage.LowCardinalityTier(msg.Usage.CacheTier)}
		s.observation.Incr("routing.cache_usage", tags)
		s.observation.Count("routing.cache_tokens", int64(msg.Usage.CachedTokens), tags)
		s.observation.Count("routing.cache_prefill_tokens_saved", int64(msg.Usage.PrefillTokensSaved), tags)
		s.observation.Histogram("routing.cache_stage_ms", msg.Usage.CacheStageMs, tags)
		s.observation.EmitExactCacheUsage(msg.Usage.CacheOutcome, cacheusage.LowCardinalityTier(msg.Usage.CacheTier),
			msg.Usage.CachedTokens, msg.Usage.PrefillTokensSaved, msg.Usage.CacheStageMs)
	}
	s.observation.EmitModelCacheUsage(pr, msg.Usage, cacheUsageValid, cacheUsagePresent)
	cacheTerminalClaimed := s.emitCacheSelectionTerminal(pr, msg.Usage, cacheUsageValid, cacheUsagePresent)
	s.reconcileOutputAdmission(pr, msg.Usage.CompletionTokens)

	// Record job success and usage BEFORE closing ChunkCh. Closing
	// ChunkCh unblocks the consumer response handler, and callers may
	// check usage immediately after the HTTP response completes.
	//
	// Only the success COUNT is recorded here. The responsiveness latency is
	// recorded separately by the consumer/dispatch goroutine at commit (see
	// dispatch.writeCommittedResponse), because that goroutine owns pr.Timing;
	// reading it from this provider read-loop goroutine would race the dispatch
	// writes. Passing 0 latency counts the success without touching the EWMA.
	s.registry.RecordJobSuccess(providerID, 0)
	// Serving this model proves the pair can load — lift any cool-down early.
	s.registry.ClearDispatchLoadCooldown(providerID, pr.Model)

	// Resolve the consumer once: platform-fee override (nil = global default)
	// and whether this is a wholesale/service channel (e.g. OpenRouter). A
	// failed lookup (raw API-key account with no user row) falls back to
	// defaults. Service accounts run on a 0% fee.
	var feePercent *int64
	isServiceConsumer := false
	settleStart := time.Now()
	if u, err := s.store.GetUserByAccountID(pr.ConsumerKey); err == nil && u != nil {
		feePercent = u.PlatformFeePercent
		isServiceConsumer = u.Role == store.RoleService
	}

	// Calculate cost. Direct consumers: provider custom price, then platform DB
	// price, then hardcoded defaults, with the per-request minimum applied.
	// Service/wholesale traffic is billed at the advertised platform price
	// (never a provider's higher custom price) and is exempt from the minimum,
	// so the debit matches the published per-token OpenRouter feed exactly.
	//
	// Prompt tokens the provider served from its prefix cache bill at the
	// cache-read rate (the feed's input_cache_read); the cache usage was
	// validated above, so billableUsage sees the same cached_tokens the
	// consumer does and the bill and the usage agree. A model-token promotion
	// settles through priceModelTokens instead, which prices every prompt token
	// at rates.Input (no cache-read discount on that path).
	providerAccountForPricing := ""
	if p := s.registry.GetProvider(providerID); p != nil {
		providerAccountForPricing = providerPricingKeys(p)
	}
	var price store.ModelPrice
	var priced bool
	if !isServiceConsumer && pr.PromotionFreeTokens == 0 {
		price, priced = s.store.GetModelPrice(providerAccountForPricing, pr.Model)
	}
	if !priced {
		price, priced = s.store.GetModelPrice("platform", pr.Model)
	}
	rates := payments.RatesFor(price, priced)
	billable := cacheusage.Billable(msg.Usage)
	settle := rates.CostWithMinimum
	if isServiceConsumer {
		settle = rates.Cost
	}
	totalCost := settle(billable)
	pricedCost := totalCost // before free-route, clamp and uncollected adjustments

	// Free settlement when an OWNED machine served the request. Two paths reach
	// here:
	//   - FreeSelfRoute (exclusive self-route): the router only ever picks owned
	//     providers, so a mismatch should be impossible (machine unlinked
	//     mid-flight); a mismatch falls back to paid to close the "mark free,
	//     serve elsewhere" hole.
	//   - PreferOwner (prefer-with-fallback): the request may legitimately have
	//     fallen back to a PUBLIC provider, in which case paid settlement is the
	//     correct, expected outcome — not an error.
	// Either way: free iff the provider that actually served it is owned by the
	// requesting account. Ownership is read from the serving provider object
	// (stable across deregistration), not a fresh lookup.
	freeSelfRoute := false
	if pr.FreeSelfRoute || pr.PreferOwner || pr.PromotionFreeTokens > 0 {
		serving := s.registry.GetProvider(providerID)
		if serving == nil {
			serving = provider
		}
		serving.Mu().Lock()
		servingOwner := serving.AccountID
		serving.Mu().Unlock()
		if servingOwner != "" && servingOwner == pr.ConsumerKey {
			// Owned machine served it → free. For PreferOwner this also fully
			// refunds the up-front reservation below (totalCost 0 < reserved).
			freeSelfRoute = true
			totalCost = 0
		} else if pr.FreeSelfRoute {
			// Exclusive self-route should never be served by a non-owned
			// provider — surface it and settle as paid (defense-in-depth).
			s.logger.Error("self-route completion served by a non-owned provider — settling as paid (defense-in-depth)",
				"provider_id", providerID,
				"request_id", msg.RequestID,
				"serving_owner", servingOwner,
				"consumer_key", pr.ConsumerKey,
			)
		}
		// PreferOwner served by a public provider is the normal fallback — no
		// log, settle as paid against the reservation.
	}

	recordAccounting := s.completionAccounting(pr, providerID, msg.Usage, feePercent, freeSelfRoute)
	completeFinancials := s.completionFinancials(pr, provider, msg.Usage, feePercent, freeSelfRoute, recordAccounting)
	var billingFinalized bool
	var providerPayout int64

	// Settle billing against the pre-flight reservation. All balance
	// mutations (overage charge, refund) happen inside the finalization
	// gate so that a concurrent timeout/error refund path cannot race
	// with the settlement here.
	if pr.ModelTokenReservationID != "" {
		var promotionErr error
		billingFinalized, totalCost, providerPayout, promotionErr = s.settleModelTokenPromotion(pr, provider, msg.Usage, rates, feePercent, freeSelfRoute, recordAccounting)
		if promotionErr != nil {
			s.logger.Error("promotion settlement failed", "request_id", msg.RequestID, "reservation_id", pr.ModelTokenReservationID, "error", promotionErr)
		}
	} else {
		billingFinalized, totalCost, providerPayout = s.settleCompletedConsumer(pr, totalCost, feePercent, freeSelfRoute, completeFinancials)
	}

	if billingFinalized {
		// Revenue effect of the cache hit that was actually settled: what this
		// request would have cost with every prompt token at the input rate,
		// less what it did cost, through the same settle function (so the
		// per-request minimum is honoured). Only a request that settled at its
		// computed price counts: free self-route and an uncollected charge
		// settle at 0, an overage clamp or a failed overage charge settles at a
		// cap the cold price would have hit too, and a model-token promotion
		// settles through priceModelTokens at the input rate.
		if pr.ModelTokenReservationID == "" && totalCost > 0 && totalCost == pricedCost && billable.CachedTokens > 0 {
			if discount := payments.CacheReadDiscount(settle, billable); discount > 0 {
				s.observation.Count("billing.cache_read_discount_micro_usd", discount, []string{"model:" + pr.Model})
			}
		}

		// Fallback actual_ttft_ms anchor for the COMMITTED attempt only. The
		// dispatch/handler goroutine normally stamps FirstContentAt at the
		// content-commit site (commitFirstContent / the generic stamp); this
		// fallback covers the fast single-chunk case where TypeInferenceComplete
		// reaches this provider read-loop goroutine before that stamp runs. It is
		// gated on ContentCommittedSafe so it ONLY ever stamps for the attempt that
		// actually committed content: an abandoned/retried attempt that completes
		// late (it never committed) must NOT stamp the SHARED Timing, or its stale
		// timestamp would clamp/zero the real committed retry's actual_ttft_ms
		// (FirstContentAt is first-write-wins). MarkFirstContentArrived is
		// idempotent, so for the committed attempt this is a no-op when the
		// dispatch goroutine already stamped.
		if pr.ContentCommittedSafe() && msg.Usage.CompletionTokens > 0 {
			pr.MarkFirstContentArrived()
		}

		// Update the routing telemetry outcome with final token counts and timing.
		// handleComplete is the authoritative final writer for provider completion;
		// when the consumer already disconnected this is a partial success because
		// the provider completed and billing settled, but the client did not receive
		// the full response.
		outcome := routeoutcome.CompleteRouteOutcome(pr, msg.Usage, totalCost, consumerGone)
		// Join only after both inputs are authoritative: cacheUsageValid was
		// established from the terminal usage above, and completeRouteOutcome read
		// the committed attempt's mutex-guarded first-content timestamp after the
		// fallback stamp. No request, provider, route, or scope identifier is tagged.
		if cacheTerminalClaimed {
			s.emitCacheSelectionTTFT(pr, msg.Usage, cacheUsageValid, outcome.ActualTTFTMs)
		}
		if pr.Timing != nil {
			// completeRouteOutcome already applied the per-attempt timing via
			// applyPendingRouteTelemetry — actual_ttft_ms (from FirstContentAt),
			// dispatch_to_first_chunk_ms (from FirstChunkAt), total_duration_ms,
			// and the ParseMs..DispatchMs decomposition — all using the
			// mutex-guarded timing accessors, which are race-free on this provider
			// read-loop goroutine. This block only ADDS the measured decode
			// throughput, which needs FirstChunkAt read via the same guarded
			// accessor.
			firstChunk := pr.FirstChunkAtSafe()
			// Measured decode throughput: completion tokens over the decode
			// window (first chunk -> completion). Guard zero/negative durations
			// and zero tokens so unmeasurable requests record 0.
			// CompletionTokens is provider-supplied and untrusted, so clamp the
			// derived TPS to a sanity ceiling: a dishonest/buggy provider must
			// not be able to write an absurd value that would skew routing
			// calibration (threat-model T-007/T-027). Throughput is advisory,
			// never a security gate.
			if msg.Usage.CompletionTokens > 0 && !firstChunk.IsZero() {
				if decodeSecs := time.Since(firstChunk).Seconds(); decodeSecs > 0 {
					tps := float64(msg.Usage.CompletionTokens) / decodeSecs
					if tps > maxPlausibleDecodeTPS {
						tps = maxPlausibleDecodeTPS
					}
					outcome.ActualDecodeTPS = tps
				}
			}
		}
		s.updateInferenceRouteOutcomeWithModel(msg.RequestID, pr.Attempt, pr.Model, outcome)
		// Outcome only: the terminal half completes on return (deferred at the
		// claim site), after the settlement stamps below.
		pr.Profile.SetOutcome(outcome.FinalStatus, routeoutcome.ProfileErrorReason(outcome), "", "completed", "")

		s.observation.Incr("inference.completions", []string{"model:" + pr.Model})
		// Split the partial case out of the (intentionally unchanged) completions
		// counter: the provider completed and billing settled, but the consumer had
		// already disconnected after commit. Same money path as a clean success, so
		// it is NOT a provider failure — but operationally distinct, and invisible on
		// dashboards without its own counter.
		if consumerGone {
			s.NewMetrics().PartialSuccess(pr.Model, routeoutcome.ErrorClassClientGoneAfterCommitCompleted)
		}
		s.observation.Count("inference.prompt_tokens_total", int64(msg.Usage.PromptTokens), []string{"model:" + pr.Model})
		s.observation.Histogram("inference.prompt_tokens", float64(msg.Usage.PromptTokens), []string{"model:" + pr.Model})
		s.observation.Count("inference.completion_tokens_total", int64(msg.Usage.CompletionTokens), []string{"model:" + pr.Model})
		s.observation.Histogram("inference.completion_tokens", float64(msg.Usage.CompletionTokens), []string{"model:" + pr.Model})

		// Per-backend request quality (v0.8.0 paged rollout, Gate G5). Same two
		// numbers just written to the route-outcome row, emitted as live
		// histograms segmented by the SLOT that served — (provider, pr.Model),
		// never the provider alone, because one box can hold several models on
		// different backends during a staged rollout. See kv_backend_metrics.go.
		//
		// Attributed through the provider this read loop already holds, not a
		// fresh registry lookup by id: this runs on the provider WebSocket
		// goroutine, and re-resolving would take a second registry read lock
		// per completion. It is also the more accurate object — if the box
		// reconnected between dispatch and completion, the registry now holds
		// a DIFFERENT *Provider for the same id, and the slot that served is
		// this one.
		s.emitRequestBackendLatency(pr.Model, s.providerKVBackendAttribution(provider, pr.Model),
			outcome.ActualTTFTMs, outcome.ActualDecodeTPS)

		// Ordinary settlement has already run this one-shot callback. Promotion
		// provider earnings were committed atomically with their reservation.
		recordAccounting(totalCost)
		if ap := pr.Profile; ap != nil {
			ap.SettleDBUS.Add(time.Since(settleStart).Microseconds())
		}
	}

	// Signal completion to the consumer response handler. This must happen
	// AFTER usage/billing is recorded because closing ChunkCh immediately
	// unblocks the HTTP response, and callers may check usage right after.
	// Skipped when the consumer is gone: no reader, and the channels may
	// already be closed (send would panic).
	if !consumerGone {
		pr.CompleteCh <- msg.Usage
		close(pr.ChunkCh)
		close(pr.CompleteCh)
	}

	// Mark provider idle if no more pending requests.
	s.registry.SetProviderIdle(providerID)

	s.logger.Info("inference complete",
		"request_id", msg.RequestID,
		"provider_id", providerID,
		"prompt_tokens", msg.Usage.PromptTokens,
		"completion_tokens", msg.Usage.CompletionTokens,
		"cost_micro_usd", totalCost,
		"provider_payout_micro_usd", providerPayout,
	)
}

// handleInferenceError handles a provider inference_error frame on the read
// loop (and the coordinator-synthesized errors handleChunk raises there). The
// frame holds no terminal claim; ownership is decided at the peek inside.
func (s *Owner) HandleInferenceError(providerID string, provider *registry.Provider, msg *protocol.InferenceErrorMessage) {
	s.handleInferenceErrorOwned(providerID, provider, msg, false)
}

// handleInferenceErrorOwned is handleInferenceError with terminal ownership
// threaded in: owned is true only when the caller already holds the attempt's
// terminal claim (handleCompleteAt converting a deadline-late empty
// completion), so this path must neither re-claim nor drop that frame as a
// duplicate.
func (s *Owner) handleInferenceErrorOwned(providerID string, provider *registry.Provider, msg *protocol.InferenceErrorMessage, owned bool) {
	if provider == nil {
		s.logger.Warn("error from unregistered provider", "provider_id", providerID)
		return
	}
	safeMsg, invalidFailureCode, invalidTerminalCause := failure.SanitizeProviderError(msg)
	msg = &safeMsg
	if invalidFailureCode {
		s.observation.Incr("inference.invalid_failure_code", nil)
	}
	if invalidTerminalCause {
		// Never tag the counter with the untrusted value: the value itself may be
		// an exfiltration payload and would also create unbounded cardinality.
		s.observation.Incr(metricUnknownTerminalCause, nil)
		s.observation.Incr(metricTypedTerminal, []string{"cause:unknown"})
	}
	// Ownership is decided BEFORE the pending request is removed. Completions
	// settle on a worker goroutine while error frames run inline on the read
	// loop, so an error frame for a request whose completion already claimed
	// the terminal (parked on arbitration, or mid-settlement) used to remove
	// the pending request, write the error outcome and settle — mixing the
	// completion's usage/profile with this frame's outcome. The claim is the
	// single ownership token across terminal TYPES: a frame that cannot claim
	// is a duplicate of an in-flight owned terminal and is dropped here,
	// leaving the pending request to its owner. Without a profile (profiler
	// off) there is no token and the RemovePending race decides, as before.
	// claimedHere is set only when THIS call took the claim: a pending request
	// a consumer-side cleanup removes between the claim and RemovePending
	// would otherwise never finalize (neither the funnel nor the fallback
	// completes a claimed terminal).
	var claimedHere *registry.AttemptProfile
	pending := provider.GetPending(msg.RequestID)
	if pending != nil && pending.Profile != nil && !observation.CompactOnlyAttempt(pending.Profile) && !owned {
		if !pending.Profile.ClaimTerminal() {
			s.logger.Warn("duplicate error for in-flight request", "provider_id", providerID)
			s.observation.Incr("inference.unknown_request_frames", []string{"kind:duplicate_error"})
			s.observation.AddUnknownRequestFrames(1)
			msg.Profile = nil
			return
		}
		owned, claimedHere = true, pending.Profile
		// Retain the profile now, while the owner still holds the pending
		// request: the record closes at the unknown-request return below if a
		// consumer-side cleanup removes it before RemovePending.
		s.observation.RetainProviderProfile(pending.Profile, msg.Profile)
		msg.Profile = nil
	}
	if pending != nil && failure.IsDrainingErrorReason(msg.ErrorReason) {
		s.noteProviderDraining(providerID, pending.Model)
	}
	pr := provider.RemovePending(msg.RequestID)
	// Clear any parked settlement record (consumer disconnected mid-stream).
	// Same object as a non-nil pr when the terminal raced the disconnect defer.
	parked := s.claimSettlement(msg.RequestID)
	// See handleCompleteAt: a terminal with no live pending record is matched
	// against the cancel the coordinator sent for it (metric-only).
	var cancelled cancellation.Entry
	wasCancelled := false
	if pr == nil {
		cancelled, wasCancelled = s.resolveCancelledTerminal(
			msg.RequestID, cancellation.TerminalError, cancellation.ErrorOutcome(msg), time.Now())
		pr = parked
	}
	if pr == nil {
		if wasCancelled && cancelled.Cause != cancellation.CauseStrayChunk {
			// Coordinator-minted id (it matched a recorded cancel): the
			// provider honored the cancel before producing output.
			s.logger.Debug("error for cancelled request",
				"request_id", msg.RequestID, "provider_id", providerID,
				"cause", cancelled.Cause, "status_code", msg.StatusCode)
		} else {
			// request_id is provider-controlled until it matches coordinator-owned
			// pending state. Do not log it: an attacker could use unknown IDs as an
			// arbitrary log exfiltration channel.
			s.logger.Warn("error for unknown request", "provider_id", providerID)
			s.emitUnknownFrame(cancellation.UnknownFrameKindError, provider)
		}
		s.observation.Incr("inference.unknown_request_frames", []string{"kind:error"})
		s.observation.AddUnknownRequestFrames(1)
		// A terminal claimed here whose pending request a consumer-side cleanup
		// removed in between: the provider errored, the coordinator lost
		// ownership; close the record rather than leak the attempt. An owned
		// claim passed in by handleCompleteAt is closed by that caller instead
		// (as "completed"); both calls are nil-safe when nothing was claimed.
		claimedHere.SetOutcome("", "", "", "error", "")
		claimedHere.CompleteTerminal()
		return
	}
	// From this point onward use only the coordinator-owned identifier.
	msg.RequestID = pr.RequestID
	if pending == nil && failure.IsDrainingErrorReason(msg.ErrorReason) {
		// A consumer-gone request may already be parked outside the pending
		// map. Fence its provider before SetProviderIdle drains queued work.
		s.noteProviderDraining(providerID, pr.Model)
	}
	if ap := pr.Profile; ap != nil {
		if observation.CompactOnlyAttempt(ap) {
			ap.ClaimTerminal()
		}
		ap.Mark(registry.StampCompleteIngress)
		// A pending entry was claimed at the peek above; a PARKED record (no
		// pending entry) is claimed here. claimSettlement is single-winner, so
		// retention is exactly-once; in the narrow parked race (an owned
		// completion claims on its worker, a post-commit disconnect parks the
		// record, and this error frame wins the parked settlement) the settler
		// can differ from the claim owner — the completion then closes its own
		// record as completed without billing while this frame settles, which
		// is safe because this defer is unconditional. Only the owner retains
		// the profile, once.
		if owned || ap.ClaimTerminal() {
			s.observation.RetainProviderProfile(ap, msg.Profile)
		}
		msg.Profile = nil
		// Leave final_status/error_reason to the phase-aware classifier (the
		// relay or dispatch loop writes partial_success / error / cancelled
		// through the route-outcome funnel); only the terminal cause and the
		// provider-side outcome are authoritative here.
		ap.SetOutcome("", "", string(msg.TerminalCause), "error", "")
		// The terminal half completes when this handler returns: after the
		// parked (consumer-gone) branch has classified partial_success, and
		// after the live branch has pushed the error to its channel reader.
		defer ap.CompleteTerminal()
	}
	// The request is terminal — drop its memoized chunk-decryption key.
	s.chunkKeys.Forget(pr.SessionPrivKey)
	consumerGone := parked != nil
	// Provider errors carry no validated cache usage, but still close the
	// selection/outcome correlation denominator as an unreported result.
	s.emitCacheSelectionTerminal(pr, protocol.UsageInfo{}, false, false)

	// Record a job failure, but not for capacity rejections or consumer
	// cancellations — neither is a provider fault. Capacity = load shedding the
	// coordinator reroutes. Cancel (499 / "request cancelled") = the CONSUMER
	// disconnected; before the settlement holder these terminals died on
	// pr==nil with zero reputation effect, and the old fleet emits one for
	// every mid-stream disconnect — penalizing them would erode the whole
	// fleet's reputation for consumer behavior.
	//
	// A structured health-neutral error_reason is exempt too
	// (isProviderHealthNeutralErrorReason): jinja_* template-render failures (E4 —
	// the model's chat template could not render the REQUEST's tool schemas
	// or message history, a request-shape fault that fails identically on
	// every provider; prod: jinja requests averaged 1.57 dispatch rows, each
	// one erasing reputation fleet-wide for a body the provider never
	// controlled) and tool_noncompliance (E5 — the MODEL's sampled output
	// broke a forced tool_choice contract; the 422 stays on the bounded
	// failover path precisely because a re-sample can comply, so each
	// attempted provider must not eat a reputation strike for what the model
	// generated), plus deadline_unreachable (the coordinator-supplied remaining
	// SLA could not be met). A plain 422 with no structured reason still counts
	// — only the typed vocabulary exonerates.
	// Typed terminal cause (new providers). Classify once and emit the typed
	// terminal metrics; neutral (safety_deadline / backpressure_timeout /
	// cancelled — platform policy or consumer behavior) and capacity
	// (admission_timeout — healthy but busy) causes are exempt from the fault
	// recorder below regardless of status/string shape. Absent, engine_error,
	// or unknown causes keep the legacy heuristics bit-for-bit.
	causeClass := s.noteTypedTerminalCause(msg.TerminalCause)
	causeNeutralForHealth := causeClass == failure.CauseClassNeutral || causeClass == failure.CauseClassCapacity

	capacityRejection := msg.FailureCode == protocol.FailureCodeCapacity ||
		msg.FailureCode == protocol.FailureCodeModelUnavailable ||
		causeClass == failure.CauseClassCapacity
	cancelTerminal := msg.FailureCode == protocol.FailureCodeCancelled ||
		msg.TerminalCause == failure.TerminalCauseCancelled
	providerHealthNeutral := failure.IsProviderHealthNeutralErrorReason(msg.ErrorReason)
	if !capacityRejection && !cancelTerminal && !providerHealthNeutral && !causeNeutralForHealth {
		s.registry.RecordJobFailure(providerID)
	}

	// Cool down a load-rejecting pair so retries skip it (see
	// dispatchLoadCooldowns). Covers BOTH flavors: capacity rejects
	// ("insufficient memory", not a fault) and generic load failures ("model
	// load failed": bad weights/metallib/kernel — IS a fault, reputation hit
	// above stands). The cool-down matters most during an alias migration: a
	// build that verifies on disk but cannot GPU-load would otherwise keep
	// attracting 100% of the alias traffic as repeated 500s — cooling the pair
	// makes the desired build unroutable so alias resolution falls back to the
	// previous build.
	// A typed fully-neutral cause (safety_deadline / backpressure_timeout /
	// cancelled) is strictly neutral, and a typed capacity cause
	// (admission_timeout) feeds ONLY the capacity cooldown recorded in
	// noteInferenceError — neither may feed the load cooldown. Their error
	// text never carries the load-failure vocabulary anyway; the explicit
	// allowlist (legacy or fault only) makes both guarantees unconditional
	// rather than dependent on provider error-string phrasing.
	if (causeClass == failure.CauseClassLegacy || causeClass == failure.CauseClassFault) &&
		msg.ErrorReason == failure.ErrorReasonModelLoad {
		if s.registry.RecordDispatchLoadFailure(providerID, pr.Model) {
			s.logger.Warn("load-failure cool-down started",
				"provider_id", providerID,
				"model", pr.Model,
			)
			s.observation.Incr("routing.load_failure_cooldowns", []string{"model:" + pr.Model})
		}
	}

	s.registry.SetProviderIdle(providerID)

	if consumerGone {
		status := "partial_success"
		errorClass := "client_gone_after_commit_provider_error"
		if cancelTerminal {
			errorClass = "client_gone_after_commit_provider_cancelled"
		}
		// After-commit client cancellation: the provider terminated (error /
		// cancel / disconnect) after the consumer had already gone. Count it on
		// routing.client_gone so the after_commit phase reflects ALL post-commit
		// disconnects, not just provider-completed ones (handleComplete). A
		// no-terminal disconnect is counted by the settlement grace path.
		s.NewMetrics().ClientGone(pr.Model, pr.EstimatedPromptTokens, observation.ProviderChipFamily(provider), phaseAfterCommit)
		outcome := routeoutcome.PendingRouteOutcomeWithReason(pr, status, errorClass, msg.StatusCode, msg.ErrorReason, msg.Error)
		if !cancelTerminal {
			outcome.AdmittedButFailed = true
		}
		routeoutcome.ApplyAttemptUsage(outcome, msg.AttemptUsage)
		s.updateInferenceRouteOutcomeForPending(pr, outcome)
		// Consumer disconnected — no reader for the channels; settle by
		// refunding, OFF the read loop (a store Credit can block for seconds
		// under DB pressure, and blocking this loop stalls heartbeats and
		// challenge responses — the eviction-churn vector). Idempotent vs. the
		// settlement grace timer via FinalizeReservation.
		//
		// Deliberately NOT unconditional: during the dispatch retry window the
		// consumer handler keeps the base reservation alive for the next
		// attempt — refunding/finalizing it here would let a later successful
		// attempt settle against a dead reservation (served for free). Errors
		// with a live consumer are refunded by their channel readers (relay /
		// dispatch-exhaustion paths); the relay-return→park gap is swept by
		// the post-commit defer's last-chance refund in consumer.go.
		refundPr := pr
		refundID := msg.RequestID
		saferun.Go(s.logger, "api.refundAfterDisconnect", func() {
			s.refundReservedBalance(refundPr, "provider_error_after_disconnect:"+refundID)
		})
		return
	}

	pr.ErrorCh <- *msg
	close(pr.ChunkCh)
	close(pr.CompleteCh)
	close(pr.ErrorCh)

	s.logger.Error("inference error",
		"request_id", msg.RequestID,
		"provider_id", providerID,
		"failure_code", msg.FailureCode,
		"status_code", msg.StatusCode,
		"terminal_cause", msg.TerminalCause,
	)
}

func (s *Owner) emitCacheSelectionTerminal(pr *registry.PendingRequest, usage protocol.UsageInfo, valid, present bool) bool {
	return s.observation.EmitCacheSelectionTerminal(pr, usage, valid, present)
}

func (s *Owner) emitCacheSelectionTTFT(pr *registry.PendingRequest, usage protocol.UsageInfo, valid bool, ttft float64) {
	s.observation.EmitCacheSelectionTTFT(pr, usage, valid, ttft)
}
