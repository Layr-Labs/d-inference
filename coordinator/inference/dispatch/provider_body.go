package dispatch

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
	"github.com/eigeninference/d-inference/coordinator/providercontrol/releasepolicy"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// penaltySafeProviderVersion is the first provider release whose VLM penalty
// path handles repetition/presence/frequency penalties without crashing (the
// TokenRing 2D-prompt fix). Providers below it crash on a vision request that
// carries any of these fields, so the coordinator strips them before sealing
// for such a provider. Keep in sync with the release that ships the fix.
const penaltySafeProviderVersion = "0.6.7"

// visionPenaltyFields crash the pre-fix VLM penalty path on image requests.
var visionPenaltyFields = []string{"repetition_penalty", "presence_penalty", "frequency_penalty"}

// bodyForProvider returns the request body to seal for `provider`. It equals
// rawBody, except a vision request routed to a pre-fix provider has the
// crash-inducing penalty fields stripped. Fixed providers receive the penalties
// unchanged. Per-provider (not pre-routing) so a retry on a fixed provider keeps
// them. Remove once MIN_PROVIDER_VERSION clears all pre-fix builds.
func bodyForProvider(rawBody []byte, requiresVision bool, provider *registry.Provider) []byte {
	if !requiresVision {
		return rawBody
	}
	if provider.Version != "" && !releasepolicy.VersionLess(provider.Version, penaltySafeProviderVersion) {
		return rawBody // fixed provider — pass penalties through
	}
	// A body carrying none of the penalty fields at its top level is returned
	// unchanged without decoding it — the same outcome the decode path reaches
	// through changed=false, minus a full-body parse per sizing probe.
	if has, ok := topLevelObjectHasAnyKey(rawBody, visionPenaltyFields); ok && !has {
		return rawBody
	}
	parsed, err := DecodeJSONObject(rawBody)
	if err != nil {
		return rawBody
	}
	changed := false
	for _, key := range visionPenaltyFields {
		if _, ok := parsed[key]; ok {
			delete(parsed, key)
			changed = true
		}
	}
	if !changed {
		return rawBody
	}
	if stripped, err := httpresponse.MarshalBody(parsed); err == nil {
		return stripped
	}
	return rawBody
}

var ErrProviderBodyTooLarge = errors.New("provider request body too large")

type ProviderBodyTooLargeError struct {
	size int
}

func (e *ProviderBodyTooLargeError) Error() string {
	return fmt.Sprintf("%s: %d bytes exceeds the %d-byte limit after cache isolation",
		ErrProviderBodyTooLarge, e.size, MaxInferenceBodyBytes)
}

func (e *ProviderBodyTooLargeError) Unwrap() error {
	return ErrProviderBodyTooLarge
}

func OversizedProviderBodyBytes(err error) int {
	var sizeErr *ProviderBodyTooLargeError
	if errors.As(err, &sizeErr) {
		return sizeErr.size
	}
	return 0
}

func legacyCacheBustBodyBytes(
	rawBody []byte,
	requiresVision bool,
	provider *registry.Provider,
) (int, error) {
	if provider == nil {
		return 0, nil
	}
	return cacheAttemptSizeError(
		bodyForProvider(rawBody, requiresVision, provider),
		strings.Repeat("x", registry.LegacyCacheBustKeyLength))
}

func providerBodySizeError(
	rawBody []byte,
	requiresVision bool,
	provider *registry.Provider,
) (int, error) {
	if provider == nil {
		return 0, nil
	}
	provider.Mu().Lock()
	usesLegacyCacheBust := provider.PrefixCacheProtocol < 1
	provider.Mu().Unlock()
	legacyKey := ""
	if usesLegacyCacheBust {
		legacyKey = strings.Repeat("x", registry.LegacyCacheBustKeyLength)
	}
	return cacheAttemptSizeError(
		bodyForProvider(rawBody, requiresVision, provider), legacyKey)
}

func minimumLegacyCacheBustOverflow(rawBody []byte, requiresVision bool) (int, error) {
	// An empty-version provider exercises the only provider-specific shrinking
	// transform: legacy vision penalty removal. Raise a fleet-wide protocol floor
	// only when even that smallest valid protocol-0 body exceeds the cap.
	return legacyCacheBustBodyBytes(rawBody, requiresVision, &registry.Provider{})
}

func RoutingTraitsForProviderBody(
	hasTools bool,
	providerBody []byte,
	requiresVision bool,
) (registry.RequestTraits, error) {
	traits := registry.RequestTraits{HasTools: hasTools}
	_, err := minimumLegacyCacheBustOverflow(providerBody, requiresVision)
	if errors.Is(err, ErrProviderBodyTooLarge) {
		traits.MinPrefixCacheProtocol = 1
	}
	return traits, err
}

// bodyForCacheAttempt returns the body to seal for one dispatch attempt: the
// provider-specific body (bodyForProvider) with the protocol-0 cache-bust key
// added as prompt_cache_key when the attempt carries one, size-checked
// against the sealed-frame cap.
func bodyForCacheAttempt(rawBody []byte, requiresVision bool, provider *registry.Provider, pr *registry.PendingRequest) ([]byte, error) {
	body := bodyForProvider(rawBody, requiresVision, provider)
	if pr == nil || pr.LegacyCacheBustKey == "" {
		if len(body) > MaxInferenceBodyBytes {
			return nil, &ProviderBodyTooLargeError{size: len(body)}
		}
		return body, nil
	}
	keyJSON, err := json.Marshal(pr.LegacyCacheBustKey)
	if err != nil {
		return nil, err
	}
	sealed, ok := spliceTopLevelMember(body, legacyCacheBustField, keyJSON)
	if !ok {
		if sealed, err = sealLegacyCacheBust(body, keyJSON); err != nil {
			return nil, err
		}
	}
	if len(sealed) > MaxInferenceBodyBytes {
		return nil, &ProviderBodyTooLargeError{size: len(sealed)}
	}
	return sealed, nil
}
