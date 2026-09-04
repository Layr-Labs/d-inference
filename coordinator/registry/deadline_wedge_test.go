package registry

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
)

// Deadline-wedge skip (deadline_wedge.go): narrow form only — N consecutive
// deadline_unreachable refusals of SHORT prompts dispatched onto EMPTY slots
// arm a bounded, half-open skip of the (fault key, model) pair; any accept
// clears it; the switch off is shadow (routing byte-identical).

func wedgeFixture(t *testing.T, enabled bool) (*Registry, *Provider, string) {
	t.Helper()
	reg := New(testLogger())
	reg.SetDeadlineWedgeSkipEnabled(enabled)
	model := "wedge-model"
	p := makeTokenBudgetProvider(t, reg, "wedged", model, 100, 0, 1_000_000, 80)
	return reg, p, model
}

func refuseN(reg *Registry, p *Provider, model string, n int) (last DeadlineWedgeEvent) {
	for i := 0; i < n; i++ {
		last = reg.NoteDeadlineRefusal(p.ID, model, 100, 0)
	}
	return last
}

func TestDeadlineWedgeArmsOnlyAtThreshold(t *testing.T) {
	reg, p, model := wedgeFixture(t, true)
	if ev := refuseN(reg, p, model, deadlineWedgeThreshold-1); ev != DeadlineWedgeRun {
		t.Fatalf("event after %d refusals = %v, want run", deadlineWedgeThreshold-1, ev)
	}
	if reg.DeadlineWedgeSkipActive(p.ID, model) {
		t.Fatalf("pair skipped after only %d refusals", deadlineWedgeThreshold-1)
	}
	if ev := refuseN(reg, p, model, 1); ev != DeadlineWedgeArmed {
		t.Fatalf("event at the threshold = %v, want armed", ev)
	}
	if !reg.DeadlineWedgeSkipActive(p.ID, model) {
		t.Fatal("pair not skipped at the threshold")
	}
	// A straggler inside the TTL neither re-arms nor extends.
	if ev := refuseN(reg, p, model, 1); ev != DeadlineWedgeRun {
		t.Fatalf("straggler event = %v, want run", ev)
	}
}

func TestDeadlineWedgeIgnoresOccupiedSlotsAndLongPrompts(t *testing.T) {
	reg, p, model := wedgeFixture(t, true)
	for i := 0; i < 3*deadlineWedgeThreshold; i++ {
		if ev := reg.NoteDeadlineRefusal(p.ID, model, 100, 1); ev != DeadlineWedgeIgnored {
			t.Fatalf("occupied-slot refusal event = %v, want ignored", ev)
		}
		if ev := reg.NoteDeadlineRefusal(p.ID, model, deadlineWedgeMaxPromptTokens, 0); ev != DeadlineWedgeIgnored {
			t.Fatalf("long-prompt refusal event = %v, want ignored", ev)
		}
	}
	if reg.DeadlineWedgeSkipActive(p.ID, model) {
		t.Fatal("occupied-slot / long-prompt refusals must never arm the skip")
	}
}

func TestDeadlineWedgeAcceptClears(t *testing.T) {
	reg, p, model := wedgeFixture(t, true)
	refuseN(reg, p, model, deadlineWedgeThreshold-1)
	// A commit-time accept resets the run: the next refusal starts over.
	reg.RecordCapacityAccept(p.ID, model)
	if ev := refuseN(reg, p, model, 1); ev != DeadlineWedgeRun || reg.DeadlineWedgeSkipActive(p.ID, model) {
		t.Fatalf("run not reset by the accept (event %v)", ev)
	}
	// An armed skip is cleared by an accept (the probe served).
	refuseN(reg, p, model, deadlineWedgeThreshold)
	if !reg.DeadlineWedgeSkipActive(p.ID, model) {
		t.Fatal("fixture: skip should be armed")
	}
	reg.RecordCapacityAcceptOutcome(p.ID, model, false)
	if reg.DeadlineWedgeSkipActive(p.ID, model) {
		t.Fatal("accept must clear the armed skip")
	}
	if st := reg.DeadlineWedgeStats(); st.Cleared != 2 || st.ArmedPairs != 0 {
		t.Fatalf("stats after clears = %+v, want Cleared 2, ArmedPairs 0", st)
	}
}

// TestDeadlineWedgeHalfOpenProbe: once the TTL lapses exactly one
// reservation passes (the probe, claimed at commit); the gate stays closed to
// everyone else while its outcome is pending; a refused probe re-arms with a
// doubled TTL and a served probe clears.
func TestDeadlineWedgeHalfOpenProbe(t *testing.T) {
	reg, p, model := wedgeFixture(t, true)
	refuseN(reg, p, model, deadlineWedgeThreshold)
	key := deadlineWedgeKey{FaultKey: p.ID, ModelID: model}
	// Expire the TTL without sleeping.
	reg.deadlineWedge.mu.Lock()
	reg.deadlineWedge.skips[key].until = time.Now().Add(-time.Second)
	reg.deadlineWedge.mu.Unlock()
	if reg.DeadlineWedgeSkipActive(p.ID, model) {
		t.Fatal("expired skip must open for a probe")
	}
	pr := planTestRequest("probe", 100, 100)
	pr.Model = model
	got, decision := reg.ReserveProviderEx(model, pr)
	if got == nil {
		t.Fatalf("probe reservation failed: %+v", decision)
	}
	if pr.ReserveOccupancy != 0 {
		t.Fatalf("ReserveOccupancy=%d, want 0 (empty slot)", pr.ReserveOccupancy)
	}
	// The claim closes the gate to everyone else.
	if !reg.DeadlineWedgeSkipActive(p.ID, model) {
		t.Fatal("gate must stay closed while the probe's outcome is pending")
	}
	if st := reg.DeadlineWedgeStats(); st.Probes != 1 {
		t.Fatalf("Probes=%d, want 1", st.Probes)
	}
	got.RemovePending(pr.RequestID)
	// The probe refuses: re-armed with the doubled TTL.
	if ev := reg.NoteDeadlineRefusal(p.ID, model, 100, 0); ev != DeadlineWedgeRearmed {
		t.Fatalf("refused probe event = %v, want rearmed", ev)
	}
	reg.deadlineWedge.mu.Lock()
	s := reg.deadlineWedge.skips[key]
	ttl := time.Until(s.until)
	trips := s.trips
	reg.deadlineWedge.mu.Unlock()
	if trips != 2 || ttl < 2*deadlineWedgeBaseTTL-5*time.Second || ttl > 2*deadlineWedgeBaseTTL {
		t.Fatalf("re-arm: trips=%d ttl≈%v, want trips 2 (two arms) and ≈ %v (doubled)", trips, ttl, 2*deadlineWedgeBaseTTL)
	}
	if deadlineWedgeBackoff(10) != deadlineWedgeMaxTTL {
		t.Fatalf("backoff must cap at %v", deadlineWedgeMaxTTL)
	}
}

// TestDeadlineWedgeGateSkipsAndCountsAsCapacity: with the switch on the scan
// drops the armed pair with GateDeadlineWedge and counts it as a capacity
// rejection (over_capacity, never no_provider); the preflight agrees.
func TestDeadlineWedgeGateSkipsAndCountsAsCapacity(t *testing.T) {
	reg, p, model := wedgeFixture(t, true)
	refuseN(reg, p, model, deadlineWedgeThreshold)
	pr := planTestRequest("skipped", 100, 100)
	pr.Model = model
	got, decision := reg.ReserveProviderEx(model, pr)
	if got != nil {
		t.Fatal("armed pair must not be reserved")
	}
	if decision.CapacityRejections != 1 || decision.GateRejections[GateDeadlineWedge] != 1 {
		t.Fatalf("decision=%+v, want one capacity rejection tallied as deadline_wedge", decision)
	}
	candidates, capacity, tooLarge := reg.QuickCapacityCheckForRequest(model, 100, 100, RequestTraits{}, false)
	if candidates != 0 || capacity != 1 || tooLarge != 0 {
		t.Fatalf("preflight candidates=%d capacity=%d tooLarge=%d, want 0/1/0", candidates, capacity, tooLarge)
	}
	if st := reg.DeadlineWedgeStats(); st.Skips == 0 || st.ShadowSkips != 0 || st.ArmedPairs != 1 {
		t.Fatalf("stats=%+v, want skips counted, no shadow skips, one armed pair", st)
	}
}

// TestDeadlineWedgeShadowIsByteIdentical: with the switch off (default) an
// armed pair is still reserved — routing is unchanged — and only the
// would-be skips are counted.
func TestDeadlineWedgeShadowIsByteIdentical(t *testing.T) {
	reg, p, model := wedgeFixture(t, false)
	if reg.DeadlineWedgeStats().Enabled {
		t.Fatal("switch must default off (shadow)")
	}
	if ev := refuseN(reg, p, model, deadlineWedgeThreshold); ev != DeadlineWedgeArmed {
		t.Fatalf("shadow mode must still record the run (event %v)", ev)
	}
	pr := planTestRequest("shadow", 100, 100)
	pr.Model = model
	got, decision := reg.ReserveProviderEx(model, pr)
	if got == nil || got.ID != p.ID || decision.GateRejections[GateDeadlineWedge] != 0 {
		t.Fatalf("shadow mode changed routing: got=%v decision=%+v", got, decision)
	}
	got.RemovePending(pr.RequestID)
	if reg.DeadlineWedgeSkipActive(p.ID, model) {
		t.Fatal("shadow mode must report no active skip")
	}
	if st := reg.DeadlineWedgeStats(); st.ShadowSkips == 0 || st.Skips != 0 || st.ArmedPairs != 1 {
		t.Fatalf("stats=%+v, want shadow skips counted, no real skips, one armed pair", st)
	}
}

// TestDeadlineWedgeFollowsIdentityRebindAndDisconnect: a run recorded under
// the session key migrates to the stable key on attestation (so a reconnect
// cannot reset it), and Disconnect drops a session-keyed identity's residue.
func TestDeadlineWedgeFollowsIdentityRebindAndDisconnect(t *testing.T) {
	reg, p, model := wedgeFixture(t, true)
	refuseN(reg, p, model, deadlineWedgeThreshold-1)
	p.SetAttestationResult(&attestation.VerificationResult{Valid: true, SerialNumber: "WEDGE-SER"})
	if ev := refuseN(reg, p, model, 1); ev != DeadlineWedgeArmed {
		t.Fatalf("run did not follow the rebind (event %v)", ev)
	}
	reg.deadlineWedge.mu.Lock()
	_, underStable := reg.deadlineWedge.skips[deadlineWedgeKey{FaultKey: "serial:WEDGE-SER", ModelID: model}]
	_, underSession := reg.deadlineWedge.skips[deadlineWedgeKey{FaultKey: p.ID, ModelID: model}]
	reg.deadlineWedge.mu.Unlock()
	if !underStable || underSession {
		t.Fatalf("skip keyed stable=%v session=%v, want stable only", underStable, underSession)
	}
	// Reconnect under the same serial: still skipped.
	reg.Disconnect(p.ID)
	p2 := makeTokenBudgetProvider(t, reg, "wedged-2", model, 100, 0, 1_000_000, 80)
	p2.SetAttestationResult(&attestation.VerificationResult{Valid: true, SerialNumber: "WEDGE-SER"})
	if !reg.DeadlineWedgeSkipActive(p2.ID, model) {
		t.Fatal("skip must survive reconnect under the stable identity")
	}

	// A session with no stable identity leaves nothing behind on Disconnect.
	anon := makeTokenBudgetProvider(t, reg, "anon", model, 100, 0, 1_000_000, 80)
	refuseN(reg, anon, model, deadlineWedgeThreshold)
	reg.Disconnect(anon.ID)
	reg.deadlineWedge.mu.Lock()
	_, residue := reg.deadlineWedge.skips[deadlineWedgeKey{FaultKey: anon.ID, ModelID: model}]
	reg.deadlineWedge.mu.Unlock()
	if residue {
		t.Fatal("Disconnect must drop the session-keyed wedge entry")
	}
}

// TestReserveOccupancyStampedOnBothPaths: the empty-slot discriminator is
// stamped at commit by the primary scan and by the plan path.
func TestReserveOccupancyStampedOnBothPaths(t *testing.T) {
	reg := New(testLogger())
	model := "wedge-occupancy-model"
	for i := range 3 {
		planTestProvider(t, reg, "occ-"+string(rune('a'+i)), model, int64(i)*400)
	}
	pr := planTestRequest("occ-primary", 100, 100)
	pr.Model = model
	p, _, plan := reg.ReserveProviderWithPlan(model, pr)
	if p == nil || plan == nil {
		t.Fatal("reservation failed")
	}
	if pr.ReserveOccupancy != 0 {
		t.Fatalf("primary ReserveOccupancy=%d, want 0 on an idle winner", pr.ReserveOccupancy)
	}
	// Occupy the next plan entry, then reserve it through the plan path.
	next, _ := plan.PeekNext()
	occupant := reg.GetProvider(next.ProviderID)
	occupant.AddPending(inGapPending("occupant", model, 100, 100))
	retry := planTestRequest("occ-retry", 100, 100)
	retry.Model = model
	got, _, _ := reg.ReserveNextFromPlan(retry, plan, p.ID)
	if got == nil || got.ID != next.ProviderID {
		t.Fatalf("plan path reserved %v, want %s", got, next.ProviderID)
	}
	if retry.ReserveOccupancy != 2 {
		t.Fatalf("plan-path ReserveOccupancy=%d, want 2 (one pending for the model + one total pending)", retry.ReserveOccupancy)
	}
}
