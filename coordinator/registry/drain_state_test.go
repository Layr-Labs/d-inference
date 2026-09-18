package registry

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Drain awareness (drain_state.go) on a real Registry with routable
// providers: the heartbeat "draining" status and the typed-rejection mark
// both remove a provider from routing while counting it as TRANSIENT
// capacity (429 / queue material), never as structural absence.

const drainStateTestModel = "drain-model"

// registerDrainStateProvider registers a hardware-trusted, challenge-verified
// provider serving drainStateTestModel (the routable-provider recipe shared by the
// scheduler scenario tests).
func registerDrainStateProvider(t *testing.T, r *Registry, id string, decodeTPS float64) *Provider {
	t.Helper()
	msg := testRegisterMessage()
	msg.Models = []protocol.ModelInfo{{ID: drainStateTestModel, ModelType: "chat", Quantization: "4bit"}}
	msg.DecodeTPS = decodeTPS
	p := r.Register(id, nil, msg)
	p.mu.Lock()
	p.TrustLevel = TrustHardware
	p.RuntimeVerified = true
	p.RuntimeManifestChecked = true
	p.ChallengeVerifiedSIP = true
	p.LastChallengeVerified = time.Now()
	p.SystemMetrics = protocol.SystemMetrics{MemoryPressure: 0.1, CPUUsage: 0.1, ThermalState: "nominal"}
	p.mu.Unlock()
	return p
}

func drainStateHeartbeat(status string) *protocol.HeartbeatMessage {
	return &protocol.HeartbeatMessage{Type: protocol.TypeHeartbeat, Status: status}
}

func drainStateRequest(id string) *PendingRequest {
	return &PendingRequest{RequestID: id, Model: drainStateTestModel, EstimatedPromptTokens: 100, RequestedMaxTokens: 64}
}

func TestHeartbeatDraining_SkipsProviderAndCountsAsCapacity(t *testing.T) {
	r := New(testLogger())
	registerDrainStateProvider(t, r, "a", 200)
	registerDrainStateProvider(t, r, "b", 1)

	// Sanity: the fast box wins while both are routable.
	if p, _ := r.ReserveProviderEx(drainStateTestModel, drainStateRequest("warm")); p == nil || p.ID != "a" {
		t.Fatalf("baseline reservation = %v, want provider a", p)
	}
	r.GetProvider("a").RemovePending("warm")

	r.Heartbeat("a", drainStateHeartbeat(protocol.HeartbeatStatusDraining))
	if !r.ProviderDraining("a") {
		t.Fatalf("provider a not marked draining after a draining heartbeat")
	}
	p, decision := r.ReserveProviderEx(drainStateTestModel, drainStateRequest("r1"))
	if p == nil || p.ID != "b" {
		t.Fatalf("reservation with a draining = %v, want provider b (decision %+v)", p, decision)
	}
	r.GetProvider("b").RemovePending("r1")

	// Only the draining box left: the scan and the admission preflight both
	// report transient capacity, not "no providers".
	r.Disconnect("b")
	p, decision = r.ReserveProviderEx(drainStateTestModel, drainStateRequest("r2"))
	if p != nil {
		t.Fatalf("reserved %s while it was draining", p.ID)
	}
	if decision.CapacityRejections != 1 {
		t.Errorf("scan CapacityRejections = %d, want 1 (draining counts as transient capacity); decision %+v", decision.CapacityRejections, decision)
	}
	candidates, capacityRejections, tooLarge := r.QuickCapacityCheck(drainStateTestModel, 500, 64, RequestTraits{})
	if candidates != 0 || capacityRejections != 1 || tooLarge != 0 {
		t.Errorf("QuickCapacityCheck = (%d, %d, %d), want (0, 1, 0)", candidates, capacityRejections, tooLarge)
	}

	// A later idle heartbeat clears a heartbeat-owned mark.
	r.Heartbeat("a", drainStateHeartbeat("idle"))
	if r.ProviderDraining("a") {
		t.Fatalf("provider a still draining after an idle heartbeat")
	}
	if p, _ := r.ReserveProviderEx(drainStateTestModel, drainStateRequest("r3")); p == nil || p.ID != "a" {
		t.Fatalf("reservation after the drain cleared = %v, want provider a", p)
	}
}

// A mark set by the typed draining REJECTION is cleared by the provider's
// own idle/serving heartbeat like a heartbeat-set one: the rejection is only
// emitted by a binary that also reports "draining", so an update drain that
// aborted before its draining heartbeat was delivered is back in routing on
// the next heartbeat. The TTL remains the heartbeat-loss fallback.
func TestMarkDraining_ClearedByIdleHeartbeat_OrTTL(t *testing.T) {
	r := New(testLogger())
	p := registerDrainStateProvider(t, r, "a", 200)

	if !r.MarkDraining("a") {
		t.Fatalf("first MarkDraining did not report a transition")
	}
	if r.MarkDraining("a") {
		t.Fatalf("second MarkDraining reported a transition")
	}
	if candidates, rejections, _ := r.QuickCapacityCheck(drainStateTestModel, 500, 64, RequestTraits{}); candidates != 0 || rejections != 1 {
		t.Errorf("QuickCapacityCheck while marked = (%d, %d), want (0, 1)", candidates, rejections)
	}
	// A legacy/unknown status leaves the mark alone.
	r.Heartbeat("a", drainStateHeartbeat(""))
	if !r.ProviderDraining("a") {
		t.Fatalf("rejection-set drain mark cleared by a heartbeat without a status")
	}
	// The aborted-drain case: the provider never reported "draining" and now
	// reports idle. Routing must see it again immediately.
	r.Heartbeat("a", drainStateHeartbeat("idle"))
	if r.ProviderDraining("a") {
		t.Fatalf("rejection-set drain mark survived the provider's idle heartbeat")
	}
	if candidates, rejections, _ := r.QuickCapacityCheck(drainStateTestModel, 500, 64, RequestTraits{}); candidates != 1 || rejections != 0 {
		t.Errorf("QuickCapacityCheck after the idle heartbeat = (%d, %d), want (1, 0)", candidates, rejections)
	}

	// TTL expiry restores eligibility without any heartbeat.
	if !r.MarkDraining("a") {
		t.Fatalf("re-mark after the clear did not report a transition")
	}
	p.mu.Lock()
	p.drainingUntil = time.Now().Add(-time.Second)
	p.mu.Unlock()
	if r.ProviderDraining("a") {
		t.Fatalf("drain mark still honored past its TTL")
	}

	// Rejection then "draining" then "serving": the provider's own report
	// clears it in this order too.
	r.MarkDraining("a")
	r.Heartbeat("a", drainStateHeartbeat(protocol.HeartbeatStatusDraining))
	if !r.ProviderDraining("a") {
		t.Fatalf("draining heartbeat did not keep the mark")
	}
	r.Heartbeat("a", drainStateHeartbeat("serving"))
	if r.ProviderDraining("a") {
		t.Fatalf("drain mark not cleared by a serving heartbeat")
	}
}

func TestDrainState_UnknownProviderIsNoop(t *testing.T) {
	r := New(testLogger())
	if r.MarkDraining("nope") {
		t.Fatalf("MarkDraining on an unknown id reported a transition")
	}
	if r.ProviderDraining("nope") {
		t.Fatalf("ProviderDraining on an unknown id reported true")
	}
}

// A heartbeat-owned mark must stay heartbeat-owned when a typed rejection
// lands on top of it (a dispatch already on the wire when the drain began),
// so an aborted update that resumes serving clears it with its own
// idle/serving heartbeat instead of blacking the box out until the TTL.
func TestMarkDraining_DoesNotTakeOwnershipFromHeartbeat(t *testing.T) {
	r := New(testLogger())
	registerDrainStateProvider(t, r, "a", 200)

	r.Heartbeat("a", drainStateHeartbeat(protocol.HeartbeatStatusDraining))
	if r.MarkDraining("a") {
		t.Fatalf("MarkDraining on a heartbeat-marked provider reported a transition")
	}
	r.Heartbeat("a", drainStateHeartbeat("idle"))
	if r.ProviderDraining("a") {
		t.Fatalf("idle heartbeat did not clear a heartbeat-owned mark after a typed rejection landed on it")
	}
	if candidates, rejections, _ := r.QuickCapacityCheck(drainStateTestModel, 500, 64, RequestTraits{}); candidates != 1 || rejections != 0 {
		t.Errorf("QuickCapacityCheck after un-drain = (%d, %d), want (1, 0)", candidates, rejections)
	}
}
