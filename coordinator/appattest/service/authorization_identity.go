package service

import (
	"context"
	"encoding/json"
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
	current, revoked := x.s.registry.RecordVerifiedAppAttestPresenter(x.provider,
		evidence.Binding.Credential, evidence.Binding.Account, evidence.Binding.Endpoint)
	if !current {
		return
	}
	if revoked {
		// A local revocation may have won after the durable readiness read.
		// The registry already fenced this exact pointer atomically.
		a.forget(x.provider)
		x.s.sendAppAttestAuthorizationStatus(x.provider)
		return
	}
	if evidence.RevocationKnown && evidence.Revoked {
		x.fenceRevokedCredential(evidence.Binding.Credential)
		return
	}
	if verdict.Outcome == "unknown" {
		// The previous proof remains usable only within its existing deadlines.
		// Keep its refresh record so recovery does not require another assertion;
		// unknown evidence neither replaces the proof nor extends its lease.
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
		// A first authorization can have no history; a later canonical merge
		// may discover the historical baseline. The registry applies one
		// baseline only, preserving live deltas and avoiding double counting
		// overlapping cumulative snapshots on repeated alias changes.
		if continuity.Previous != nil {
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
			revoked := false
			a.mu.Lock()
			if a.current[x.provider] == record {
				if state.Revoked {
					revoked = true
				} else {
					a.apply(x.provider, record, state, observedAt)
				}
			}
			a.mu.Unlock()
			if revoked {
				x.fenceRevokedCredential(x.key.KeyID)
				return
			}
		}
	}
	x.s.sendAppAttestAuthorizationStatus(x.provider)
}

// The current connection has just proven possession of this credential. It
// may have no previous serving grant, so credential-index invalidation alone
// cannot find it. A hard denial also prevents fallback through legacy trust.
func (x *Session) fenceRevokedCredential(key string) {
	x.s.authorizer.forget(x.provider)
	x.s.registry.RevokeAppAttestCredential(key)
	x.s.registry.DenyAppAttestProvider(x.provider)
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

func (s *Service) appAttestIdentityCandidate(r *protocol.RegisterMessage, account string) bool {
	return s.NeedsIdentityAccount(r) && appAttestAccountRolloutDecision(r.Version, account, s.config.RolloutPercent) == "enabled"
}

// NeedsIdentityAccount is only the structural prerequisite for an early token
// lookup. It does not choose the account cohort or grant a serving identity.
// Legacy-only registrations can retain their post-attestation token lookup.
func (s *Service) NeedsIdentityAccount(r *protocol.RegisterMessage) bool {
	return s.config.ServingEnabled && s.config.Environment == "production" && r != nil && r.AppAttestProtocol == 3 &&
		s.config.RolloutPercent > 0 && s.config.RolloutPercent <= 100 && appAttestCandidateOSSupported(r) &&
		appAttestProviderVersionSafe(r.Version)
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
