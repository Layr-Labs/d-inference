package registry

import (
	"context"
	"io"
	"log/slog"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// The sweep summary is emitted after its read scan and before any removals,
// providing a deterministic barrier without adding hooks to the registry.
type evictionBarrierHandler struct {
	slog.Handler
	afterScan func()
}

func (h evictionBarrierHandler) Handle(ctx context.Context, record slog.Record) error {
	if record.Message == "eviction sweep" {
		h.afterScan()
	}
	return h.Handler.Handle(ctx, record)
}

func TestEvictStaleRevalidatesRecoveryAndSessionIdentity(t *testing.T) {
	for _, replacement := range []bool{false, true} {
		name := "heartbeat-recovery"
		if replacement {
			name = "replacement-with-same-id"
		}
		t.Run(name, func(t *testing.T) {
			scanned, resume := make(chan struct{}), make(chan struct{})
			release := sync.OnceFunc(func() { close(resume) })
			defer release()
			armed := false
			logger := slog.New(evictionBarrierHandler{
				Handler: slog.NewTextHandler(io.Discard, nil),
				afterScan: func() {
					if armed {
						close(scanned)
						<-resume
					}
				},
			})
			r := New(logger)
			p := registerProviderWithModel(r, "eviction-revalidate", aliasQAT)
			oldHeartbeat := time.Now().Add(-5 * time.Minute)
			p.mu.Lock()
			p.LastHeartbeat = oldHeartbeat
			p.mu.Unlock()
			const timeout = 90 * time.Second
			r.evictStale(timeout) // First strike.
			armed = true
			done := make(chan struct{})
			go func() {
				r.evictStale(timeout) // Second strike; pause before removal.
				close(done)
			}()
			select {
			case <-scanned:
			case <-time.After(2 * time.Second):
				t.Fatal("second stale scan did not reach the eviction barrier")
			}

			want := p
			if replacement {
				r.Disconnect(p.ID)
				want = registerProviderWithModel(r, p.ID, aliasQAT)
				// Keep the replacement stale too, so preserving it proves the
				// identity check independently of the freshness check.
				want.mu.Lock()
				want.LastHeartbeat = oldHeartbeat
				want.mu.Unlock()
			} else {
				r.Heartbeat(p.ID, &protocol.HeartbeatMessage{Type: protocol.TypeHeartbeat, Status: "idle"})
			}
			release()
			select {
			case <-done:
			case <-time.After(2 * time.Second):
				t.Fatal("eviction did not finish after releasing the barrier")
			}
			if got := r.GetProvider(p.ID); got != want {
				t.Fatal("a stale scan disconnected the recovered or replacement session")
			}
			if r.ProviderCount() != 1 {
				t.Fatalf("provider count = %d, want 1", r.ProviderCount())
			}
			assertModelIndexConsistent(t, r)
		})
	}
}
