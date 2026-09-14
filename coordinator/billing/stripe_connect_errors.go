package billing

import (
	"errors"
	"fmt"
	"strings"
)

// APIError is a non-2xx response from the Stripe API. Its presence in an
// error chain means Stripe received, processed, and REJECTED the request —
// as opposed to transport/read/parse failures, where an idempotency-keyed
// request may have been accepted with the response lost in flight.
type APIError struct {
	StatusCode int
	Code       string // Stripe error code, e.g. "account_invalid" (may be empty)
	Message    string
}

func (e *APIError) Error() string {
	if e.Code != "" {
		return fmt.Sprintf("stripe %d [%s]: %s", e.StatusCode, e.Code, e.Message)
	}
	return fmt.Sprintf("stripe %d: %s", e.StatusCode, e.Message)
}

// IsDefinitiveAPIErr reports whether err chains to a Stripe API response
// that definitively rejected the request — i.e. no money moved. Only 4xx
// responses qualify: Stripe documents 5xx on POST mutations as indeterminate
// and potentially side-effecting (https://docs.stripe.com/error-low-level),
// and explicitly recommends retrying them with the same idempotency key.
//
// One 4xx is also indeterminate: 409 idempotency conflicts
// (idempotency_key_in_use) mean the ORIGINAL request is still executing and
// may yet succeed — treating that as a definitive failure would refund a
// mutation that can still roll forward.
//
// False for transport timeouts, connection drops, body read/parse failures,
// 5xx responses, and idempotency conflicts — callers must not refund on
// those without confirming (retry with the same idempotency key, or park
// the row for reconciliation).
func IsDefinitiveAPIErr(err error) bool {
	var apiErr *APIError
	if !errors.As(err, &apiErr) {
		return false
	}
	if apiErr.Code == "idempotency_key_in_use" || apiErr.StatusCode == 409 {
		return false
	}
	return apiErr.StatusCode >= 400 && apiErr.StatusCode < 500
}

// IsAccountGoneErr reports whether a Stripe error means the connected account
// no longer exists (the user closed it in their Stripe dashboard, or it was
// deleted). The stored acct_… is permanently unusable — the caller should
// clear it so the user can onboard a fresh account.
func IsAccountGoneErr(err error) bool {
	if err == nil {
		return false
	}
	msg := err.Error()
	return strings.Contains(msg, "No such destination") ||
		strings.Contains(msg, "No such account") ||
		strings.Contains(msg, "account_invalid") ||
		strings.Contains(msg, "does not have access to account")
}

// IsServiceAgreementErr reports whether a Stripe error means the connected
// account is under a service agreement that can't receive platform transfers
// (e.g. an AU/NZ/JP account created under `full` instead of `recipient`).
// The agreement is immutable — the account must be recreated.
func IsServiceAgreementErr(err error) bool {
	return err != nil && strings.Contains(err.Error(), "service agreement")
}
