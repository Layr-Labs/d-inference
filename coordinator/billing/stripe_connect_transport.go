package billing

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
)

// stripeAPIBase is overridden by tests to point at httptest.NewServer().
var stripeAPIBase = "https://api.stripe.com"

// stripeAccountIDRe validates connected-account IDs before they are
// interpolated into Stripe API paths or the Stripe-Account header. The IDs we
// use always originate from Stripe responses we stored ourselves, but
// validating at the client boundary makes path/header injection structurally
// impossible if a corrupted or attacker-influenced value ever reaches here
// (threat-model review advisory).
var stripeAccountIDRe = regexp.MustCompile(`^acct_[A-Za-z0-9_-]{1,128}$`)

// validAccountID returns an error unless id looks like a Stripe connected
// account ID (acct_…). Mock-mode code paths return before this check so the
// synthetic acct_mock_… IDs (which may embed emails) are unaffected.
func validAccountID(id string) error {
	if !stripeAccountIDRe.MatchString(id) {
		return fmt.Errorf("stripe connect: invalid account id %q", id)
	}
	return nil
}

// SetStripeAPIBaseForTest swaps the Stripe API base URL and returns the
// previous value so the caller can restore it. Test-only helper — production
// code must never call this.
func SetStripeAPIBaseForTest(url string) string {
	prev := stripeAPIBase
	stripeAPIBase = url
	return prev
}

type doOption func(req *http.Request)

func withStripeAccount(acct string) doOption {
	return func(req *http.Request) {
		if acct != "" {
			req.Header.Set("Stripe-Account", acct)
		}
	}
}

func (c *StripeConnect) do(method, path string, form url.Values, idempotencyKey string, opts ...doOption) ([]byte, error) {
	var body io.Reader
	if form != nil {
		body = strings.NewReader(form.Encode())
	}
	req, err := http.NewRequest(method, stripeAPIBase+path, body)
	if err != nil {
		return nil, fmt.Errorf("build request: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+c.secretKey)
	if form != nil {
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	}
	if idempotencyKey != "" {
		req.Header.Set("Idempotency-Key", idempotencyKey)
	}
	for _, opt := range opts {
		opt(req)
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("api request: %w", err)
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("read response: %w", err)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		// Surface Stripe's structured error verbatim as a typed *APIError.
		// The error code (when present) is included so callers can classify
		// failures (see IsAccountGoneErr / IsServiceAgreementErr), and the
		// type itself marks the failure as DEFINITIVE — Stripe answered, so
		// the request provably did not move money (unlike transport errors,
		// where an idempotent request may have been accepted).
		var errEnvelope struct {
			Error struct {
				Message string `json:"message"`
				Type    string `json:"type"`
				Code    string `json:"code"`
			} `json:"error"`
		}
		if json.Unmarshal(respBody, &errEnvelope) == nil && errEnvelope.Error.Message != "" {
			return nil, &APIError{StatusCode: resp.StatusCode, Code: errEnvelope.Error.Code, Message: errEnvelope.Error.Message}
		}
		return nil, &APIError{StatusCode: resp.StatusCode, Message: string(respBody)}
	}
	return respBody, nil
}
