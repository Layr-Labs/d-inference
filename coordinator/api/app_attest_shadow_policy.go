package api

import "github.com/eigeninference/d-inference/coordinator/protocol"

func (x *appAttestShadowSession) observeBuildPolicy(status *protocol.AppAttestStatus) {
	if status == nil {
		x.observe("prospective_policy", "unknown_missing_signed_status", nil)
		return
	}
	snapshot := x.s.releaseTrustPolicy.Load()
	if snapshot == nil || len(snapshot.ByBinaryHash) == 0 || status.BinaryHash == "" {
		x.observe("release_comparison", "unknown", nil)
	} else {
		matched := false
		for _, candidate := range snapshot.ByBinaryHash[status.BinaryHash] {
			if candidate.Platform == "macos-arm64" && candidate.Version == status.AppVersion {
				matched = true
				break
			}
		}
		if matched {
			x.observe("release_comparison", "matched_app_report", nil)
		} else {
			x.observe("release_comparison", "mismatched_app_report", nil)
		}
	}
	// Comparing an authenticated app claim to a catalog is useful telemetry.
	// It does not qualify that measurement as Apple-certified build identity.
	x.observe("prospective_policy", "unknown_build_measurement_unqualified", nil)
}
