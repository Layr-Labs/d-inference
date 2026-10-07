package registry_test

import (
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/deadline"

	production "github.com/eigeninference/d-inference/coordinator/registry"
)

type deadlineOperation struct {
	kind string
	at   time.Time
}

// Observe actual operation inputs, never the policy's private clock state.
type deadlinePostureObserver struct {
	deadline.PosturePolicy
	mu         sync.Mutex
	operations []deadlineOperation
}

func (o *deadlinePostureObserver) record(kind string, at time.Time) {
	o.mu.Lock()
	defer o.mu.Unlock()
	o.operations = append(o.operations, deadlineOperation{kind: kind, at: at})
}

func (o *deadlinePostureObserver) Activity(now time.Time) {
	o.PosturePolicy.Activity(now)
	o.record("activity", now)
}

func (o *deadlinePostureObserver) InvalidatePosture(now time.Time) {
	o.PosturePolicy.InvalidatePosture(now)
	o.record("posture", now)
}

func (o *deadlinePostureObserver) Reset() {
	o.PosturePolicy.Reset()
	o.record("reset", time.Time{})
}

func (o *deadlinePostureObserver) last(kind string) time.Time {
	o.mu.Lock()
	defer o.mu.Unlock()
	for i := len(o.operations) - 1; i >= 0; i-- {
		operation := o.operations[i]
		if operation.kind == "reset" {
			return time.Time{}
		}
		if operation.kind == kind {
			return operation.at
		}
	}
	return time.Time{}
}

func (o *deadlinePostureObserver) lastActivity() time.Time { return o.last("activity") }

func (o *deadlinePostureObserver) lastInvalidation() time.Time { return o.last("posture") }

type deadlineObservations struct {
	mu        sync.Mutex
	providers map[string]*deadlinePostureObserver
}

func newDeadlineObservations() *deadlineObservations {
	return &deadlineObservations{providers: make(map[string]*deadlinePostureObserver)}
}

func (o *deadlineObservations) configure(deps *production.Dependencies) {
	deps.DeadlinePosture = func(id string, actual *deadline.Posture) deadline.PosturePolicy {
		observer := &deadlinePostureObserver{PosturePolicy: actual}
		o.mu.Lock()
		o.providers[id] = observer
		o.mu.Unlock()
		return observer
	}
}

func (o *deadlineObservations) forProvider(id string) *deadlinePostureObserver {
	o.mu.Lock()
	defer o.mu.Unlock()
	return o.providers[id]
}
