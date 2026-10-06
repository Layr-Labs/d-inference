package service

import (
	"encoding/json"

	"github.com/eigeninference/d-inference/coordinator/appattest"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/authorization"
	cohort "github.com/eigeninference/d-inference/coordinator/internal/appattest/cohort"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (x *Session) updateServingAuthorization(status *protocol.AppAttestStatus, evidence appattest.AuthorizationEvidence, verdict appattest.AuthorizationVerdict) {
	x.authorizationResult = "serving_unavailable"
	proof := authorization.NewVerifiedProof(evidence, status, x.id, x.integrity.Dropped, x.integrity.Baseline())
	x.authorizationResult = x.authorizationIdentity().Update(proof, verdict)
}

func (x *Session) authorizationIdentity() *authorization.Identity {
	if x.identity == nil {
		deps := authorization.IdentityDependencies{
			Controller: x.s.authorizer, Registry: x.s.registry,
			Operational: func() store.MachineOperationalStore {
				st, _ := store.As[store.MachineOperationalStore](x.s.store)
				return st
			},
			Recovery: func() store.MachineContinuityRecoveryStore {
				st, _ := store.As[store.MachineContinuityRecoveryStore](x.s.store)
				return st
			},
			Readiness: func() store.AppAttestReadinessStore {
				st, _ := store.As[store.AppAttestReadinessStore](x.s.store)
				return st
			},
			Notify: x.s.sendAppAttestAuthorizationStatus,
			Count:  func(name string) { x.s.ddIncr(name, nil) },
			Observe: func(stage, outcome string) {
				if stage == "authorization" {
					x.authorizationResult = outcome
				}
				last := x.lastOutcome
				x.observe(stage, outcome, nil)
				x.lastOutcome = last
			},
		}
		if x.inventory != nil {
			deps.Inventory = x.inventory
		}
		x.identity = authorization.NewIdentity(deps, x.provider, x.account)
	}
	return x.identity
}

func (s *Service) appAttestIdentityCandidate(r *protocol.RegisterMessage, account string) bool {
	return s.NeedsIdentityAccount(r) && cohort.Account(account, s.config.RolloutPercent) == "enabled"
}

// NeedsIdentityAccount is only the structural prerequisite for an early token
// lookup. It does not choose the account cohort or grant a serving identity.
// Legacy-only registrations can retain their post-attestation token lookup.
func (s *Service) NeedsIdentityAccount(r *protocol.RegisterMessage) bool {
	return s.config.ServingEnabled && s.config.Environment == "production" && r != nil && r.AppAttestProtocol == 3 &&
		s.config.RolloutPercent > 0 && s.config.RolloutPercent <= 100 && appAttestCandidateOSSupported(r)
}

// A protocol-v3 build also runs on older macOS. An explicit older OS report
// preserves legacy identity recovery instead of waiting for unsupported App
// Attest. Unknown reports grant nothing and remain subject to qualification.
// This compatibility decision never replaces verification of signed evidence.
func appAttestCandidateOSSupported(r *protocol.RegisterMessage) bool {
	var report struct {
		Attestation struct {
			OSVersion string `json:"osVersion"`
		} `json:"attestation"`
	}
	_ = json.Unmarshal(r.Attestation, &report)
	major := reportedOSMajor(report.Attestation.OSVersion)
	return major == 0 || major >= 27
}
