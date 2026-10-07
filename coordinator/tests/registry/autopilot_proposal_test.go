package registry_test

import (
	"context"
	"slices"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/autopilotledger"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/registry/autopilot"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func autopilotProposalRecords(t *testing.T, r *autopilotFixture) []store.AutopilotRecord {
	t.Helper()
	if !r.events.Flush(r.store, testLogger()) {
		t.Fatal("proposal ledger flush failed")
	}
	ledger, ok := store.As[store.AutopilotStore](r.store)
	if !ok {
		t.Fatal("test store has no Autopilot ledger")
	}
	records, err := ledger.AutopilotRecords(context.Background(), time.Time{}, 1000)
	if err != nil {
		t.Fatal(err)
	}
	return records
}

func TestAutopilotRepeatedShadowTicksPersistOneDecision(t *testing.T) {
	var heartbeatAt time.Time
	r, c, now := newAutopilotControllerTest(t, true, func(deps *production.Dependencies) {
		deps.HeartbeatNow = func() time.Time { return heartbeatAt }
	})
	heartbeatAt = now
	p := autopilotControllerProvider(t, r, "shadow", now, autopilotTestDonor)
	var first store.AutopilotRecord
	for i := range 100 {
		at := now.Add(time.Duration(i) * r.cfg.Interval)
		p.Mu().Lock()
		heartbeat := &protocol.HeartbeatMessage{
			Status: "idle", SystemMetrics: p.SystemMetrics,
			BackendCapacity: autopilotControllerCapacity(p.BackendCapacity.CapacitySeq+1, autopilotTestDonor),
			ModelAutopilot:  autopilot.CloneState(p.ModelAutopilot), WarmModels: slices.Clone(p.WarmModels),
		}
		p.Mu().Unlock()
		heartbeatAt = at
		if !r.Heartbeat(p.ID, heartbeat) {
			t.Fatal("fresh shadow heartbeat was rejected")
		}
		p.Mu().Lock()
		p.LastChallengeVerified = at
		p.Reputation.TotalJobs++
		p.Reputation.SuccessfulJobs++ // change estimated benefit, not the placement
		p.Mu().Unlock()
		summary := c.Tick(at)
		if summary.Proposed != 1 || summary.Issued != 0 {
			t.Fatalf("tick %d did not retain its inert planning summary: %+v", i, summary)
		}
		records := autopilotProposalRecords(t, r)
		if len(records) != 1 || records[0].Phase != "proposed" {
			t.Fatalf("tick %d appended a duplicate decision: %+v", i, records)
		}
		if i == 0 {
			first = records[0]
		} else if records[0].CommandID != first.CommandID || !records[0].At.Equal(first.At) || records[0].Benefit != first.Benefit {
			t.Fatal("repeated proposal replaced its first-observed cost evidence")
		}
	}
	p.Mu().Lock()
	_, pending := r.states[p.ID].PrepareDelivery()
	residents := autopilot.ResidentIDs(p.ModelAutopilot)
	p.Mu().Unlock()
	if pending || r.pendingLoads.Count() != 0 || !slices.Equal(residents, []string{autopilotTestDonor}) {
		t.Fatal("proposal deduplication changed shadow residency ownership")
	}
}

func TestAutopilotShadowLedgerSeparatesSessionConsentAndActualPlacement(t *testing.T) {
	for _, change := range []string{"session", "revision", "residents", "selection"} {
		t.Run(change, func(t *testing.T) {
			r, c, now := newAutopilotControllerTest(t, true)
			p := autopilotControllerProvider(t, r, "shadow", now, autopilotTestDonor)
			if summary := c.Tick(now); summary.Proposed != 1 {
				t.Fatal("baseline did not propose a target load")
			}
			first := autopilotProposalRecords(t, r)[0]
			if change == "session" {
				r.Disconnect(p.ID)
				p = autopilotControllerProvider(t, r, "next-session", now, autopilotTestDonor)
			} else {
				p.Mu().Lock()
				var nextState *protocol.ModelAutopilotState
				switch change {
				case "revision":
					p.ModelAutopilot.Revision = "approved-next"
				case "residents":
					p.ModelAutopilot.ResidentModels = nil
					p.BackendCapacity = autopilotControllerCapacity(11)
					p.WarmModels, p.CurrentModel = nil, ""
					nextState = autopilot.CloneState(p.ModelAutopilot)
				case "selection":
					p.ModelAutopilot.SelectedModels = append(p.ModelAutopilot.SelectedModels, "new-approved-build")
				}
				p.Mu().Unlock()
				if nextState != nil {
					r.Heartbeat(p.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: autopilotControllerCapacity(11), ModelAutopilot: nextState})
					p.Mu().Lock()
					r.samples[p.ID].MarkAccepted(now)
					p.Mu().Unlock()
				}
			}
			for range 2 {
				if summary := c.Tick(now.Add(r.cfg.Interval)); summary.Proposed != 1 || summary.Issued != 0 {
					t.Fatalf("changed placement not observed: %+v", summary)
				}
			}
			records := autopilotProposalRecords(t, r)
			if len(records) != 2 || records[0].CommandID == records[1].CommandID {
				t.Fatalf("distinct %s decision collapsed or repeats appended: %+v", change, records)
			}
			for _, record := range records {
				if record.Phase != "proposed" || record.Load != first.Load || record.Reason != first.Reason {
					t.Fatalf("fixture must change identity, not action or reason: %+v", records)
				}
			}
		})
	}
}

func TestAutopilotProposalIdentityTracksDecisionNotSetOrderOrNumericNoise(t *testing.T) {
	state := autopilotControllerState("donor-a", "donor-b")
	state.SelectedModels = []string{"target", "donor-a", "donor-b"}
	action := autopilot.Action{Workload: "target\x1fshape", Reason: "demand", Load: "target", Unload: []string{"donor-a", "donor-b"},
		Node: autopilot.Node{ID: "session", Seq: 10, State: state}, Benefit: 100}
	before := autopilotledger.ProposalID(action)
	for _, change := range []string{"set order", "numeric noise", "session", "revision", "workload", "reason", "target", "unloads", "residents", "selection"} {
		t.Run(change, func(t *testing.T) {
			copy := action
			copy.Node.State = autopilot.CloneState(action.Node.State)
			copy.Unload = slices.Clone(action.Unload)
			switch change {
			case "set order":
				slices.Reverse(copy.Unload)
				slices.Reverse(copy.Node.State.ResidentModels)
				slices.Reverse(copy.Node.State.SelectedModels)
			case "numeric noise":
				copy.Node.Seq++
				copy.Benefit++
				copy.Node.State.ResidentModels[0].ResidentSeconds++
				copy.Node.State.ResidentModels[0].IdleSeconds++
			case "session":
				copy.Node.ID = "next-session"
			case "revision":
				copy.Node.State.Revision = "approved-next"
			case "workload":
				copy.Workload = "target\x1fother-shape"
			case "reason":
				copy.Reason = "protected_floor"
			case "target":
				copy.Load = "other-target"
			case "unloads":
				copy.Unload = copy.Unload[:1]
			case "residents":
				copy.Node.State.ResidentModels = copy.Node.State.ResidentModels[:1]
			case "selection":
				copy.Node.State.SelectedModels = append(copy.Node.State.SelectedModels, "new-approved-build")
			}
			equal := autopilotledger.ProposalID(copy) == before
			if equal != (change == "set order" || change == "numeric noise") {
				t.Fatalf("proposal identity equality=%v for %s", equal, change)
			}
		})
	}
}
