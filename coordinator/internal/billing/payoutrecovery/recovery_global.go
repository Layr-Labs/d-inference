package payoutrecovery

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/eigeninference/d-inference/coordinator/billing/globalpayouts"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// syncGlobalPayout always reads Stripe's current state rather than applying
// potentially duplicated/out-of-order webhook state directly to the ledger.
func (s *Reconciler) SyncGlobalPayout(ctx context.Context, id string) error {
	repo, ok := Store(s.billing)
	if !ok || s.billing.GlobalPayouts() == nil {
		return errors.New("Global Payouts unavailable")
	}
	p, err := repo.ClaimGlobalPayout(id, time.Now())
	if err != nil {
		return err
	}
	if p == nil {
		p, e := repo.GetGlobalPayout(id)
		if e != nil {
			return e
		}
		if p.Refunded || p.RequiresManualReconciliation() {
			return nil
		}
		return errors.New("payout reconciliation is already in progress")
	}
	if p.Rejection != nil {
		return repo.ApplyGlobalPayout(id, store.GlobalPayoutResult{ExpectedLease: p.LeaseUntil, Status: "failed", FailureCode: p.Rejection.Code}, time.Now())
	}
	// Stop automatic work before the idempotency retention horizon, including
	// old ambiguous requests whose original funding configuration has changed.
	started := p.DispatchStartedAt
	if started.IsZero() {
		started = p.SubmittedAt
	}
	if p.DispatchAttempts > 0 && p.ExternalID == "" && time.Since(started) > 12*time.Hour {
		if err := repo.ApplyGlobalPayout(id, store.GlobalPayoutResult{ExpectedLease: p.LeaseUntil, FailureCode: store.GlobalPayoutManualReview}, time.Now()); err != nil {
			return err
		}
		s.logger.Error("global payout outcome requires manual reconciliation", "withdrawal_id", p.ID)
		return nil
	}
	var request globalpayouts.PaymentRequest
	if err = json.Unmarshal(p.Request, &request); err != nil {
		return err
	}
	if p.ExternalID == "" && request.From["financial_account"] != s.billing.GlobalPayouts().FinancialAccount {
		// An unsent request can safely refund after configuration changes. Persist
		// that rejection before refunding. Prior ambiguous attempts stay held.
		if p.DispatchAttempts == 0 {
			if err := recordGlobalPayoutRejection(ctx, repo, p.ID, p.DispatchAttempts, "funding_account_changed", p.LeaseUntil); err != nil {
				return err
			}
			return repo.ApplyGlobalPayout(id, store.GlobalPayoutResult{ExpectedLease: p.LeaseUntil, Status: "failed", FailureCode: "funding_account_changed"}, time.Now())
		}
		return repo.ApplyGlobalPayout(id, store.GlobalPayoutResult{ExpectedLease: p.LeaseUntil, FailureCode: "funding_account_changed"}, time.Now())
	}
	priorAttempts := p.DispatchAttempts
	ready, err := s.prepareGlobalFunding(ctx, repo, p, &request)
	if err != nil || !ready {
		return err
	}
	var remote *globalpayouts.Payment
	client := s.billing.GlobalPayouts()
	if p.ExternalID != "" {
		remote, err = client.Payment(ctx, p.ExternalID)
	} else {
		if priorAttempts > 0 {
			if err = repo.StartGlobalPayoutDispatch(id, p.LeaseUntil, time.Now()); err != nil {
				return err
			}
			p.DispatchAttempts++
		}
		remote, err = client.Send(ctx, p.Request, globalPaymentKey(p))
	}
	if err != nil {
		if p.ExternalID == "" && p.DispatchAttempts == 1 && globalFundingError(err) {
			return repo.ApplyGlobalPayout(id, store.GlobalPayoutResult{ExpectedLease: p.LeaseUntil, Status: "queued", FailureCode: store.WithdrawalFundingReason}, time.Now())
		}
		result := store.GlobalPayoutResult{ExpectedLease: p.LeaseUntil, FailureCode: "confirmation_pending"}
		var apiErr *globalpayouts.Error
		if p.ExternalID == "" && p.DispatchAttempts == 1 && errors.As(err, &apiErr) && apiErr.Definitive() {
			if persistErr := recordGlobalPayoutRejection(ctx, repo, p.ID, p.DispatchAttempts, apiErr.Code, p.LeaseUntil); persistErr != nil {
				return persistErr
			}
			result.Status = "failed"
			result.FailureCode = apiErr.Code
		}
		if persistErr := repo.ApplyGlobalPayout(id, result, time.Now()); persistErr != nil {
			return persistErr
		}
		return err
	}
	if err = remote.Validate(request); err != nil {
		return err
	}
	return repo.ApplyGlobalPayout(id, store.GlobalPayoutResult{ExpectedLease: p.LeaseUntil, ExternalID: remote.ID, Status: remote.Status, FailureCode: remote.StatusDetails[remote.Status].Reason, DestinationAmount: remote.To.Credited.Value, Currency: remote.To.Credited.Currency, Arrival: remote.ExpectedArrivalDate}, time.Now())
}
