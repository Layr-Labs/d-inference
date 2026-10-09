package registry_test

// The native pair relay keeps its own record of a committed session: the
// session table and each member attachment's binding. When the registry
// releases an abandoned quarantine no relay event observes it, so the relay
// must drop that record itself or the surviving member connection (and, at
// the session cap, every member) could never pair again. This drives the real
// relay over in-memory provider writers on a synctest bubble's fake clock.

import (
	"context"
	"encoding/json"
	"fmt"
	"sync"
	"testing"
	"testing/synctest"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/providerwrite"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
	"nhooyr.io/websocket"
)

// memberFrameWriters gives every registered connection the production writer
// over an in-memory transport, and exposes the native pair frames it wrote.
type memberFrameWriters struct {
	mu     sync.Mutex
	frames map[string]chan protocol.NativePairMessage
}

func (w *memberFrameWriters) Open(session string, _ *websocket.Conn) *providerwrite.Writer {
	frames := make(chan protocol.NativePairMessage, 32)
	w.mu.Lock()
	w.frames[session] = frames
	w.mu.Unlock()
	writer := providerwrite.New(&frameTransport{stop: make(chan struct{}), write: func(data []byte) error {
		var m protocol.NativePairMessage
		if json.Unmarshal(data, &m) == nil {
			frames <- m
		}
		return nil
	}}, nil)
	go writer.Run()
	return writer
}

func (w *memberFrameWriters) of(session string) chan protocol.NativePairMessage {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.frames[session]
}

func attachPairMember(t *testing.T, f *nativePairWireFixture, writers *memberFrameWriters, rank int, id, nonce string) {
	t.Helper()
	f.nonces[rank], f.sent[rank] = nonce, 0
	f.p[rank] = pairMember(t, f.r, nil, id, f.serials[rank], nonce)
	f.n[rank], f.frames[rank] = attachAdmitted(t, f.c, f.p[rank], nonce), writers.of(id)
}

func TestNativePairRelayReusesSurvivingMemberAfterAbandonedQuarantine(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		writers := &memberFrameWriters{frames: make(map[string]chan protocol.NativePairMessage)}
		f := newNativePairFixture(t, pairEnvironmentWith(t, production.Dependencies{Connections: writers}))
		var registered []string
		attach := func(rank int, id string, nonce int) {
			attachPairMember(t, f, writers, rank, id, fmt.Sprintf("%064x", nonce))
			registered = append(registered, id)
		}
		defer func() {
			f.c.Close()
			for _, id := range registered {
				f.r.Disconnect(id)
			}
			synctest.Wait()
		}()
		attach(0, "pair-a", 1)
		attach(1, "pair-b", 2)

		f.reserve(t)
		f.prepared(t, 0)
		f.prepared(t, 1)
		var expires time.Time
		for rank := range f.n {
			expires = time.Unix(0, f.read(t, rank, protocol.TypeNativePairOwnerStart).ExpiresAtUnixNano)
		}

		// Member A's control connection drops after commit, exactly as the
		// provider read loop tears it down: relay first, then the registry.
		f.c.Detach(f.n[0])
		f.r.Disconnect(f.p[0].ID)

		// Member B stays connected, is told to stop and reports its cleanup.
		f.read(t, 1, protocol.TypeNativePairCancel)
		if err := f.c.Handle(f.n[1], f.sign(t, 1, protocol.TypeNativePairOwnerReleased, releaseReceipt(f.starts[1]))); err != nil {
			t.Fatalf("surviving member's release receipt: %v", err)
		}

		// A's machine comes back while its departed owner may still be running.
		survivor, survivorSent := f.n[1], f.sent[1]
		attach(0, "pair-a2", 3)
		if _, err := f.c.Reserve(f.n, f.policy.ID, time.Minute); err == nil {
			t.Fatal("device re-reserved while its departed owner may still be running")
		}
		f.c.Detach(f.n[0])
		f.r.Disconnect(f.p[0].ID)

		sleepUntil(expires.Add(ownersMustHaveRetired))

		// The registry released the pair with no relay event. B's original
		// attachment must be reusable with a fresh connection from A's machine.
		attach(0, "pair-a3", 4)
		f.p[1].Mu().Lock()
		f.p[1].LastHeartbeat = time.Now()
		f.p[1].Mu().Unlock()
		trustPairDevice(t, f.p[1], f.serials[1], pairDeviceSEKey(f.serials[1]), &protocol.BackendCapacity{TotalMemoryGB: 64})
		if f.n[1] != survivor || f.sent[1] != survivorSent {
			t.Fatal("fixture replaced the surviving attachment")
		}
		next, err := f.c.Reserve(f.n, f.policy.ID, time.Minute)
		if err != nil {
			t.Fatalf("surviving member could not pair again after the abandoned quarantine was released: %v", err)
		}
		for rank := range f.n {
			f.read(t, rank, protocol.TypeNativePairPrepare)
		}
		next.Cancel()
		ctx, stop := context.WithTimeout(context.Background(), time.Minute)
		defer stop()
		if err := next.WaitControlStopped(ctx); err != nil {
			t.Fatal("replacement relay writers did not join", err)
		}
	})
}
