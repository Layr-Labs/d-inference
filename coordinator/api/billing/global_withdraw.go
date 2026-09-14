package billing

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
	"github.com/eigeninference/d-inference/coordinator/billing/globalpayouts"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *Controller) maybeGlobalWithdraw(w http.ResponseWriter, r *http.Request, user *store.User) bool {
	repo, ok := s.globalPayoutStore()
	if !ok {
		return false
	}
	// Inspect once and restore the body for the Connect handler. A Global
	// confirmation must remain on its original rail even after unlink/country changes.
	body, readErr := io.ReadAll(http.MaxBytesReader(w, r.Body, 4096))
	if readErr != nil {
		httpresponse.WriteJSON(w, 400, httpresponse.ErrorBody("invalid_request_error", "Invalid withdrawal request."))
		return true
	}
	r.Body = io.NopCloser(bytes.NewReader(body))
	var req struct {
		Amount  string `json:"amount_usd"`
		Method  string `json:"method"`
		QuoteID string `json:"quote_id"`
	}
	decodeErr := json.Unmarshal(body, &req)
	local, err := repo.GetGlobalRecipient(user.AccountID)
	if errors.Is(err, store.ErrNotFound) && req.QuoteID == "" {
		return false
	}
	if err != nil && !errors.Is(err, store.ErrNotFound) {
		globalPayoutError(w, err)
		return true
	}
	if s.billing().GlobalPayouts() == nil {
		globalPayoutError(w, errors.New("Global Payouts unavailable"))
		return true
	}
	if decodeErr != nil {
		httpresponse.WriteJSON(w, 400, httpresponse.ErrorBody("invalid_request_error", "Invalid withdrawal request."))
		return true
	}
	cents, err := payoutUSDCents(req.Amount)
	if err != nil || req.QuoteID == "" || (req.Method != "" && req.Method != "standard") {
		httpresponse.WriteJSON(w, 400, httpresponse.ErrorBody("quote_required", "Review your bank withdrawal before confirming."))
		return true
	}
	p, err := repo.GetGlobalPayout(req.QuoteID)
	if err != nil || p.AccountID != user.AccountID || p.AmountMicroUSD != cents*10_000 {
		httpresponse.WriteJSON(w, 409, httpresponse.ErrorBody("quote_required", "Review your bank withdrawal again."))
		return true
	}
	if p.Status == "quoted" {
		var original globalpayouts.PaymentRequest
		if err := json.Unmarshal(p.Request, &original); err != nil {
			globalPayoutError(w, err)
			return true
		}
		paused := !s.billing().GlobalPayoutsEnabled()
		changed := original.From["financial_account"] != s.billing().GlobalPayouts().FinancialAccount
		if paused || changed {
			// Serialize invalidation with Begin: never clear a saved client
			// identity based on a stale "quoted" snapshot after another debit.
			p, err = repo.ExpireGlobalPayoutQuote(user.AccountID, p.ID, time.Now())
			if err != nil {
				globalPayoutError(w, err)
				return true
			}
			if p.Status == "quoted" {
				code, message := "payout_changed", "Payout settings changed. Review a new withdrawal."
				if paused {
					code, message = "quote_paused", "New bank withdrawals are paused. Your unsubmitted confirmation has been released."
				}
				httpresponse.WriteJSON(w, http.StatusConflict, httpresponse.ErrorBody(code, message))
				return true
			}
		}
	}
	if p.Status == "quoted" {
		if local == nil {
			globalPayoutError(w, store.ErrPayoutConflict)
			return true
		}
		if err = s.refreshGlobalRecipient(r.Context(), local); err != nil {
			globalPayoutError(w, err)
			return true
		}
		p, err = repo.BeginGlobalPayout(user.AccountID, p.ID, time.Now())
		if err != nil {
			globalPayoutError(w, err)
			return true
		}
	}
	// A lost HTTP response can be retried using the same quote ID without a
	// second ledger debit or a new Stripe idempotency key.
	if err = s.syncGlobalPayout(r.Context(), p.ID); err != nil {
		s.logger.Error("global payout reconciliation pending", "withdrawal_id", p.ID, "error", err)
	}
	latest, err := repo.GetGlobalPayout(p.ID)
	if err == nil {
		p = latest
	}
	httpresponse.WriteJSON(w, http.StatusAccepted, map[string]any{"status": p.Status, "withdrawal_id": p.ID, "payout_id": p.ExternalID, "amount_usd": formatUSD(p.AmountMicroUSD), "fee_usd": "0.00", "net_usd": formatUSD(p.AmountMicroUSD), "method": "standard", "payout_rail": "global", "destination_amount": p.DestinationAmount, "payout_currency": p.Currency, "refunded": p.Refunded, "eta": "Typically 1–7 business days", "balance_micro_usd": s.billing().Ledger().Balance(user.AccountID)})
	return true
}
