package api

import (
	"context"
	"encoding/json"
	"time"

	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// settleBonsaiTrial commits quota, consumer-zero usage, subsidy expense and
// withdrawable provider earnings together. The persistent logical reservation
// identity, shared by all attempts, is the final idempotency boundary.
func (s *Server) settleBonsaiTrial(pr *registry.PendingRequest, provider *registry.Provider, usage protocol.UsageInfo, owned bool) bool {
	reservation := pr.TrialReservation
	if reservation == nil {
		return false
	}
	finalized, err := pr.FinalizeReservation(func() error {
		if owned {
			if !s.releaseTrialReservation(reservation, true) {
				return store.ErrTrialUnavailable
			}
			return nil
		}
		if usage.PromptTokens <= 0 || ((pr.HasFirstContentIngress() || pr.ContentCommittedSafe()) && usage.CompletionTokens <= 0) {
			return store.ErrTrialInvalidUsage
		}
		var snapshot trialPriceSnapshot
		if json.Unmarshal(reservation.PricingJSON, &snapshot) != nil {
			return store.ErrTrialUnavailable
		}
		cost, err := snapshot.Rates.Cost(int64(usage.PromptTokens), int64(usage.CompletionTokens))
		if err != nil {
			s.releaseTrialReservation(reservation, false)
			return err
		}
		payout := trialProviderPayout(cost, snapshot.FeePercent)
		provider.Mu().Lock()
		account, key, providerID := provider.AccountID, provider.PublicKey, provider.ID
		provider.Mu().Unlock()
		var earning *store.ProviderEarning
		if account != "" {
			earning = &store.ProviderEarning{AccountID: account, ProviderID: providerID, ProviderKey: key,
				JobID: reservation.ID, Model: pr.Model, AmountMicroUSD: payout,
				PromptTokens: usage.PromptTokens, CompletionTokens: usage.CompletionTokens, CreatedAt: time.Now()}
		}
		ts, ok := store.As[store.TrialStore](s.store)
		if !ok {
			return store.ErrTrialUnavailable
		}
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		return ts.SettleTrial(ctx, reservation.ID, store.TrialSettlement{
			Usage: store.UsageRecord{ProviderID: providerID, ConsumerKey: pr.ConsumerKey, Model: pr.Model,
				PublicModel: consumerModel(pr), RequestID: reservation.ID, PromptTokens: usage.PromptTokens,
				CompletionTokens: usage.CompletionTokens, RequestLocation: pr.ConsumerLocation, Timestamp: time.Now()},
			Earning: earning, SubsidyMicroUSD: cost, ServingRequestID: pr.RequestID,
		})
	})
	if err != nil {
		s.releaseTrialReservation(reservation, false)
		s.logger.Error("trial settlement unresolved", "reservation_id", reservation.ID, "error", err)
		s.ddIncr("billing.bonsai_trial", []string{"outcome:unresolved"})
		return false
	}
	if finalized {
		s.ddIncr("billing.bonsai_trial", []string{"outcome:settled"})
	}
	return finalized
}

// Avoid cost*pct overflow while preserving the normal integer fee policy.
func trialProviderPayout(cost int64, feePercent *int64) int64 {
	pct := payments.DefaultPlatformFeePercent
	if feePercent != nil {
		pct = *feePercent
	}
	if pct < 0 {
		pct = 0
	}
	if pct > 100 {
		pct = 100
	}
	return cost - (cost/100*pct + (cost%100)*pct/100)
}
