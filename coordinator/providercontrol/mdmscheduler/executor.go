package mdmscheduler

import (
	"context"

	"github.com/eigeninference/d-inference/coordinator/providercontrol/verification"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Executor runs one verification attempt. Scheduler owns admission, cancellation
// and durable settlement; verification owns evidence checks and observations.
type Executor struct{ deps Dependencies }

func NewExecutor(deps Dependencies) Executor { return Executor{deps: deps} }

func (e Executor) Execute(ctx context.Context, target Target, kind store.VerificationTaskKind, udid string) AttemptResult {
	if target.Provider == nil || target.Provider.ChallengeShouldStop() {
		return AttemptResult{Outcome: store.VerificationOutcomePostureMismatch, Terminal: true}
	}
	ctx, metadata := verification.NewScheduledAttempt(ctx)
	if kind == store.VerificationTaskSecurityInfo {
		outcome := e.deps.Verifier().VerifySecurityInfo(ctx, target.ProviderID, target.Provider, target.Attestation)
		switch outcome {
		case verification.Granted:
			return AttemptResult{Outcome: store.VerificationOutcomeSuccess, Granted: true, UDID: metadata.UDID()}
		case verification.Terminal:
			return AttemptResult{Outcome: store.VerificationOutcomePostureMismatch, Terminal: true, UDID: metadata.UDID()}
		default:
			fixed := store.VerificationOutcomeTransient
			if target.Provider.GetMDMFailureReason() == "securityinfo-timeout" {
				fixed = store.VerificationOutcomeTimeout
			}
			return AttemptResult{Outcome: fixed, UDID: metadata.UDID()}
		}
	}
	if udid == "" {
		return AttemptResult{Outcome: store.VerificationOutcomeInvalid, Terminal: true}
	}
	recordCounter(e.deps, "mda_verification_total", "outcome", "sent")
	e.deps.Verifier().VerifyMDA(ctx, target.ProviderID, target.Provider, target.Attestation, udid)
	if ctx.Err() != nil {
		return AttemptResult{Outcome: store.VerificationOutcomeCancelled}
	}
	target.Provider.Mu().Lock()
	verified := target.Provider.MDAVerified
	target.Provider.Mu().Unlock()
	if verified {
		return AttemptResult{Outcome: store.VerificationOutcomeSuccess, Granted: true, UDID: udid}
	}
	if target.Provider.ChallengeShouldStop() {
		return AttemptResult{Outcome: store.VerificationOutcomeInvalid, Terminal: true, UDID: udid}
	}
	if metadata.MDAOutcome() == "timeout" {
		return AttemptResult{Outcome: store.VerificationOutcomeTimeout, UDID: udid}
	}
	if metadata.MDAOutcome() == "invalid" ||
		metadata.MDAOutcome() == "binding_mismatch" {
		return AttemptResult{
			Outcome: store.VerificationOutcomeInvalid, Terminal: true, UDID: udid,
		}
	}
	return AttemptResult{Outcome: store.VerificationOutcomeTransient, UDID: udid}
}
