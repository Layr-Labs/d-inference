package api

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/billing/globalpayouts"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

var payoutUSDPattern = regexp.MustCompile(`^[0-9]{1,7}(\.[0-9]{1,2})?$`)

func payoutUSDCents(amount string) (int64, error) {
	amount = strings.TrimSpace(amount)
	if !payoutUSDPattern.MatchString(amount) {
		return 0, errors.New("use a USD amount with at most two decimal places")
	}
	parts := strings.SplitN(amount, ".", 2)
	dollars, _ := strconv.ParseInt(parts[0], 10, 64)
	cents := int64(0)
	if len(parts) == 2 {
		cents, _ = strconv.ParseInt((parts[1] + "0")[:2], 10, 64)
	}
	total := dollars*100 + cents
	if total < 100 || total > 100_000_000 {
		return 0, errors.New("withdrawal must be between $1 and $1,000,000")
	}
	return total, nil
}
func payoutCurrencyExponent(currency string) int {
	switch strings.ToLower(currency) {
	case "bif", "clp", "djf", "gnf", "jpy", "kmf", "krw", "mga", "pyg", "rwf", "ugx", "vnd", "vuv", "xaf", "xof", "xpf":
		return 0
	case "bhd", "jod", "kwd", "omr", "tnd":
		return 3
	default:
		return 2
	}
}

func (s *Server) handleGlobalPayoutQuote(w http.ResponseWriter, r *http.Request) {
	user := s.requirePrivyUser(w, r)
	if user == nil {
		return
	}
	repo, ok := s.globalPayoutStore()
	if !ok || !s.billing.GlobalPayoutsEnabled() {
		globalPayoutError(w, errors.New("Global Payouts unavailable"))
		return
	}
	var req struct {
		Amount string `json:"amount_usd"`
	}
	if json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&req) != nil {
		writeJSON(w, 400, errorResponse("invalid_request_error", "Enter a valid withdrawal amount."))
		return
	}
	cents, err := payoutUSDCents(req.Amount)
	if err != nil {
		writeJSON(w, 400, errorResponse("invalid_request_error", err.Error()))
		return
	}
	local, err := repo.GetGlobalRecipient(user.AccountID)
	if err != nil {
		globalPayoutError(w, err)
		return
	}
	if err = s.refreshGlobalRecipient(r.Context(), local); err != nil {
		globalPayoutError(w, err)
		return
	}
	if !local.Ready {
		writeJSON(w, 409, errorResponse("not_onboarded", "Complete your bank details in Stripe before withdrawing."))
		return
	}
	policy, _ := globalpayouts.Lookup(local.Country)
	request := globalpayouts.NewRequest(s.billing.GlobalPayouts().FinancialAccount, local.RecipientID, local.PayoutMethodID, policy.Currency, cents)
	quote, err := s.billing.GlobalPayouts().Quote(r.Context(), request)
	if err != nil {
		s.logger.Warn("global payout quote failed", "error", err)
		globalPayoutError(w, err)
		return
	}
	if err = quote.Validate(request); err != nil {
		globalPayoutError(w, err)
		return
	}
	now := time.Now()
	expires := now.Add(2 * time.Minute)
	if quote.FXQuote != nil && !quote.FXQuote.LockExpiresAt.IsZero() && quote.FXQuote.LockExpiresAt.Before(expires) {
		expires = quote.FXQuote.LockExpiresAt
	}
	if !expires.After(now.Add(5 * time.Second)) {
		globalPayoutError(w, store.ErrPayoutQuoteExpired)
		return
	}
	id := uuid.NewString()
	request.QuoteID = quote.ID
	request.Description = "Darkbloom earnings"
	request.Metadata = map[string]string{"darkbloom_withdrawal_id": id}
	payload, err := json.Marshal(request)
	if err != nil {
		globalPayoutError(w, err)
		return
	}
	p := store.GlobalPayout{ID: id, AccountID: user.AccountID, RecipientID: local.RecipientID, RecipientGeneration: local.ID, PayoutMethodID: local.PayoutMethodID, Country: local.Country, AmountMicroUSD: cents * 10_000, DestinationAmount: quote.To.Credited.Value, Currency: quote.To.Credited.Currency, Request: payload, Status: "quoted", ExpiresAt: expires, CreatedAt: now}
	if err = repo.CreateGlobalPayoutQuote(p); err != nil {
		globalPayoutError(w, err)
		return
	}
	writeJSON(w, 200, map[string]any{"id": id, "amount_usd": formatUSD(p.AmountMicroUSD), "fee_usd": "0.00", "destination_amount": p.DestinationAmount, "currency": p.Currency, "currency_exponent": payoutCurrencyExponent(p.Currency), "expires_at": expires, "destination_last4": local.Last4, "eta": "Typically 1–7 business days"})
}

func (s *Server) maybeGlobalWithdraw(w http.ResponseWriter, r *http.Request, user *store.User) bool {
	repo, ok := s.globalPayoutStore()
	if !ok {
		return false
	}
	// Inspect once and restore the body for the Connect handler. A Global
	// confirmation must remain on its original rail even after unlink/country changes.
	body, readErr := io.ReadAll(http.MaxBytesReader(w, r.Body, 4096))
	if readErr != nil {
		writeJSON(w, 400, errorResponse("invalid_request_error", "Invalid withdrawal request."))
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
	if s.billing.GlobalPayouts() == nil {
		globalPayoutError(w, errors.New("Global Payouts unavailable"))
		return true
	}
	if decodeErr != nil {
		writeJSON(w, 400, errorResponse("invalid_request_error", "Invalid withdrawal request."))
		return true
	}
	cents, err := payoutUSDCents(req.Amount)
	if err != nil || req.QuoteID == "" || (req.Method != "" && req.Method != "standard") {
		writeJSON(w, 400, errorResponse("quote_required", "Review your bank withdrawal before confirming."))
		return true
	}
	p, err := repo.GetGlobalPayout(req.QuoteID)
	if err != nil || p.AccountID != user.AccountID || p.AmountMicroUSD != cents*10_000 {
		writeJSON(w, 409, errorResponse("quote_required", "Review your bank withdrawal again."))
		return true
	}
	if p.Status == "quoted" {
		if !s.billing.GlobalPayoutsEnabled() {
			globalPayoutError(w, errors.New("new bank withdrawals are paused"))
			return true
		}
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
	writeJSON(w, http.StatusAccepted, map[string]any{"status": p.Status, "withdrawal_id": p.ID, "payout_id": p.ExternalID, "amount_usd": formatUSD(p.AmountMicroUSD), "fee_usd": "0.00", "net_usd": formatUSD(p.AmountMicroUSD), "method": "standard", "payout_rail": "global", "destination_amount": p.DestinationAmount, "payout_currency": p.Currency, "refunded": p.Refunded, "eta": "Typically 1–7 business days", "balance_micro_usd": s.billing.Ledger().Balance(user.AccountID)})
	return true
}
