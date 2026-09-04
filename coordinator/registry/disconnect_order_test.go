package registry

import (
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// TestDisconnectFlushesPendingBeforeQueueDrain pins the teardown order inside
// Disconnect: the in-flight requests' 502 flush lands BEFORE the queue drain
// runs its reservation scan (one ReserveProviderEx per queued waiter — 10-37 ms
// per pass under queueing on the 2026-08-31 fleet), so their failovers are not
// delayed behind the drain, and the drained waiter is placed on the surviving
// provider, never the dying one (it has already left the registry map).
func TestDisconnectFlushesPendingBeforeQueueDrain(t *testing.T) {
	reg := New(testLogger())
	const model = "mlx-community/Qwen3.5-9B-Instruct-4bit"
	var providers []*Provider
	for _, id := range []string{"dying", "survivor"} {
		p := reg.Register(id, nil, testRegisterMessage())
		p.TrustLevel = TrustHardware
		p.LastChallengeVerified = time.Now()
		p.ChallengeVerifiedSIP = true
		providers = append(providers, p)
	}
	dying := providers[0]

	pr := &PendingRequest{
		RequestID: "req-inflight",
		Model:     model,
		ErrorCh:   make(chan protocol.InferenceErrorMessage, 1),
	}
	dying.AddPending(pr)
	qr := &QueuedRequest{
		RequestID:  "req-queued",
		Model:      model,
		ResponseCh: make(chan *Provider, 1),
	}
	reg.Queue().Enqueue(qr)

	var scans atomic.Int32
	var flushedBeforeFirstScan atomic.Bool
	reg.reservationAfterScan = func(string) {
		if scans.Add(1) == 1 {
			flushedBeforeFirstScan.Store(len(pr.ErrorCh) == 1)
		}
	}

	reg.Disconnect(dying.ID)

	if scans.Load() == 0 {
		t.Fatal("Disconnect did not drain the queue (no reservation scan ran)")
	}
	if !flushedBeforeFirstScan.Load() {
		t.Fatal("queue drain scanned before the pending 502 flush: in-flight failovers wait behind the drain")
	}
	select {
	case msg := <-pr.ErrorCh:
		if msg.StatusCode != 502 || msg.Error != "provider disconnected" {
			t.Fatalf("flushed terminal = %d %q, want 502 \"provider disconnected\"", msg.StatusCode, msg.Error)
		}
	default:
		t.Fatal("pending request was not flushed")
	}
	select {
	case assigned := <-qr.ResponseCh:
		if assigned == nil || assigned.ID != "survivor" {
			t.Fatalf("queued waiter assigned to %v, want the surviving provider", assigned)
		}
	case <-time.After(time.Second):
		t.Fatal("queued waiter was not drained onto the surviving provider")
	}
}
