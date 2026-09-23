package service

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/appattest"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestTruncatedAppleCodeMeasurementNeedsUniqueDurableQualifiedRelease(t *testing.T) {
	s, p, record, readiness := newAuthorizationFixture(t)
	// An environment-only bootstrap never authorizes a 20-byte measurement.
	s.config.QualifiedBuildHashes, s.config.QualifiedCodeHashes = record.status.BinaryHash, record.status.BinaryHash+":"+record.evidence.CodeDirectoryHash
	full := record.evidence.CodeDirectoryHash
	prefix := full[:40]
	record.evidence.CodeDirectoryHash = prefix
	record.evidence.CodeMeasurementTruncated = true
	if s.authorizer.apply(p, record, readiness, time.Now()) {
		t.Fatal("environment-only mapping accepted truncated Apple measurement")
	}

	q := durablePrefixTestBuild(record.status, full)
	st, _ := store.As[store.AppAttestBuildStore](s.store)
	if _, err := st.QualifyAppAttestBuild(context.Background(), q); err != nil {
		t.Fatal(err)
	}
	if err := s.RefreshBuildQualifications(context.Background()); err != nil {
		t.Fatal(err)
	}
	if !s.authorizer.apply(p, record, readiness, time.Now()) {
		t.Fatal("unique approved durable full hash failed to bind Apple prefix")
	}
	if _, ok := s.registry.ProviderServingAuthorization(p); !ok {
		t.Fatal("verified truncated proof did not grant after durable binding")
	}

	// Every refresh rechecks the authenticated prefix against current durable
	// qualifications. A self-reported binary cannot choose between collisions.
	record.evidence.CodeDirectoryHash = strings.Repeat("e", 40)
	if s.authorizer.apply(p, record, readiness, time.Now()) {
		t.Fatal("wrong Apple prefix accepted")
	}
	record.evidence.CodeDirectoryHash = prefix
	record.evidence.CodeMeasurementTruncated = false
	if s.authorizer.apply(p, record, readiness, time.Now()) {
		t.Fatal("untyped 20-byte value accepted")
	}
	record.evidence.CodeDirectoryHash = full
	if !s.authorizer.apply(p, record, readiness, time.Now()) {
		t.Fatal("existing full 32-byte exact match regressed")
	}
	record.evidence.CodeDirectoryHash = prefix
	record.evidence.CodeMeasurementTruncated = true

	other := q
	other.Release.Version = "0.9.5"
	other.Release.BinaryHash = strings.Repeat("d", 64)
	other.CodeDirectoryHash = prefix + strings.Repeat("e", 24)
	if _, err := st.QualifyAppAttestBuild(context.Background(), other); err != nil {
		t.Fatal(err)
	}
	if err := s.RefreshBuildQualifications(context.Background()); err != nil {
		t.Fatal(err)
	}
	if s.authorizer.apply(p, record, readiness, time.Now()) {
		t.Fatal("second qualified full hash with same prefix accepted")
	}
	e := record.evidence
	s.applyBuildQualification(&e, &record.status, s.currentReleasePolicySnapshot())
	if !e.CodeMeasurementAmbiguous || e.CodeMeasurementMatched {
		t.Fatal("colliding full hashes were not classified as ambiguous")
	}
	verdict := appattest.EvaluateAuthorization(e, time.Now())
	if verdict.Outcome != "unknown" || confirmedAppAttestPolicyViolation(verdict) {
		t.Fatalf("ambiguous prefix became a hard cryptographic denial: %+v", verdict)
	}
	makeLegacyAuthorized(p)
	p.RequireVerifiedMachineIdentity()
	x := sessionForAuthorization(s, p, record)
	x.updateServingAuthorization(&record.status, e, verdict)
	if x.authorizationResult != "policy_unknown" || !s.registry.ProviderLegacyServingAuthorized(p) || s.registry.ProviderServingDenialReason(p) != "" {
		t.Fatal("ambiguous prefix fenced independent legacy serving")
	}
	if _, err := st.RevokeAppAttestBuild(context.Background(), other.Release.BinaryHash, "operator", "collision test"); err != nil {
		t.Fatal(err)
	}
	if err := s.RefreshBuildQualifications(context.Background()); err != nil {
		t.Fatal(err)
	}
	if s.authorizer.apply(p, record, readiness, time.Now()) {
		t.Fatal("revoked colliding full hash disappeared from ambiguity check")
	}
	otherSelection := q
	otherSelection.Release.BinaryHash = strings.Repeat("f", 64)
	otherSelection.CodeDirectoryHash = strings.Repeat("e", 64)
	builds := map[string]store.AppAttestBuildQualification{
		q.Release.BinaryHash:              q,
		other.Release.BinaryHash:          other,
		otherSelection.Release.BinaryHash: otherSelection,
	}
	if matched, ambiguous := uniqueDurableCodePrefix(builds, otherSelection.Release.BinaryHash, otherSelection.CodeDirectoryHash, prefix); matched || !ambiguous {
		t.Fatal("self-reported selection suppressed ambiguity among other durable hashes")
	}
}

func TestTruncatedAppleMeasurementCatalogOutageKeepsIndependentLegacyServing(t *testing.T) {
	for _, mode := range []string{"outage", "inactive"} {
		t.Run(mode, func(t *testing.T) {
			s, p, record, readiness := newAuthorizationFixture(t)
			makeLegacyAuthorized(p)
			p.RequireVerifiedMachineIdentity()
			if !s.registry.ProviderLegacyServingAuthorized(p) {
				t.Fatal("legacy authorization fixture")
			}
			full := record.evidence.CodeDirectoryHash
			record.evidence.CodeDirectoryHash = full[:40]
			record.evidence.CodeMeasurementTruncated = true
			st, _ := store.As[store.AppAttestBuildStore](s.store)
			if _, err := st.QualifyAppAttestBuild(context.Background(), durablePrefixTestBuild(record.status, full)); err != nil {
				t.Fatal(err)
			}
			if err := s.RefreshBuildQualifications(context.Background()); err != nil {
				t.Fatal(err)
			}
			catalog := &ReleasePolicy{}
			if mode == "inactive" {
				catalog = &ReleasePolicy{Known: true, Approves: func(*registry.Provider, *protocol.AppAttestStatus) bool { return false }, ContainsQualifiedRelease: func(store.Release) bool { return false }}
			}
			e := record.evidence
			e.CatalogKnown, e.BuildMatched = catalog.Known, false
			applyAppAttestReadiness(&e, readiness)
			s.applyBuildQualification(&e, &record.status, catalog)
			if !e.CodeMeasurementKnown || !e.CodeMeasurementMatched || e.BuildQualified {
				t.Fatalf("catalog availability changed cryptographic prefix match: %+v", e)
			}
			verdict := appattest.EvaluateAuthorization(e, time.Now())
			if verdict.Outcome == "eligible" || confirmedAppAttestPolicyViolation(verdict) {
				t.Fatalf("catalog failure became eligible or hard denial: %+v", verdict)
			}
			x := sessionForAuthorization(s, p, record)
			x.updateServingAuthorization(&record.status, e, verdict)
			if mode == "outage" && x.authorizationResult != "policy_unknown" {
				t.Fatalf("catalog outage took unexpected authorization path: %s", x.authorizationResult)
			}
			if p.GetStatus() == registry.StatusUntrusted || s.registry.ProviderServingDenialReason(p) != "" || !s.registry.ProviderLegacyServingAuthorized(p) {
				t.Fatal("catalog failure fenced independent legacy serving")
			}
			if _, ok := s.registry.ProviderServingAuthorization(p); ok {
				t.Fatal("catalog failure granted App Attest serving")
			}
		})
	}
}

func TestTruncatedAppleMeasurementCannotUseUnapprovedDurableRow(t *testing.T) {
	s, _, record, _ := newAuthorizationFixture(t)
	full := record.evidence.CodeDirectoryHash
	e := record.evidence
	e.CodeDirectoryHash = full[:40]
	e.CodeMeasurementTruncated = true
	q := durablePrefixTestBuild(record.status, full)
	// A malformed database snapshot with an identity but no operator approval
	// does not turn a signed prefix into a trusted full build measurement.
	s.qualificationMu.Lock()
	s.publishBuildQualifications(map[string]store.AppAttestBuildQualification{q.Release.BinaryHash: q}, time.Now())
	s.qualificationMu.Unlock()
	s.applyBuildQualification(&e, &record.status, s.currentReleasePolicySnapshot())
	if e.CodeMeasurementKnown || e.CodeMeasurementMatched || e.BuildQualified {
		t.Fatalf("unapproved durable row accepted: %+v", e)
	}
	if got := appattest.EvaluateAuthorization(e, time.Now()); got.Outcome != "unknown" || confirmedAppAttestPolicyViolation(got) {
		t.Fatalf("unapproved durable row caused hard denial: %+v", got)
	}
}

func TestTruncatedAppleCodeMeasurementFailsClosedOnBuildReadiness(t *testing.T) {
	for _, mode := range []string{"revoked", "catalog_unavailable", "catalog_inactive", "expired_snapshot", "unqualified", "wrong_version"} {
		t.Run(mode, func(t *testing.T) {
			s, p, record, readiness := newAuthorizationFixture(t)
			full := record.evidence.CodeDirectoryHash
			record.evidence.CodeDirectoryHash = full[:40]
			record.evidence.CodeMeasurementTruncated = true
			q := durablePrefixTestBuild(record.status, full)
			st, _ := store.As[store.AppAttestBuildStore](s.store)
			if mode != "unqualified" {
				if _, err := st.QualifyAppAttestBuild(context.Background(), q); err != nil {
					t.Fatal(err)
				}
				if err := s.RefreshBuildQualifications(context.Background()); err != nil {
					t.Fatal(err)
				}
			}
			switch mode {
			case "revoked":
				if _, err := st.RevokeAppAttestBuild(context.Background(), q.Release.BinaryHash, "operator", "withdraw build"); err != nil {
					t.Fatal(err)
				}
				s.FenceBuild(q.Release.BinaryHash)
			case "catalog_unavailable":
				s.currentReleasePolicy = func() ReleasePolicy { return ReleasePolicy{} }
			case "catalog_inactive":
				s.currentReleasePolicy = func() ReleasePolicy {
					return ReleasePolicy{Known: true, Approves: func(*registry.Provider, *protocol.AppAttestStatus) bool { return true }, ContainsQualifiedRelease: func(store.Release) bool { return false }}
				}
			case "expired_snapshot":
				s.qualificationMu.Lock()
				s.publishBuildQualifications(s.qualifications.Load().builds, time.Now().Add(-BuildQualificationFreshness-time.Second))
				s.qualificationMu.Unlock()
			case "wrong_version":
				record.status.AppVersion = "0.9.6"
			}
			if s.authorizer.apply(p, record, readiness, time.Now()) {
				t.Fatal("unready build accepted truncated Apple measurement")
			}
		})
	}
}

func durablePrefixTestBuild(status protocol.AppAttestStatus, full string) store.AppAttestBuildQualification {
	return store.AppAttestBuildQualification{AppAttestBuildIdentity: store.AppAttestBuildIdentity{
		Release: store.Release{Version: status.AppVersion, Platform: "macos-arm64", Backend: "mlx-swift", BinaryHash: status.BinaryHash,
			BundleHash: strings.Repeat("b", 64), MetallibHash: strings.Repeat("d", 64), URL: "https://example.com/bundle"},
		CodeDirectoryHash: full, SourceCommit: strings.Repeat("f", 40), CIRunID: "123"},
		Evidence: "physical transition tests", ApprovedBy: "operator"}
}
