package payoutrecovery

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/eigeninference/d-inference/coordinator/billing/globalpayouts"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func globalFundingError(err error) bool {
	var e *globalpayouts.Error
	return errors.As(err, &e) && e.Definitive() && (e.Code == "balance_insufficient" || e.Code == "insufficient_funds")
}

func globalPaymentKey(p *store.GlobalPayout) string {
	key := "gp-withdraw-" + p.ID
	if p.FundingGeneration > 0 {
		key += fmt.Sprintf("-funding-%d", p.FundingGeneration)
	}
	return key
}

func (s *Reconciler) rejectUnsentGlobalPayout(ctx context.Context, repo store.GlobalPayoutStore, p *store.GlobalPayout, code string) error {
	if err := recordGlobalPayoutRejection(ctx, repo, p.ID, 0, code, p.LeaseUntil); err != nil {
		return err
	}
	return repo.ApplyGlobalPayout(p.ID, store.GlobalPayoutResult{ExpectedLease: p.LeaseUntil, Status: "failed", FailureCode: code}, time.Now())
}

// Funding checks and quote renewal are safe only before a send. Unknown outcomes
// keep their immutable payload and key, regardless of current platform funding.
func (s *Reconciler) prepareGlobalFunding(ctx context.Context, repo store.GlobalPayoutStore, p *store.GlobalPayout, request *globalpayouts.PaymentRequest) (bool, error) {
	if p.ExternalID != "" || p.DispatchAttempts != 0 {
		return true, nil
	}
	client := s.billing.GlobalPayouts()
	available, err := client.AvailableUSD(ctx)
	if err != nil {
		// Release the lease without consuming a dispatch attempt or inferring
		// a funding shortage from an unsuccessful balance read.
		if persistErr := repo.ApplyGlobalPayout(p.ID, store.GlobalPayoutResult{ExpectedLease: p.LeaseUntil, FailureCode: "funding_check_pending"}, time.Now()); persistErr != nil {
			return false, persistErr
		}
		return false, err
	}
	fees, amount, expires := p.EstimatedStripeFees, p.DestinationAmount, p.ExpiresAt
	// Below the principal, no nonnegative fee estimate can make this send
	// fundable. Otherwise refresh an expired quote before using its fees.
	if available < p.AmountMicroUSD/10_000 {
		return false, repo.ApplyGlobalPayout(p.ID, store.GlobalPayoutResult{ExpectedLease: p.LeaseUntil, Status: "queued", FailureCode: store.WithdrawalFundingReason}, time.Now())
	}
	// The approved USD amount and bank destination stay fixed. The UI discloses
	// that a queued payout's local-currency estimate is refreshed at dispatch.
	if !expires.After(time.Now().Add(5 * time.Second)) {
		request.QuoteID = ""
		quote, err := client.Quote(ctx, *request)
		if err != nil {
			var apiErr *globalpayouts.Error
			if errors.As(err, &apiErr) && apiErr.Definitive() && !globalFundingError(err) {
				return false, s.rejectUnsentGlobalPayout(ctx, repo, p, apiErr.Code)
			}
			return false, err
		}
		if err = quote.Validate(*request); err != nil {
			return false, s.rejectUnsentGlobalPayout(ctx, repo, p, "quote_changed")
		}
		policy, ok := globalpayouts.Lookup(p.Country)
		if !ok {
			return false, s.rejectUnsentGlobalPayout(ctx, repo, p, "payout_country_unavailable")
		}
		if err = policy.ValidateRecipientAmount(quote.To.Credited); err != nil {
			return false, s.rejectUnsentGlobalPayout(ctx, repo, p, "recipient_amount_out_of_bounds")
		}
		expires = time.Now().Add(2 * time.Minute)
		if quote.FXQuote != nil && quote.FXQuote.LockExpiresAt.Before(expires) {
			expires = quote.FXQuote.LockExpiresAt
		}
		if !expires.After(time.Now().Add(5 * time.Second)) {
			return false, store.ErrPayoutQuoteExpired
		}
		request.QuoteID = quote.ID
		amount = quote.To.Credited.Value
		fees, err = json.Marshal(quote.EstimatedFees)
		if err != nil {
			return false, err
		}
	}
	needed, err := globalpayouts.RequiredFundingCents(p.AmountMicroUSD/10_000, fees)
	if err != nil {
		return false, s.rejectUnsentGlobalPayout(ctx, repo, p, "invalid_fee_estimate")
	}
	if available < needed {
		return false, repo.ApplyGlobalPayout(p.ID, store.GlobalPayoutResult{ExpectedLease: p.LeaseUntil, Status: "queued", FailureCode: store.WithdrawalFundingReason}, time.Now())
	}
	payload, err := json.Marshal(request)
	if err != nil {
		return false, err
	}
	now := time.Now()
	if err = repo.StartUnsentGlobalPayout(p.ID, p.LeaseUntil, payload, fees, amount, expires, now); err != nil {
		return false, err
	}
	p.Request = payload
	p.DispatchAttempts = 1
	p.DispatchStartedAt = now
	p.Status = "pending"
	return true, nil
}
