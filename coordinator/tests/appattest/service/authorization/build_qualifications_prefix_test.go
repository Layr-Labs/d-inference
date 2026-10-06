package authorization_test

import (
	"context"
	"strings"
	"testing"
	"testing/synctest"
	"time"

	"github.com/eigeninference/d-inference/coordinator/appattest"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/authorization"
	eligibility "github.com/eigeninference/d-inference/coordinator/internal/appattest/eligibility"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/qualification"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestTruncatedAppleCodeMeasurementNeedsUniqueDurableQualifiedRelease(t *testing.T) {
	f, p, _, readiness := newAuthorizationFixture(t, false)
	// An environment-only bootstrap never authorizes a 20-byte measurement.
	f.bootstrap.BuildHashes, f.bootstrap.CodeHashes = f.status.BinaryHash, f.status.BinaryHash+":"+f.evidence.CodeDirectoryHash
	full := f.evidence.CodeDirectoryHash
	prefix := full[:40]
	f.evidence.CodeDirectoryHash = prefix
	f.evidence.CodeMeasurementTruncated = true
	if f.controller.Apply(p, authorization.NewRecord(f.evidence, f.status, "proof", nil, 0), readiness, time.Now()) {
		t.Fatal("environment-only mapping accepted truncated Apple measurement")
	}

	q := durablePrefixTestBuild(f.status, full)
	st, _ := store.As[store.AppAttestBuildStore](f.store)
	if _, err := st.QualifyAppAttestBuild(context.Background(), q); err != nil {
		t.Fatal(err)
	}
	if err := f.cache.Refresh(context.Background(), f.store, f.registry.SetAppAttestQualificationGeneration); err != nil {
		t.Fatal(err)
	}
	if !f.controller.Apply(p, authorization.NewRecord(f.evidence, f.status, "proof", nil, 0), readiness, time.Now()) {
		t.Fatal("unique approved durable full hash failed to bind Apple prefix")
	}
	if _, ok := f.registry.ProviderServingAuthorization(p); !ok {
		t.Fatal("verified truncated proof did not grant after durable binding")
	}

	// Every refresh rechecks the authenticated prefix against current durable
	// qualifications. A self-reported binary cannot choose between collisions.
	f.evidence.CodeDirectoryHash = strings.Repeat("e", 40)
	if f.controller.Apply(p, authorization.NewRecord(f.evidence, f.status, "proof", nil, 0), readiness, time.Now()) {
		t.Fatal("wrong Apple prefix accepted")
	}
	f.evidence.CodeDirectoryHash = prefix
	f.evidence.CodeMeasurementTruncated = false
	if f.controller.Apply(p, authorization.NewRecord(f.evidence, f.status, "proof", nil, 0), readiness, time.Now()) {
		t.Fatal("untyped 20-byte value accepted")
	}
	f.evidence.CodeDirectoryHash = full
	if !f.controller.Apply(p, authorization.NewRecord(f.evidence, f.status, "proof", nil, 0), readiness, time.Now()) {
		t.Fatal("existing full 32-byte exact match regressed")
	}
	f.evidence.CodeDirectoryHash = prefix
	f.evidence.CodeMeasurementTruncated = true

	other := q
	other.Release.Version = "0.9.5"
	other.Release.BinaryHash = strings.Repeat("d", 64)
	other.CodeDirectoryHash = prefix + strings.Repeat("e", 24)
	if _, err := st.QualifyAppAttestBuild(context.Background(), other); err != nil {
		t.Fatal(err)
	}
	if err := f.cache.Refresh(context.Background(), f.store, f.registry.SetAppAttestQualificationGeneration); err != nil {
		t.Fatal(err)
	}
	if f.controller.Apply(p, authorization.NewRecord(f.evidence, f.status, "proof", nil, 0), readiness, time.Now()) {
		t.Fatal("second qualified full hash with same prefix accepted")
	}
	e := f.evidence
	prefixQualification(f, &e, f.policy())
	if !e.CodeMeasurementAmbiguous || e.CodeMeasurementMatched {
		t.Fatal("colliding full hashes were not classified as ambiguous")
	}
	verdict := appattest.EvaluateAuthorization(e, time.Now())
	if verdict.Outcome != "unknown" || eligibility.PolicyViolation(verdict) {
		t.Fatalf("ambiguous prefix became a hard cryptographic denial: %+v", verdict)
	}
	makeLegacyAuthorized(p)
	p.RequireVerifiedMachineIdentity()
	x := authorization.NewIdentity(authorization.IdentityDependencies{Controller: f.controller, Registry: f.registry}, p, "account")
	result := x.Update(authorization.NewVerifiedProof(e, &f.status, "proof", nil, 0), verdict)
	if result != "policy_unknown" || !f.registry.ProviderLegacyServingAuthorized(p) || f.registry.ProviderServingDenialReason(p) != "" {
		t.Fatal("ambiguous prefix fenced independent legacy serving")
	}
	if _, err := st.RevokeAppAttestBuild(context.Background(), other.Release.BinaryHash, "operator", "collision test"); err != nil {
		t.Fatal(err)
	}
	if err := f.cache.Refresh(context.Background(), f.store, f.registry.SetAppAttestQualificationGeneration); err != nil {
		t.Fatal(err)
	}
	if f.controller.Apply(p, authorization.NewRecord(f.evidence, f.status, "proof", nil, 0), readiness, time.Now()) {
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
	if matched, ambiguous := qualification.UniqueCodePrefix(builds, otherSelection.Release.BinaryHash, otherSelection.CodeDirectoryHash, prefix); matched || !ambiguous {
		t.Fatal("self-reported selection suppressed ambiguity among other durable hashes")
	}
}

func TestTruncatedAppleMeasurementCatalogOutageKeepsIndependentLegacyServing(t *testing.T) {
	for _, mode := range []string{"outage", "inactive"} {
		t.Run(mode, func(t *testing.T) {
			f, p, _, readiness := newAuthorizationFixture(t, false)
			makeLegacyAuthorized(p)
			p.RequireVerifiedMachineIdentity()
			if !f.registry.ProviderLegacyServingAuthorized(p) {
				t.Fatal("legacy authorization fixture")
			}
			full := f.evidence.CodeDirectoryHash
			f.evidence.CodeDirectoryHash = full[:40]
			f.evidence.CodeMeasurementTruncated = true
			st, _ := store.As[store.AppAttestBuildStore](f.store)
			if _, err := st.QualifyAppAttestBuild(context.Background(), durablePrefixTestBuild(f.status, full)); err != nil {
				t.Fatal(err)
			}
			if err := f.cache.Refresh(context.Background(), f.store, f.registry.SetAppAttestQualificationGeneration); err != nil {
				t.Fatal(err)
			}
			catalog := &authorization.ReleasePolicy{}
			if mode == "inactive" {
				catalog = &authorization.ReleasePolicy{Known: true, Approves: func(*registry.Provider, *protocol.AppAttestStatus) bool { return false }, ContainsQualifiedRelease: func(store.Release) bool { return false }}
			}
			e := f.evidence
			e.CatalogKnown, e.BuildMatched = catalog.Known, false
			eligibility.ApplyReadiness(&e, readiness)
			prefixQualification(f, &e, catalog)
			if !e.CodeMeasurementKnown || !e.CodeMeasurementMatched || e.BuildQualified {
				t.Fatalf("catalog availability changed cryptographic prefix match: %+v", e)
			}
			verdict := appattest.EvaluateAuthorization(e, time.Now())
			if verdict.Outcome == "eligible" || eligibility.PolicyViolation(verdict) {
				t.Fatalf("catalog failure became eligible or hard denial: %+v", verdict)
			}
			x := authorization.NewIdentity(authorization.IdentityDependencies{Controller: f.controller, Registry: f.registry}, p, "account")
			result := x.Update(authorization.NewVerifiedProof(e, &f.status, "proof", nil, 0), verdict)
			if mode == "outage" && result != "policy_unknown" {
				t.Fatalf("catalog outage took unexpected authorization path: %s", result)
			}
			if p.GetStatus() == registry.StatusUntrusted || f.registry.ProviderServingDenialReason(p) != "" || !f.registry.ProviderLegacyServingAuthorized(p) {
				t.Fatal("catalog failure fenced independent legacy serving")
			}
			if _, ok := f.registry.ProviderServingAuthorization(p); ok {
				t.Fatal("catalog failure granted App Attest serving")
			}
		})
	}
}

func TestTruncatedAppleCodeMeasurementFailsClosedOnBuildReadiness(t *testing.T) {
	for _, mode := range []string{"revoked", "catalog_unavailable", "catalog_inactive", "expired_snapshot", "unqualified", "wrong_version"} {
		t.Run(mode, func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				f, p, _, readiness := newAuthorizationFixture(t, false)
				full := f.evidence.CodeDirectoryHash
				f.evidence.CodeDirectoryHash = full[:40]
				f.evidence.CodeMeasurementTruncated = true
				q := durablePrefixTestBuild(f.status, full)
				st, _ := store.As[store.AppAttestBuildStore](f.store)
				if mode != "unqualified" {
					if _, err := st.QualifyAppAttestBuild(context.Background(), q); err != nil {
						t.Fatal(err)
					}
					if err := f.cache.Refresh(context.Background(), f.store, f.registry.SetAppAttestQualificationGeneration); err != nil {
						t.Fatal(err)
					}
				}
				switch mode {
				case "revoked":
					if _, err := st.RevokeAppAttestBuild(context.Background(), q.Release.BinaryHash, "operator", "withdraw build"); err != nil {
						t.Fatal(err)
					}
					f.cache.FenceBuild(q.Release.BinaryHash, f.registry.SetAppAttestQualificationGeneration)
				case "catalog_unavailable":
					f.policy = func() *authorization.ReleasePolicy { return &authorization.ReleasePolicy{} }
				case "catalog_inactive":
					f.policy = func() *authorization.ReleasePolicy {
						return &authorization.ReleasePolicy{Known: true, Approves: func(*registry.Provider, *protocol.AppAttestStatus) bool { return true }, ContainsQualifiedRelease: func(store.Release) bool { return false }}
					}
				case "expired_snapshot":
					time.Sleep(qualification.Freshness + time.Second)
				case "wrong_version":
					f.status.AppVersion = "0.9.6"
				}
				if f.controller.Apply(p, authorization.NewRecord(f.evidence, f.status, "proof", nil, 0), readiness, time.Now()) {
					t.Fatal("unready build accepted truncated Apple measurement")
				}
			})
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

func prefixQualification(f *authorizationFixture, e *appattest.AuthorizationEvidence, policy *authorization.ReleasePolicy) {
	var catalog *qualification.Catalog
	if policy != nil {
		catalog = &qualification.Catalog{Known: policy.Known, ContainsQualifiedRelease: policy.ContainsQualifiedRelease}
	}
	f.cache.Apply(e, &f.status, catalog, f.bootstrap)
}
func makeLegacyAuthorized(p *registry.Provider) {
	p.SetAttested(true, registry.TrustHardware)
	p.CodeAttested, p.ChallengeVerifiedSIP = true, true
	p.SetLastChallengeVerified(time.Now())
}
