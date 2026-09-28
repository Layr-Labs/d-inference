package registry

import (
	"context"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestNativePairPendingCancelPublicationPrecedesConnectionReuse(t *testing.T) {
	f := newNativePairFixture(t)
	s := f.reserve(t)

	// Exercise the actual cancellation split without a scheduler sleep or an
	// injected callback. Queued work wakes both real relay workers, which must
	// see stopped and join while the original cancel publication is paused.
	f.c.mu.Lock()
	for rank := range f.n {
		if e := f.c.enqueueLocked(s, rank, protocol.TypeNativePairBinding, []byte("queued-before-cancel")); e != nil {
			f.c.mu.Unlock()
			t.Fatal(e)
		}
	}
	frames, publish := f.c.beginCancellationLocked(s)
	f.c.mu.Unlock()
	if !publish {
		t.Fatal("first cancellation did not claim publication")
	}
	published := false
	defer func() {
		if !published {
			f.c.publishCancellation(s, frames)
		}
	}()

	ctx, stop := context.WithTimeout(context.Background(), time.Second)
	defer stop()
	if e := s.WaitControlStopped(ctx); e != nil {
		t.Fatal("workers did not reach the publication gap", e)
	}
	if f.phase(s) != VerifiedPairReleased {
		t.Fatal("never-started pending pair retained native ownership")
	}
	f.c.mu.Lock()
	held := s.writersEnded && !s.cancellationPublished && f.c.sessions[s.membership.Epoch] == s
	for _, n := range f.n {
		held = held && n.session == s
	}
	_, duplicate := f.c.beginCancellationLocked(s)
	f.c.mu.Unlock()
	if !held || duplicate {
		t.Fatal("joined workers lost the original publication obligation")
	}
	if _, e := f.c.Reserve(f.n, f.policy.ID, time.Minute); e == nil {
		t.Fatal("new grant overtook unpublished old cancellation")
	}
	for _, ch := range f.frames {
		select {
		case <-ch:
			t.Fatal("stopped relay published queued work")
		default:
		}
	}

	f.c.publishCancellation(s, frames)
	published = true
	f.c.mu.Lock()
	released := s.cancellationPublished && f.c.sessions[s.membership.Epoch] == nil
	for _, n := range f.n {
		released = released && n.session == nil
	}
	f.c.mu.Unlock()
	if !released {
		t.Fatal("completed publication did not release the control attachment")
	}
	// Start the replacement before reading either socket, so the assertions
	// check the actual priority writer's FIFO, not just internal sequence values.
	next, e := f.c.Reserve(f.n, f.policy.ID, time.Minute)
	if e != nil {
		t.Fatal(e)
	}
	for rank := range f.n {
		oldCancel := f.read(t, rank, protocol.TypeNativePairCancel)
		newPrepare := f.read(t, rank, protocol.TypeNativePairPrepare)
		if oldCancel.Epoch == newPrepare.Epoch || oldCancel.Generation == newPrepare.Generation || oldCancel.Sequence >= newPrepare.Sequence {
			t.Fatal("replacement prepare did not follow the original cancel")
		}
	}
	f.c.Cancel(s)
	if f.phase(next) != VerifiedPairPending {
		t.Fatal("old cancellation changed replacement grant")
	}
}
