package billing

import (
	"errors"
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
	"github.com/eigeninference/d-inference/coordinator/billing/globalpayouts"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func globalPayoutError(w http.ResponseWriter, err error) {
	code, message, status := "payout_unavailable", "Bank withdrawals are temporarily unavailable. Please try again shortly.", http.StatusBadGateway
	var stripeErr *globalpayouts.Error
	if errors.As(err, &stripeErr) {
		switch stripeErr.Code {
		case "amount_too_small_for_payout_method", "amount_too_small_for_selected_delivery_option":
			code, message, status = "invalid_request_error", "This bank transfer requires a larger withdrawal amount.", http.StatusBadRequest
		case "amount_too_large_for_payout_method", "amount_too_large_for_selected_delivery_option":
			code, message, status = "invalid_request_error", "This bank transfer exceeds the withdrawal limit. Try a smaller amount.", http.StatusBadRequest
		case "fx_quote_expired":
			code, message, status = "quote_expired", "The exchange quote expired. Review your withdrawal again.", http.StatusConflict
		case "outbound_flow_unsupported_country", "recipient_feature_not_active", "payout_method_disabled", "payout_method_archived":
			code, message, status = "not_onboarded", "Your bank account needs attention. Update your payout details in Stripe.", http.StatusConflict
		}
	}
	if errors.Is(err, store.ErrInsufficientBalance) {
		code, message, status = "insufficient_withdrawable", "Only available earned funds can be withdrawn.", http.StatusBadRequest
	}
	if errors.Is(err, store.ErrPayoutQuoteExpired) {
		code, message, status = "quote_expired", "The exchange quote expired. Review your withdrawal again.", http.StatusConflict
	}
	if errors.Is(err, store.ErrPayoutConflict) {
		code, message, status = "payout_changed", "Your payout details changed. Review your withdrawal again.", http.StatusConflict
	}
	var limitErr *globalpayouts.RecipientLimitError
	if errors.As(err, &limitErr) {
		code, message, status = "recipient_amount_limit", limitErr.Error(), http.StatusBadRequest
	}
	httpresponse.WriteJSON(w, status, httpresponse.ErrorBody(code, message))
}
