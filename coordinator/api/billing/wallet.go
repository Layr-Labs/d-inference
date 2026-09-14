package billing

import (
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
	"github.com/eigeninference/d-inference/coordinator/api/requestauth"
)

// WalletBalance handles GET /v1/billing/wallet/balance.
func (s *Controller) WalletBalance(w http.ResponseWriter, r *http.Request) {
	accountID := requestauth.ResolveAccountID(r)

	resp := map[string]any{
		"credit_balance_micro_usd": s.billing().Ledger().Balance(accountID),
	}

	httpresponse.WriteJSON(w, http.StatusOK, resp)
}
