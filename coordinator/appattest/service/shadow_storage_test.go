package service

import (
	"context"
	"errors"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Hold both archive transactions separately: returning from Begin must not
// release admission while the deferred Complete is still using the database.
type blockedShadowArchive struct {
	*store.MemoryStore
	begin, complete                          chan struct{}
	releaseBegin, releaseComplete            chan struct{}
	begins, completions, events, enrollments atomic.Int32
}

func (s *blockedShadowArchive) BeginAppAttestEvidence(ctx context.Context, _ store.AppAttestEvidence) error {
	if s.begins.Add(1) > 4 {
		return errors.New("shared pool exhausted")
	}
	s.begin <- struct{}{}
	select {
	case <-s.releaseBegin:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (s *blockedShadowArchive) CompleteAppAttestEvidence(ctx context.Context, _ string, d store.AppAttestDecision) (string, error) {
	s.completions.Add(1)
	s.complete <- struct{}{}
	select {
	case <-s.releaseComplete:
		return d.Outcome, nil
	case <-ctx.Done():
		return "", ctx.Err()
	}
}

func (s *blockedShadowArchive) RecordAppAttestEvent(context.Context, store.AppAttestEvent) error {
	s.events.Add(1)
	return nil
}

func (s *blockedShadowArchive) SaveAppAttestEnrollment(context.Context, store.AppAttestEnrollment) error {
	s.enrollments.Add(1)
	return errors.New("no enrollment expected under saturation")
}

func TestAppAttestStorageBoundsBusyAndStoppedSessionsThroughCompletion(t *testing.T) {
	st := &blockedShadowArchive{MemoryStore: store.NewMemory(store.Config{}), begin: make(chan struct{}, 4), complete: make(chan struct{}, 4), releaseBegin: make(chan struct{}), releaseComplete: make(chan struct{})}
	s := &Service{store: st}
	newSession := func(reason string) *Session {
		p := newSessionProvider("endpoint", "se")
		return &Session{s: s, provider: p, store: st, archive: st, id: "session", expected: "assertion", rejectReason: reason, in: make(chan protocol.AppAttestShadowPayload, 2)}
	}
	reply := protocol.AppAttestShadowPayload{Session: "session", Action: "assertion", Proof: "malformed", Result: "ok"}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	done := make(chan struct{}, 4)
	for i := 0; i < 4; i++ {
		x := newSession("verifier_busy")
		go func() { x.handle(ctx, reply); done <- struct{}{} }()
	}
	waitFour := func(ch <-chan struct{}) {
		t.Helper()
		for i := 0; i < 4; i++ {
			select {
			case <-ch:
			case <-ctx.Done():
				t.Fatal("archive workers did not reach expected phase")
			}
		}
	}
	waitFour(st.begin)
	checkExcess := func() {
		t.Helper()
		for _, reason := range []string{"", "verifier_busy", "session_stopped"} {
			x := newSession(reason)
			if reason == "session_stopped" {
				x.offer(reply)
				x.closeAndArchivePending()
			} else {
				x.handle(ctx, reply)
			}
			if x.dropped.Load() != 1 {
				t.Errorf("%q: storage refusal was not counted", reason)
			}
		}
		if got := st.begins.Load(); got != 4 {
			t.Errorf("excess sessions reached the archive: %d Begin calls", got)
		}
		// Observations and outbound enrollment must not bypass the same bound.
		x := newSession("")
		x.inventory = &machineInventorySession{store: st}
		x.observe("prepare", "observed", nil)
		x.protocolVersion = 2
		x.key = &store.AppAttestShadowKey{KeyID: "key"}
		if x.send(ctx, "attest") || st.events.Load() != 0 || st.enrollments.Load() != 0 {
			t.Error("standalone event/enrollment bypassed saturated archive admission")
		}
	}
	checkExcess()
	close(st.releaseBegin)
	waitFour(st.complete)
	checkExcess()
	close(st.releaseComplete)
	waitFour(done)
	if st.completions.Load() != 4 {
		t.Fatal("accepted evidence was not completed")
	}
	// A refused session does not consume a permit; completed work releases it.
	x := newSession("")
	x.inventory = &machineInventorySession{store: st}
	x.observe("prepare", "observed", nil)
	if st.events.Load() != 1 {
		t.Error("storage admission did not recover after completion")
	}
}
