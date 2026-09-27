package api

// provider_body_seal.go seals a provider body for a protocol-0 cache
// isolation attempt (the per-attempt prompt_cache_key buster) and sizes the
// result without necessarily building it. Both take the splice fast path of
// provider_body_splice.go for bodies proven canonical and fall back to the
// decode/re-encode path otherwise; bodyForCacheAttempt (consumer.go) is the
// dispatch-time caller, the sizing probes behind routingTraitsForProviderBody
// are the pre-dispatch ones.

import "encoding/json"

// legacyCacheBustField is the request field a protocol-0 provider reads its
// per-attempt cache isolation key from.
const legacyCacheBustField = "prompt_cache_key"

// sealLegacyCacheBust is the decode/re-encode path for bodies the splice fast
// path cannot prove canonical.
func sealLegacyCacheBust(body, keyJSON []byte) ([]byte, error) {
	var parsed map[string]json.RawMessage
	if err := json.Unmarshal(body, &parsed); err != nil {
		return nil, err
	}
	parsed[legacyCacheBustField] = keyJSON
	return marshalForwardBody(parsed)
}

// cacheAttemptSealedSize returns the length bodyForCacheAttempt's sealed body
// would have for a provider-specific body and (possibly empty) legacy
// cache-bust key, computed arithmetically for canonical bodies and by the
// decode/re-encode path otherwise — never building the sealed bytes on the
// arithmetic path.
func cacheAttemptSealedSize(body []byte, legacyKey string) (int, error) {
	if legacyKey == "" {
		return len(body), nil
	}
	keyJSON, err := json.Marshal(legacyKey)
	if err != nil {
		return 0, err
	}
	if size, ok := splicedTopLevelMemberSize(body, legacyCacheBustField, keyJSON); ok {
		return size, nil
	}
	sealed, err := sealLegacyCacheBust(body, keyJSON)
	if err != nil {
		return 0, err
	}
	return len(sealed), nil
}

// cacheAttemptSizeError mirrors bodyForCacheAttempt's verdict from a size:
// (0, nil) when the sealed body fits, (size, errProviderBodyTooLarge) when it
// does not, and (0, err) for a body that cannot be sealed at all.
func cacheAttemptSizeError(body []byte, legacyKey string) (int, error) {
	size, err := cacheAttemptSealedSize(body, legacyKey)
	if err != nil {
		return 0, err
	}
	if size > maxInferenceBodyBytes {
		return size, &providerBodyTooLargeError{size: size}
	}
	return 0, nil
}
