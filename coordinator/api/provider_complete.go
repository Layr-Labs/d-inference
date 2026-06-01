package api

import (
	"errors"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *Server) handleComplete(providerID string, provider *registry.Provider, msg *protocol.InferenceCompleteMessage) {
	if provider == nil {
		s.logger.Warn("complete from unregistered provider", "provider_id", providerID)
		return
	}
	pr := provider.RemovePending(msg.RequestID)
	if pr == nil {
		s.logger.Warn("complete for unknown request", "provider_id", providerID, "request_id", msg.RequestID)
		return
	}

	// Store SE signature for the consumer response headers.
	pr.SESignature = msg.SESignature
	pr.ResponseHash = msg.ResponseHash

	// Record job success and usage BEFORE closing ChunkCh. Closing
	// ChunkCh unblocks the consumer response handler, and callers may
	// check usage immediately after the HTTP response completes.
	responseTime := time.Duration(msg.Usage.CompletionTokens) * time.Millisecond * 10
	s.registry.RecordJobSuccess(providerID, responseTime)

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
	billingFinalized := true

	// Settle billing against the pre-flight reservation. All balance
	// mutations (overage charge, refund) happen inside the finalization
	// gate so that a concurrent timeout/error refund path cannot race
	// with the settlement here.
	if pr.ReservedMicroUSD > 0 {
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
	} else {
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
		}
		s.ddHistogram("store.debit.latency_ms", float64(time.Since(start).Milliseconds()), []string{"op:charge"})
	}

	if billingFinalized {
		// Record in-memory usage (for current session queries).
		s.ledger.RecordUsage(pr.ConsumerKey, payments.UsageEntry{
			JobID:            msg.RequestID,
			Model:            pr.Model,
			PromptTokens:     msg.Usage.PromptTokens,
			CompletionTokens: msg.Usage.CompletionTokens,
			CostMicroUSD:     totalCost,
			Timestamp:        time.Now(),
		})

		// Persist usage to DB asynchronously — billing has already been
		// settled above, so this INSERT is not on the critical path. KeyID
		// carries per-key usage/spend attribution (empty for legacy callers).
		saferun.Go(s.logger, "recordUsage", func() {
			s.store.RecordUsageFull(providerID, pr.ConsumerKey, pr.KeyID, pr.Model, msg.RequestID, msg.Usage.PromptTokens, msg.Usage.CompletionTokens, totalCost, pr.ConsumerLocation)
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

			if accountID != "" {
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
	pr.CompleteCh <- msg.Usage
	close(pr.ChunkCh)
	close(pr.CompleteCh)

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
