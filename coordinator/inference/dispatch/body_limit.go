package dispatch

import (
	"errors"
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

func (d *execution) noteProviderBodyTooLarge(errText string, bodyBytes int) {
	d.providerBodyTooLargeErr = errText
	d.providerBodyTooLargeBytes = bodyBytes
	d.setLastError(errText, http.StatusRequestEntityTooLarge)
}

func (d *execution) preflightLegacyCacheBust() {
	_, err := minimumLegacyCacheBustOverflow(d.rawBody, d.requiresVision)
	if errors.Is(err, ErrProviderBodyTooLarge) {
		d.minPrefixCacheProtocol = 1
	}
}

func (d *execution) noteProviderBodyTooLargeFor(
	provider *registry.Provider,
	errText string,
) {
	if provider == nil {
		return
	}
	if d.excludeProviders == nil {
		d.excludeProviders = make(map[string]struct{})
	}
	d.excludeProviders[provider.ID] = struct{}{}
	bodyBytes, _ := providerBodySizeError(
		d.rawBody, d.requiresVision, provider)
	d.noteProviderBodyTooLarge(errText, bodyBytes)
}

func (d *execution) latchProviderBodyTooLarge(errText string) {
	d.noteProviderBodyTooLarge(errText, d.providerBodyTooLargeBytes)
	d.terminalClientError = true
	d.terminalClientErrorCode = http.StatusRequestEntityTooLarge
	d.terminalClientErrorReason = "payload_too_large"
	d.terminalClientErrorMessage = errText
}
