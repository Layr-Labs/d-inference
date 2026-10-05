package deviceverification

import (
	"context"

	verification "github.com/eigeninference/d-inference/coordinator/internal/provider/verification"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type mdmSchedulerAttemptMetadata struct {
	udid       string
	mdaOutcome string
}

type mdmSchedulerAttemptContextKey struct{}

func (s *Verifier) ExecuteScheduledVerification(ctx context.Context, binding verification.Binding,

	kind store.VerificationTaskKind, udid string) verification.AttemptResult {
	if binding.Provider == nil || binding.Provider.ChallengeShouldStop() {
		return verification.AttemptResult{Outcome: store.VerificationOutcomePostureMismatch, Terminal: true}
	}
	metadata := &mdmSchedulerAttemptMetadata{}
	ctx = context.WithValue(ctx, mdmSchedulerAttemptContextKey{}, metadata)
	if kind == store.VerificationTaskSecurityInfo {
		outcome := s.VerifyProviderViaMDM(ctx, binding.ProviderID, binding.Provider, binding.Attestation)
		switch outcome {
		case Granted:
			return verification.AttemptResult{Outcome: store.VerificationOutcomeSuccess, Granted: true, UDID: metadata.udid}
		case Terminal:
			return verification.AttemptResult{Outcome: store.VerificationOutcomePostureMismatch, Terminal: true, UDID: metadata.udid}
		default:
			fixed := store.VerificationOutcomeTransient
			if binding.Provider.GetMDMFailureReason() == "securityinfo-timeout" {
				fixed = store.VerificationOutcomeTimeout
			}
			return verification.AttemptResult{Outcome: fixed, UDID: metadata.udid}
		}
	}
	if udid == "" {
		return verification.AttemptResult{Outcome: store.VerificationOutcomeInvalid, Terminal: true}
	}
	s.verificationBackend.
		Scheduler.
		ObserveMDASent()
	s.VerifyAppleDeviceAttestation(ctx, binding.ProviderID, binding.Provider, binding.Attestation, udid)
	if ctx.Err() != nil {
		return verification.AttemptResult{Outcome: store.VerificationOutcomeCancelled}
	}
	binding.Provider.Mu().Lock()
	verified := binding.Provider.MDAVerified
	binding.Provider.Mu().Unlock()
	if verified {
		return verification.AttemptResult{Outcome: store.VerificationOutcomeSuccess, Granted: true, UDID: udid}
	}
	if binding.Provider.ChallengeShouldStop() {
		return verification.AttemptResult{Outcome: store.VerificationOutcomeInvalid, Terminal: true, UDID: udid}
	}
	if metadata.mdaOutcome == "timeout" {
		return verification.AttemptResult{Outcome: store.VerificationOutcomeTimeout, UDID: udid}
	}
	if metadata.mdaOutcome == "invalid" ||
		metadata.mdaOutcome == "binding_mismatch" {
		return verification.AttemptResult{
			Outcome: store.VerificationOutcomeInvalid, Terminal: true, UDID: udid,
		}
	}
	return verification.AttemptResult{Outcome: store.VerificationOutcomeTransient, UDID: udid}
}
