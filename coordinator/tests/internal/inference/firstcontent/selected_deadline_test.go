package firstcontent_test

import (
	"context"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/firstcontent"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestSelectedFirstContentWriteKeepsBoundCutoff(t *testing.T) {
	received := time.Now().Add(-time.Second)
	bound := received.Add(5 * time.Second)
	pr := &registry.PendingRequest{FirstContentDeadline: bound}
	ctx, cancel := firstcontent.FirstTokenWriteContextForPending(context.Background(), received, time.Minute, pr)
	defer cancel()
	if got, ok := ctx.Deadline(); !ok || !got.Equal(bound) {
		t.Fatalf("writer cutoff = %v/%v, want selected %v", got, ok, bound)
	}
	callerCutoff := received.Add(2 * time.Second)
	caller, cancelCaller := context.WithDeadline(context.Background(), callerCutoff)
	defer cancelCaller()
	ctx, cancel = firstcontent.FirstTokenWriteContextForPending(caller, received, time.Minute, pr)
	defer cancel()
	if got, ok := ctx.Deadline(); !ok || !got.Equal(callerCutoff) {
		t.Fatalf("caller cutoff = %v/%v, want %v", got, ok, callerCutoff)
	}
	ctx, cancel = firstcontent.FirstTokenWriteContextForPending(context.Background(), received, 0, pr)
	defer cancel()
	if _, ok := ctx.Deadline(); ok {
		t.Fatal("an account exemption acquired a first-content writer clock")
	}
}

func TestSelectedFirstContentSpeculationUsesBoundIngress(t *testing.T) {
	for _, tc := range []struct {
		name        string
		receivedAgo time.Duration
		advance     time.Duration
		want        time.Duration
	}{
		{"shorter-candidate-halfway", 4 * time.Second, 15 * time.Second, time.Second},
		{"earlier-quote-advance", 4 * time.Second, 4500 * time.Millisecond, 500 * time.Millisecond},
		{"selected-halfway-already-passed", 6 * time.Second, 15 * time.Second, 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			received := time.Now().Add(-tc.receivedAgo)
			pr := &registry.PendingRequest{FirstContentDeadline: received.Add(10 * time.Second), Timing: &registry.RequestTiming{ReceivedAt: received}}
			clock := firstcontent.NewClock(received, 30*time.Second, tc.advance).ForPending(pr)
			got := clock.SpeculativeWait()
			if got > tc.want || got < max(0, tc.want-200*time.Millisecond) {
				t.Fatalf("bound speculative wait = %v, want %v from original ingress", got, tc.want)
			}
			if !pr.FirstContentDeadline.Equal(received.Add(10 * time.Second)) {
				t.Fatal("hedge calculation changed the selected cutoff")
			}
		})
	}
}
