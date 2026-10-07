package billing

import (
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	"github.com/eigeninference/d-inference/coordinator/api/httpx"
)

// handleWalletBalance handles GET /v1/billing/wallet/balance.
func (s *Owner) HandleWalletBalance(w http.ResponseWriter, r *http.Request) {
	accountID := access.ResolveAccountID(r)

	resp := map[string]any{
		"credit_balance_micro_usd": s.billing.Ledger().Balance(accountID),
	}
	httpx.WriteJSON(w, http.StatusOK, resp)
}
