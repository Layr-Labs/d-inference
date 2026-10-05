package eligibility

// Infrastructure/key-recovery/format-compatibility failures are not a reason to
// ban an independently verified legacy path. Cryptographic substitution and
// observed unsafe Mac policy are hard evidence and fence both paths.
func ProofViolation(reason string) bool {
	switch reason {
	case "signature", "nonce", "mac_acl", "app_identity", "credential_key":
		return true
	}
	return false
}
