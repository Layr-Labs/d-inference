package promotions

import (
	"errors"
	"time"

	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func StampReservation(pr *registry.PendingRequest, reservation *store.ModelTokenReservation) {
	if pr == nil || reservation == nil {
		return
	}
	pr.ModelTokenReservationID = reservation.ID
	pr.PromotionModelID = reservation.ModelID
	pr.PromotionFreeTokens = reservation.FreeTokens
}

func (s *Engine) Settle(pr *registry.PendingRequest, provider *registry.Provider, usage protocol.UsageInfo, rates payments.Rates, feePercent *int64, freeSelf bool, referralEligible bool, onSettled func(int64)) (bool, int64, int64, error) {
	backend, ok := store.As[store.ModelTokenPromotionStore](s.store)
	if !ok {
		return false, 0, 0, errors.New("promotion store unavailable")
	}
	quote := quote(usage.PromptTokens, usage.CompletionTokens, rates, nil)
	actual := int64(usage.PromptTokens) + int64(usage.CompletionTokens)
	var earning *store.ModelTokenEarning
	if !freeSelf && provider != nil {
		provider.Mu().Lock()
		account, key, id := provider.AccountID, provider.PublicKey, provider.ID
		provider.Mu().Unlock()
		if account != "" {
			price, err := PriceTokens(usage.PromptTokens, usage.CompletionTokens, rates, pr.PromotionFreeTokens, feePercent)
			if err != nil {
				pr.MarkReservationFinalized()
				return false, 0, 0, errors.Join(store.ErrPromotionInvalidSettlement, err, s.abandon(pr.ModelTokenReservationID))
			}
			earning = &store.ModelTokenEarning{ProviderEarning: store.ProviderEarning{AccountID: account, ProviderID: id, ProviderKey: key, JobID: pr.RequestID, Model: pr.Model, AmountMicroUSD: price.Payout, PromptTokens: usage.PromptTokens, CompletionTokens: usage.CompletionTokens, CreatedAt: time.Now()}, FractionalMicroUSD: price.Remainder}
		}
	}
	if freeSelf {
		actual = 0
		quote = func(int64) (int64, int64, error) { return 0, 0, nil }
	}
	var result store.ModelTokenSettlement
	finalized, err := pr.FinalizeReservation(func() error {
		var settleErr error
		result, settleErr = backend.SettleModelTokenReservation(pr.ModelTokenReservationID, actual, quote, earning, referralEligible)
		return settleErr
	})
	if err != nil {
		// Fence ordinary refunds after a terminal settlement has been selected.
		// Reconcile ambiguous commits using the durable reservation identity.
		pr.MarkReservationFinalized()
		if permanentModelTokenSettlementError(err) {
			refundErr := s.abandon(pr.ModelTokenReservationID)
			return false, 0, 0, errors.Join(err, refundErr)
		}
		id := pr.ModelTokenReservationID
		s.settlements.Store(id, func() error {
			settled, retryErr := backend.SettleModelTokenReservation(id, actual, quote, earning, referralEligible)
			if permanentModelTokenSettlementError(retryErr) {
				return s.abandon(id)
			}
			// Applied is false after a lost commit acknowledgement. The stored
			// settled state and cost are authoritative, so resume accounting in
			// both cases. Released reservations never produce accounting.
			if retryErr == nil && settled.Reservation.State == "settled" && onSettled != nil {
				onSettled(settled.Reservation.ConsumerCostMicroUSD)
			}
			return retryErr
		})
		return false, 0, 0, err
	}
	s.active.Delete(pr.ModelTokenReservationID)
	return finalized && result.Applied, result.Reservation.ConsumerCostMicroUSD, result.Reservation.ProviderPayoutMicroUSD, nil
}

func permanentModelTokenSettlementError(err error) bool {
	return errors.Is(err, store.ErrPromotionInvalidSettlement) || errors.Is(err, store.ErrInsufficientBalance)
}

// A deterministic failure cannot become valid through lease renewal. Stop
// settlement retries and renewal, and use the idempotent refund queue if releasing
// the token/cash holds fails. No charge or provider payout was committed.
func (s *Engine) abandon(id string) error {
	s.settlements.Delete(id)
	s.active.Delete(id)
	_, err := s.Release(id)
	return err
}
