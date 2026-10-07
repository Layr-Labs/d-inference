package shared

import (
	"encoding/json"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func RecordGlobalRejection(p *store.GlobalPayout, attempt int, code string) error {
	if attempt != 1 || p.DispatchAttempts != attempt || p.ExternalID != "" || p.Status != "pending" {
		return store.ErrPayoutConflict
	}
	if p.Rejection != nil && (p.Rejection.Attempt != attempt || p.Rejection.Code != code) {
		return store.ErrPayoutConflict
	}
	p.Rejection = &store.GlobalPayoutRejection{Attempt: attempt, Code: code}
	return nil
}

func GlobalQuotePruneLimit(limit int) int {
	if limit < 1 || limit > 1000 {
		return 1000
	}
	return limit
}

func globalPayoutRefund(status string) bool {
	return status == "failed" || status == "canceled" || status == "returned"
}

// applyGlobalResult refuses state regression from stale concurrent readbacks.
// A posted payment may return later; already-refunded payments never reopen.
func ApplyGlobalResult(p *store.GlobalPayout, r store.GlobalPayoutResult, now time.Time) (refund bool, err error) {
	if p.Status == "quoted" {
		return false, store.ErrPayoutConflict
	}
	if r.ExternalID != "" && p.ExternalID != "" && r.ExternalID != p.ExternalID {
		return false, store.ErrPayoutConflict
	}
	p.CheckedAt = now
	p.LeaseUntil = time.Time{}
	if p.Refunded {
		return false, nil
	}
	if r.ExternalID != "" {
		p.ExternalID = r.ExternalID
	}
	if r.Status == "" {
		p.FailureCode = r.FailureCode
		return false, nil
	}
	if r.Status != "processing" && r.Status != "posted" && !globalPayoutRefund(r.Status) {
		return false, store.ErrPayoutConflict
	}
	if p.Status == "posted" && r.Status == "processing" {
		return false, nil
	}
	p.Status = r.Status
	p.FailureCode = r.FailureCode
	p.Arrival = r.Arrival
	if r.DestinationAmount > 0 {
		p.DestinationAmount = r.DestinationAmount
		p.Currency = r.Currency
	}
	if globalPayoutRefund(r.Status) {
		p.Refunded = true
		return true, nil
	}
	return false, nil
}

func ValidateGlobalQuote(p store.GlobalPayout) error {
	if p.ID == "" || p.AccountID == "" || p.RecipientID == "" || p.RecipientGeneration == "" || p.PayoutMethodID == "" || p.AmountMicroUSD <= 0 || p.AmountMicroUSD%10_000 != 0 || !json.Valid(p.Request) || p.ExpiresAt.IsZero() || p.Status != "quoted" {
		return store.ErrPayoutConflict
	}
	return nil
}
