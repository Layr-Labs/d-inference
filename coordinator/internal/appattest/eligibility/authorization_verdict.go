package eligibility

import (
	"github.com/eigeninference/d-inference/coordinator/appattest"
)

func PolicyViolation(verdict appattest.AuthorizationVerdict) bool {
	if verdict.Outcome != "ineligible" {
		return false
	}
	for _, reason := range verdict.Reasons {
		switch reason {
		case "connection_binding_mismatch", "hardware_claims_mismatch", "verification_key_mismatch",
			"launch_category_not_developer_id", "apple_code_measurement_mismatch", "bundle_version_mismatch", "credential_revoked":
			return true
		}
	}
	// Missing runtime/catalog/qualification facts deny this path; independent
	// legacy release policy continues to decide legacy eligibility.
	return false
}
