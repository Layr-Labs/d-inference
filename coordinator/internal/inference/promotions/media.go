package promotions

import (
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// TopUpRequest updates the same token/cash hold after linked media is inlined.
func (s *Engine) TopUpRequest(w http.ResponseWriter, r *http.Request, p Admission, current int64) (int64, bool) {
	reservation := Reservation(r)
	backend, ok := store.As[store.ModelTokenPromotionStore](s.store)
	if !ok {
		s.unavailable(w, p.Model)
		return current, true
	}
	rates := payments.RatesFor(s.store.GetModelPrice("platform", p.Model))
	limit := s.keyRemaining(access.KeyIDFromContext(r.Context()), access.KeyLimitMicroFromContext(r.Context()), access.KeyLimitResetFromContext(r.Context()))
	updated, err := backend.TopUpModelTokenReservation(reservation.ID, int64(max(p.BillingPromptTokens, p.EstimatedPromptTokens))+int64(p.RequestedMaxTokens), quote(max(p.BillingPromptTokens, p.EstimatedPromptTokens), p.RequestedMaxTokens, rates, limit))
	if err != nil {
		s.writeAdmissionError(w, p.Model, err, true, reservation.FreeTokens)
		return current, true
	}
	modelTokenRequest(r).reservation = updated
	return updated.ReservedMicroUSD, false
}
