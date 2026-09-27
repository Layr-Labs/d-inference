package registry

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
)

func TestAppAttestRewardSnapshotRechecksAuthorizationAndHardware(t *testing.T) {
	r, p, lease := appAttestTestProvider(t)
	p.SetAttestationResult(&attestation.VerificationResult{Valid: true, SerialNumber: "claimed-serial", HardwareModel: "claimed-model"})
	if !r.GrantAppAttestServingAuthorization(p, lease) {
		t.Fatal("grant")
	}
	snapshot, found := r.GetProviderRewardSnapshot(p.ID)
	if !found || !snapshot.AppAttestAuthorized || !snapshot.ServingAuthorized || snapshot.AccountID != lease.AccountID || snapshot.MachineID != lease.MachineID {
		t.Fatalf("snapshot %+v", snapshot)
	}
	if snapshot.HardwareModel != lease.MachineModel || snapshot.MemoryGB != lease.MemoryGB {
		t.Fatal("snapshot used unbound hardware")
	}
	p.mu.Lock()
	p.appAttestAuthorization.ValidUntil = time.Now().Add(-time.Second)
	p.mu.Unlock()
	snapshot, _ = r.GetProviderRewardSnapshot(p.ID)
	if snapshot.AppAttestAuthorized || snapshot.ServingAuthorized {
		t.Fatal("expired lease earned reward eligibility")
	}
	// A hybrid must not fall back to retained hardware flags after revocation.
	p.mu.Lock()
	testMakeTextRoutable(p)
	p.CodeAttested = true
	p.Attested = true
	p.mu.Unlock()
	r.RevokeAppAttestCredential(lease.CredentialID)
	snapshot, _ = r.GetProviderRewardSnapshot(p.ID)
	if snapshot.ServingAuthorized {
		t.Fatal("revoked hybrid retained reward eligibility")
	}
}

func TestAppAttestLeaseCannotSubstituteRewardHardware(t *testing.T) {
	r, p, lease := appAttestTestProvider(t)
	lease.MemoryGB *= 2
	if r.GrantAppAttestServingAuthorization(p, lease) {
		t.Fatal("unmatched memory accepted")
	}
	lease.MemoryGB = p.Hardware.MemoryGB
	lease.MachineModel = "different-model"
	if r.GrantAppAttestServingAuthorization(p, lease) {
		t.Fatal("unmatched model accepted")
	}
}
