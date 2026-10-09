package registry_test

// A cluster member is not a provider of the public fleet. Neither connection
// of a pair is counted, listed, rewarded, warmed, probed or leased as one,
// even while the pair is serving with its model loaded on the leader; the
// pair is counted once, through its leader, only in its owner's own view.

import (
	"testing"
	"testing/synctest"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/autopilotcontrol"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/warmplan"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/registry/autopilot"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func listedProviders(r *production.Registry, model string) int {
	for _, m := range r.ListModels() {
		if m.ID == model {
			return m.Providers
		}
	}
	return 0
}

func ownedProviders(r *production.Registry, account, model string) int {
	for _, m := range r.OwnedModels(account) {
		if m.ID == model {
			return m.Providers
		}
	}
	return 0
}

func TestClusterMembersAreNotCountedAsPublicProviders(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		f := newPairRoutingFixture(t, true)
		defer f.close()
		f.serve(t)
		const model = nativePairFixtureModel

		// Two connected members, the leader with the model loaded and idle:
		// the public fleet still has no provider and no capacity for the model.
		requirePublic := func(want int) {
			t.Helper()
			if got := listedProviders(f.r, model); got != want {
				t.Fatalf("model listing counts %d providers, want %d", got, want)
			}
			if got := f.r.ModelProviderSnapshot()[model]; got != int64(want) {
				t.Fatalf("provider snapshot counts %d, want %d", got, want)
			}
			if got := f.r.HasProviderForModel(model); got != (want > 0) {
				t.Fatalf("model availability = %v with %d public providers", got, want)
			}
			_, _, idleSlots, signals := f.r.HedgeGovernorSnapshot(model, nil)
			if idleSlots != want || signals != (want > 0) {
				t.Fatalf("fleet capacity signals: idle slots=%d available=%v, want %d public providers", idleSlots, signals, want)
			}
			roster := f.r.PublicProviderModels()
			for rank, member := range f.p {
				if listed := roster[member.ID].Models; len(listed) != 0 {
					t.Fatalf("rank%d is listed in the public roster with %v", rank, listed)
				}
			}
		}
		requirePublic(0)
		solo := f.solo(t, "solo-public", "")
		requirePublic(1)
		// The walk behind the public statistics and attestation listings
		// visits the solo provider and neither member.
		visited := map[string]bool{}
		f.r.ForEachProviderVerification(func(p *production.Provider, _ production.Verification, _ production.PublicProviderModelSnapshot) {
			visited[p.ID] = true
		})
		if !visited[solo.ID] || visited[f.p[0].ID] || visited[f.p[1].ID] {
			t.Fatalf("public verification walk visited %v, want the solo provider only", visited)
		}
		if listed := f.r.PublicProviderModels()[solo.ID].Models; len(listed) != 1 {
			t.Fatalf("the solo provider is listed with %v", listed)
		}

		// The owner sees its pair once; nobody else sees it at all.
		if got := ownedProviders(f.r, formationAccount, model); got != 1 {
			t.Fatalf("the owner's models count the pair %d times, want once", got)
		}
		if got := ownedProviders(f.r, "account-two", model); got != 0 {
			t.Fatalf("another account's models count the pair %d times", got)
		}
	})
}

func TestClusterMembersAreNotListedForTheirOwnerWhenRoutingIsOff(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		f := newPairRoutingFixture(t, false)
		defer f.close()
		f.relayKeys(t)
		if got := ownedProviders(f.r, formationAccount, nativePairFixtureModel); got != 0 {
			t.Fatalf("with routing off the owner's models count %d member connections", got)
		}
		if got := listedProviders(f.r, nativePairFixtureModel); got != 0 {
			t.Fatalf("with routing off the public listing counts %d member connections", got)
		}
	})
}

// Base rewards pay for capacity the public fleet can use. Neither member is
// reported as serving or as holding a loaded model, although the leader does.
func TestClusterMembersEarnNoBaseRewards(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		f := newPairRoutingFixture(t, true)
		defer f.close()
		f.serve(t)
		solo := f.solo(t, "solo-public", "")
		rewarded := map[string]production.ProviderSnapshot{}
		for _, snapshot := range f.r.ListProviders() {
			rewarded[snapshot.ID] = snapshot
		}
		for rank, member := range f.p {
			if s := rewarded[member.ID]; s.ServingAuthorized || s.ModelLoaded || s.CurrentModel != "" || !s.Online {
				t.Fatalf("rank%d reward snapshot = %+v, want an online machine with no public serving", rank, s)
			}
		}
		if s := rewarded[solo.ID]; !s.ServingAuthorized || !s.ModelLoaded {
			t.Fatalf("solo reward snapshot = %+v, want public serving with the model loaded", s)
		}
	})
}

// The warm pool neither counts a member as warm capacity nor plans a load on
// one, and no model command reaches either connection of a serving pair.
func TestClusterMembersAreNotWarmPoolCapacityOrLoadTargets(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		var fleet func(time.Time) map[string]warmplan.Fleet
		var planner *production.ModelLoadPlanner
		f := newPairRoutingFixture(t, true, func(deps *production.Dependencies) {
			deps.WarmPlanning = func(d warmplan.Dependencies[production.ModelLoadAction]) *warmplan.Controller[production.ModelLoadAction] {
				fleet = d.Fleet
				return warmplan.NewController(d)
			}
			deps.ModelLoadPlanning = func(p *production.ModelLoadPlanner) production.ModelLoadPlanning {
				planner = p
				return p
			}
		})
		defer f.close()
		f.r.ConfigureWarmPool(warmplan.Config{})
		f.serve(t)

		view := fleet(time.Now())[nativePairFixtureModel]
		if view.Warm != 0 || len(view.EligibleCold) != 0 {
			t.Fatalf("warm pool counts a serving pair: warm=%d cold=%d disqualified=%v", view.Warm, len(view.EligibleCold), view.ColdDisq)
		}
		for rank, member := range f.p {
			planned := []production.ModelLoadAction{{ProviderID: member.ID, ModelID: nativePairFixtureModel}}
			if reserved := planner.Reserve(planned, time.Now()); len(reserved) != 0 {
				t.Fatalf("a model load was planned on rank%d of a serving pair", rank)
			}
			if err := f.r.SendLoadModel(member.ID, nativePairFixtureModel); err == nil {
				t.Fatalf("load_model was sent to rank%d of a serving pair", rank)
			}
		}
		f.solo(t, "solo-public", "")
		if view = fleet(time.Now())[nativePairFixtureModel]; view.Warm != 1 {
			t.Fatalf("warm pool counts %d warm providers, want the solo provider alone", view.Warm)
		}
	})
}

// A capacity probe is solo protocol traffic. A plan may hold a pair's leader
// as an alternate next to the owner's other machine; probing the plan asks
// that machine and never a member.
func TestClusterMembersAreNeverSentCapacityProbes(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		f := newPairRoutingFixture(t, true)
		defer f.close()
		f.relayKeys(t)
		quoting := func(slots ...protocol.BackendSlotCapacity) *protocol.BackendCapacity {
			return &protocol.BackendCapacity{TotalMemoryGB: 64, CapacitySeq: 1, Slots: slots}
		}
		// Both of the owner's machines speak the capacity-quote protocol.
		f.r.Heartbeat(f.p[0].ID, &protocol.HeartbeatMessage{Type: protocol.TypeHeartbeat, Status: "idle", BackendCapacity: quoting(pairSlot())})
		solo := f.solo(t, "solo-owned", formationAccount)
		f.r.Heartbeat(solo.ID, &protocol.HeartbeatMessage{Type: protocol.TypeHeartbeat, Status: "idle", BackendCapacity: quoting(pairSlot())})

		// The first request lands on the leader; the second then prefers the
		// idle solo machine and keeps the leader as its alternate.
		first := ownerRequest("first", formationAccount)
		first.ExcludedProviderIDs = []string{solo.ID}
		if selected, _ := f.reserve(first); selected != f.p[0] {
			t.Fatal("fixture request was not reserved on the leader")
		}
		second := ownerRequest("second", formationAccount)
		selected, _, plan := f.r.ReserveProviderWithPlan(nativePairFixtureModel, second)
		if selected != solo || plan == nil {
			t.Fatalf("fixture plan was not led by the solo machine: selected=%v", selected)
		}
		for range f.r.ProbePlanCandidates(plan, production.CapacityProbeShape{Model: nativePairFixtureModel, PromptTokens: 100, MaxOutputTokens: 100}, time.Second) {
		}
		synctest.Wait()
		for rank := range f.p {
			for len(f.frames[rank]) > 0 {
				if frame := <-f.frames[rank]; frame.Type == protocol.TypeCapacityProbe {
					t.Fatalf("rank%d was sent a capacity probe", rank)
				}
			}
		}
	})
}

// Autopilot control leases manage a solo machine's model inventory. A member
// that registered an autopilot consent is still never sent one.
func TestClusterMembersGetNoAutopilotControlLease(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		writers := &memberFrameWriters{frames: make(map[string]chan protocol.NativePairMessage)}
		var control *autopilotcontrol.Controller[*production.Provider]
		r := pairEnvironmentWith(t, production.Dependencies{Connections: writers,
			AutopilotControl: func(actual *autopilotcontrol.Controller[*production.Provider]) autopilotcontrol.Operations[*production.Provider] {
				control = actual
				return actual
			}})
		r.SetStore(memory.NewMemory(store.Config{}))
		cfg := autopilot.DefaultConfig()
		cfg.Enabled = true
		if err := r.ConfigureAutopilot(cfg); err != nil {
			t.Fatal(err)
		}
		consent := &protocol.ModelAutopilotState{Protocol: protocol.ModelAutopilotProtocol, Enabled: true, CachedOnly: true,
			Revision: "fixture", SelectedModels: []string{nativePairFixtureModel}}
		member := pairMemberWith(t, r, nil, "member", "serial-a", "member-nonce", func(msg *protocol.RegisterMessage) {
			msg.ModelAutopilot = consent
		})
		soloRegistration := testRegisterMessage()
		soloRegistration.Models = []protocol.ModelInfo{{ID: nativePairFixtureModel, ModelType: "chat", Quantization: "4bit"}}
		soloRegistration.ModelAutopilot = consent
		solo := makeSchedulerProviderWithRegistration(t, r, "solo", nativePairFixtureModel, soloRegistration)
		defer func() {
			r.Disconnect(member.ID)
			r.Disconnect(solo.ID)
			synctest.Wait()
		}()

		control.RefreshControlLeases(time.Now())
		synctest.Wait()
		leased := func(id string) bool {
			for frames := writers.of(id); len(frames) > 0; {
				if (<-frames).Type == protocol.TypeModelAutopilotControl {
					return true
				}
			}
			return false
		}
		if !leased(solo.ID) {
			t.Fatal("fixture solo provider was not sent a control lease")
		}
		if leased(member.ID) {
			t.Fatal("a cluster member was sent an autopilot control lease")
		}
	})
}
