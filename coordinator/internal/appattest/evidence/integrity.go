package evidence

import (
	"sync/atomic"

	"github.com/eigeninference/d-inference/coordinator/internal/appattest/authorization"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// Integrity retains the cumulative audit independently of challenge-local
// completeness. A fresh proof may recover a historical gap, never absorb a
// later input loss into the proof that was already queued.
type Integrity struct {
	dropped  atomic.Uint64
	baseline uint64
	archived bool
}

func (i *Integrity) Dropped() uint64  { return i.dropped.Load() }
func (i *Integrity) Baseline() uint64 { return i.baseline }
func (i *Integrity) Archived() bool   { return i.archived }
func (i *Integrity) Complete() bool   { return i.archived && i.Dropped() == i.baseline }

func (i *Integrity) BeginChallenge() {
	i.baseline = i.Dropped()
	i.archived = false
}

func (i *Integrity) RecordCommit(action, outcome string) {
	if action == "assertion" && outcome == "verified" {
		i.archived = true
	}
}

// Drop advances the audit under the controller's final-grant critical section.
// Without serving enabled it still retains the same cumulative loss audit.
func (i *Integrity) Drop(controller *authorization.Controller, p *registry.Provider) {
	if controller != nil && p != nil {
		controller.Drop(p, &i.dropped)
	} else {
		i.dropped.Add(1)
	}
}
