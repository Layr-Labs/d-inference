package registry_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

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

func TestAppAttestRewardSnapshotRechecksAuthorizationAndHardware(t *testing.T) {
	clock := &appAttestTestClock{}
	r, p, lease := appAttestTestProvider(t, production.NewWithDependencies(testLogger(), production.Dependencies{AppAttestNow: clock.Now}))
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
	clock.Store(lease.ValidUntil.Add(time.Second).UnixNano())
	snapshot, _ = r.GetProviderRewardSnapshot(p.ID)
	if snapshot.AppAttestAuthorized || snapshot.ServingAuthorized {
		t.Fatal("expired lease earned reward eligibility")
	}
	// A hybrid must not fall back to retained hardware flags after revocation.
	p.Mu().Lock()
	testMakeTextRoutable(p)
	p.CodeAttested = true
	p.Attested = true
	p.Mu().Unlock()
	r.RevokeAppAttestCredential(lease.CredentialID)
	snapshot, _ = r.GetProviderRewardSnapshot(p.ID)
	if snapshot.ServingAuthorized {
		t.Fatal("revoked hybrid retained reward eligibility")
	}
}
