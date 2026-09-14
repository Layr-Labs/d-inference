package billing

import (
	"net/http"
	"strconv"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
	"github.com/eigeninference/d-inference/coordinator/api/requestauth"
)

// StripeWithdrawals handles GET /v1/billing/stripe/withdrawals.
// Returns the user's recent Stripe withdrawals for display in the UI.
func (s *Controller) StripeWithdrawals(w http.ResponseWriter, r *http.Request) {
	user := requestauth.RequirePrivyUser(w, r)
	if user == nil {
		return
	}
	limit := 50
	if l := r.URL.Query().Get("limit"); l != "" {
		if v, err := strconv.Atoi(l); err == nil && v > 0 && v <= 200 {
			limit = v
		}
	}
	withdrawals, err := s.billing().Store().ListStripeWithdrawals(user.AccountID, limit)
	if err != nil {
		httpresponse.WriteJSON(w, http.StatusInternalServerError, httpresponse.ErrorBody("internal_error", err.Error()))
		return
	}
	combined, err := s.appendGlobalWithdrawals(user.AccountID, withdrawals, limit)
	if err != nil {
		globalPayoutError(w, err)
		return
	}
	httpresponse.WriteJSON(w, http.StatusOK, map[string]any{"withdrawals": combined})
}
