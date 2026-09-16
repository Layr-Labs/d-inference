package billing

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/eigeninference/d-inference/coordinator/billing/globalpayouts"
	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// syncGlobalPayout always reads Stripe's current state rather than applying
// potentially duplicated/out-of-order webhook state directly to the ledger.
func (s *Controller) syncGlobalPayout(ctx context.Context, id string) error {
	repo, ok := s.globalPayoutStore()
	if !ok || s.billing().GlobalPayouts() == nil {
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
	if p.ExternalID == "" && request.From["financial_account"] != s.billing().GlobalPayouts().FinancialAccount {
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
	client := s.billing().GlobalPayouts()
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

func (s *Controller) StartGlobalPayoutReconciler(ctx context.Context) {
	repo, ok := s.globalPayoutStore()
	if !ok {
		return
	}
	saferun.Go(s.logger, "api.globalPayoutReconciler", func() {
		ticker := time.NewTicker(time.Minute)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
			}
			if _, err := repo.PruneExpiredGlobalPayoutQuotes(time.Now(), 1000); err != nil {
				s.logger.Warn("expired payout quote cleanup failed", "error", err)
			}
			if s.billing().GlobalPayouts() == nil {
				continue
			}
			rows, err := repo.ListGlobalPayoutsToReconcile(time.Now(), 200)
			if err != nil {
				s.logger.Error("global payout reconciliation scan failed", "error", err)
				continue
			}
			for _, p := range rows {
				if ctx.Err() != nil {
					return
				}
				if err = s.syncGlobalPayout(ctx, p.ID); err != nil {
					s.logger.Warn("global payout reconciliation failed", "withdrawal_id", p.ID, "error", err)
				}
			}
		}
	})
}
