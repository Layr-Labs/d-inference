package shared

import (
	"encoding/json"
	"github.com/eigeninference/d-inference/coordinator/store"
	"time"
)

// A queued request has no uncertain send. Persist the refreshed quote and the
// start of its idempotency horizon before releasing any money to Stripe.
func StartUnsentGlobalPayout(p *store.GlobalPayout, leaseUntil time.Time, request, fees json.RawMessage, destinationAmount int64, expiresAt, now time.Time) error {
	if (p.Status != "queued" && p.Status != "pending") || p.ExternalID != "" || p.Refunded || p.Rejection != nil || p.DispatchAttempts != 0 || !p.LeaseUntil.Equal(leaseUntil) || !leaseUntil.After(now) || !expiresAt.After(now) || !json.Valid(request) || destinationAmount <= 0 {
		return store.ErrPayoutConflict
	}
	p.Request = append(json.RawMessage(nil), request...)
	p.EstimatedStripeFees = append(json.RawMessage(nil), fees...)
	p.DestinationAmount = destinationAmount
	p.ExpiresAt = expiresAt
	p.Status = "pending"
	p.FailureCode = ""
	p.DispatchAttempts = 1
	p.DispatchStartedAt = now
	return nil
}

// Reserve a send only after its preflight checks. A claim alone does not start
// Stripe's idempotency clock or make an unsent request ambiguous.
func StartGlobalPayoutDispatch(p *store.GlobalPayout, leaseUntil, now time.Time) error {
	if p.Status != "pending" || p.ExternalID != "" || p.Refunded || p.Rejection != nil || !p.LeaseUntil.Equal(leaseUntil) || !leaseUntil.After(now) {
		return store.ErrPayoutConflict
	}
	if p.DispatchAttempts == 0 {
		p.DispatchStartedAt = now
	}
	p.DispatchAttempts++
	return nil
}
