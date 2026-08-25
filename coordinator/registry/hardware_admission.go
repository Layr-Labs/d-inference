package registry

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/saferun"
)

// SetHardwareAdmissionEnforced atomically enables or disables the mandatory
// routing gate. Enabling does not implicitly admit existing connections: the API
// layer reconciles each one against the durable serial ledger first.
func (r *Registry) SetHardwareAdmissionEnforced(enforced bool) {
	r.hardwareAdmissionEnforced.Store(enforced)
}

func (r *Registry) HardwareAdmissionEnforced() bool {
	return r.hardwareAdmissionEnforced.Load()
}

func (r *Registry) ProviderHardwareAdmitted(p *Provider) bool {
	if p == nil {
		return false
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	return r.providerHardwareEligibleLocked(p)
}

func (r *Registry) providerHardwareEligibleLocked(p *Provider) bool {
	return !p.HardwareAdmissionRevoked &&
		!p.HardwareAdmissionStateUnavailable &&
		(!r.hardwareAdmissionEnforced.Load() || p.HardwareAdmitted)
}

func (r *Registry) SetProviderHardwareAdmitted(
	p *Provider,
	admitted bool,
) bool {
	if p == nil {
		return false
	}
	r.mu.RLock()
	current, ok := r.providers[p.ID]
	if !ok || current != p {
		r.mu.RUnlock()
		return false
	}
	p.mu.Lock()
	p.HardwareAdmitted = admitted
	p.mu.Unlock()
	r.mu.RUnlock()
	return true
}

// SetProviderHardwareRevoked marks an exact live connection with an always-on
// routing fence. The fence applies even when threshold enforcement is disabled.
func (r *Registry) SetProviderHardwareRevoked(p *Provider, revoked bool) bool {
	return r.SetProviderHardwareAdmissionFence(p, revoked, false)
}

func (r *Registry) SetProviderHardwareAdmissionFence(
	p *Provider,
	revoked bool,
	stateUnavailable bool,
) bool {
	if p == nil {
		return false
	}
	r.mu.RLock()
	current, ok := r.providers[p.ID]
	if !ok || current != p {
		r.mu.RUnlock()
		return false
	}
	p.mu.Lock()
	p.HardwareAdmissionRevoked = revoked
	p.HardwareAdmissionStateUnavailable = stateUnavailable
	if revoked || stateUnavailable {
		p.HardwareAdmitted = false
	}
	p.mu.Unlock()
	r.mu.RUnlock()
	return true
}

func (p *Provider) HardwareAdmissionStatus() bool {
	if p == nil {
		return false
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.HardwareAdmitted
}

func (p *Provider) HardwareAdmissionRevokedStatus() bool {
	if p == nil {
		return false
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.HardwareAdmissionRevoked
}

func (p *Provider) PersistenceEnabled() bool {
	if p == nil {
		return false
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.persistenceEnabled
}

// CommitProviderHardwareAdmission atomically verifies that p is still the exact
// registered connection, marks it admitted, and enables persistence. Disconnect
// and this commit serialize on r.mu: disconnect-first makes the commit fail;
// commit-first makes disconnect observe persistenceEnabled and close the session.
func (r *Registry) CommitProviderHardwareAdmission(p *Provider) bool {
	if p == nil {
		return false
	}
	r.mu.Lock()
	current, ok := r.providers[p.ID]
	if !ok || current != p {
		r.mu.Unlock()
		return false
	}
	p.mu.Lock()
	if p.HardwareAdmissionRevoked || p.HardwareAdmissionStateUnavailable {
		p.mu.Unlock()
		r.mu.Unlock()
		return false
	}
	p.HardwareAdmitted = true
	activatedPersistence := !p.persistenceEnabled
	p.persistenceEnabled = true
	sessionID := p.ID
	p.mu.Unlock()
	r.mu.Unlock()

	if activatedPersistence {
		r.openAdmittedProviderSession(p, sessionID)
		r.persistProviderNow(p)
	}
	return true
}

func (r *Registry) openAdmittedProviderSession(p *Provider, sessionID string) {
	if r.store != nil {
		saferun.Go(r.logger, "registry.openAdmittedSession", func() {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			if err := r.store.OpenProviderSession(ctx, sessionID, "", ""); err != nil {
				r.logger.Warn("failed to open admitted provider session",
					"provider_id", sessionID, "error", err)
				return
			}

			// The store write is asynchronous. If disconnect won after the
			// in-memory commit but before this row opened, close it immediately;
			// otherwise the ordinary disconnect path owns closure.
			r.mu.RLock()
			current, connected := r.providers[sessionID]
			connected = connected && current == p
			r.mu.RUnlock()
			if !connected {
				closeCtx, closeCancel := context.WithTimeout(
					context.Background(), 5*time.Second)
				defer closeCancel()
				if err := r.store.CloseProviderSession(
					closeCtx, sessionID, "disconnected", time.Now()); err != nil {
					r.logger.Warn("failed to close disconnected admitted provider session",
						"provider_id", sessionID, "error", err)
				}
			}
		})
	}
}
