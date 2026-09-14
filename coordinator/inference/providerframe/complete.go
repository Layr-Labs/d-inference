package providerframe

import (
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/inference/attempt"
	"github.com/eigeninference/d-inference/coordinator/inference/dispatch"
	"github.com/eigeninference/d-inference/coordinator/inference/response"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// maxPlausibleDecodeTPS is the sanity ceiling applied to the telemetry-only
// ActualDecodeTPS before it is persisted. Real decode throughput on the fleet's
// Apple-silicon hardware is in the tens-to-low-hundreds of tokens/sec; this
// ceiling is far above any genuine value and exists solely to stop a dishonest
// or buggy provider's unbounded CompletionTokens from writing an absurd TPS that
// could skew routing calibration. The value is advisory, never a security gate.
const maxPlausibleDecodeTPS = 10000.0

func (s *Service) CompleteAt(
	providerID string,
	provider *registry.Provider,
	msg *protocol.InferenceCompleteMessage,
	receivedAt time.Time,
) {
	if provider == nil {
		s.deps.Logger().Warn("complete from unregistered provider", "provider_id", providerID)
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
		compact := compactOnlyAttempt(pending.Profile)
		terminalOwner, terminalClaimed = pending.Profile == nil || compact || pending.Profile.ClaimTerminal(), true
		if !terminalOwner {
			s.deps.Logger().Warn("duplicate complete for in-flight request", "provider_id", providerID)
			s.deps.Metrics.Incr("inference.unknown_request_frames", []string{"kind:duplicate_complete"})
			s.unknownRequestFrames.Add(1)
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
		s.deps.RetainProfile(pending.Profile, msg.Profile)
		msg.Profile = nil
		if !pending.HasFirstContentIngress() &&
			!pending.FirstContentDeadline.IsZero() &&
			receivedAt.After(pending.FirstContentDeadline) {
			// A clean terminal without content is a valid empty completion only
			// while the first-content SLA is still live. Once the absolute deadline
			// has passed it must not race the dispatch timer into an empty HTTP 200.
			// owned: this frame already holds the claim, so the error path
			// must neither re-claim nor drop the conversion as a duplicate.
			s.errorOwned(providerID, provider, &protocol.InferenceErrorMessage{
				Type:        protocol.TypeInferenceError,
				RequestID:   pending.RequestID,
				Error:       "provider completed after the first-content deadline",
				StatusCode:  http.StatusServiceUnavailable,
				ErrorReason: attempt.ErrorReasonDeadlineUnreachable,
				FailureCode: protocol.FailureCodeCapacity,
			}, true)
			// Error completes the terminal only when it still
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
				// Error — and the idempotent CompleteTerminal
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
	parked := s.deps.ClaimSettlement(msg.RequestID)
	// No live pending record means the attempt was abandoned (or is unknown):
	// correlate the terminal with the cancel the coordinator sent. Metric-only
	// — a parked post-commit record still settles billing below, and a
	// pre-commit attempt was refunded when it was abandoned. Only a terminal
	// that finds no live record is matched, so the coordinator's own
	// synthesized errors (raised while the record is live) never resolve one.
	var cancelled attempt.Cancellation
	wasCancelled := false
	if pr == nil {
		cancelled, wasCancelled = s.deps.Attempts().ResolveCancelledTerminal(
			msg.RequestID, attempt.CancelTerminalComplete, attempt.CancelledOutcomeCompletePartial, receivedAt)
		pr = parked
	}
	if pr == nil {
		if wasCancelled && cancelled.Cause() != attempt.CancelCauseStrayChunk {
			// The id matched a cancel the coordinator recorded, so it is
			// coordinator-minted and safe to log: the provider honored the
			// cancel with a partial completion.
			s.deps.Logger().Debug("complete for cancelled request",
				"request_id", msg.RequestID, "provider_id", providerID, "cause", cancelled.Cause())
		} else {
			// Until it matches pending state, request_id is provider-controlled and
			// therefore an arbitrary log-exfiltration channel.
			s.deps.Logger().Warn("complete for unknown request", "provider_id", providerID)
			s.deps.Telemetry.UnknownFrame(unknownFrameKindComplete, provider)
		}
		s.deps.Metrics.Incr("inference.unknown_request_frames", []string{"kind:complete"})
		s.unknownRequestFrames.Add(1)
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
	if compactOnlyAttempt(pr.Profile) {
		// With heavy profiling off, RemovePending/claimSettlement is the
		// existing arbitration. Only its actual winner claims compact
		// evidence, after removal; receipt never gates another terminal.
		pr.Profile.ClaimTerminal()
		terminalOwner = true
	}
	if !terminalClaimed { // parked record (mutex single-winner): no pending entry above
		terminalOwner = pr.Profile == nil || compactOnlyAttempt(pr.Profile) || pr.Profile.ClaimTerminal()
	}
	// Terminal usage is recorded at ingress, outside the billing gate, so a
	// completion whose reservation was already finalized (a late terminal after
	// a consumer-side refund, or any path that skips billing) still carries the
	// provider's token counts for the profile consistency check. Only the
	// terminal owner writes; msg.Profile is already nil when the pending block
	// above retained it.
	if terminalOwner {
		pr.Profile.SetTerminalUsage(msg.Usage.PromptTokens, msg.Usage.CompletionTokens)
		s.deps.RetainProfile(pr.Profile, msg.Profile)
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
	s.chunkKeys.forget(pr.SessionPrivKey)
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
		s.deps.Telemetry.ClientGone(pr.Model, pr.EstimatedPromptTokens, dispatch.ProviderChipFamily(provider), dispatch.PhaseAfterCommit)
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
		s.deps.Registry().RecordCapacityAcceptOutcome(pr.ProviderID, pr.Model, !pr.RateOutcomeCountedSafe())
	}

	// Store SE signature for the consumer response headers.
	pr.SESignature = msg.SESignature
	pr.ResponseHash = msg.ResponseHash
	pr.MatchedStopSequence = response.AllowedMatchedStopSequence(
		pr.RequestedStopSequences, msg.StopSequence)
	if msg.StopSequence != "" && pr.MatchedStopSequence == "" {
		s.deps.Logger().Warn("provider reported an unrequested stop sequence",
			"provider_id", providerID,
			"request_id", msg.RequestID,
		)
		s.deps.Metrics.Incr("inference.invalid_stop_sequence", nil)
	}

	// Billing-zero observability: a COMPLETED request that reports zero tokens
	// is billed $0 (and fully refunded). The provider-side fix (EngineBridge
	// max + content-frame floor) should prevent this, but emit a metric so any
	// residual leak is visible on the dashboard rather than silent.
	if msg.Usage.CompletionTokens == 0 {
		s.deps.Metrics.Incr("billing.zero_usage_complete", []string{"model:" + pr.Model})
		s.deps.Logger().Warn("completed request reported zero completion tokens — billed $0",
			"provider_id", providerID,
			"request_id", msg.RequestID,
			"model", pr.Model,
			"prompt_tokens", msg.Usage.PromptTokens,
		)
	}
	cacheUsagePresent := hasCacheUsage(msg.Usage)
	cacheUsageValid := ValidCacheUsage(msg.Usage)
	if cacheUsagePresent && !cacheUsageValid {
		s.deps.Metrics.Incr("routing.cache_usage_rejected", nil)
		clearCacheUsage(&msg.Usage)
	}
	if cacheUsageValid {
		tags := []string{"outcome:" + msg.Usage.CacheOutcome, "tier:" + dispatch.LowCardinalityCacheTier(msg.Usage.CacheTier)}
		s.deps.Metrics.Incr("routing.cache_usage", tags)
		s.deps.Metrics.Count("routing.cache_tokens", int64(msg.Usage.CachedTokens), tags)
		s.deps.Metrics.Count("routing.cache_prefill_tokens_saved", int64(msg.Usage.PrefillTokensSaved), tags)
		s.deps.Metrics.Histogram("routing.cache_stage_ms", msg.Usage.CacheStageMs, tags)
		s.deps.Cache.ExactUsage(msg.Usage.CacheOutcome, dispatch.LowCardinalityCacheTier(msg.Usage.CacheTier),
			msg.Usage.CachedTokens, msg.Usage.PrefillTokensSaved, msg.Usage.CacheStageMs)
	}
	s.deps.Cache.Usage(pr, msg.Usage, cacheUsageValid, cacheUsagePresent)
	cacheTerminalClaimed := s.deps.Cache.Terminal(pr, msg.Usage, cacheUsageValid, cacheUsagePresent)
	s.deps.ReconcileOutput(pr, msg.Usage.CompletionTokens)

	// Record job success and usage BEFORE closing ChunkCh. Closing
	// ChunkCh unblocks the consumer response handler, and callers may
	// check usage immediately after the HTTP response completes.
	//
	// Only the success COUNT is recorded here. The responsiveness latency is
	// recorded separately by the consumer/dispatch goroutine at commit (see
	// dispatch.writeCommittedResponse), because that goroutine owns pr.Timing;
	// reading it from this provider read-loop goroutine would race the dispatch
	// writes. Passing 0 latency counts the success without touching the EWMA.
	s.deps.Registry().RecordJobSuccess(providerID, 0)
	// Serving this model proves the pair can load — lift any cool-down early.
	s.deps.Registry().ClearDispatchLoadCooldown(providerID, pr.Model)

	result := s.deps.Settlement().Complete(providerID, provider, pr, msg, func(totalCost int64) {
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
		// CompleteAt is the authoritative final writer for provider completion;
		// when the consumer already disconnected this is a partial success because
		// the provider completed and billing settled, but the client did not receive
		// the full response.
		outcome := attempt.CompleteRouteOutcome(pr, msg.Usage, totalCost, consumerGone)
		// Join only after both inputs are authoritative: cacheUsageValid was
		// established from the terminal usage above, and completeRouteOutcome read
		// the committed attempt's mutex-guarded first-content timestamp after the
		// fallback stamp. No request, provider, route, or scope identifier is tagged.
		if cacheTerminalClaimed {
			s.deps.Cache.TTFT(pr, msg.Usage, cacheUsageValid, outcome.ActualTTFTMs)
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
		s.deps.Outcomes.RouteOutcome(msg.RequestID, pr.Attempt, pr.Model, outcome)
		// Outcome only: the terminal half completes on return (deferred at the
		// claim site), after the settlement stamps below.
		pr.Profile.SetOutcome(outcome.FinalStatus, attempt.ProfileErrorReason(outcome), "", "completed", "")

		s.deps.Metrics.Incr("inference.completions", []string{"model:" + pr.Model})
		// Split the partial case out of the (intentionally unchanged) completions
		// counter: the provider completed and billing settled, but the consumer had
		// already disconnected after commit. Same money path as a clean success, so
		// it is NOT a provider failure — but operationally distinct, and invisible on
		// dashboards without its own counter.
		if consumerGone {
			s.deps.Telemetry.PartialSuccess(pr.Model, attempt.ErrorClassClientGoneAfterCommitCompleted)
		}
		s.deps.Metrics.Count("inference.prompt_tokens_total", int64(msg.Usage.PromptTokens), []string{"model:" + pr.Model})
		s.deps.Metrics.Histogram("inference.prompt_tokens", float64(msg.Usage.PromptTokens), []string{"model:" + pr.Model})
		s.deps.Metrics.Count("inference.completion_tokens_total", int64(msg.Usage.CompletionTokens), []string{"model:" + pr.Model})
		s.deps.Metrics.Histogram("inference.completion_tokens", float64(msg.Usage.CompletionTokens), []string{"model:" + pr.Model})

		// Per-backend request quality (v0.8.0 paged rollout, Gate G5). Same two
		// numbers just written to the route-outcome row, emitted as live
		// histograms segmented by the SLOT that served — (provider, pr.Model),
		// never the provider alone, because one box can hold several models on
		// different backends during a staged rollout. See coordinator/api/kv_backend_metrics.go.
		//
		// Attributed through the provider this read loop already holds, not a
		// fresh registry lookup by id: this runs on the provider WebSocket
		// goroutine, and re-resolving would take a second registry read lock
		// per completion. It is also the more accurate object — if the box
		// reconnected between dispatch and completion, the registry now holds
		// a DIFFERENT *Provider for the same id, and the slot that served is
		// this one.
		s.deps.Telemetry.BackendLatency(pr.Model, s.deps.BackendAttribution(provider, pr.Model),
			outcome.ActualTTFTMs, outcome.ActualDecodeTPS)
	})
	totalCost, providerPayout := result.CostMicroUSD, result.ProviderPayoutMicroUSD

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
	s.deps.Registry().SetProviderIdle(providerID)

	s.deps.Logger().Info("inference complete",
		"request_id", msg.RequestID,
		"provider_id", providerID,
		"prompt_tokens", msg.Usage.PromptTokens,
		"completion_tokens", msg.Usage.CompletionTokens,
		"cost_micro_usd", totalCost,
		"provider_payout_micro_usd", providerPayout,
	)
}
