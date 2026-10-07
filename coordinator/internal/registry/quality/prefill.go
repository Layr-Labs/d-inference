package quality

import "github.com/eigeninference/d-inference/coordinator/env"

// PrefillFallback prefers the registration benchmark over the decode-rate proxy.
func PrefillFallback(reported, decode, ratio float64) float64 {
	if reported > 0 {
		return reported
	}
	return decode * ratio
}

// DecodeFloorUseFleetMedian reads the live tier-2 rate-source switch.
func DecodeFloorUseFleetMedian() bool {
	return env.EnvBool(env.EnvPrefix+"_DECODE_FLOOR_USE_FLEET_MEDIAN", true)
}
