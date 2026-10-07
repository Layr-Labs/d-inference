package payouts

import (
	"net/http"
	"strconv"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	"github.com/eigeninference/d-inference/coordinator/api/httpx"
)

// handleStripeWithdrawals handles GET /v1/billing/stripe/withdrawals.
// Returns the user's recent Stripe withdrawals for display in the UI.
func (s *Owner) HandleStripeWithdrawals(w http.ResponseWriter, r *http.Request) {
	user := access.RequirePrivyUser(w, r)
	if user == nil {
		return
	}
	limit := 50
	if l := r.URL.Query().Get("limit"); l != "" {
		if v, err := strconv.Atoi(l); err == nil && v > 0 && v <= 200 {
			limit = v
		}
	}
	withdrawals, err := s.billing.Store().ListStripeWithdrawals(user.AccountID, limit)
	if err != nil {
		httpx.WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse("internal_error", err.Error()))
		return
	}
	combined, err := s.appendGlobalWithdrawals(user.AccountID, withdrawals, limit)
	if err != nil {
		globalPayoutError(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"withdrawals": combined})
}
