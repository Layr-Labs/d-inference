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
	claimed, err := repo.ClaimGlobalPayout(id, time.Now())
	if err != nil {
		return err
	}
	if !claimed {
		p, e := repo.GetGlobalPayout(id)
		if e != nil {
			return e
		}
		if p.Refunded || p.RequiresManualReconciliation() {
			return nil
		}
		return errors.New("payout reconciliation is already in progress")
	}
	p, err := repo.GetGlobalPayout(id)
	if err != nil {
		return err
	}
	if p.Rejection != nil {
		return repo.ApplyGlobalPayout(id, store.GlobalPayoutResult{Status: "failed", FailureCode: p.Rejection.Code}, time.Now())
	}
	// Stop automatic work before the idempotency retention horizon, including
	// old ambiguous requests whose original funding configuration has changed.
	if p.ExternalID == "" && time.Since(p.SubmittedAt) > 12*time.Hour {
		if err := repo.ApplyGlobalPayout(id, store.GlobalPayoutResult{FailureCode: store.GlobalPayoutManualReview}, time.Now()); err != nil {
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
		// This claim reserved the first attempt; no Send has run yet. Persist
		// that rejection before refunding. Prior ambiguous attempts stay held.
		if p.DispatchAttempts == 1 {
			if err := recordGlobalPayoutRejection(ctx, repo, p.ID, p.DispatchAttempts, "funding_account_changed"); err != nil {
				return err
			}
			return repo.ApplyGlobalPayout(id, store.GlobalPayoutResult{Status: "failed", FailureCode: "funding_account_changed"}, time.Now())
		}
		return repo.ApplyGlobalPayout(id, store.GlobalPayoutResult{FailureCode: "funding_account_changed"}, time.Now())
	}
	var remote *globalpayouts.Payment
	client := s.billing.GlobalPayouts()
	if p.ExternalID != "" {
		remote, err = client.Payment(ctx, p.ExternalID)
	} else {
		remote, err = client.Send(ctx, p.Request, "gp-withdraw-"+p.ID)
	}
	if err != nil {
		result := store.GlobalPayoutResult{FailureCode: "confirmation_pending"}
		var apiErr *globalpayouts.Error
		if p.ExternalID == "" && p.DispatchAttempts == 1 && errors.As(err, &apiErr) && apiErr.Definitive() {
			if persistErr := recordGlobalPayoutRejection(ctx, repo, p.ID, p.DispatchAttempts, apiErr.Code); persistErr != nil {
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
	return repo.ApplyGlobalPayout(id, store.GlobalPayoutResult{ExternalID: remote.ID, Status: remote.Status, FailureCode: remote.StatusDetails[remote.Status].Reason, DestinationAmount: remote.To.Credited.Value, Currency: remote.To.Credited.Currency, Arrival: remote.ExpectedArrivalDate}, time.Now())
}
