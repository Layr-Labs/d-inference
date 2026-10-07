package exchange_test

import (
	"context"
	"errors"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/appattest/evidence"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/exchange"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/input"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/observation"
	storagebudget "github.com/eigeninference/d-inference/coordinator/internal/appattest/storage"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/transcript"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
	memorystore "github.com/eigeninference/d-inference/coordinator/store/memory"
)

// Hold both archive transactions separately: returning from Begin must not
// release admission while the deferred Complete is still using the database.
type blockedShadowArchive struct {
	*memorystore.MemoryStore
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
	st := &blockedShadowArchive{MemoryStore: memorystore.NewMemory(store.Config{}), begin: make(chan struct{}, 4), complete: make(chan struct{}, 4), releaseBegin: make(chan struct{}), releaseComplete: make(chan struct{})}
	budget := &storagebudget.Budget{}
	type storageWork struct {
		pipeline  *exchange.Pipeline
		attempt   exchange.Attempt
		integrity *evidence.Integrity
		admission *input.Admission
		inbox     chan protocol.AppAttestShadowPayload
		scope     *storagebudget.Scope
	}
	newSession := func(reason string) storageWork {
		p := newSessionProvider("endpoint", "se")
		integrity, scope := &evidence.Integrity{}, storagebudget.NewScope(budget)
		return storageWork{pipeline: exchange.NewPipeline(exchange.PipelineDependencies{Verification: exchange.Dependencies{Keys: st}, Archive: st, Enrollments: st, Provider: p,
			Budget: budget, Scope: scope, Integrity: integrity}), integrity: integrity, scope: scope,
			attempt:   exchange.Attempt{Challenge: exchange.Challenge{Binding: transcript.Binding{Session: "session"}, Expected: "assertion"}, Rejection: reason},
			admission: &input.Admission{}, inbox: make(chan protocol.AppAttestShadowPayload, 2)}
	}
	reply := protocol.AppAttestShadowPayload{Session: "session", Action: "assertion", Proof: "malformed", Result: "ok"}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	done := make(chan struct{}, 4)
	for i := 0; i < 4; i++ {
		x := newSession("verifier_busy")
		go func() { x.pipeline.Handle(ctx, x.attempt, reply); done <- struct{}{} }()
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
				x.admission.Offer(reply, x.inbox, func() { x.integrity.Drop(nil, nil) })
				x.admission.Close()
				input.DrainStopped(x.inbox, func(ctx context.Context, reply protocol.AppAttestShadowPayload) {
					x.pipeline.Handle(ctx, x.attempt, reply)
				})
			} else {
				x.pipeline.Handle(ctx, x.attempt, reply)
			}
			if x.integrity.Dropped() != 1 {
				t.Errorf("%q: storage refusal was not counted", reason)
			}
		}
		if got := st.begins.Load(); got != 4 {
			t.Errorf("excess sessions reached the archive: %d Begin calls", got)
		}
		// Observations and outbound enrollment must not bypass the same bound.
		x := newSession("")
		fields := observation.Format(observation.Event{Provider: newSessionProvider("endpoint", "se"), Session: "session", Stage: "prepare", Outcome: "observed"}).Fields
		observation.Record(x.scope, st, "p1", "prepare", "observed", fields)
		sent := exchange.Send(ctx, exchange.SendDependencies{Enrollments: st, Scope: x.scope, Integrity: x.integrity, Transport: newSessionProvider("endpoint", "se").EnqueueText},
			transcript.Binding{Session: "session", ProtocolVersion: 3}, &store.AppAttestShadowKey{KeyID: "key"}, "attest")
		observation.Record(x.scope, st, "p1", "attest", sent.Outcome, fields)
		if sent.Sent || st.events.Load() != 0 || st.enrollments.Load() != 0 {
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
	fields := observation.Format(observation.Event{Provider: newSessionProvider("endpoint", "se"), Session: "session", Stage: "prepare", Outcome: "observed"}).Fields
	observation.Record(x.scope, st, "p1", "prepare", "observed", fields)
	if st.events.Load() != 1 {
		t.Error("storage admission did not recover after completion")
	}
}
