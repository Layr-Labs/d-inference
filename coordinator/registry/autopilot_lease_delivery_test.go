package registry

import (
	"encoding/json"
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestAutopilotLeaseRenewalDoesNotWaitForPeerSockets(t *testing.T) {
	r, c, now := newAutopilotControllerTest(t, false)
	var peers []*Provider
	for i := 0; i < 9; i++ {
		p := autopilotControllerProvider(t, r, fmt.Sprintf("peer-%d", i), now)
		// No socket consumer: eight peers remain stalled across both renewals.
		// The final peer consumes its frame below, as an available writer would.
		w := &providerWriter{control: make(chan *providerWriteRequest, 1), stop: make(chan struct{}), done: make(chan struct{})}
		p.mu.Lock()
		p.writer = w
		p.autopilotControlUntil = time.Time{}
		p.mu.Unlock()
		t.Cleanup(func() { w.closeNow(); close(w.done) })
		peers = append(peers, p)
	}
	renew := func(at time.Time) {
		t.Helper()
		done := make(chan struct{})
		go func() { c.refreshControlLeases(at); close(done) }()
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
		case frame := <-peers[8].writer.control:
			if err := json.Unmarshal(frame.data, &control); err != nil {
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
	renew(now.Add(c.config.Interval))
	second := readHealthy()
	if second.ExpiresAtMS <= first.ExpiresAtMS {
		t.Fatal("full queues on stalled peers prevented healthy renewal")
	}
	peers[0].mu.Lock()
	stalledUntil := peers[0].autopilotControlUntil
	peers[0].mu.Unlock()
	if stalledUntil.UnixMilli() != first.ExpiresAtMS {
		t.Fatal("a rejected enqueue extended coordinator lease authority")
	}
}
