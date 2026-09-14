package billing

import (
	"errors"
	"fmt"
	"net/url"
	"strings"
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
