package authorization_test

import (
	"context"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/appattest/authorization"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/evidence"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestDroppedInputAndGrantAreSerialized(t *testing.T) {
	f, p, record, state := newAuthorizationFixture(t, true)
	a := f.controller
	a.Remember(p, record)
	if !a.Apply(p, record, state, time.Now()) {
		t.Fatal("initial grant")
	}
	integrity := &evidence.Integrity{}
	entered, releasePolicy, applied := make(chan struct{}), make(chan struct{}), make(chan struct{})
	policy := *f.policy()
	approve := policy.Approves
	policy.Approves = func(p *registry.Provider, status *protocol.AppAttestStatus) bool {
		close(entered)
		<-releasePolicy
		return approve(p, status)
	}
	f.policy = func() *authorization.ReleasePolicy { return &policy }
	go func() { a.Apply(p, record, state, time.Now()); close(applied) }()
	<-entered // The real policy decision holds the grant critical section.
	started, done := make(chan struct{}), make(chan struct{})
	go func() {
		close(started)
		integrity.Drop(a, p)
		close(done)
	}()
	<-started
	select {
	case <-done:
		close(releasePolicy)
		<-applied
		t.Fatal("drop completed before the grant lock was released")
	case <-time.After(10 * time.Millisecond):
	}
	if integrity.Dropped() != 0 {
		close(releasePolicy)
		<-applied
		t.Fatal("gap counter advanced outside the grant lock")
	}
	close(releasePolicy)
	<-applied
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("drop did not complete after the grant lock was released")
	}
	if integrity.Dropped() != 1 || a.Current(p) != nil {
		t.Fatal("drop did not remove the previous proof")
	}
	if _, ok := f.registry.ProviderServingAuthorization(p); ok {
		t.Fatal("drop retained an active lease")
	}
	f.readiness = &authorizationBatchStore{Store: f.store, state: map[string]store.AppAttestReadiness{"credential": state}}
	a.Refresh(context.Background())
	if _, ok := f.registry.ProviderServingAuthorization(p); ok {
		t.Fatal("refresh recreated a grant after the proof was forgotten")
	}
}
