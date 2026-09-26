package registry

import (
	"context"
	"encoding/json"
	"errors"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestQueuedDrainAckCannotSettleReusedIDGeneration(t *testing.T) {
	conn, peer := testWebSocketPair(t)
	r := New(testLogger())
	p := r.Register("session", nil, &protocol.RegisterMessage{Models: []protocol.ModelInfo{{ID: "model"}}})
	w := &providerWriter{
		conn: conn, queue: make(chan *providerWriteRequest, 1), control: make(chan *providerWriteRequest, 1),
		stop: make(chan struct{}), done: make(chan struct{}),
	}
	p.writer = w
	started := false
	t.Cleanup(func() {
		if !started {
			go w.run()
		}
		r.Disconnect(p.ID)
	})
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	first := r.CommitProviderDrain(p, "reused")
	written := make(chan error, 1)
	go func() { written <- r.WriteProviderDrainAck(ctx, p, "reused", first) }()
	var queued *providerWriteRequest
	select {
	case queued = <-w.control:
	case <-ctx.Done():
		t.Fatal("receipt did not queue")
	}
	second := r.CommitProviderDrain(p, "reused")
	w.control <- queued
	started = true
	go w.run()
	select {
	case err := <-written:
		if !errors.Is(err, errProviderDrainSuperseded) {
			t.Fatalf("queued old receipt crossed newer generation: %v", err)
		}
	case <-ctx.Done():
		t.Fatal("superseded receipt did not finish")
	}
	p.mu.Lock()
	ready := p.drainReady
	p.mu.Unlock()
	if ready {
		t.Fatal("old queued receipt authorized replacement using the reused ID")
	}
	if err := r.WriteProviderDrainAck(ctx, p, "reused", second); err != nil {
		t.Fatal(err)
	}
	if err := p.WriteTextControl(ctx, []byte(`{"type":"after_ack"}`)); err != nil {
		t.Fatal(err)
	}
	_, data, err := peer.Read(ctx)
	if err != nil {
		t.Fatal(err)
	}
	var ack protocol.ProviderDrainMessage
	if err := json.Unmarshal(data, &ack); err != nil || ack.Type != protocol.TypeProviderDrainAck || ack.RequestID != "reused" {
		t.Fatalf("latest receipt not delivered: %s (%v)", data, err)
	}
	_, data, err = peer.Read(ctx)
	if err != nil || string(data) != `{"type":"after_ack"}` {
		t.Fatalf("stale receipt leaked to the wire: %s (%v)", data, err)
	}
}
