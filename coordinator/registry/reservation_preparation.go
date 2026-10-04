package registry

import (
	"sync/atomic"
	"time"
)

// ReservationPreparation is the shared scan stage preceding serialized commit.
// A decorator must return the same prepared result, closing it if it abandons
// the handoff. Preparation holds the registry read lease; commit revalidates
// under Registry -> Provider -> gates -> gate locking exactly as before.
type ReservationPreparation interface {
	Prepare(model string, pending *PendingRequest, excludeIDs ...string) *PreparedReservation
}

type ReservationPlanner struct{ registry *Registry }

func (p *ReservationPlanner) scan(model string, pending *PendingRequest, excludeIDs ...string) ReservationSelection {
	return p.registry.scanProviderReservation(model, pending, excludeIDs...)
}

func (p *ReservationPlanner) Prepare(model string, pending *PendingRequest, excludeIDs ...string) *PreparedReservation {
	return p.registry.prepareProviderReservation(model, pending, excludeIDs...)
}

// PreparedReservation owns one immutable candidate scan and its read lease.
// It exposes no live registry, provider, gate or candidate state. The reservation
// owner consumes it once; an adapter abandoning preparation must Close it.
type PreparedReservation struct {
	registry *Registry
	scan     providerReservationScan
	lockedAt time.Time
	closed   atomic.Bool
}

func (p *PreparedReservation) Close() {
	if p == nil {
		return
	}
	if p.closed.CompareAndSwap(false, true) {
		p.registry.mu.RUnlock()
	}
}

// Finish transfers the selected work out of the scan phase and releases its
// read lease. Commit always revalidates this selection against current state.
func (p *PreparedReservation) Finish() ReservationSelection {
	p.scan.scanUS = time.Since(p.lockedAt).Microseconds()
	p.Close()
	return reservationSelection(p.registry, p.scan)
}

type ReservationSelection struct {
	providerReservationScan
	registry              *Registry
	Provider              *Provider
	CacheAffinityEligible bool
}

func reservationSelection(r *Registry, scan providerReservationScan) ReservationSelection {
	selection := ReservationSelection{providerReservationScan: scan, registry: r}
	if scan.selected != nil {
		selection.Provider = scan.selected.provider
		selection.CacheAffinityEligible = scan.selected.cacheAffinityEligible
	}
	return selection
}

// ReservationResult is the outcome of the serialized admission transaction.
type ReservationResult struct {
	Provider  *Provider
	Outcome   ReservationCommitOutcome
	Decision  RoutingDecision
	candidate *routingCandidate
}

func (s ReservationSelection) Commit(model string, pending *PendingRequest, excludeIDs ...string) ReservationResult {
	provider, candidate, outcome, decision := s.commit(model, pending, excludeIDs...)
	return ReservationResult{Provider: provider, candidate: candidate, Outcome: outcome, Decision: decision}
}
