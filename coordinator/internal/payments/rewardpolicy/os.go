package rewardpolicy

import "github.com/eigeninference/d-inference/coordinator/internal/payments/rewardeligibility"

// OSVersionEligible applies the shared floor for new BASE and Autopilot rewards.
func OSVersionEligible(version string) bool {
	return rewardeligibility.OSVersionEligible(version)
}
