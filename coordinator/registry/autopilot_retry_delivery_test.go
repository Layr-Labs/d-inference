package registry

import (
	"encoding/json"
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestAutopilotRetriesDoNotBlockLeaseRenewalOrLoseOwnership(t *testing.T) {
	r, c, now := newAutopilotControllerTest(t, false)
	c.config.MaxConcurrentOperations = 16
	var peers []*Provider
	for i := 0; i < 9; i++ {
		p := autopilotControllerProvider(t, r, fmt.Sprintf("retry-peer-%d", i), now)
		w := &providerWriter{control: make(chan *providerWriteRequest, 2), stop: make(chan struct{}), done: make(chan struct{})}
		if i < 4 {
			w.control <- &providerWriteRequest{}
			w.control <- &providerWriteRequest{}
		}
		command := protocol.ModelAutopilotMessage{Type: protocol.TypeModelAutopilot, CommandID: p.ID + "-command",
			SessionID: p.ID, Revision: "test", LoadModelID: autopilotTestTarget, ExpiresAtMS: now.Add(-time.Second).UnixMilli()}
		p.mu.Lock()
		p.writer = w
		p.autopilotPending = &autopilotPendingCommand{Command: command, Status: "reserved", Attempts: 1, Uncertain: i < 8,
			SentAt: now.Add(-31 * time.Second), LastSentAt: now.Add(-31 * time.Second)}
		p.mu.Unlock()
		t.Cleanup(func() { w.closeNow(); close(w.done) })
		peers = append(peers, p)
	}
	tick := func(at time.Time) {
		t.Helper()
		done := make(chan struct{})
		go func() { c.tick(at); close(done) }()
		select {
		case <-done:
		case <-time.After(time.Second):
			t.Fatal("command retries held the controller tick behind stalled sockets")
		}
	}
	readHealthy := func() []byte {
		t.Helper()
		select {
		case frame := <-peers[8].writer.control:
			return frame.data
		case <-time.After(time.Second):
			t.Fatal("healthy peer did not receive queued control frame")
			return nil
		}
	}
	tick(now)
	var first protocol.ModelAutopilotControl
	if err := json.Unmarshal(readHealthy(), &first); err != nil {
		t.Fatal(err)
	}
	var retry protocol.ModelAutopilotMessage
	if err := json.Unmarshal(readHealthy(), &retry); err != nil {
		t.Fatal(err)
	}
	if retry.CommandID != peers[8].ID+"-command" || retry.ExpiresAtMS != now.Add(-time.Second).UnixMilli() {
		t.Fatalf("retry changed immutable command identity or acceptance deadline: %+v", retry)
	}
	for i, p := range peers {
		p.mu.Lock()
		pending := p.autopilotPending
		valid := pending != nil && pending.Attempts == 2 && (i == 8 || pending.Uncertain)
		p.mu.Unlock()
		if !valid {
			t.Fatalf("peer %d lost pending/uncertain ownership", i)
		}
	}
	tick(now.Add(c.config.Interval))
	var second protocol.ModelAutopilotControl
	if err := json.Unmarshal(readHealthy(), &second); err != nil {
		t.Fatal(err)
	}
	// tick renews against wall-clock time; two immediate ticks can share a millisecond.
	if first.Type != protocol.TypeModelAutopilotControl || second.Type != protocol.TypeModelAutopilotControl ||
		!first.Enabled || !second.Enabled || second.ExpiresAtMS < first.ExpiresAtMS {
		t.Fatal("stalled retries prevented the next healthy control lease")
	}
}
