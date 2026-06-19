package api

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestZombieStreamCancellerThrottle(t *testing.T) {
	z := newZombieStreamCanceller()
	t0 := time.Now()

	if !z.record("req-1", t0).sendCancel {
		t.Fatal("first chunk for an unknown request should cancel")
	}
	if z.record("req-1", t0.Add(time.Second)).sendCancel {
		t.Fatal("second chunk within the throttle window should NOT re-cancel")
	}
	// A different request is independent.
	if !z.record("req-2", t0.Add(time.Second)).sendCancel {
		t.Fatal("a different unknown request should cancel")
	}
	// After the throttle window, the same request cancels again.
	if !z.record("req-1", t0.Add(zombieCancelThrottle+time.Second)).sendCancel {
		t.Fatal("after the throttle window the same request should cancel again")
	}
}

func TestZombieStreamCancellerEscalatesAfterRepeatedCancels(t *testing.T) {
	z := newZombieStreamCanceller()
	t0 := time.Now()

	first := z.record("req-1", t0)
	if !first.sendCancel || first.forceReconnect {
		t.Fatalf("first abandoned chunk action = %+v, want cancel without reconnect", first)
	}

	second := z.record("req-1", t0.Add(zombieCancelThrottle+time.Second))
	if !second.sendCancel || second.forceReconnect {
		t.Fatalf("second abandoned chunk action = %+v, want cancel without reconnect", second)
	}

	third := z.record("req-1", t0.Add(2*zombieCancelThrottle+2*time.Second))
	if !third.sendCancel || !third.forceReconnect {
		t.Fatalf("third abandoned chunk action = %+v, want cancel and reconnect", third)
	}
}

func TestZombieStreamCancellerSweepBounded(t *testing.T) {
	z := newZombieStreamCanceller()
	base := time.Now()
	for i := 0; i < 5000; i++ {
		z.record(string(rune('a'+i%26))+string(rune('0'+i%10))+string(rune(i)), base)
	}
	z.mu.Lock()
	n := len(z.sent)
	z.mu.Unlock()
	if n > zombieCancelMaxEntries {
		t.Fatalf("map not bounded during fresh burst: %d entries", n)
	}

	// All those are expired relative to a far-future call, which triggers the sweep.
	z.record("trigger", base.Add(zombieCancelThrottle+time.Hour))
	z.mu.Lock()
	n = len(z.sent)
	z.mu.Unlock()
	if n > zombieCancelMaxEntries {
		t.Fatalf("map not bounded after sweep: %d entries", n)
	}
}

func TestDeliverChunkWithBackpressureDelivers(t *testing.T) {
	pr := &registry.PendingRequest{ChunkCh: make(chan string, 1)}

	delivered, closed := deliverChunkWithBackpressure(pr, "chunk")
	if !delivered || closed {
		t.Fatalf("deliverChunkWithBackpressure = delivered:%v closed:%v, want delivered open", delivered, closed)
	}
	if got := <-pr.ChunkCh; got != "chunk" {
		t.Fatalf("delivered chunk = %q, want chunk", got)
	}
}

func TestDeliverChunkWithBackpressureFailsInsteadOfDropping(t *testing.T) {
	pr := &registry.PendingRequest{ChunkCh: make(chan string)}

	delivered, closed := deliverChunkWithBackpressure(pr, "chunk")
	if delivered || closed {
		t.Fatalf("deliverChunkWithBackpressure = delivered:%v closed:%v, want backpressure failure", delivered, closed)
	}
	select {
	case got := <-pr.ChunkCh:
		t.Fatalf("chunk was delivered despite backpressure: %q", got)
	default:
	}
}

func TestDeliverChunkWithBackpressureDetectsClosedChannel(t *testing.T) {
	ch := make(chan string)
	close(ch)
	pr := &registry.PendingRequest{ChunkCh: ch}

	delivered, closed := deliverChunkWithBackpressure(pr, "chunk")
	if delivered || !closed {
		t.Fatalf("deliverChunkWithBackpressure = delivered:%v closed:%v, want closed", delivered, closed)
	}
}

func TestIsModelLoadFailure(t *testing.T) {
	cases := []struct {
		err  string
		want bool
	}{
		{"insufficient memory to load model 'gemma-4-26b-qat-4bit'", true},
		{"model load failed: the operation couldn’t be completed. (providercore.inferenceerror error 0.)", true},
		{"request cancelled", false},
		{"token_budget_exhausted: request queue full", false},
		{"invalid request body", false},
	}
	for _, c := range cases {
		if got := isModelLoadFailure(c.err); got != c.want {
			t.Fatalf("isModelLoadFailure(%q) = %v, want %v", c.err, got, c.want)
		}
	}
}
