package service_test

import (
	"context"
	"encoding/base64"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/appattest"
	eligibility "github.com/eigeninference/d-inference/coordinator/internal/appattest/eligibility"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/qualification"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
	memorystore "github.com/eigeninference/d-inference/coordinator/store/memory"
)

type unapprovedBuildStore struct {
	*memorystore.MemoryStore
	rows []store.AppAttestBuildQualification
}

func (s *unapprovedBuildStore) ListAppAttestBuildQualifications(context.Context) ([]store.AppAttestBuildQualification, error) {
	return s.rows, nil
}

func TestTruncatedAppleMeasurementCannotUseUnapprovedDurableRow(t *testing.T) {
	var cache qualification.Cache
	e, status, q := qualificationEvidence()
	full := e.CodeDirectoryHash
	e.CodeDirectoryHash = full[:40]
	e.CodeMeasurementTruncated = true
	// A malformed database snapshot with an identity but no operator approval
	// does not turn a signed prefix into a trusted full build measurement.
	st := &unapprovedBuildStore{MemoryStore: memorystore.NewMemory(store.Config{}), rows: []store.AppAttestBuildQualification{q}}
	if err := cache.Refresh(context.Background(), st, nil); err != nil {
		t.Fatal(err)
	}
	cache.Apply(&e, &status, &qualification.Catalog{Known: true, ContainsQualifiedRelease: func(store.Release) bool { return true }}, qualification.Bootstrap{BuildHashes: status.BinaryHash, CodeHashes: status.BinaryHash + ":" + full})
	if e.CodeMeasurementKnown || e.CodeMeasurementMatched || e.BuildQualified {
		t.Fatalf("unapproved durable row accepted: %+v", e)
	}
	if got := appattest.EvaluateAuthorization(e, time.Now()); got.Outcome != "unknown" || eligibility.PolicyViolation(got) {
		t.Fatalf("unapproved durable row caused hard denial: %+v", got)
	}
}

func qualificationEvidence() (appattest.AuthorizationEvidence, protocol.AppAttestStatus, store.AppAttestBuildQualification) {
	category := uint32(6)
	binding := appattest.AuthorizationBinding{Account: "account", Machine: "machine", Credential: "credential", Connection: "proof", Endpoint: base64.StdEncoding.EncodeToString(make([]byte, 32)), AppID: "TEST.app", Environment: "production"}
	e := appattest.AuthorizationEvidence{CodeDirectoryHash: strings.Repeat("c", 64), Binding: binding, Expected: binding, ProtocolVersion: 3, CredentialVerified: true, EndpointBound: true, AssertionAt: time.Now().UTC(),
		ValidationCategory: &category, ReportedVersion: "0.9.4", CatalogKnown: true, BuildMatched: true, BuildQualified: true,
		CodeMeasurementKnown: true, CodeMeasurementMatched: true, VerificationKeyKnown: true, VerificationKeyMatched: true,
		HardwareKnown: true, HardwareMatched: true, ArchiveComplete: true, RenewalConfigured: true}
	status := protocol.AppAttestStatus{BinaryHash: strings.Repeat("a", 64), AppVersion: "0.9.4", AttestationPublicKey: "se", MachineModel: "Mac16,10", MemoryGB: "32"}
	q := store.AppAttestBuildQualification{AppAttestBuildIdentity: store.AppAttestBuildIdentity{
		Release: store.Release{Version: status.AppVersion, Platform: "macos-arm64", Backend: "mlx-swift", BinaryHash: status.BinaryHash,
			BundleHash: strings.Repeat("b", 64), MetallibHash: strings.Repeat("d", 64), URL: "https://example.com/bundle"},
		CodeDirectoryHash: e.CodeDirectoryHash, SourceCommit: strings.Repeat("f", 40), CIRunID: "123"},
		Evidence: "physical transition tests", ApprovedBy: "operator"}
	return e, status, q
}
