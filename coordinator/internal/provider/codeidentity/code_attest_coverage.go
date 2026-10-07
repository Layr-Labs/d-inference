package codeidentity

import (
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *Controller,

) SweepCodeAttestCoverage() {
	if s == nil || s.registry == nil {
		return
	}
	rows := []store.CodeAttestation{}
	s.registry.ForEachProvider(func(p *registry.Provider) {
		if r, ok := s.CodeCoverageObservation(p, false); ok {
			rows = append(rows, r)
		}
	})
	s.PersistCodeCoverage(rows)
	if s.codeAttestThrottle != nil && s.observation != nil {
		usage := s.codeAttestThrottle.Usage()
		s.observation.Gauge("code_attest.reservation_locks", float64(usage.ReservationLocks), nil)
		s.observation.Gauge("code_attest.loop_generations", float64(usage.LoopGenerations), nil)
		s.observation.Gauge("code_attest.loop_tokens", float64(usage.LoopTokens), nil)
		s.observation.Gauge("code_attest.loop_generation", float64(usage.LoopGeneration), nil)
		s.observation.Gauge("code_attest.local_budgets", float64(usage.LocalBudgets), nil)
		s.observation.Gauge("code_attest.durable_budgets", float64(usage.DurableBudgets), nil)
	}
}

func (s *Controller,

) StopCodeAttestCoverageForProvider(providerID string) {
	if s == nil || s.registry == nil {
		return
	}
	if r, ok := s.CodeCoverageObservation(s.registry.GetProvider(providerID), true); ok {
		s.PersistCodeCoverage([]store.CodeAttestation{r})
	}
}
