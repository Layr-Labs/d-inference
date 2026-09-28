package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// DisconnectDuplicatesByMachine arbitrates only after the caller earned full
// App Attest serving authorization and authenticated canonical identity. The
// newest qualified connection wins deterministically, so simultaneous grants
// cannot each disconnect the other. No claimed serial or provisional machine
// identity can evict another provider, and accounts are independent.
func (r *Registry) DisconnectDuplicatesByMachine(keep *Provider) {
	if keep == nil {
		return
	}
	r.mu.Lock()
	if r.providers[keep.ID] != keep {
		r.mu.Unlock()
		return
	}
	keep.mu.Lock()
	account, machine := keep.verifiedMachineAccount, keep.verifiedMachineID
	qualified := r.providerAppAttestServingAuthorizedLocked(keep, time.Now())
	keep.mu.Unlock()
	if !qualified || account == "" || machine == "" {
		r.mu.Unlock()
		return
	}
	winner := keep
	var candidates []*Provider
	for _, p := range r.providers {
		p.mu.Lock()
		match := p.AccountID == account && p.verifiedMachineAccount == account && p.verifiedMachineID == machine
		if match {
			candidates = append(candidates, p)
			if r.providerAppAttestServingAuthorizedLocked(p, time.Now()) &&
				(p.registeredAt.After(winner.registeredAt) || (p.registeredAt.Equal(winner.registeredAt) && p.ID > winner.ID)) {
				winner = p
			}
		}
		p.mu.Unlock()
	}
	var evict []*Provider
	for _, p := range candidates {
		// A newer connection can have completed identity binding while its
		// runtime/policy checks are still finishing. An older connection's
		// periodic renewal must not evict that pending newcomer before it has
		// an opportunity to qualify. It cannot displace the winner yet either.
		if p == winner || p.registeredAt.After(winner.registeredAt) ||
			(p.registeredAt.Equal(winner.registeredAt) && p.ID > winner.ID) {
			continue
		}
		p.mu.Lock()
		// Fence selection and queued frames before releasing the membership
		// lock; socket cleanup follows without holding any registry lock.
		p.appAttestAuthorization = AppAttestServingAuthorization{}
		p.appAttestSecurityDenied = true
		p.mu.Unlock()
		evict = append(evict, p)
	}
	r.mu.Unlock()
	for _, p := range evict {
		r.disconnectProvider(p.ID, p, -1, protocol.CoordinatorCauseProviderRestart)
	}
}
