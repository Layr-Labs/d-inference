package api

import (
	"errors"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func reservationMetricMode(service bool) string {
	if service {
		return "service_hold"
	}
	return "ledger"
}

func (s *Server) reserveInitialBalance(accountID, model string, amount int64, reservationID string) (bool, int64, error) {
	start := time.Now()
	reservedWithdrawable, _, err := s.reserveInferenceBalanceWithRetry(
		accountID, amount, reservationID,
	)
	if err != nil {
		s.ddIncr("billing.reservations", []string{"model:" + model, "mode:ledger", "outcome:rejected"})
		return false, 0, err
	}
	s.ddIncr("billing.reservations", []string{"model:" + model, "mode:ledger", "outcome:reserved"})
	s.ddHistogram("billing.reserved_micro_usd", float64(amount), []string{"model:" + model, "mode:ledger"})
	s.ddHistogram("store.debit.latency_ms", float64(time.Since(start).Milliseconds()), []string{"op:reserve"})
	return false, reservedWithdrawable, nil
}

func (s *Server) reserveInferenceBalanceWithRetry(
	accountID string,
	amountMicroUSD int64,
	operationKey string,
) (int64, bool, error) {
	var lastErr error
	for attempt := 0; ; attempt++ {
		reservedWithdrawable, applied, err := s.store.ReserveInferenceBalance(
			accountID, amountMicroUSD, operationKey,
		)
		if err == nil {
			return reservedWithdrawable, applied, nil
		}
		lastErr = err
		if errors.Is(err, store.ErrInsufficientBalance) ||
			errors.Is(err, store.ErrFinancialOperationConflict) {
			return 0, false, err
		}
		if !errors.Is(err, store.ErrCommitOutcomeUnknown) &&
			attempt+1 >= settlementRetryAttempts {
			return 0, false, lastErr
		}
		time.Sleep(time.Duration(min(attempt+1, 100)) * 50 * time.Millisecond)
	}
}

func (s *Server) releaseInitialReservation(accountID, model string, amount, reservedWithdrawable int64, reservationID string, serviceMode bool) {
	if amount <= 0 {
		return
	}
	tags := []string{"model:" + model, "mode:" + reservationMetricMode(serviceMode)}
	start := time.Now()
	applied, err := s.releaseInferenceReservationWithRetry(
		accountID, amount, reservedWithdrawable,
		reservationFinalizationKey(reservationID), "reservation_refund:"+reservationID,
	)
	if err != nil {
		s.logger.Error("failed to release initial reservation",
			"reservation_id", reservationID,
			"error", err,
		)
		return
	}
	if !applied {
		return
	}
	s.ddIncr("billing.reservation_refunds", tags)
	s.ddIncr("billing.reservation_releases", append(tags, "reason:early"))
	s.ddHistogram("store.credit.latency_ms", float64(time.Since(start).Milliseconds()), []string{"op:reservation_refund"})
}

func (s *Server) releaseInferenceReservationWithRetry(
	accountID string,
	amountMicroUSD, withdrawableMicroUSD int64,
	operationKey, reference string,
) (bool, error) {
	for attempt := 0; ; attempt++ {
		applied, err := s.store.ReleaseInferenceReservation(
			accountID, amountMicroUSD, withdrawableMicroUSD, operationKey, reference,
		)
		if err == nil {
			return applied, nil
		}
		if store.IsPermanentFinancialError(err) {
			return false, err
		}
		time.Sleep(time.Duration(min(attempt+1, 100)) * 50 * time.Millisecond)
	}
}

func reservationFinalizationKey(reservationID string) string {
	return "finalize:" + reservationID
}

func reservationTopUpKey(pr *registry.PendingRequest) string {
	return "topup:" + pr.ReservationID + ":" + pr.RequestID + ":" + pr.ProviderID
}

func reservationTopUpReleaseKey(pr *registry.PendingRequest) string {
	return "topup-release:" + pr.ReservationID + ":" + pr.RequestID + ":" + pr.ProviderID
}
