package appattest

import "time"

const AuthorizationPolicyVersion = "mac-app-attest-v1"
const AssertionFreshness = 15 * time.Minute

// AuthorizationBinding belongs to one live connection, never just a machine.
// Consumers must evaluate again with current revocation/catalog state before
// dispatch; persisting an eligible verdict does not grant a reusable lease.
type AuthorizationBinding struct {
	Account, Machine, Credential, Connection, Endpoint, AppID, Environment string
}

type AuthorizationEvidence struct {
	VerificationKeyKnown, VerificationKeyMatched bool
	HardwareKnown, HardwareMatched               bool
	ArchiveComplete                              bool
	RenewalConfigured                            bool
	Binding, Expected                            AuthorizationBinding
	ProtocolVersion                              int
	CredentialVerified, EndpointBound            bool
	AssertionAt                                  time.Time
	ValidationCategory                           *uint32
	BundleVersion, ReportedVersion               string
	CatalogKnown, BuildMatched, BuildQualified   bool
	RevocationKnown, Revoked                     bool
	ReceiptVerified                              bool
	ReceiptExpiresAt, ReceiptRenewAt             time.Time
	RiskMetric                                   *uint64
}

type AuthorizationVerdict struct {
	PolicyVersion string    `json:"policy_version"`
	Outcome       string    `json:"outcome"`
	Reasons       []string  `json:"reasons"`
	ValidUntil    time.Time `json:"valid_until"`
}

// EvaluateAuthorization is the prospective replacement policy. It contains no
// MDM/APNs inputs or registry mutations. Missing evidence remains unknown, and
// negative evidence is ineligible even when other checks are still unknown.
func EvaluateAuthorization(e AuthorizationEvidence, now time.Time) AuthorizationVerdict {
	v := AuthorizationVerdict{PolicyVersion: AuthorizationPolicyVersion, Outcome: "eligible", Reasons: []string{}}
	unknown := func(reason string) {
		v.Reasons = append(v.Reasons, reason)
		if v.Outcome == "eligible" {
			v.Outcome = "unknown"
		}
	}
	deny := func(reason string) { v.Reasons = append(v.Reasons, reason); v.Outcome = "ineligible" }
	if e.Binding != e.Expected {
		deny("connection_binding_mismatch")
	}
	if e.Binding.Account == "" || e.Binding.Machine == "" || e.Binding.Credential == "" || e.Binding.Connection == "" || e.Binding.Endpoint == "" || e.Binding.AppID == "" || e.Binding.Environment == "" {
		unknown("identity_missing")
	}
	if e.ProtocolVersion != 2 && e.ProtocolVersion != 3 {
		unknown("signed_status_unavailable")
	}
	if !e.ArchiveComplete {
		unknown("evidence_archive_gap")
	}
	if e.ProtocolVersion != 3 || !e.HardwareKnown {
		unknown("hardware_claims_unbound")
	} else if !e.HardwareMatched {
		deny("hardware_claims_mismatch")
	}
	if e.ProtocolVersion != 3 || !e.VerificationKeyKnown {
		unknown("verification_key_unbound")
	} else if !e.VerificationKeyMatched {
		deny("verification_key_mismatch")
	}
	if !e.CredentialVerified {
		unknown("credential_unverified")
	}
	if !e.EndpointBound {
		unknown("endpoint_custody_unverified")
	}
	if e.AssertionAt.IsZero() || e.AssertionAt.After(now) || !e.AssertionAt.Add(AssertionFreshness).After(now) {
		unknown("assertion_stale_or_missing")
	}
	if e.ValidationCategory == nil {
		unknown("launch_category_missing")
	} else if *e.ValidationCategory != 6 {
		deny("launch_category_not_developer_id")
	}
	if e.BundleVersion == "" {
		unknown("apple_bundle_version_missing")
	} else if e.BundleVersion != e.ReportedVersion {
		deny("bundle_version_mismatch")
	}
	if !e.CatalogKnown {
		unknown("release_catalog_unavailable")
	} else if !e.BuildMatched {
		deny("release_not_approved")
	}
	// A hash reported by the app is not an Apple-certified measurement. Only
	// immutable builds with completed Mac security-transition qualification
	// belong in the separately approved qualification set.
	if !e.BuildQualified {
		unknown("build_qualification_missing")
	}
	if !e.RevocationKnown {
		unknown("revocation_unavailable")
	} else if e.Revoked {
		deny("credential_revoked")
	}
	if !e.ReceiptVerified || !e.ReceiptExpiresAt.After(now) {
		unknown("receipt_unverified_or_expired")
	}
	if !e.RenewalConfigured {
		unknown("receipt_renewal_unconfigured")
	}
	if e.RiskMetric == nil {
		unknown("risk_metric_missing")
	}
	// Do not invent a safe fraud-count threshold. Freshness is a readiness
	// requirement; suspicious key-count enforcement is a separately qualified
	// abuse policy, and is not a claim of physical-device uniqueness.
	if e.ReceiptRenewAt.IsZero() || !e.ReceiptRenewAt.Add(24*time.Hour).After(now) {
		unknown("risk_metric_renewal_overdue")
	}
	if v.Outcome == "eligible" {
		v.ValidUntil = e.AssertionAt.Add(AssertionFreshness)
		for _, deadline := range []time.Time{e.ReceiptExpiresAt, e.ReceiptRenewAt.Add(24 * time.Hour)} {
			if deadline.Before(v.ValidUntil) {
				v.ValidUntil = deadline
			}
		}
	}
	return v
}
