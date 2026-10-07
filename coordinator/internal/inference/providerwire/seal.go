package providerwire

import (
	"encoding/json"

	inreq "github.com/eigeninference/d-inference/coordinator/api/inference/request"
)

// legacyCacheBustField is the request field a protocol-0 provider reads its
// per-attempt cache isolation key from.
const LegacyCacheBustField = "prompt_cache_key"

// sealLegacyCacheBust is the decode/re-encode path for bodies the splice fast
// path cannot prove canonical.
func sealLegacyCacheBust(body, keyJSON []byte) ([]byte, error) {
	var parsed map[string]json.RawMessage
	if err := json.Unmarshal(body, &parsed); err != nil {
		return nil, err
	}
	parsed[LegacyCacheBustField] = keyJSON
	return inreq.MarshalForwardBody(parsed)
}

// cacheAttemptSealedSize returns the length bodyForCacheAttempt's sealed body
// would have for a provider-specific body and (possibly empty) legacy
// cache-bust key, computed arithmetically for canonical bodies and by the
// decode/re-encode path otherwise — never building the sealed bytes on the
// arithmetic path.
func CacheAttemptSealedSize(body []byte, legacyKey string) (int, error) {
	if legacyKey == "" {
		return len(body), nil
	}
	keyJSON, err := json.Marshal(legacyKey)
	if err != nil {
		return 0, err
	}
	if size, ok := SplicedTopLevelMemberSize(body, LegacyCacheBustField, keyJSON); ok {
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
func CacheAttemptSizeError(body []byte, legacyKey string) (int, error) {
	size, err := CacheAttemptSealedSize(body, legacyKey)
	if err != nil {
		return 0, err
	}
	if size > inreq.MaxInferenceBodyBytes {
		return size, &providerBodyTooLargeError{size: size}
	}
	return 0, nil
}
