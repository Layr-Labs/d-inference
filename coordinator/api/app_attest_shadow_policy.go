package api

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/appattest"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (x *appAttestShadowSession) observeBuildPolicy(status *protocol.AppAttestStatus, metadata *appattest.Key) {
	binding := appattest.AuthorizationBinding{Account: x.account, Machine: x.machineID(), Credential: x.key.KeyID, Connection: x.id, Endpoint: x.publicKey, AppID: x.key.AppID, Environment: x.key.Environment}
	evidence := appattest.AuthorizationEvidence{Binding: binding, Expected: binding, ProtocolVersion: x.protocolVersion,
		CredentialVerified: true, EndpointBound: true, AssertionAt: x.assertionAt, ArchiveComplete: x.dropped.Load() == 0,
		RenewalConfigured: x.s.appAttestShadow.ReceiptKeyPath != "" && x.s.appAttestShadow.ReceiptKeyID != ""}
	evidence.Expected.AppID, evidence.Expected.Environment = x.s.appAttestShadow.AppID, x.s.appAttestShadow.Environment
	if metadata != nil {
		// Enrollment metadata cannot stand in for a current assertion's metadata.
		evidence.BundleVersion, evidence.ValidationCategory = metadata.BundleVersion, metadata.ValidationCategory
	}
	snapshot := x.s.releaseTrustPolicy.Load()
	evidence.CatalogKnown = snapshot != nil && len(snapshot.ByBinaryHash) > 0
	if status != nil {
		evidence.ReportedVersion = status.AppVersion
		evidence.BuildQualified = qualifiedAppAttestBuild(x.s.appAttestShadow.QualifiedBuildHashes, status.BinaryHash)
		if evidence.CatalogKnown {
			for _, candidate := range snapshot.ByBinaryHash[status.BinaryHash] {
				if candidate.Platform == "macos-arm64" && candidate.Version == status.AppVersion {
					evidence.BuildMatched = true
					break
				}
			}
		}
	}
	if st, ok := store.As[store.AppAttestReadinessStore](x.s.store); ok {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		state, err := st.GetAppAttestReadiness(ctx, x.key.KeyID)
		cancel()
		if err == nil {
			evidence.RevocationKnown, evidence.Revoked = true, state.Revoked
			if !state.Revoked && x.inventory != nil && status != nil {
				x.inventory.mu.Lock()
				x.inventory.observation.VerifiedAppAttestKey = x.key.KeyID
				x.inventory.mu.Unlock()
				x.inventory.recordStatus(status)
				evidence.Binding.Machine = x.machineID()
				evidence.Expected.Machine = x.machineID()
			}
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
	verdict := appattest.EvaluateAuthorization(evidence, time.Now().UTC())
	x.policyFields = map[string]any{"policy_version": verdict.PolicyVersion, "reasons": verdict.Reasons,
		"valid_until": verdict.ValidUntil, "assertion_at": x.assertionAt, "credential_id": x.key.KeyID,
		"release_matched": evidence.BuildMatched, "build_qualified": evidence.BuildQualified,
		"receipt_verified": evidence.ReceiptVerified, "risk_metric_available": evidence.RiskMetric != nil}
	x.observe("prospective_policy", verdict.Outcome, nil)
	x.policyFields = nil
}

func qualifiedAppAttestBuild(configured, hash string) bool {
	if len(hash) != 64 {
		return false
	}
	if _, err := hex.DecodeString(hash); err != nil {
		return false
	}
	for _, candidate := range strings.Split(configured, ",") {
		if strings.TrimSpace(candidate) == hash {
			return true
		}
	}
	return false
}

// A failed exchange supersedes the prior prospective verdict immediately.
// The provider's legacy trust and connection are never changed here.
func (x *appAttestShadowSession) observeFailedPolicy(reason string) {
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
