package api

import (
	"errors"
	"fmt"
	"net/url"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/payments"
)

// validateRedirectURL ensures the user-supplied URL is on the same host as
// the operator-configured default. localhost is always allowed (dev). If no
// default is configured, the URL must be https and the call rejects http.
func validateRedirectURL(candidate, defaultURL string) error {
	cu, err := url.Parse(candidate)
	if err != nil {
		return errors.New("invalid URL")
	}
	if cu.Scheme != "https" && cu.Scheme != "http" {
		return errors.New("scheme must be http or https")
	}
	host := strings.ToLower(cu.Hostname())
	if host == "localhost" || host == "127.0.0.1" || host == "::1" {
		return nil
	}
	if defaultURL == "" {
		// No allowlist configured → require https + non-empty host.
		if cu.Scheme != "https" || host == "" {
			return errors.New("must be https with a hostname when no default is configured")
		}
		return nil
	}
	du, err := url.Parse(defaultURL)
	if err != nil {
		return nil // defaults are operator-configured; if malformed, fall back to allow https
	}
	if !strings.EqualFold(cu.Hostname(), du.Hostname()) {
		return fmt.Errorf("host %q does not match allowed host %q", cu.Hostname(), du.Hostname())
	}
	return nil
}

// microUSDToCents truncates to integer cents (1¢ = 10,000 micro-USD).
func microUSDToCents(microUSD int64) int64 { return microUSD / 10_000 }

func formatUSD(microUSD int64) string {
	return payments.FormatUSD(microUSD, 2)
}

func etaForMethod(method string) string {
	if method == "instant" {
		return "~30 minutes"
	}
	return "1-2 business days"
}

// Compile-time check we don't accidentally drop the auth import; the Privy
// helpers stay in scope via requirePrivyUser.
var _ = auth.UserFromContext

// Compile-time check on time import staying live.
var _ = time.Now
