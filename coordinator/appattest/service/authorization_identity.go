package service

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/appattest"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (x *Session) updateServingAuthorization(status *protocol.AppAttestStatus, evidence appattest.AuthorizationEvidence, verdict appattest.AuthorizationVerdict) {
	a := x.s.authorizer
	if a == nil || status == nil || x.protocolVersion != 3 {
		return
	}
	if evidence.RevocationKnown && evidence.Revoked {
		a.forget(x.provider)
		x.s.registry.RevokeAppAttestCredential(evidence.Binding.Credential)
		x.s.sendAppAttestAuthorizationStatus(x.provider)
		return
	}
	if verdict.Outcome != "eligible" {
		a.forget(x.provider)
		if confirmedAppAttestPolicyViolation(verdict) {
			x.s.registry.MarkUntrusted(x.provider.ID)
		}
		x.s.sendAppAttestAuthorizationStatus(x.provider)
		return
	}
	_, boundMachine := x.provider.GetVerifiedMachineIdentity()
	if !x.servingIdentityReady || boundMachine != evidence.Binding.Machine {
		st, ok := store.As[store.MachineOperationalStore](x.s.store)
		if !ok {
			return
		}
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		continuity, err := st.ResolveMachineContinuity(ctx, x.provider.ID, x.account, x.key.KeyID, x.s.registry.ProviderIDs())
		if err != nil || continuity.Machine.ID != evidence.Binding.Machine {
			return
		}
		// An audited canonical merge may change the machine ID on the same
		// live connection. Rebind it without overwriting work earned since the
		// original restoration.
		if !x.servingIdentityReady && continuity.Previous != nil {
			if err := x.s.registry.MergeVerifiedMachineHistory(ctx, x.provider, continuity.Previous); err != nil {
				return
			}
		}
		if !x.s.registry.BindVerifiedMachineIdentity(x.provider, x.account, continuity.Machine.ID) {
			return
		}
		x.provider.CompleteProviderStateRestore()
		x.servingIdentityReady = true
	}
	// Remember only current cryptographically verified evidence; receipt and
	// revocation state are re-read independently and never recreate a signature.
	record := &appAttestAuthorizationRecord{evidence: evidence, status: *status, proofSession: x.id, dropped: x.dropped.Load}
	a.remember(x.provider, record)
	if st, ok := store.As[store.AppAttestReadinessStore](x.s.store); ok {
		observedAt := time.Now().UTC()
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		state, err := st.GetAppAttestReadiness(ctx, x.key.KeyID)
		cancel()
		if err == nil {
			a.mu.Lock()
			if a.current[x.provider] == record {
				if state.Revoked {
					x.s.registry.RevokeAppAttestCredential(x.key.KeyID)
				} else {
					a.apply(x.provider, record, state, observedAt)
				}
			}
			a.mu.Unlock()
		}
	}
	x.s.sendAppAttestAuthorizationStatus(x.provider)
}

func confirmedAppAttestPolicyViolation(verdict appattest.AuthorizationVerdict) bool {
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

func (s *Service) appAttestIdentityCandidate(r *protocol.RegisterMessage) bool {
	return s.config.ServingEnabled && r.AppAttestProtocol == 3 &&
		appAttestRolloutDecision(r.Version, "validated-later", "validated-later", 100) == "enabled"
}
