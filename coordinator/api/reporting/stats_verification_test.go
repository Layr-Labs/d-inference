package reporting

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func TestVerificationCountsUnionAndDuplicateMachine(t *testing.T) {
	verified := registry.VerificationPath{State: "verified", VerifiedAt: 1, ExpiresAt: 9999999999}
	pending := registry.VerificationPath{State: "pending"}
	var counts verificationCounts
	for _, v := range []registry.Verification{
		{AppAttest: verified, Legacy: pending}, {AppAttest: pending, Legacy: verified},
		{AppAttest: verified, Legacy: verified}, {AppAttest: pending, Legacy: pending},
	} {
		counts.add(v)
	}
	if counts.Connections != 4 || counts.Authorized != 3 || counts.AppAttest != 2 || counts.Legacy != 2 || counts.Overlap != 1 {
		t.Fatalf("double counted union: %+v", counts)
	}
	s := newStatsSnapshotServer(memory.NewMemory(store.Config{}))
	p := s.registry.Register("connection", nil, &protocol.RegisterMessage{})
	p.AccountID = "account"
	if !s.registry.BindVerifiedMachineIdentity(p, "account", "machine") {
		t.Fatal("bind identity")
	}
	var duplicate verificationCounts
	machines := map[[2]string]struct{}{}
	p.Mu().Lock()
	for range 2 {
		duplicate.addProvider(p, registry.Verification{AppAttest: verified, Legacy: pending}, machines)
	}
	p.Mu().Unlock()
	if duplicate.Connections != 2 || duplicate.KnownMachines != 1 {
		t.Fatalf("machine denominator: %+v", duplicate)
	}
}
