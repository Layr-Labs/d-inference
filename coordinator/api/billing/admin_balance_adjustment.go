package billing

import (
	"encoding/json"
	"net/http"
	"strconv"

	"github.com/eigeninference/d-inference/coordinator/api/httpx"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// handleAdminCredit grants non-withdrawable inference credit.
func (s *Owner) HandleAdminCredit(w http.ResponseWriter, r *http.Request) {
	s.handleAdminBalanceAdjustment(w, r, false)
}

// handleAdminReward grants withdrawable earnings.
func (s *Owner) HandleAdminReward(w http.ResponseWriter, r *http.Request) {
	s.handleAdminBalanceAdjustment(w, r, true)
}

// Both admin adjustments share authorization, validation and account lookup.
// Their ledger operation and response fields remain explicitly separate.
func (s *Owner) handleAdminBalanceAdjustment(w http.ResponseWriter, r *http.Request, withdrawable bool) {
	if !s.access.IsAdminAuthorized(w, r) {
		return
	}

	var req struct {
		Email     string `json:"email"`
		AmountUSD string `json:"amount_usd"`
		Note      string `json:"note"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}
	if req.Email == "" {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", "email is required"))
		return
	}
	amountFloat, err := strconv.ParseFloat(req.AmountUSD, 64)
	if err != nil || amountFloat <= 0 {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", "amount_usd must be a positive number"))
		return
	}
	amountMicroUSD := int64(amountFloat * 1_000_000)

	user, err := s.store.GetUserByEmail(req.Email)
	if err != nil {
		httpx.WriteJSON(w, http.StatusNotFound, httpx.ErrorResponse("not_found", "no user found with email: "+req.Email))
		return
	}

	action, entryType, credit := "credit", store.LedgerAdminCredit, s.store.Credit
	if withdrawable {
		action, entryType, credit = "reward", store.LedgerAdminReward, s.store.CreditWithdrawable
	}
	ref := string(entryType)
	if req.Note != "" {
		ref += ":" + req.Note
	}
	if err := credit(user.AccountID, amountMicroUSD, entryType, ref); err != nil {
		httpx.WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse("internal_error", "failed to "+action+": "+err.Error()))
		return
	}
	s.logger.Info("admin "+action+" applied", "email", req.Email, "account_id", user.AccountID,
		"amount_micro_usd", amountMicroUSD, "note", req.Note)
	response := map[string]any{
		"ok": true, "account_id": user.AccountID, "email": user.Email,
		"withdrawable":  withdrawable,
		"balance_after": float64(s.store.GetBalance(user.AccountID)) / 1_000_000,
	}
	if withdrawable {
		response["rewarded_usd"] = amountFloat
		response["withdrawable_after"] = float64(s.store.GetWithdrawableBalance(user.AccountID)) / 1_000_000
	} else {
		response["credited_usd"] = amountFloat
	}
	httpx.WriteJSON(w, http.StatusOK, response)
}
