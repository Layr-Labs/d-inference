package dispatch

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestReleaseUnsentDispatchResolvesEmptyCompletionAndRemovesPending(t *testing.T) {
	c := newTestController(t)
	p := c.deps.Registry().Register("unsent", nil, &protocol.RegisterMessage{})
	pr := &registry.PendingRequest{RequestID: "unsent-request", ProviderID: p.ID}
	pr.EnableSpeculativeEmptyCompletionArbitration()
	p.AddPending(pr)
	t.Cleanup(func() { pr.ResolveSpeculativeEmptyCompletion(false) })
	decision := make(chan [2]bool, 1)
	go func() {
		accepted, waited := pr.AwaitSpeculativeEmptyCompletionDecision()
		decision <- [2]bool{accepted, waited}
	}()
	c.releaseUnsentDispatch(p, pr)
	select {
	case got := <-decision:
		if got != [2]bool{false, true} {
			t.Fatalf("unsent completion decision=%v, want rejected after arbitration", got)
		}
	case <-time.After(time.Second):
		t.Fatal("unsent cleanup stranded the completion reader")
	}
	if p.GetPending(pr.RequestID) != nil {
		t.Fatal("unsent cleanup left pending state behind")
	}
	c.releaseUnsentDispatch(nil, pr)
	c.releaseUnsentDispatch(p, nil)
}
