package registry

import "github.com/eigeninference/d-inference/coordinator/protocol"

// Upstream transient assertion retry changes ProofSessionID on the SAME live
// provider connection. A current verified replacement proof may discharge only
// the original cleanup obligation. Admission equality deliberately does not use
// this helper. No deadline, nonce, grant, signer or device identity is refreshed.
func sameVerifiedPairCleanupIdentity(original, current protocol.NativeMemberIdentity) bool {
	if original.Kind != protocol.NativeIdentityAppAttest || current.Kind != protocol.NativeIdentityAppAttest ||
		original.Validate() != nil || current.Validate() != nil {
		return false
	}
	before, beforeError := original.SigningKeyIdentity()
	after, afterError := current.SigningKeyIdentity()
	if beforeError != nil || afterError != nil || before != after {
		return false
	}
	current.ProofSessionID = original.ProofSessionID
	return current == original
}
