package api

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// consoleKeyInheritsSelfRouteOnly reports whether a legacy POST /v1/auth/keys
// mint must be SelfRouteOnly. When every active (not disabled, not expired)
// key on the account is already machine-only, minting an unrestricted
// console key would silently escalate that account onto the paid public
// fleet. Vacuous (no active keys) is false: first-time console users still
// get an unrestricted key.
func consoleKeyInheritsSelfRouteOnly(keys []store.APIKey, now time.Time) bool {
	active := 0
	for i := range keys {
		if !apiKeyIsActive(keys[i], now) {
			continue
		}
		if !keys[i].SelfRouteOnly {
			return false
		}
		active++
	}
	return active > 0
}

func apiKeyIsActive(k store.APIKey, now time.Time) bool {
	if k.Disabled {
		return false
	}
	if k.ExpiresAt != nil && now.After(*k.ExpiresAt) {
		return false
	}
	return true
}
