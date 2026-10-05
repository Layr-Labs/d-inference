package registry_test

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestVerificationNeverPublishesPrivateEvidenceOrInfersFromOS(t *testing.T) {
	r, p, _ := appAttestTestProvider(t)
	p.AttestationResult = &attestation.VerificationResult{OSVersion: "27.0"}
	v := r.ProviderVerification(p)
	if v.AppAttest.State != "unsupported" || v.Method() != "none" {
		t.Fatalf("OS manufactured authorization: %+v", v)
	}
	raw, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	for _, private := range []string{"account", "machine", "credential", "key_id", "serial", "receipt", "certificate", "proof_session", "endpoint"} {
		if strings.Contains(string(raw), private) {
			t.Fatalf("public verdict exposed %s: %s", private, raw)
		}
	}
}

func TestVerificationPathsAndHistoricalDispatch(t *testing.T) {
	clock := &appAttestTestClock{}
	r, p, lease := appAttestTestProviderWithProtocol(t, production.NewWithDependencies(testLogger(), production.Dependencies{AppAttestNow: clock.Now}), 3)
	if got := r.ProviderVerification(p); got.Method() != "none" || got.AppAttest.State != "pending" {
		t.Fatalf("pending: %+v", got)
	}
	if !r.GrantAppAttestServingAuthorization(p, lease) {
		t.Fatal("grant")
	}
	app := r.ProviderVerification(p)
	if app.Method() != "app_attest" || app.Legacy.State == "verified" || p.TrustLevel == production.TrustHardware {
		t.Fatalf("App Attest fabricated legacy evidence: %+v", app)
	}
	p.Mu().Lock()
	testMakeTextRoutable(p)
	p.CodeAttested = true
	p.Mu().Unlock()
	if got := r.ProviderVerification(p); got.Method() != "dual" {
		t.Fatalf("dual: %+v", got)
	}
	pr := &production.PendingRequest{RequestID: "historical", Model: appAttestTestModel}
	if r.ReserveProvider(appAttestTestModel, pr) != p {
		t.Fatal("reserve")
	}
	if err := p.NewInferenceHandoff(pr).Authorize(); err != nil {
		t.Fatal(err)
	}
	if pr.DispatchVerification.Method() != "dual" {
		t.Fatal("writer did not snapshot final authorization")
	}
	clock.Store(lease.ValidUntil.Add(time.Second).UnixNano())
	if got := r.ProviderVerification(p); got.Method() != "legacy" || got.AppAttest.State != "expired" {
		t.Fatalf("legacy fallback: %+v", got)
	}
	r.RevokeAppAttestCredential(lease.CredentialID)
	if got := r.ProviderVerification(p); got.Method() != "none" || got.AppAttest.State != "revoked" || got.Legacy.State != "revoked" {
		t.Fatalf("revoked: %+v", got)
	}
	if pr.DispatchVerification.Method() != "dual" {
		t.Fatal("current revocation rewrote dispatch history")
	}
	r.Disconnect(p.ID)
	if got := r.ProviderVerification(p); got.Method() != "none" || got.AppAttest.State != "offline" {
		t.Fatalf("offline: %+v", got)
	}
}

func TestVerificationRejectsUnsupportedAppAttestProtocolVersions(t *testing.T) {
	for _, version := range []int{0, 1, 2, 4, 100} {
		clock := &appAttestTestClock{}
		r, p, lease := appAttestTestProviderWithProtocol(t, production.NewWithDependencies(testLogger(), production.Dependencies{AppAttestNow: clock.Now}), version)
		if !r.GrantAppAttestServingAuthorization(p, lease) {
			t.Fatal("grant")
		}
		clock.Store(lease.ValidUntil.Add(time.Second).UnixNano())
		if got := r.ProviderVerification(p); got.AppAttest.State != "unsupported" {
			t.Fatalf("protocol %d state=%s, want unsupported", version, got.AppAttest.State)
		}
	}
	r, p, lease := appAttestTestProviderWithProtocol(t, production.New(testLogger()), 3)
	if !r.GrantAppAttestServingAuthorization(p, lease) {
		t.Fatal("grant")
	}
	r.ClearAppAttestServingAuthorization(p)
	if got := r.ProviderVerification(p); got.AppAttest.State != "pending" {
		t.Fatalf("protocol 3 state=%s, want pending", got.AppAttest.State)
	}
}
