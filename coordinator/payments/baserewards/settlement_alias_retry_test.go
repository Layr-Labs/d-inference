package baserewards

import (
	"context"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type aliasRetryStore struct {
	*machineEngineStore
	registry      *registry.Registry
	batches       int
	deniedSession string
}

func (s *aliasRetryStore) SettleProviderFloorDrawBatch(ctx context.Context, items []store.FloorDrawBatchItem, authorize func(int) bool) (store.FloorDrawBatchResult, error) {
	s.batches++
	return s.inner.SettleProviderFloorDrawBatch(ctx, items, func(i int) bool {
		if s.batches == 2 && s.deniedSession == "" {
			s.deniedSession = items[i].SessionID
			p := s.registry.GetProvider(s.deniedSession)
			p.Mu().Lock()
			p.Status = registry.StatusOffline
			p.Mu().Unlock()
		}
		return authorize(i)
	})
}

func TestRewardPlanKeepsHealthyDuplicateAfterPreferredAliasLosesAuthorization(t *testing.T) {
	ctx := context.Background()
	epoch, start, end, clock := closedEpoch()
	reg := registry.New(testLogger())
	st := &aliasRetryStore{machineEngineStore: &machineEngineStore{engineStore: newEngineStore()}, registry: reg}
	machine, err := st.inner.ObserveMachine(ctx, store.MachineObservation{SessionID: "known", AccountID: "owner", VerifiedAppAttestKey: "apple", At: time.Now()})
	if err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{"known", "new"} {
		p := addProvider(reg, id, "endpoint", id, "Mac15,8", 64)
		setSerial(p, id, "Mac15,8")
		p.AccountID = "owner"
		if id == "known" && !reg.BindVerifiedMachineIdentity(p, "owner", machine.ID) {
			t.Fatal("bind")
		}
		if err := st.inner.OpenProviderSession(ctx, id, "", "owner"); err != nil {
			t.Fatal(err)
		}
		if err := st.inner.TouchProviderSession(ctx, id, "", "owner", "endpoint", time.Now()); err != nil {
			t.Fatal(err)
		}
		st.sessions = append(st.sessions, fullUptimeSession(id, "endpoint", id, "owner", start, end))
	}
	e := newTestEngine(st, reg, clock)
	result, err := e.SettleEpoch(ctx, epoch)
	if err != nil || st.batches != 3 || result.Settled != 1 || result.TotalDrawMicroUSD != 2016 {
		t.Fatalf("healthy alternate was lost: %+v batches=%d %v", result, st.batches, err)
	}
	draws, err := st.ListFloorDrawsForEpoch(ctx, epoch)
	if err != nil || len(draws) != 1 || draws[0].ProviderKey != store.MachineFloorKey(machine.ID) || st.inner.GetBalance("owner") != 2016 {
		t.Fatalf("duplicate payment: %+v %v", draws, err)
	}
	if st.deniedSession == "" {
		t.Fatal("no authorization loss exercised")
	}
}
