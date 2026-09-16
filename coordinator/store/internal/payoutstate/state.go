package payoutstate

import (
	"encoding/json"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
)

func CloneGlobalPayout(p contracts.GlobalPayout) contracts.GlobalPayout {
	p.Request = append(json.RawMessage(nil), p.Request...)
	p.EstimatedStripeFees = append(json.RawMessage(nil), p.EstimatedStripeFees...)
	if p.Rejection != nil {
		r := *p.Rejection
		p.Rejection = &r
	}
	return p
}

func RecordGlobalRejection(p *contracts.GlobalPayout, attempt int, code string) error {
	if attempt != 1 || p.DispatchAttempts != attempt || p.ExternalID != "" || p.Status != "pending" {
		return contracts.ErrPayoutConflict
	}
	if p.Rejection != nil && (p.Rejection.Attempt != attempt || p.Rejection.Code != code) {
		return contracts.ErrPayoutConflict
	}
	p.Rejection = &contracts.GlobalPayoutRejection{Attempt: attempt, Code: code}
	return nil
}

func GlobalQuotePruneLimit(limit int) int {
	if limit < 1 || limit > 1000 {
		return 1000
	}
	return limit
}

func GlobalPayoutRefund(status string) bool {
	return status == "failed" || status == "canceled" || status == "returned"
}

func GlobalPayoutReconcile(p contracts.GlobalPayout, now time.Time) bool {
	return !p.RequiresManualReconciliation() && (p.Status == "pending" || p.Status == "processing" || (p.Status == "posted" && now.Sub(p.SubmittedAt) < 90*24*time.Hour)) && !p.LeaseUntil.After(now) && now.Sub(p.CheckedAt) >= time.Minute
}

// applyGlobalResult refuses state regression from stale concurrent readbacks.
// A posted payment may return later; already-refunded payments never reopen.
func ApplyGlobalResult(p *contracts.GlobalPayout, r contracts.GlobalPayoutResult, now time.Time) (refund bool, err error) {
	if p.Status == "quoted" {
		return false, contracts.ErrPayoutConflict
	}
	if r.ExternalID != "" && p.ExternalID != "" && r.ExternalID != p.ExternalID {
		return false, contracts.ErrPayoutConflict
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
	if r.Status != "processing" && r.Status != "posted" && !GlobalPayoutRefund(r.Status) {
		return false, contracts.ErrPayoutConflict
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
	if GlobalPayoutRefund(r.Status) {
		p.Refunded = true
		return true, nil
	}
	return false, nil
}

func ValidateGlobalQuote(p contracts.GlobalPayout) error {
	if p.ID == "" || p.AccountID == "" || p.RecipientID == "" || p.RecipientGeneration == "" || p.PayoutMethodID == "" || p.AmountMicroUSD <= 0 || p.AmountMicroUSD%10_000 != 0 || !json.Valid(p.Request) || p.ExpiresAt.IsZero() || p.Status != "quoted" {
		return contracts.ErrPayoutConflict
	}
	return nil
}
