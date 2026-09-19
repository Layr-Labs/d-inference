package registry

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestAccountAffinitySharedSnapshotPreservesAndClearsFields(t *testing.T) {
	r, providers := routingAffinityFixture(t, AccountAffinityOn)
	p := providers[0]
	r.mu.Lock()
	defer r.mu.Unlock()
	p.mu.Lock()
	p.BackendCapacity.Slots[0].NumRunning = 1
	p.BackendCapacity.Slots = append(p.BackendCapacity.Slots, protocol.BackendSlotCapacity{
		Model: "other-model", State: "running", NumRunning: 2, NumWaiting: 3,
	})
	identity := stableAccountAffinityIdentityLocked(p)
	p.mu.Unlock()
	var snap routingSnapshot
	project := func(p *Provider) {
		p.mu.Lock()
		defer p.mu.Unlock()
		r.fillRoutingSnapshotPLocked(&snap, p, "affinity-build", time.Now())
	}
	project(p)
	if !snap.affinityIdentity.valid() || snap.affinityIdentity != identity || snap.affinityBackendOccupancy != 6 {
		t.Fatal("shared snapshot lost affinity identity or whole-machine occupancy")
	}
	// Preflight and final reservation share this projection; reused storage
	// cannot keep another provider's identity/work, including after disable.
	project(providers[1])
	if snap.affinityIdentity == identity || snap.affinityBackendOccupancy != 0 {
		t.Fatal("shared snapshot retained the previous provider's affinity state")
	}
	r.accountAffinity.Mode = AccountAffinityOff
	project(p)
	if snap.affinityIdentity.valid() || snap.affinityBackendOccupancy != 0 {
		t.Fatal("disabled affinity retained snapshot state")
	}
}
