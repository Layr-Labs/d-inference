package registry_test

import (
	"context"
	"encoding/json"
	"errors"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/providerdrain"
	providerwrite "github.com/eigeninference/d-inference/coordinator/internal/registry/providerwrite"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestQueuedDrainAckCannotSettleReusedIDGeneration(t *testing.T) {
	conn, peer := testWebSocketPair(t)
	w := newWriterFixture(1, 1, conn, nil, nil, nil)
	authorities := make(providerDrainAuthorities)
	r := production.NewWithDependencies(testLogger(), production.Dependencies{
		Connections: retainedWriterFactory{writer: w.Writer}, ProviderDrains: authorities.bind,
	})
	p := r.Register("session", nil, &protocol.RegisterMessage{Models: []protocol.ModelInfo{{ID: "model"}}})
	started := false
	t.Cleanup(func() {
		if !started {
			go w.Run()
		}
		r.Disconnect(p.ID)
	})
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	first := r.CommitProviderDrain(p, "reused")
	written := make(chan error, 1)
	go func() { written <- r.WriteProviderDrainAck(ctx, p, "reused", first) }()
	var queued *providerwrite.Request
	select {
	case queued = <-w.lanes.Receive(true):
	case <-ctx.Done():
		t.Fatal("receipt did not queue")
	}
	second := r.CommitProviderDrain(p, "reused")
	w.offer(queued, true)
	started = true
	go w.Run()
	select {
	case err := <-written:
		if !errors.Is(err, providerdrain.ErrSuperseded) {
			t.Fatalf("queued old receipt crossed newer generation: %v", err)
		}
	case <-ctx.Done():
		t.Fatal("superseded receipt did not finish")
	}
	p.Mu().Lock()
	ready := authorities[p.ID].CanReplace("reused")
	p.Mu().Unlock()
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
