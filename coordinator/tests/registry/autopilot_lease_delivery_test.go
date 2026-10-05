package registry_test

import (
	"encoding/json"
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestAutopilotLeaseRenewalDoesNotWaitForPeerSockets(t *testing.T) {
	connections := autopilotDeliveryWriters{}
	r, c, now := newAutopilotControllerTest(t, false, func(deps *production.Dependencies) {
		deps.Connections = connections
	})
	var peers []*production.Provider
	var writers []*writerFixture
	for i := 0; i < 9; i++ {
		id := fmt.Sprintf("peer-%d", i)
		// No socket consumer: eight peers remain stalled across both renewals.
		// The final peer consumes its frame below, as an available writer would.
		w := newWriterFixture(0, 1, nil, nil, nil, nil)
		connections[id] = w
		p := autopilotControllerProvider(t, r, id, now)
		p.Mu().Lock()
		r.states[p.ID].AcceptControl(p.ModelAutopilot, protocol.ModelAutopilotControl{
			Revision: "test", ExpiresAtMS: time.Time{}.UnixMilli(),
		})
		p.Mu().Unlock()
		t.Cleanup(func() { w.Close(); w.Run() })
		peers = append(peers, p)
		writers = append(writers, w)
	}
	renew := func(at time.Time) {
		t.Helper()
		done := make(chan struct{})
		go func() { c.RefreshControlLeases(at); close(done) }()
		select {
		case <-done:
		case <-time.After(time.Second):
			t.Fatal("lease renewal waited for a stalled socket")
		}
	}
	readHealthy := func() protocol.ModelAutopilotControl {
		t.Helper()
		var control protocol.ModelAutopilotControl
		select {
		case frame := <-writers[8].lanes.Receive(true):
			if err := json.Unmarshal(writers[8].executeFrame(frame), &control); err != nil {
				t.Fatal(err)
			}
		case <-time.After(time.Second):
			t.Fatal("healthy peer did not receive renewal")
		}
		return control
	}
	renew(now)
	first := readHealthy()
	if !first.Enabled || first.ObserveOnly || first.Revision != "test" || first.ExpiresAtMS <= now.UnixMilli() {
		t.Fatalf("invalid lease: %+v", first)
	}
	renew(now.Add(r.cfg.Interval))
	second := readHealthy()
	if second.ExpiresAtMS <= first.ExpiresAtMS {
		t.Fatal("full queues on stalled peers prevented healthy renewal")
	}
	peers[0].Mu().Lock()
	// Grants have millisecond precision: the authority must end at exactly the
	// first accepted expiry, neither shortened nor extended by a rejected enqueue.
	activeBeforeExpiry := r.states[peers[0].ID].ControlActive(peers[0].ModelAutopilot, peers[0].ID, time.UnixMilli(first.ExpiresAtMS-1))
	activeAtExpiry := r.states[peers[0].ID].ControlActive(peers[0].ModelAutopilot, peers[0].ID, time.UnixMilli(first.ExpiresAtMS))
	peers[0].Mu().Unlock()
	if !activeBeforeExpiry || activeAtExpiry {
		t.Fatal("a rejected enqueue extended coordinator lease authority")
	}
}
