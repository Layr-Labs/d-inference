package service

import (
	"context"
	"encoding/json"
	"time"

	"github.com/eigeninference/d-inference/coordinator/appattest"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (x *Session) observeBuildPolicy(status *protocol.AppAttestStatus, metadata *appattest.Key) {
	binding := appattest.AuthorizationBinding{Account: x.account, Machine: x.machineID(), Credential: x.key.KeyID, Connection: x.id, Endpoint: x.publicKey, AppID: x.key.AppID, Environment: x.key.Environment}
	evidence := appattest.AuthorizationEvidence{Binding: binding, Expected: binding, ProtocolVersion: x.protocolVersion,
		CredentialVerified: true, EndpointBound: true, AssertionAt: x.assertionAt, ArchiveComplete: x.dropped.Load() == 0,
		RenewalConfigured: x.s.config.ReceiptKeyPath != "" && x.s.config.ReceiptKeyID != ""}
	evidence.Expected.AppID, evidence.Expected.Environment = x.s.config.AppID, x.s.config.Environment
	if metadata != nil {
		// Enrollment metadata cannot stand in for a current assertion's metadata.
		evidence.BundleVersion, evidence.ValidationCategory = metadata.BundleVersion, metadata.ValidationCategory
	}
	snapshot := x.s.currentReleasePolicySnapshot()
	evidence.CatalogKnown = snapshot != nil && snapshot.Known
	if status != nil {
		evidence.HardwareKnown, evidence.HardwareMatched = appAttestHardwareComparison(x.protocolVersion, status, x.hardware)
		evidence.VerificationKeyKnown = x.protocolVersion == 3 && x.attestationKey != "" && status.AttestationPublicKey != ""
		evidence.VerificationKeyMatched = evidence.VerificationKeyKnown && status.AttestationPublicKey == x.attestationKey
		evidence.ReportedVersion = status.AppVersion
		evidence.BuildQualified = qualifiedAppAttestBuild(x.s.config.QualifiedBuildHashes, status.BinaryHash)
		evidence.CodeMeasurementKnown, evidence.CodeMeasurementMatched = qualifiedAppAttestMeasurement(x.s.config.QualifiedCodeHashes, status.BinaryHash, metadata)
		evidence.BuildMatched = appAttestReleaseApproved(snapshot, x.provider, status)
	}
	if st, ok := store.As[store.AppAttestReadinessStore](x.s.store); ok {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		state, err := st.GetAppAttestReadiness(ctx, x.key.KeyID)
		cancel()
		if err == nil {
			evidence.RevocationKnown, evidence.Revoked = true, state.Revoked
			if r := state.Receipt; r != nil {
				var receipt appattest.Receipt
				if json.Unmarshal(r.Details, &receipt) == nil {
					evidence.ReceiptVerified = r.Outcome == "verified"
					evidence.RiskMetric = receipt.RiskMetric
					evidence.ReceiptExpiresAt, evidence.ReceiptRenewAt = r.ExpiresAt, r.NextAt
				}
			}
		}
	}
	// Signed status was already verified and durably committed. A readiness
	// lookup failure or revocation cannot erase that observation, but only a
	// known non-revoked credential may attach an identity alias.
	if x.inventory != nil && status != nil {
		x.inventory.mu.Lock()
		x.inventory.observation.VerifiedAppAttestKey = ""
		if evidence.RevocationKnown && !evidence.Revoked {
			x.inventory.observation.VerifiedAppAttestKey = x.key.KeyID
		}
		x.inventory.mu.Unlock()
		x.inventory.recordStatus(status)
		evidence.Binding.Machine = x.machineID()
		evidence.Expected.Machine = x.machineID()
	}
	verdict := appattest.EvaluateAuthorization(evidence, time.Now().UTC())
	x.updateServingAuthorization(status, evidence, verdict)
	x.policyFields = map[string]any{"policy_version": verdict.PolicyVersion, "reasons": verdict.Reasons,
		"valid_until": verdict.ValidUntil, "assertion_at": x.assertionAt, "credential_id": x.key.KeyID,
		"release_matched": evidence.BuildMatched, "build_qualified": evidence.BuildQualified,
		"apple_code_measurement_known": evidence.CodeMeasurementKnown, "apple_code_measurement_matched": evidence.CodeMeasurementMatched,
		"hardware_claims_bound":  evidence.HardwareKnown && evidence.HardwareMatched,
		"verification_key_bound": evidence.VerificationKeyKnown && evidence.VerificationKeyMatched,
		"receipt_verified":       evidence.ReceiptVerified, "risk_metric_available": evidence.RiskMetric != nil}
	x.observe("prospective_policy", verdict.Outcome, nil)
	x.policyFields = nil
}

// A failed exchange supersedes the prior prospective verdict immediately.
// The provider's legacy trust and connection are never changed here.
func (x *Session) observeFailedPolicy(reason string) {
	if a := x.s.authorizer; a != nil && confirmedAppAttestViolation(reason) {
		a.forget(x.provider)
		x.s.registry.MarkUntrusted(x.provider.ID)
		x.s.sendAppAttestAuthorizationStatus(x.provider)
	}
	outcome := "ineligible"
	if retryableAppAttestOutcome(reason) || reason == "unsupported" || reason == "not_configured" || reason == "" {
		outcome = "unknown"
	}
	keyID := ""
	if x.key != nil {
		keyID = x.key.KeyID
	}
	x.policyFields = map[string]any{"policy_version": appattest.AuthorizationPolicyVersion,
		"reasons": []string{"exchange_" + reason}, "valid_until": time.Time{}, "credential_id": keyID, "assertion_at": x.assertionAt}
	x.observe("prospective_policy", outcome, nil)
	x.policyFields = nil
}

// Infrastructure/key-recovery/format-compatibility failures are not a reason to
// ban an independently verified legacy path. Cryptographic substitution and
// observed unsafe Mac policy are hard evidence and fence both paths.
func confirmedAppAttestViolation(reason string) bool {
	switch reason {
	case "signature", "nonce", "mac_acl", "app_identity", "credential_key", "challenge_mismatch":
		return true
	}
	return false
}
