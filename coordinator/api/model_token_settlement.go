package api

import (
	"errors"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func stampModelTokenReservation(pr *registry.PendingRequest, reservation *store.ModelTokenReservation) {
	if pr == nil || reservation == nil {
		return
	}
	pr.ModelTokenReservationID = reservation.ID
	pr.PromotionModelID = reservation.ModelID
	pr.PromotionFreeTokens = reservation.FreeTokens
}

func (s *Server) settleModelTokenPromotion(pr *registry.PendingRequest, provider *registry.Provider, usage protocol.UsageInfo, in, out int64, custom bool, payout int64, freeSelf bool, onSettled func(int64)) (bool, int64, error) {
	backend, ok := store.As[store.ModelTokenPromotionStore](s.store)
	if !ok {
		return false, 0, errors.New("promotion store unavailable")
	}
	quote := modelTokenQuote(pr.Model, usage.PromptTokens, usage.CompletionTokens, in, out, custom, nil)
	actual := int64(usage.PromptTokens) + int64(usage.CompletionTokens)
	var earning *store.ProviderEarning
	if !freeSelf && provider != nil && payout > 0 {
		provider.Mu().Lock()
		account, key, id := provider.AccountID, provider.PublicKey, provider.ID
		provider.Mu().Unlock()
		if account != "" {
			earning = &store.ProviderEarning{AccountID: account, ProviderID: id, ProviderKey: key, JobID: pr.RequestID, Model: pr.Model, AmountMicroUSD: payout, PromptTokens: usage.PromptTokens, CompletionTokens: usage.CompletionTokens, CreatedAt: time.Now()}
		}
	}
	if freeSelf {
		actual = 0
		quote = func(int64) (int64, int64, error) { return 0, 0, nil }
	}
	var result store.ModelTokenSettlement
	finalized, err := pr.FinalizeReservation(func() error {
		var settleErr error
		result, settleErr = backend.SettleModelTokenReservation(pr.ModelTokenReservationID, actual, quote, earning)
		return settleErr
	})
	if err != nil {
		// Fence ordinary refunds after a terminal settlement has been selected.
		// Reconcile ambiguous commits using the durable reservation identity.
		pr.MarkReservationFinalized()
		if permanentModelTokenSettlementError(err) {
			refundErr := s.abandonModelTokenSettlement(pr.ModelTokenReservationID)
			return false, 0, errors.Join(err, refundErr)
		}
		id := pr.ModelTokenReservationID
		s.modelTokenSettlements.Store(id, func() error {
			settled, retryErr := backend.SettleModelTokenReservation(id, actual, quote, earning)
			if permanentModelTokenSettlementError(retryErr) {
				return s.abandonModelTokenSettlement(id)
			}
			// Applied is false after a lost commit acknowledgement. The stored
			// settled state and cost are authoritative, so resume accounting in
			// both cases. Released reservations never produce accounting.
			if retryErr == nil && settled.Reservation.State == "settled" && onSettled != nil {
				onSettled(settled.Reservation.ConsumerCostMicroUSD)
			}
			return retryErr
		})
		return false, 0, err
	}
	s.modelTokenActive.Delete(pr.ModelTokenReservationID)
	return finalized && result.Applied, result.Reservation.ConsumerCostMicroUSD, nil
}

func permanentModelTokenSettlementError(err error) bool {
	return errors.Is(err, store.ErrPromotionInvalidSettlement) || errors.Is(err, store.ErrInsufficientBalance)
}

// A deterministic failure cannot become valid through lease renewal. Stop
// settlement retries and renewal, and use the idempotent refund queue if releasing
// the token/cash holds fails. No charge or provider payout was committed.
func (s *Server) abandonModelTokenSettlement(id string) error {
	s.modelTokenSettlements.Delete(id)
	s.modelTokenActive.Delete(id)
	_, err := s.releaseModelTokenReservation(id)
	return err
}
