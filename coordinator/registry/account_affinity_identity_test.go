package registry

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
)

func TestAccountAffinityCanonicalIdentityAndClaimedSerialFence(t *testing.T) {
	for _, tc := range []struct {
		name string
		edit func(*Provider)
		want string
	}{
		{"claimed serial and key", func(p *Provider) {}, ""},
		{"canonical", func(p *Provider) { p.verifiedMachineAccount, p.verifiedMachineID = p.AccountID, "canonical" }, "machine:canonical"},
		{"canonical without legacy proof", func(p *Provider) {
			p.verifiedMachineAccount, p.verifiedMachineID, p.AttestationResult = p.AccountID, "canonical", nil
		}, "machine:canonical"},
		{"wrong account binding", func(p *Provider) { p.verifiedMachineAccount, p.verifiedMachineID = "different-owner", "canonical" }, ""},
		{"missing account binding", func(p *Provider) { p.verifiedMachineID = "canonical" }, ""},
		{"MDA-bound serial", func(p *Provider) {
			p.TrustLevel, p.MDAVerified, p.SEKeyBound = TrustHardware, true, true
			p.MDAResult = &attestation.MDAResult{DeviceSerial: "serial"}
		}, "serial:serial"},
		{"mismatched MDA serial", func(p *Provider) {
			p.TrustLevel, p.MDAVerified, p.SEKeyBound = TrustHardware, true, true
			p.MDAResult = &attestation.MDAResult{DeviceSerial: "other"}
		}, ""},
		{"MDA without SE binding", func(p *Provider) {
			p.TrustLevel, p.MDAVerified = TrustHardware, true
			p.MDAResult = &attestation.MDAResult{DeviceSerial: "serial"}
		}, ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			p := &Provider{AccountID: "owner", requireVerifiedMachineIdentity: true,
				AttestationResult: &attestation.VerificationResult{Valid: true, SerialNumber: "serial", PublicKey: "key"}}
			tc.edit(p)
			if got := stableAccountAffinityIdentityLocked(p); got != testAccountAffinityIdentity(tc.want) {
				t.Fatalf("identity = %+v, want %q", got, tc.want)
			}
		})
	}
}

func TestAccountAffinityCanonicalIdentitySurvivesCredentialRotation(t *testing.T) {
	p := &Provider{ID: "old-session", AccountID: "owner", verifiedMachineAccount: "owner", verifiedMachineID: "canonical"}
	before := accountAffinityScore("consumer", "model", stableAccountAffinityIdentityLocked(p))
	p.ID, p.PublicKey, p.appAttestCredentialID = "new-session", "new-endpoint", "new-credential"
	p.AttestationResult = &attestation.VerificationResult{Valid: true, SerialNumber: "unrelated-claim", PublicKey: "new-key"}
	if after := accountAffinityScore("consumer", "model", stableAccountAffinityIdentityLocked(p)); after != before {
		t.Fatal("session or credential rotation changed canonical affinity")
	}
}

func TestAccountAffinityAppAttestOnlyPreservesAuthorization(t *testing.T) {
	r, p, lease := appAttestTestProvider(t)
	if err := r.ConfigureAccountAffinity(AccountAffinityConfig{Mode: AccountAffinityOn, MaxTTFTPenaltyMs: 250}); err != nil {
		t.Fatal(err)
	}
	p.mu.Lock()
	p.AttestationResult = nil
	p.PrefillTPS = 1000
	p.mu.Unlock()
	if !r.GrantAppAttestServingAuthorization(p, lease) {
		t.Fatal("fixture could not authorize the App Attest-only provider")
	}
	pr := routingAffinityRequest("app-attest-affinity")
	pr.Model = appAttestTestModel
	got, decision := r.ReserveProviderEx(pr.Model, pr)
	if got != p || !decision.AccountAffinity.Applied {
		t.Fatalf("App Attest-only provider lost affinity: %+v", decision.AccountAffinity)
	}
	p.RemovePending(pr.RequestID)
	// Keeping a verified identity does not keep a serving grant alive.
	p.mu.Lock()
	p.appAttestAuthorization.ValidUntil = time.Now().Add(-time.Second)
	p.mu.Unlock()
	retry := routingAffinityRequest("expired-app-attest-affinity")
	retry.Model = appAttestTestModel
	if got, _ := r.ReserveProviderEx(retry.Model, retry); got != nil || p.PendingCount() != 0 {
		t.Fatal("canonical affinity bypassed authorization expiry")
	}
}
