package service

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/eigeninference/d-inference/coordinator/appattest"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (x *Session) updateServingAuthorization(status *protocol.AppAttestStatus, evidence appattest.AuthorizationEvidence, verdict appattest.AuthorizationVerdict) {
	x.readinessRetryPending = false
	x.authorizationResult = "serving_unavailable"
	defer func() {
		// A prospective eligible policy is distinct from an actual live grant.
		// Keep the exchange outcome intact for the bounded retry loop.
		last := x.lastOutcome
		x.observe("authorization", x.authorizationResult, nil)
		x.lastOutcome = last
	}()
	a := x.s.authorizer
	if a == nil || status == nil || x.protocolVersion != 3 {
		return
	}
	current, revoked := x.s.registry.RecordVerifiedAppAttestPresenter(x.provider,
		evidence.Binding.Credential, evidence.Binding.Account, evidence.Binding.Endpoint)
	if !current {
		x.authorizationResult = "presenter_rejected"
		return
	}
	if revoked {
		x.authorizationResult = "credential_revoked"
		// A local revocation may have won after the durable readiness read.
		// The registry already fenced this exact pointer atomically.
		a.forget(x.provider)
		x.s.sendAppAttestAuthorizationStatus(x.provider)
		return
	}
	if evidence.RevocationKnown && evidence.Revoked {
		x.authorizationResult = "credential_revoked"
		x.fenceRevokedCredential(evidence.Binding.Credential)
		return
	}
	if verdict.Outcome == "unknown" {
		x.authorizationResult = "policy_unknown"
		// The previous proof remains usable only within its existing deadlines.
		// Keep its refresh record so recovery does not require another assertion;
		// unknown evidence neither replaces the proof nor extends its lease.
		// A first proof has no such record. Retry the assertion earlier after a
		// failed readiness lookup or while a verified enrollment receipt awaits
		// its first risk metric. Receipt renewal can finish independently of this
		// session; recovery must repeat identity and all policy checks before grant.
		a.mu.Lock()
		readinessPending := !evidence.RevocationKnown || (evidence.ReceiptVerified && evidence.RiskMetric == nil && evidence.RenewalConfigured)
		x.readinessRetryPending = readinessPending && a.current[x.provider] == nil
		a.mu.Unlock()
		x.s.sendAppAttestAuthorizationStatus(x.provider)
		return
	}
	if verdict.Outcome != "eligible" {
		x.authorizationResult = "policy_ineligible"
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
			x.authorizationResult = "identity_store_unavailable"
			x.retryFirstGrant()
			return
		}
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		continuity, err := st.ResolveMachineContinuity(ctx, x.provider.ID, x.account, x.key.KeyID, x.s.registry.ProviderIDs())
		if errors.Is(err, store.ErrMachineContinuityUnverified) && x.inventory != nil {
			x.inventory.mu.Lock()
			observed := x.inventory.observation
			x.inventory.mu.Unlock()
			if observed.SessionID != x.provider.ID || observed.AccountID != x.account || observed.VerifiedAppAttestKey != evidence.Binding.Credential {
				x.authorizationResult = "identity_alias_unbound"
				x.retryFirstGrant()
				return
			}
			if recovery, ok := store.As[store.MachineContinuityRecoveryStore](x.s.store); ok {
				recovered, recoveryErr := recovery.RecoverLiveAppAttestMachineSession(ctx, x.provider.ID, x.account, x.key.KeyID, time.Now().UTC())
				if recoveryErr != nil {
					x.authorizationResult = "identity_recovery_failed"
					x.retryFirstGrant()
					return
				}
				if recovered {
					// The new proof, not historical backfill, supplies the alias.
					// ObserveMachine performs any account-scoped canonical merge;
					// the strict continuity read must succeed afterwards.
					x.inventory.capture(false)
					machine := x.inventory.snapshot().ID
					if machine == "" {
						x.authorizationResult = "identity_recovery_incomplete"
						x.retryFirstGrant()
						return
					}
					evidence.Binding.Machine, evidence.Expected.Machine = machine, machine
					if appattest.EvaluateAuthorization(evidence, time.Now()).Outcome != "eligible" {
						x.authorizationResult = "identity_recovery_incomplete"
						return
					}
					continuity, err = st.ResolveMachineContinuity(ctx, x.provider.ID, x.account, x.key.KeyID, x.s.registry.ProviderIDs())
					if err == nil {
						x.s.ddIncr("app_attest.inventory.recovered", nil)
						x.observe("authorization_recovery", "historical_tombstone_reopened", nil)
					}
				}
			}
		}
		if err != nil {
			x.authorizationResult = "identity_lookup_failed"
			if errors.Is(err, store.ErrMachineContinuityUnverified) {
				x.authorizationResult = "identity_unverified"
			}
			x.retryFirstGrant()
			return
		}
		if continuity.Machine.ID != evidence.Binding.Machine {
			x.authorizationResult = "identity_mismatch"
			return
		}
		// A first authorization can have no history; a later canonical merge
		// may discover the historical baseline. The registry applies one
		// baseline only, preserving live deltas and avoiding double counting
		// overlapping cumulative snapshots on repeated alias changes.
		if continuity.Previous != nil {
			if err := x.s.registry.MergeVerifiedMachineHistory(ctx, x.provider, continuity.Previous); err != nil {
				x.authorizationResult = "identity_restore_failed"
				x.retryFirstGrant()
				return
			}
		}
		if !x.s.registry.BindVerifiedMachineIdentity(x.provider, x.account, continuity.Machine.ID) {
			x.authorizationResult = "identity_bind_failed"
			x.retryFirstGrant()
			return
		}
		x.provider.CompleteProviderStateRestore()
		x.servingIdentityReady = true
	}
	// Remember only current cryptographically verified evidence; receipt and
	// revocation state are re-read independently and never recreate a signature.
	record := &appAttestAuthorizationRecord{evidence: evidence, status: *status, proofSession: x.id, dropped: x.dropped.Load, dropBaseline: x.proofDropBaseline}
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
					_, x.authorizationResult = a.applyDetailed(x.provider, record, state, observedAt)
				}
			}
			a.mu.Unlock()
			if revoked {
				x.authorizationResult = "credential_revoked"
				x.fenceRevokedCredential(x.key.KeyID)
				return
			}
			if x.authorizationResult == "grant_rejected" {
				x.retryFirstGrant()
			}
		} else {
			x.authorizationResult = "readiness_lookup_failed"
		}
	} else {
		x.authorizationResult = "readiness_store_unavailable"
	}
	x.s.sendAppAttestAuthorizationStatus(x.provider)
}

// A fresh assertion is required after an identity or runtime transition that
// failed before the first lease. The retry is bounded by nextAssertionDelay;
// merely scheduling it does not retain or grant any proof.
func (x *Session) retryFirstGrant() {
	if _, granted := x.s.registry.ProviderServingAuthorization(x.provider); !granted {
		x.readinessRetryPending = true
	}
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
