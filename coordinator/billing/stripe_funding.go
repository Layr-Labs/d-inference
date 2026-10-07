package billing

import "errors"

func IsInsufficientStripeBalance(err error) bool {
	var apiErr *APIError
	return IsDefinitiveAPIErr(err) && errors.As(err, &apiErr) && apiErr.Code == "balance_insufficient"
}
