package reservations

import (
	"errors"
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	httpx "github.com/eigeninference/d-inference/coordinator/api/httpx"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// reserveInferenceBalance performs the shared pre-flight balance reservation +
// per-key spend cap for both inference handlers. Self-route (policy.enabled) and
// a nil billing backend skip it (the request is free). On a spend-cap or
// insufficient-funds rejection it writes the exact terminal response and returns
// handled=true; otherwise it returns the reserved amount and whether it was a
// service-account reservation. The post-inference charge refunds any unused
// portion; the routing estimate is kept separate so capacity checks aren't
// over-inflated.
func (s *Controller) Reserve(w http.ResponseWriter, r *http.Request, parsed map[string]any, p Params) (reservedMicroUSD int64, serviceReservation bool, handled bool) {
	// Self-route is free: skip the pre-flight balance reservation and the
	// per-key spend cap entirely. A zero-balance owner must never be blocked
	// from running on their own machine, and a self_route_only key never spends.
	if s.billing == nil || p.SelfRoute {
		return 0, false, false
	}
	if amount, attempted, handled := s.promotions.Reserve(w, r, p.Promotion()); attempted {
		return amount, false, handled
	}
	consumerKey := access.ConsumerKeyFromContext(r.Context())
	// Normally the byte-count billing bound dominates the routing estimate. A
	// remote media URL is the exception: its short URL is rewritten after this
	// gate into hundreds/thousands of vision soft tokens. Reserve against the
	// larger bound so a low-balance caller cannot trigger coordinator egress and
	// only then fail the platform-price balance check.
	reservationPromptTokens := max(p.BillingPromptTokens, p.EstimatedPromptTokens)
	reservedMicroUSD = s.Cost(p.Model, reservationPromptTokens, p.RequestedMaxTokens)
	// Per-key spend cap (phase 1) — checked before the reservation so a capped
	// key never debits the account ledger.
	if msg, ok := s.keyCap(r.Context(), reservedMicroUSD); !ok {
		s.reject(r, parsed, p, "insufficient_quota")
		httpx.WriteJSON(w, http.StatusPaymentRequired, httpx.ErrorResponse("insufficient_quota", msg, httpx.WithCode("insufficient_quota")))
		return reservedMicroUSD, false, true
	}
	var err error
	serviceReservation, err = s.ReserveInitial(consumerKey, p.Model, reservedMicroUSD)
	if err != nil {
		if errors.Is(err, store.ErrInsufficientBalance) {
			s.reject(r, parsed, p, "insufficient_funds")
			httpx.WriteJSON(w, http.StatusPaymentRequired, httpx.ErrorResponse("insufficient_funds",
				"your balance is too low for this request — add funds at /billing or lower max_tokens", httpx.WithCode("insufficient_quota")))
		} else {
			s.logger.Error("balance reservation failed (DB error)", "consumer_key", consumerKey, "error", err)
			s.unavailable(w, p.Model)
		}
		return reservedMicroUSD, serviceReservation, true
	}
	return reservedMicroUSD, serviceReservation, false
}
