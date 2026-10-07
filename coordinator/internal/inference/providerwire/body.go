package providerwire

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	inreq "github.com/eigeninference/d-inference/coordinator/api/inference/request"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

var ErrBodyTooLarge = errors.New("provider request body too large")

type providerBodyTooLargeError struct {
	size int
}

func (e *providerBodyTooLargeError) Error() string {
	return fmt.Sprintf("%s: %d bytes exceeds the %d-byte limit after cache isolation",
		ErrBodyTooLarge, e.size, inreq.MaxInferenceBodyBytes)
}

func (e *providerBodyTooLargeError) Unwrap() error { return ErrBodyTooLarge }

func OversizedBodyBytes(err error) int {
	var sizeErr *providerBodyTooLargeError
	if errors.As(err, &sizeErr) {
		return sizeErr.size
	}
	return 0
}

// MinimumLegacyCacheBustOverflow sizes a protocol-0 attempt without building it.
func MinimumLegacyCacheBustOverflow(body []byte) (int, error) {
	return CacheAttemptSizeError(body, strings.Repeat("x", registry.LegacyCacheBustKeyLength))
}

func RoutingTraits(hasTools bool, body []byte) (registry.RequestTraits, error) {
	traits := registry.RequestTraits{HasTools: hasTools}
	_, err := MinimumLegacyCacheBustOverflow(body)
	if errors.Is(err, ErrBodyTooLarge) {
		traits.MinPrefixCacheProtocol = 1
	}
	return traits, err
}

// BodyForCacheAttempt adds an optional protocol-0 cache-isolation key and checks
// the final body against the sealed-frame limit.
func BodyForCacheAttempt(body []byte, legacyKey string) ([]byte, error) {
	if legacyKey == "" {
		if len(body) > inreq.MaxInferenceBodyBytes {
			return nil, &providerBodyTooLargeError{size: len(body)}
		}
		return body, nil
	}
	keyJSON, err := json.Marshal(legacyKey)
	if err != nil {
		return nil, err
	}
	sealed, ok := SpliceTopLevelMember(body, LegacyCacheBustField, keyJSON)
	if !ok {
		if sealed, err = sealLegacyCacheBust(body, keyJSON); err != nil {
			return nil, err
		}
	}
	if len(sealed) > inreq.MaxInferenceBodyBytes {
		return nil, &providerBodyTooLargeError{size: len(sealed)}
	}
	return sealed, nil
}
