package authorization_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/appattest"
	"github.com/eigeninference/d-inference/coordinator/appattest/service"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/authorization"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/eligibility"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestAppAttestAuthorizerBoundsRevocationSnapshotAndAssertion(t *testing.T) {
	f, p, record, state := newAuthorizationFixture(t, true)
	a := f.controller
	observed := time.Now().Add(-10 * time.Second)
	if !a.Apply(p, record, state, observed) {
		t.Fatal("valid policy not granted")
	}
	lease := p.GetAppAttestServingAuthorization()
	if !lease.ValidUntil.Equal(observed.Add(authorization.RevocationFreshness)) {
		t.Fatal("snapshot age extended")
	}
	if status := f.service.Status(p); status.Path != "app_attest" || !status.MDMRemovalReady {
		t.Fatalf("readiness %+v", status)
	}
	// Fresh receipt/revocation reads cannot extend an old assertion.
	f.evidence.AssertionAt = time.Now().Add(-appattest.AssertionFreshness + 2*time.Second)
	record = authorization.NewRecord(f.evidence, f.status, "proof", nil, 0)
	if !a.Apply(p, record, state, time.Now()) {
		t.Fatal("freshness margin rejected")
	}
	if got := p.GetAppAttestServingAuthorization().ValidUntil; !got.Equal(f.evidence.AssertionAt.Add(appattest.AssertionFreshness)) {
		t.Fatal("assertion extended")
	}
	if a.Apply(p, record, state, time.Now().Add(-authorization.RevocationFreshness-time.Second)) {
		t.Fatal("stale revocation snapshot granted")
	}
}

func TestAppAttestAuthorizerRefreshFailureDoesNotExtendAndRevocationFences(t *testing.T) {
	f, p, record, state := newAuthorizationFixture(t, true)
	a := f.controller
	st := &authorizationBatchStore{Store: f.store, state: map[string]store.AppAttestReadiness{"credential": state}}
	f.readiness = st
	a.Remember(p, record)
	a.Refresh(context.Background())
	before := p.GetAppAttestServingAuthorization()
	if before.CredentialID == "" {
		t.Fatal("no initial lease")
	}
	st.err = errors.New("database unavailable")
	a.Refresh(context.Background())
	if !p.GetAppAttestServingAuthorization().ValidUntil.Equal(before.ValidUntil) {
		t.Fatal("outage extended authorization")
	}
	st.err = nil
	st.state["credential"] = store.AppAttestReadiness{Revoked: true}
	a.Refresh(context.Background())
	if _, valid := f.registry.ProviderServingAuthorization(p); valid {
		t.Fatal("revoked credential active")
	}
	if a.Apply(p, record, state, time.Now()) {
		t.Fatal("late nonrevoked snapshot undid revocation")
	}
}

func TestAppAttestAuthorizerRejectsMissingPolicyAndArchive(t *testing.T) {
	for _, mode := range []string{"unqualified", "missing_code", "archive_gap", "catalog_changed", "expired_receipt"} {
		t.Run(mode, func(t *testing.T) {
			f, p, record, state := newAuthorizationFixture(t, true)
			switch mode {
			case "unqualified":
				f.bootstrap.BuildHashes = ""
			case "missing_code":
				f.evidence.CodeDirectoryHash = ""
				record = authorization.NewRecord(f.evidence, f.status, "proof", nil, 0)
			case "archive_gap":
				record = authorization.NewRecord(f.evidence, f.status, "proof", func() uint64 { return 1 }, 0)
			case "catalog_changed":
				f.policy = func() *authorization.ReleasePolicy {
					return &authorization.ReleasePolicy{Generation: 8, Known: true, Approves: func(*registry.Provider, *protocol.AppAttestStatus) bool { return false }}
				}
			case "expired_receipt":
				state.Receipt.ExpiresAt = time.Now().Add(-time.Second)
			}
			if f.controller.Apply(p, record, state, time.Now()) {
				t.Fatal("incomplete/negative evidence authorized")
			}
			if f.service.Status(p).MDMRemovalReady {
				t.Fatal("offered unsafe removal")
			}
		})
	}
}

func TestAppAttestServingAndRemovalAreIndependentOptIns(t *testing.T) {
	t.Setenv("EIGENINFERENCE_APP_ATTEST_SERVING", "false")
	t.Setenv("EIGENINFERENCE_APP_ATTEST_MDM_REMOVAL", "false")
	if c := service.ConfigFromEnvironment(); c.ServingEnabled || c.MDMRemovalEnabled {
		t.Fatal("default legacy behavior changed")
	}
	f, p, record, state := newAuthorizationFixture(t, false)
	if !f.controller.Apply(p, record, state, time.Now()) {
		t.Fatal("serving depends on migration switch")
	}
	if v := f.service.Status(p); v.Path != "app_attest" || v.MDMRemovalReady {
		t.Fatal("migration switch ineffective")
	}
	for _, reason := range []string{"apple_invalid_key", "apple_error", "keychain_error", "timeout", "authenticator_trailing_data", "storage_error"} {
		if eligibility.ProofViolation(reason) {
			t.Fatalf("recovery classified as tamper: %s", reason)
		}
	}
	for _, reason := range []string{"signature", "mac_acl", "nonce"} {
		if !eligibility.ProofViolation(reason) {
			t.Fatalf("hard violation ignored: %s", reason)
		}
	}
}
