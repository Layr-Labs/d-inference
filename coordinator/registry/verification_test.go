package registry

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
)

func TestVerificationPathsAndHistoricalDispatch(t *testing.T) {
	r, p, lease := appAttestTestProvider(t)
	p.appAttestProtocol = 3
	if got := r.ProviderVerification(p); got.Method() != "none" || got.AppAttest.State != "pending" {
		t.Fatalf("pending: %+v", got)
	}
	if !r.GrantAppAttestServingAuthorization(p, lease) {
		t.Fatal("grant")
	}
	app := r.ProviderVerification(p)
	if app.Method() != "app_attest" || app.Legacy.State == "verified" || p.TrustLevel == TrustHardware {
		t.Fatalf("App Attest fabricated legacy evidence: %+v", app)
	}
	p.mu.Lock()
	testMakeTextRoutable(p)
	p.CodeAttested = true
	p.mu.Unlock()
	if got := r.ProviderVerification(p); got.Method() != "dual" {
		t.Fatalf("dual: %+v", got)
	}
	pr := &PendingRequest{RequestID: "historical", Model: appAttestTestModel}
	if r.ReserveProvider(appAttestTestModel, pr) != p {
		t.Fatal("reserve")
	}
	p.mu.Lock()
	w := p.writer
	p.mu.Unlock()
	if err := r.authorizeInferenceHandoff(p, pr, w); err != nil {
		t.Fatal(err)
	}
	if pr.DispatchVerification.Method() != "dual" {
		t.Fatal("writer did not snapshot final authorization")
	}
	p.mu.Lock()
	p.appAttestAuthorization.ValidUntil = time.Now().Add(-time.Second)
	p.mu.Unlock()
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

func TestVerificationRejectsUnsupportedAppAttestProtocolVersions(t *testing.T) {
	r, p, _ := appAttestTestProvider(t)
	for _, version := range []int{0, 1, 2, 4, 100} {
		p.mu.Lock()
		p.appAttestProtocol = version
		p.appAttestAuthorization.ValidUntil = time.Now().Add(-time.Second)
		p.mu.Unlock()
		if got := r.ProviderVerification(p); got.AppAttest.State != "unsupported" {
			t.Fatalf("protocol %d state=%s, want unsupported", version, got.AppAttest.State)
		}
	}
	p.mu.Lock()
	p.appAttestProtocol = 3
	p.appAttestAuthorization = AppAttestServingAuthorization{}
	p.mu.Unlock()
	if got := r.ProviderVerification(p); got.AppAttest.State != "pending" {
		t.Fatalf("protocol 3 state=%s, want pending", got.AppAttest.State)
	}
}
