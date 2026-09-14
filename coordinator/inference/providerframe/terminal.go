package providerframe

import "github.com/eigeninference/d-inference/coordinator/registry"

// Compact observers never change the profiler-off terminal arbitration policy.
func compactOnlyAttempt(ap *registry.AttemptProfile) bool {
	return ap != nil && ap.Parent() != nil && ap.Parent().CompactOnly
}
