package verification

import (
	"github.com/eigeninference/d-inference/coordinator/store"
	"slices"
)

// Status is a detached operational view. It carries counts, not ownership maps
// or cancellation handles, so metric callbacks never run under the queue lock.
type Status struct {
	Jobs, Bindings, UDIDs int
	Generation            uint64
	Active                map[store.VerificationTaskKind]int
	Depth                 map[store.VerificationTaskKind]map[store.VerificationPriority]int
}

func (q *Queue) Status() Status {
	q.mu.Lock()
	defer q.mu.Unlock()
	s := Status{Jobs: len(q.jobs), Bindings: len(q.bindings), UDIDs: len(q.byUDID), Generation: q.generation.Load(), Active: make(map[store.VerificationTaskKind]int), Depth: make(map[store.VerificationTaskKind]map[store.VerificationPriority]int)}
	for kind, n := range q.active {
		s.Active[kind] = n
	}
	for _, job := range q.jobs {
		if job.Running {
			continue
		}
		if s.Depth[job.Record.Kind] == nil {
			s.Depth[job.Record.Kind] = make(map[store.VerificationPriority]int)
		}
		s.Depth[job.Record.Kind][job.Record.Priority]++
	}
	return s
}

// Candidate is the detached registration-bound work inspected before durable
// claim I/O. Dispatch revalidates ownership after the claim returns.
type Candidate struct {
	Record     store.VerificationJob
	Binding    Binding
	BindingGen uint64
	Running    bool
}

func (q *Queue) Candidate(key string) *Candidate {
	q.mu.Lock()
	defer q.mu.Unlock()
	j := q.jobs[key]
	if j == nil {
		return nil
	}
	c := &Candidate{Record: j.Record, BindingGen: j.BindingGen, Running: j.Running}
	if j.Record.ClaimExpiresAt != nil {
		expiry := *j.Record.ClaimExpiresAt
		c.Record.ClaimExpiresAt = &expiry
	}
	if b := q.bindings[j.Record.SEPubKey]; b != nil {
		c.Binding = *b
		c.Binding.Attestation.RuntimeCapabilities = slices.Clone(b.Attestation.RuntimeCapabilities)
	}
	return c
}

func (q *Queue) Configuration() Config { return q.config }

// DueScanCursor is the next bounded durable page the dispatcher will inspect.
func (q *Queue) DueScanCursor() int {
	q.mu.Lock()
	defer q.mu.Unlock()
	return q.dueScanOffset
}
