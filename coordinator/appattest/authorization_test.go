package appattest

import (
	"slices"
	"testing"
	"time"
)

func TestAuthorizationRequiresEveryCurrentConnectionCondition(t *testing.T) {
	now := time.Now().UTC()
	category := uint32(6)
	metric := uint64(2)
	binding := AuthorizationBinding{"account", "machine", "credential", "connection", "endpoint", "TEAM.app", "production"}
	good := AuthorizationEvidence{Binding: binding, Expected: binding, ProtocolVersion: 3, CredentialVerified: true, EndpointBound: true, AssertionAt: now,
		CodeMeasurementKnown: true, CodeMeasurementMatched: true,
		ValidationCategory: &category, BundleVersion: "0.9.4", ReportedVersion: "0.9.4", CatalogKnown: true, BuildMatched: true, BuildQualified: true,
		RevocationKnown: true, RenewalConfigured: true, ArchiveComplete: true, HardwareKnown: true, HardwareMatched: true, VerificationKeyKnown: true, VerificationKeyMatched: true, ReceiptVerified: true, ReceiptExpiresAt: now.Add(time.Hour), ReceiptRenewAt: now.Add(time.Hour), RiskMetric: &metric}
	if got := EvaluateAuthorization(good, now); got.Outcome != "eligible" || !got.ValidUntil.Equal(now.Add(AssertionFreshness)) {
		t.Fatalf("positive control: %+v", got)
	}
	cases := []struct {
		name, reason, outcome string
		change                func(*AuthorizationEvidence)
	}{
		{"wrong environment", "connection_binding_mismatch", "ineligible", func(e *AuthorizationEvidence) { e.Expected.Environment = "development" }},
		{"wrong app", "connection_binding_mismatch", "ineligible", func(e *AuthorizationEvidence) { e.Expected.AppID = "OTHER.app" }},
		{"substituted verification key", "verification_key_mismatch", "ineligible", func(e *AuthorizationEvidence) { e.VerificationKeyMatched = false }},
		{"unsigned hardware", "hardware_claims_unbound", "unknown", func(e *AuthorizationEvidence) { e.HardwareKnown = false }},
		{"altered hardware", "hardware_claims_mismatch", "ineligible", func(e *AuthorizationEvidence) { e.HardwareMatched = false }},
		{"archive gap", "evidence_archive_gap", "unknown", func(e *AuthorizationEvidence) { e.ArchiveComplete = false }},
		{"reconnect", "connection_binding_mismatch", "ineligible", func(e *AuthorizationEvidence) { e.Expected.Connection = "new" }},
		{"endpoint replacement", "connection_binding_mismatch", "ineligible", func(e *AuthorizationEvidence) { e.Expected.Endpoint = "other" }},
		{"account transfer", "connection_binding_mismatch", "ineligible", func(e *AuthorizationEvidence) { e.Expected.Account = "other" }},
		{"revoked", "credential_revoked", "ineligible", func(e *AuthorizationEvidence) { e.Revoked = true }},
		{"revocation unavailable", "revocation_unavailable", "unknown", func(e *AuthorizationEvidence) { e.RevocationKnown = false }},
		{"stale assertion", "assertion_stale_or_missing", "unknown", func(e *AuthorizationEvidence) { e.AssertionAt = now.Add(-AssertionFreshness) }},
		{"future assertion", "assertion_stale_or_missing", "unknown", func(e *AuthorizationEvidence) { e.AssertionAt = now.Add(time.Second) }},
		{"missing Apple code measurement", "apple_code_measurement_unavailable", "unknown", func(e *AuthorizationEvidence) { e.CodeMeasurementKnown = false }},
		{"ambiguous Apple code prefix", "apple_code_measurement_ambiguous", "unknown", func(e *AuthorizationEvidence) { e.CodeMeasurementAmbiguous = true; e.CodeMeasurementMatched = false }},
		{"wrong Apple code measurement", "apple_code_measurement_mismatch", "ineligible", func(e *AuthorizationEvidence) { e.CodeMeasurementMatched = false }},
		{"wrong build", "bundle_version_mismatch", "ineligible", func(e *AuthorizationEvidence) { e.BundleVersion = "0.9.3" }},
		{"catalog removal", "release_not_approved", "ineligible", func(e *AuthorizationEvidence) { e.BuildMatched = false }},
		{"catalog outage", "release_catalog_unavailable", "unknown", func(e *AuthorizationEvidence) { e.CatalogKnown = false }},
		{"unqualified measurement", "build_qualification_missing", "unknown", func(e *AuthorizationEvidence) { e.BuildQualified = false }},
		{"stale initial receipt", "receipt_unverified_or_expired", "unknown", func(e *AuthorizationEvidence) { e.ReceiptVerified = false }},
		{"no fraud response", "risk_metric_missing", "unknown", func(e *AuthorizationEvidence) { e.RiskMetric = nil }},
		{"renewal overdue", "risk_metric_renewal_overdue", "unknown", func(e *AuthorizationEvidence) { e.ReceiptRenewAt = now.Add(-24 * time.Hour) }},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			e := good
			c.change(&e)
			v := EvaluateAuthorization(e, now)
			if v.Outcome != c.outcome || !slices.Contains(v.Reasons, c.reason) || !v.ValidUntil.IsZero() {
				t.Fatalf("%+v", v)
			}
		})
	}
	e := good
	e.BundleVersion = "" // macOS CDhash opt-in omits bundle version.
	if EvaluateAuthorization(e, now).Outcome != "eligible" {
		t.Fatal("qualified exact Apple code measurement required an absent version extension")
	}
	e.CodeMeasurementKnown = false
	if EvaluateAuthorization(e, now).Outcome != "unknown" {
		t.Fatal("reported version/hash replaced missing Apple code measurement")
	}
	e = good
	e.Revoked = true
	e.BuildQualified = false
	if EvaluateAuthorization(e, now).Outcome != "ineligible" {
		t.Fatal("unknown evidence masked a revocation")
	}
}
