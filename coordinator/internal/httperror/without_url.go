// Package httperror removes request URLs from outbound HTTP client errors.
package httperror

import (
	"errors"
	"fmt"
	"net/url"
)

// WithoutURL returns err without the request URL that http.Client adds as a
// *url.Error. Coordinator logs keep these errors, and some request URLs carry
// a device identifier, a provider IP address or an API key. The result keeps
// the HTTP method and wraps the cause, so errors.Is and net.Error timeout
// checks see the same cause as before.
func WithoutURL(err error) error {
	var urlErr *url.Error
	if !errors.As(err, &urlErr) {
		return err
	}
	return fmt.Errorf("%s: %w", urlErr.Op, urlErr.Err)
}
