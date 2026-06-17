package api

import (
	"errors"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *Server) handleChunk(providerID string, provider *registry.Provider, msg *protocol.InferenceResponseChunkMessage) {
	if provider == nil {
		s.logger.Warn("chunk from unregistered provider", "provider_id", providerID)
		return
	}
	pr := provider.GetPending(msg.RequestID)
	if pr == nil {
		s.logger.Warn("chunk for unknown request", "provider_id", providerID, "request_id", msg.RequestID)
		// The provider is still generating into a stream we abandoned (consumer
		// gone / already settled), burning its GPU and token-budget admission.
		// Nudge it to stop — throttled so a chunk-per-token zombie doesn't flood
		// the provider with cancels.
		if s.zombieCanceller.shouldCancel(msg.RequestID, time.Now()) {
			s.sendProviderCancel(provider, msg.RequestID)
			s.ddIncr("inference.zombie_stream_cancel", []string{})
		}
		return
	}
	chunkData, err := decryptTextResponseChunk(provider, pr, msg)
	if err != nil {
		s.logger.Warn("rejecting insecure response chunk",
			"provider_id", providerID,
			"request_id", msg.RequestID,
			"error", err,
		)
		s.registry.MarkUntrusted(providerID)
		s.handleInferenceError(providerID, provider, &protocol.InferenceErrorMessage{
			Type:       protocol.TypeInferenceError,
			RequestID:  msg.RequestID,
			Error:      "provider returned invalid encrypted chunk",
			StatusCode: http.StatusBadGateway,
		})
		return
	}
	// Non-blocking send — if consumer is gone the chunk is dropped.
	select {
	case pr.ChunkCh <- chunkData:
	default:
		s.logger.Warn("dropped chunk, consumer channel full", "request_id", msg.RequestID)
	}
}

func decryptTextResponseChunk(provider *registry.Provider, pr *registry.PendingRequest, msg *protocol.InferenceResponseChunkMessage) (string, error) {
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
	session := &e2e.SessionKeys{PrivateKey: *pr.SessionPrivKey}
	plaintext, err := e2e.Decrypt(payload, session)
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

func (s *Server) handleInferenceAccepted(provider *registry.Provider, msg *protocol.InferenceAcceptedMessage) {
	if provider == nil {
		return
	}
	pr := provider.GetPending(msg.RequestID)
	if pr == nil {
		return
	}
	// Non-blocking signal — the dispatch loop may have already committed.
	select {
	case pr.AcceptedCh <- struct{}{}:
	default:
	}
}

func (s *Server) handleComplete(providerID string, provider *registry.Provider, msg *protocol.InferenceCompleteMessage) {
	if provider == nil {
		s.logger.Warn("complete from unregistered provider", "provider_id", providerID)
		return
	}
	pr := provider.RemovePending(msg.RequestID)
	// Clear any parked settlement record (consumer disconnected mid-stream):
	// settles the disconnect case and stops the grace timer from no-op-refunding.
	parked := s.claimSettlement(msg.RequestID)
	if pr == nil {
		pr = parked
	}
	if pr == nil {
		s.logger.Warn("complete for unknown request", "provider_id", providerID, "request_id", msg.RequestID)
		return
	}
	// A parked record means the consumer handler already returned: there is no
	// channel reader, and registry.Disconnect may have already CLOSED the
	// channels (park-before-remove leaves a window where the record is in both
	// the pending map and the holder) — sending would panic. Billing still
	// settles below; only the consumer signaling is skipped.
	consumerGone := parked != nil

	// Store SE signature for the consumer response headers.
	pr.SESignature = msg.SESignature
	pr.ResponseHash = msg.ResponseHash

	// Billing-zero observability: a COMPLETED request that reports zero tokens
	// is billed $0 (and fully refunded). The provider-side fix (EngineBridge
	// max + content-frame floor) should prevent this, but emit a metric so any
	// residual leak is visible on the dashboard rather than silent.
	if msg.Usage.CompletionTokens == 0 {
		s.ddIncr("billing.zero_usage_complete", []string{"model:" + pr.Model})
		s.logger.Warn("completed request reported zero completion tokens — billed $0",
			"provider_id", providerID,
			"request_id", msg.RequestID,
			"model", pr.Model,
			"prompt_tokens", msg.Usage.PromptTokens,
		)
	}
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
	if u, err := s.store.GetUserByAccountID(pr.ConsumerKey); err == nil && u != nil {
		feePercent = u.PlatformFeePercent
		isServiceConsumer = u.Role == store.RoleService
	}

	// Calculate cost. Direct consumers: provider custom price, then platform DB
	// price, then hardcoded defaults, with the per-request minimum applied.
	// Service/wholesale traffic is billed at the advertised platform price
	// (never a provider's higher custom price) and is exempt from the minimum,
	// so the debit matches the published per-token OpenRouter feed exactly.
	providerAccountForPricing := ""
	if p := s.registry.GetProvider(providerID); p != nil {
		providerAccountForPricing = providerPricingKeys(p)
	}
	var customIn, customOut int64
	var hasCustom bool
	if !isServiceConsumer {
		customIn, customOut, hasCustom = s.store.GetModelPrice(providerAccountForPricing, pr.Model)
	}
	if !hasCustom {
		customIn, customOut, hasCustom = s.store.GetModelPrice("platform", pr.Model)
	}
	var totalCost int64
	if isServiceConsumer {
		totalCost = payments.CalculateCostWithOverridesNoMinimum(pr.Model, msg.Usage.PromptTokens, msg.Usage.CompletionTokens, customIn, customOut, hasCustom)
	} else {
		totalCost = payments.CalculateCostWithOverrides(pr.Model, msg.Usage.PromptTokens, msg.Usage.CompletionTokens, customIn, customOut, hasCustom)
	}

	providerPayout := payments.ProviderPayoutWithPercent(totalCost, feePercent)

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
	if pr.FreeSelfRoute || pr.PreferOwner {
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
			providerPayout = 0
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

	billingFinalized := true

	// Settle billing against the pre-flight reservation. All balance
	// mutations (overage charge, refund) happen inside the finalization
	// gate so that a concurrent timeout/error refund path cannot race
	// with the settlement here.
	if pr.ServiceReservation && pr.ReservedMicroUSD > 0 {
		var chargeErr error
		finalized, _ := pr.FinalizeReservation(func() error {
			if totalCost > 0 {
				start := time.Now()
				chargeErr = s.ledger.Charge(pr.ConsumerKey, totalCost, msg.RequestID)
				s.ddHistogram("store.debit.latency_ms", float64(time.Since(start).Milliseconds()), []string{"op:service_reservation_settle"})
			}
			s.releaseServiceReservation(pr, "finalize")
			return nil
		})
		if !finalized {
			billingFinalized = false
			s.logger.Warn("skipping completion billing for already-finalized service reservation",
				"provider_id", providerID,
				"request_id", msg.RequestID,
			)
		} else if chargeErr != nil {
			if errors.Is(chargeErr, store.ErrInsufficientBalance) {
				s.logger.Warn("service reservation settlement failed (insufficient balance) — zeroing uncollected charge",
					"consumer_key", pr.ConsumerKey,
					"cost_micro_usd", totalCost,
				)
			} else {
				s.logger.Error("service reservation settlement failed (DB error) — zeroing uncollected charge",
					"consumer_key", pr.ConsumerKey,
					"cost_micro_usd", totalCost,
					"error", chargeErr,
				)
			}
			totalCost = 0
			providerPayout = 0
			s.ddIncr("billing.uncollected_zeroed", []string{"model:" + pr.Model, "mode:service_hold"})
		} else {
			s.ddIncr("billing.reservation_finalize", []string{"model:" + pr.Model, "mode:service_hold", "outcome:charged"})
			s.ddHistogram("billing.service_settlement_micro_usd", float64(totalCost), []string{"model:" + pr.Model})
		}
	} else if pr.ReservedMicroUSD > 0 {
		if !pr.MarkReservationFinalized() {
			billingFinalized = false
			s.logger.Warn("skipping completion billing for already-finalized reservation",
				"provider_id", providerID,
				"request_id", msg.RequestID,
			)
		} else if totalCost > pr.ReservedMicroUSD {
			// Actual cost exceeds reservation (e.g. provider custom
			// pricing above platform rate). Attempt to charge the
			// consumer the difference. Cap overage at the reservation
			// amount as a fraud circuit-breaker — a provider cannot
			// bill more than 2x the pre-flight estimate.
			overage := totalCost - pr.ReservedMicroUSD
			if overage > pr.ReservedMicroUSD {
				s.logger.Error("overage exceeds reservation cap — clamping",
					"provider_id", providerID,
					"request_id", msg.RequestID,
					"reported_cost_micro_usd", totalCost,
					"reserved_micro_usd", pr.ReservedMicroUSD,
					"uncapped_overage_micro_usd", overage,
				)
				s.ddIncr("billing.cost_clamped", []string{"model:" + pr.Model})
				overage = pr.ReservedMicroUSD
				totalCost = pr.ReservedMicroUSD * 2
			}
			if err := s.ledger.Charge(pr.ConsumerKey, overage, "overage:"+msg.RequestID); err != nil {
				// Overage charge failed — clamp to reservation so
				// the provider still gets paid something.
				if errors.Is(err, store.ErrInsufficientBalance) {
					s.logger.Warn("overage charge failed (insufficient balance) — clamping to reservation",
						"provider_id", providerID,
						"request_id", msg.RequestID,
						"reported_cost_micro_usd", totalCost,
						"reserved_micro_usd", pr.ReservedMicroUSD,
						"overage_micro_usd", overage,
					)
				} else {
					s.logger.Error("overage charge failed (DB error) — clamping to reservation",
						"provider_id", providerID,
						"request_id", msg.RequestID,
						"reported_cost_micro_usd", totalCost,
						"reserved_micro_usd", pr.ReservedMicroUSD,
						"overage_micro_usd", overage,
						"error", err,
					)
				}
				s.ddIncr("billing.cost_clamped", []string{"model:" + pr.Model})
				totalCost = pr.ReservedMicroUSD
			} else {
				s.logger.Info("overage charged to consumer",
					"provider_id", providerID,
					"request_id", msg.RequestID,
					"overage_micro_usd", overage,
					"total_cost_micro_usd", totalCost,
				)
				s.ddIncr("billing.overage_charged", []string{"model:" + pr.Model})
				s.ddHistogram("billing.overage_micro_usd", float64(overage), []string{"model:" + pr.Model})
				pr.ReservedMicroUSD = totalCost
			}
			// Recompute payout after potential clamp.
			providerPayout = payments.ProviderPayoutWithPercent(totalCost, feePercent)
		} else if totalCost < pr.ReservedMicroUSD {
			refund := pr.ReservedMicroUSD - totalCost
			start := time.Now()
			_ = s.store.Credit(pr.ConsumerKey, refund, store.LedgerRefund, msg.RequestID)
			s.ddHistogram("billing.settlement_refund_micro_usd", float64(refund), []string{"model:" + pr.Model})
			s.ddHistogram("store.credit.latency_ms", float64(time.Since(start).Milliseconds()), []string{"op:settlement_refund"})
		}
	} else if !freeSelfRoute {
		start := time.Now()
		if err := s.ledger.Charge(pr.ConsumerKey, totalCost, msg.RequestID); err != nil {
			if errors.Is(err, store.ErrInsufficientBalance) {
				s.logger.Warn("could not charge consumer (insufficient balance)",
					"consumer_key", pr.ConsumerKey,
					"cost_micro_usd", totalCost,
				)
			} else {
				s.logger.Error("could not charge consumer (DB error)",
					"consumer_key", pr.ConsumerKey,
					"cost_micro_usd", totalCost,
					"error", err,
				)
			}
			// If this was a self-route request that FELL BACK to paid settlement
			// (marked free at dispatch, but mid-flight ownership revalidation
			// failed), the owner has no balance because self-route skips
			// reservation — so a failed charge means no money was collected and
			// we must NOT credit the provider from an unfunded balance. Zero the
			// cost and payout. (Other no-reservation paths — e.g. admin /
			// platform-covered usage — keep their existing payout behavior.)
			if pr.FreeSelfRoute {
				totalCost = 0
				providerPayout = 0
				s.ddIncr("billing.uncollected_zeroed", []string{"model:" + pr.Model})
			}
		}
		s.ddHistogram("store.debit.latency_ms", float64(time.Since(start).Milliseconds()), []string{"op:charge"})
	}

	if billingFinalized {
		// Record in-memory usage (for current session queries).
		s.ledger.RecordUsage(pr.ConsumerKey, payments.UsageEntry{
			JobID:            msg.RequestID,
			Model:            consumerModel(pr),
			PromptTokens:     msg.Usage.PromptTokens,
			CompletionTokens: msg.Usage.CompletionTokens,
			CostMicroUSD:     totalCost,
			Timestamp:        time.Now(),
		})

		// Persist usage to DB asynchronously — billing has already been
		// settled above, so this INSERT is not on the critical path. KeyID
		// carries per-key usage/spend attribution (empty for legacy callers).
		//
		// Skip the persistent (public-stats-feeding) row for FREE self-route:
		// it is private, owner-only traffic and must not appear in the public
		// /stats time-series, request-location, or flow aggregations. Private-only
		// providers only ever serve free self-route, so this also keeps their
		// traffic out of public stats. The owner still sees it via the in-memory
		// RecordUsage above (their session/transparency view).
		if !freeSelfRoute {
			saferun.Go(s.logger, "recordUsage", func() {
				s.store.RecordUsageFullWithPublicModel(providerID, pr.ConsumerKey, pr.KeyID, pr.Model, consumerModel(pr), msg.RequestID, msg.Usage.PromptTokens, msg.Usage.CompletionTokens, totalCost, pr.ConsumerLocation)
			})
		}

		// Update the routing telemetry outcome with final token counts and timing.
		// handleComplete is the authoritative final writer for a SUCCESSFUL request
		// (UpdateInferenceRouteOutcome overwrites the whole row), so this outcome
		// carries the full coordinator-side latency decomposition and the measured
		// decode throughput in addition to tokens/cost.
		s.submitTelemetry("updateInferenceRoute", func() {
			outcome := &store.InferenceRouteOutcome{
				FinalStatus:      "success",
				PromptTokens:     msg.Usage.PromptTokens,
				CompletionTokens: msg.Usage.CompletionTokens,
				ReasoningTokens:  msg.Usage.ReasoningTokens,
				CostMicroUSD:     totalCost,
			}
			if pr.Timing != nil {
				t := pr.Timing
				// This runs on the provider read-loop goroutine, not the request
				// owner. FirstChunkAt is the one Timing field the dispatch goroutine
				// writes after dispatch (while streaming), so read it via the
				// mutex-guarded accessor to avoid a data race. The remaining fields
				// (DispatchedAt, ReceivedAt, and those used by applyTimingDecomposition)
				// are all stamped before dispatch and are safe to read here via the
				// provider-registration happens-before edge.
				firstChunk := pr.FirstChunkAtSafe()
				if !firstChunk.IsZero() && !t.DispatchedAt.IsZero() {
					ms := float64(firstChunk.Sub(t.DispatchedAt).Milliseconds())
					outcome.ActualTTFTMs = ms
					outcome.DispatchToFirstChunkMs = ms
				}
				if !t.ReceivedAt.IsZero() {
					outcome.TotalDurationMs = float64(time.Since(t.ReceivedAt).Milliseconds())
				}
				// Coordinator-side latency decomposition (ParseMs..DispatchMs).
				applyTimingDecomposition(outcome, t, firstChunk)
				// Measured decode throughput: completion tokens over the decode
				// window (first chunk -> completion). Guard zero/negative
				// durations and zero tokens so unmeasurable requests record 0.
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
			_ = s.store.UpdateInferenceRouteOutcome(msg.RequestID, pr.Attempt, outcome)
		})

		s.ddIncr("inference.completions", []string{"model:" + pr.Model})
		s.ddCount("inference.prompt_tokens_total", int64(msg.Usage.PromptTokens), []string{"model:" + pr.Model})
		s.ddHistogram("inference.prompt_tokens", float64(msg.Usage.PromptTokens), []string{"model:" + pr.Model})
		s.ddCount("inference.completion_tokens_total", int64(msg.Usage.CompletionTokens), []string{"model:" + pr.Model})
		s.ddHistogram("inference.completion_tokens", float64(msg.Usage.CompletionTokens), []string{"model:" + pr.Model})

		// Resolve provider identity for payout.
		p := s.registry.GetProvider(providerID)
		if p == nil {
			p = provider
		}

		// Compute platform fee (needs referral lookup before spawning goroutines).
		platformFee := payments.PlatformFeeWithPercent(totalCost, feePercent)
		if platformFee > 0 && s.billing != nil && s.billing.Referral() != nil {
			platformFee = s.billing.Referral().DistributeReferralReward(pr.ConsumerKey, platformFee, msg.RequestID)
		}

		// Run provider credit and platform fee credit concurrently —
		// they target different accounts so there is no data dependency.
		var settlementWg sync.WaitGroup

		// Credit the provider's linked account (if any).
		if p != nil {
			p.Mu().Lock()
			accountID := p.AccountID
			publicKey := p.PublicKey
			p.Mu().Unlock()

			// Credit the provider only when there is an actual payout. A zero
			// payout means either free self-route (consumer == provider account)
			// or an uncollected charge (e.g. a self-route paid-fallback whose
			// owner had no balance) — in both cases we must not record a
			// (zero-value) earning row. Mirrors the platformFee > 0 guard below.
			if accountID != "" && !freeSelfRoute && providerPayout > 0 {
				settlementWg.Add(1)
				go func() {
					defer settlementWg.Done()
					start := time.Now()
					if err := s.store.CreditProviderAccount(&store.ProviderEarning{
						AccountID:        accountID,
						ProviderID:       providerID,
						ProviderKey:      publicKey,
						JobID:            msg.RequestID,
						Model:            pr.Model,
						AmountMicroUSD:   providerPayout,
						PromptTokens:     msg.Usage.PromptTokens,
						CompletionTokens: msg.Usage.CompletionTokens,
						CreatedAt:        time.Now(),
					}); err != nil {
						s.logger.Error("failed to credit linked provider account",
							"provider_id", providerID,
							"account_id", accountID,
							"request_id", msg.RequestID,
							"error", err,
						)
					}
					s.ddHistogram("store.credit.latency_ms", float64(time.Since(start).Milliseconds()), []string{"op:provider_account_credit"})
					s.ddCount("billing.provider_credits_micro_usd", providerPayout, []string{"model:" + pr.Model, "type:account"})
				}()
			}
		}

		// Record platform fee.
		if platformFee > 0 {
			settlementWg.Add(1)
			go func() {
				defer settlementWg.Done()
				start := time.Now()
				_ = s.store.Credit("platform", platformFee, store.LedgerPlatformFee, msg.RequestID)
				s.ddHistogram("store.credit.latency_ms", float64(time.Since(start).Milliseconds()), []string{"op:platform_fee"})
				s.ddCount("billing.platform_fees_micro_usd", platformFee, []string{"model:" + pr.Model})
			}()
		}

		settlementWg.Wait()
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

// isModelLoadFailure reports whether a (lowercased) provider error terminal
// indicates the provider could not LOAD the requested model — either a
// capacity reject ("insufficient memory to load model …", provider-side
// fastAdmissionReject/evictUntilAvailable) or a generic load failure ("model
// load failed: …", InferenceError.modelLoadFailed). Both mean the
// provider-model pair will fail identically on immediate retry and should
// cool down in routing.
func isModelLoadFailure(loweredErr string) bool {
	return strings.Contains(loweredErr, "insufficient memory") ||
		strings.Contains(loweredErr, "model load failed")
}

func (s *Server) handleInferenceError(providerID string, provider *registry.Provider, msg *protocol.InferenceErrorMessage) {
	if provider == nil {
		s.logger.Warn("error from unregistered provider", "provider_id", providerID)
		return
	}
	pr := provider.RemovePending(msg.RequestID)
	// Clear any parked settlement record (consumer disconnected mid-stream).
	// Same object as a non-nil pr when the terminal raced the disconnect defer.
	parked := s.claimSettlement(msg.RequestID)
	if pr == nil {
		pr = parked
	}
	if pr == nil {
		s.logger.Warn("error for unknown request", "provider_id", providerID, "request_id", msg.RequestID)
		return
	}
	consumerGone := parked != nil

	// Record a job failure, but not for capacity rejections or consumer
	// cancellations — neither is a provider fault. Capacity = load shedding the
	// coordinator reroutes. Cancel (499 / "request cancelled") = the CONSUMER
	// disconnected; before the settlement holder these terminals died on
	// pr==nil with zero reputation effect, and the old fleet emits one for
	// every mid-stream disconnect — penalizing them would erode the whole
	// fleet's reputation for consumer behavior.
	loweredErr := strings.ToLower(msg.Error)
	capacityRejection := msg.StatusCode == http.StatusServiceUnavailable ||
		msg.StatusCode == http.StatusTooManyRequests ||
		strings.Contains(loweredErr, "token_budget_exhausted") ||
		strings.Contains(loweredErr, "insufficient memory")
	cancelTerminal := msg.StatusCode == 499 ||
		strings.Contains(loweredErr, "request cancelled")
	if !capacityRejection && !cancelTerminal {
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
	if isModelLoadFailure(loweredErr) {
		if s.registry.RecordDispatchLoadFailure(providerID, pr.Model) {
			s.logger.Warn("load-failure cool-down started",
				"provider_id", providerID,
				"model", pr.Model,
			)
			s.ddIncr("routing.load_failure_cooldowns", []string{"model:" + pr.Model})
		}
	}

	s.registry.SetProviderIdle(providerID)

	if consumerGone {
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
		"error", msg.Error,
		"status_code", msg.StatusCode,
	)
}
