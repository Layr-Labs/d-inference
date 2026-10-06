package verification

import "github.com/eigeninference/d-inference/coordinator/store"

// ResolveMDACallback distinguishes an unrelated callback from an owned callback
// that must be consumed without granting trust. Its inputs are detached command
// and connection identities, never mutable queue ownership.
func ResolveMDACallback(job store.VerificationJob, binding Binding, bindingGen, callbackGen uint64, callbackUUID, udid, commandUUID string) (*Binding, bool) {
	if job.Kind != store.VerificationTaskMDA || job.UDID != udid {
		return nil, false
	}
	if binding.Generation != bindingGen || callbackGen != binding.Generation || callbackUUID != commandUUID || binding.Attestation.PublicKey != job.SEPubKey || !binding.ChallengeSettled || !binding.AllowMDA {
		return nil, true
	}
	return &binding, true
}
