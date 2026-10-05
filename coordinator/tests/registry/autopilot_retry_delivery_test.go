package registry_test

import (
	"encoding/json"
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/providerwrite"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/registry/autopilot"
)

func TestAutopilotRetriesDoNotBlockLeaseRenewalOrLoseOwnership(t *testing.T) {
	connections := autopilotDeliveryWriters{}
	cfg := autopilot.DefaultConfig()
	cfg.Enabled, cfg.ObserveOnly, cfg.MaxConcurrentOperations = true, false, 16
	r, c, now := newAutopilotControllerTestConfig(t, cfg, func(deps *production.Dependencies) {
		deps.Connections = connections
	})
	var peers []*production.Provider
	var writers []*writerFixture
	for i := 0; i < 9; i++ {
		id := fmt.Sprintf("retry-peer-%d", i)
		w := newWriterFixture(0, 2, nil, nil, nil, nil)
		connections[id] = w
		p := autopilotControllerProvider(t, r, id, now)
		if i < 4 {
			w.offer(providerwrite.NewFrame(nil, nil), true)
			w.offer(providerwrite.NewFrame(nil, nil), true)
		}
		command := protocol.ModelAutopilotMessage{Type: protocol.TypeModelAutopilot, CommandID: p.ID + "-command",
			SessionID: p.ID, Revision: "test", LoadModelID: autopilotTestTarget, ExpiresAtMS: now.Add(-time.Second).UnixMilli()}
		p.Mu().Lock()
		r.states[p.ID].Reserve(command, 0, now.Add(-31*time.Second), 0)
		if i < 8 {
			r.states[p.ID].WriteFailed(p.ID, command, false, func() time.Time { return now }, r.events.Queue)
		}
		p.Mu().Unlock()
		t.Cleanup(func() { w.Close(); w.Run() })
		peers = append(peers, p)
		writers = append(writers, w)
	}
	tick := func(at time.Time) {
		t.Helper()
		done := make(chan struct{})
		go func() { c.Tick(at); close(done) }()
		select {
		case <-done:
		case <-time.After(time.Second):
			t.Fatal("command retries held the controller tick behind stalled sockets")
		}
	}
	readHealthy := func() []byte {
		t.Helper()
		select {
		case frame := <-writers[8].lanes.Receive(true):
			return writers[8].executeFrame(frame)
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
		p.Mu().Lock()
		pending, present := r.states[p.ID].PrepareDelivery()
		valid := present && pending.Attempts == 2 && (i == 8 || pending.Uncertain)
		p.Mu().Unlock()
		if !valid {
			t.Fatalf("peer %d lost pending/uncertain ownership", i)
		}
	}
	tick(now.Add(r.cfg.Interval))
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
