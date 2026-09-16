package billing

import (
	"errors"
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
	billingservice "github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// retryAmbiguousStripe retries fn while it fails with a non-definitive error
// (transport timeout, connection drop, lost response) — outcomes where an
// idempotency-keyed Stripe request may have been accepted. Replaying with the
// same key returns the original result instead of moving money twice, so the
// retry either recovers the lost response or surfaces Stripe's definitive
// rejection. Definitive API errors return immediately. Bounded at 3 attempts
// (0/200/400ms backoff), same budget as the other in-request retries.
func retryAmbiguousStripe[T any](fn func() (T, error)) (T, error) {
	out, err := fn()
	for attempt := 1; attempt <= 2 && err != nil && !billingservice.IsDefinitiveAPIErr(err); attempt++ {
		time.Sleep(time.Duration(attempt) * 200 * time.Millisecond)
		out, err = fn()
	}
	return out, err
}

// creditRefundOnceWithRetry credits a reference-idempotent refund, riding out
// transient store blips with short retries (safe: duplicates are deduped on
// the ledger reference). Returns whether the credit is durably applied.
//
// The retries deliberately ignore the request context and run to completion:
// they only execute AFTER money has moved (or a debit landed), and a client
// disconnect must not abandon the user's refund. Worst case is bounded at
// 600ms of backoff (3 attempts × 0/200/400ms).
func (s *Controller) creditRefundOnceWithRetry(accountID string, amountMicroUSD int64, ref, withdrawalID string) bool {
	for attempt := 0; attempt < 3; attempt++ {
		if attempt > 0 {
			time.Sleep(time.Duration(attempt) * 200 * time.Millisecond)
		}
		_, err := s.billing().Store().CreditWithdrawableOnce(accountID, amountMicroUSD, store.LedgerRefund, ref)
		if err == nil {
			return true
		}
		s.logger.Warn("stripe payout: refund credit attempt failed",
			"attempt", attempt+1, "error", err, "withdrawal_id", withdrawalID, "ledger_ref", ref)
	}
	s.logger.Error("stripe payout: refund credit failed after retries — MANUAL CREDIT REQUIRED",
		"withdrawal_id", withdrawalID, "ledger_ref", ref, "amount_micro_usd", amountMicroUSD)
	return false
}

// persistWithdrawalUpdate retries transient errors with the same expected state.
// A changed row returns immediately; retrying it must not overwrite a webhook.
// Used after money has moved (transfer/payout created): losing the update
// strands the row in a state the webhook matcher and sweep reconciler don't
// look at, so it's worth riding out a transient store blip in-request. Like
// creditRefundOnceWithRetry, it deliberately ignores request-context
// cancellation (bounded at 600ms total backoff) — abandoning the persist on
// client disconnect is exactly how rows get orphaned.
func (s *Controller) persistWithdrawalUpdate(previous, wd *store.StripeWithdrawal, stage string) error {
	var err error
	for attempt := 0; attempt < 3; attempt++ {
		if attempt > 0 {
			time.Sleep(time.Duration(attempt) * 200 * time.Millisecond)
		}
		var applied bool
		applied, err = s.billing().Store().CompareAndSwapStripeWithdrawal(previous, wd)
		if err == nil {
			if !applied {
				return errWithdrawalStateChanged
			}
			return nil
		}
		s.logger.Warn("stripe payout: persist "+stage+" attempt failed",
			"attempt", attempt+1, "error", err, "withdrawal_id", wd.ID)
	}
	return err
}

var errWithdrawalStateChanged = errors.New("withdrawal state changed during submission")

func (s *Controller) writeWithdrawalStateChanged(w http.ResponseWriter, withdrawalID string) {
	s.logger.Warn("stripe payout: submission state changed; preserving webhook state", "withdrawal_id", withdrawalID)
	httpresponse.WriteJSON(w, http.StatusConflict, httpresponse.ErrorBody("withdrawal_state_changed",
		"your withdrawal was updated while it was being submitted — check its status before retrying"))
}
