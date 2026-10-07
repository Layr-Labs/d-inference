package registry_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/providerdrain"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestLifecycleDrainFencesHeldReservationUntilDisconnect(t *testing.T) {
	conn, _ := testWebSocketPair(t)
	w := newWriterFixture(1, 1, conn, nil, nil, nil)
	go w.Run()
	t.Cleanup(w.Close)
	authorities := make(providerDrainAuthorities)
	var planner *production.ModelLoadPlanner
	r := production.NewWithDependencies(testLogger(), production.Dependencies{
		Connections: retainedWriterFactory{writer: w.Writer}, ProviderDrains: authorities.bind,
		ModelLoadPlanning: func(actual *production.ModelLoadPlanner) production.ModelLoadPlanning {
			planner = actual
			return actual
		},
	})
	p := registerDrainStateProvider(t, r, "lifecycle", 100)
	pr := drainStateRequest("reserved-before-drain")
	if r.ReserveProvider(drainStateTestModel, pr) != p {
		t.Fatal("reservation failed")
	}
	if r.CommitProviderDrain(p, "stop") == 0 {
		t.Fatal("drain not committed")
	}
	// A delayed pre-drain idle heartbeat and a missed heartbeat TTL cannot
	// resurrect a process whose operator has explicitly stopped admission.
	r.Heartbeat(p.ID, drainStateHeartbeat("idle"))
	p.Mu().Lock()
	authorities[p.ID].Mark(time.Now().Add(-providerdrain.TTL - time.Hour))
	p.Mu().Unlock()
	if !r.ProviderDraining(p.ID) {
		t.Fatal("lifecycle drain expired")
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if _, err := p.WriteInferenceTextDeferred(ctx, pr, func(time.Time) ([]byte, error) {
		return []byte(`{"type":"inference_request"}`), nil
	}, nil); !errors.Is(err, production.ErrProviderDraining) {
		t.Fatalf("reserved frame crossed drain boundary: %v", err)
	}
	if got := r.ReserveProvider(drainStateTestModel, drainStateRequest("late")); got != nil {
		t.Fatal("new request routed")
	}
	if err := r.SendLoadModel(p.ID, drainStateTestModel); err == nil {
		t.Fatal("load command crossed drain")
	}
	if err := r.SendPrefetchModel(p.ID, drainStateTestModel, 1); err == nil {
		t.Fatal("prefetch crossed drain")
	}
	preparation := planner.Prepare()
	_, eligible := preparation.Candidate(p.ID, drainStateTestModel, time.Now())
	preparation.Close()
	if eligible {
		t.Fatal("cold load planner selected draining provider")
	}
	r.Disconnect(p.ID)
	if r.CommitProviderDrain(p, "stale") != 0 {
		t.Fatal("stale connection committed a drain")
	}
	registerDrainStateProvider(t, r, p.ID, 100)
	if r.ProviderDraining(p.ID) {
		t.Fatal("drain leaked onto new connection")
	}
}
