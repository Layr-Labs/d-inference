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
	if !r.hardwareAdmissionEnforced.Load() {
		return true
	}
	return p.HardwareAdmissionStatus()
}

func (r *Registry) SetProviderHardwareAdmitted(providerID string, admitted bool) bool {
	p := r.GetProvider(providerID)
	if p == nil {
		return false
	}
	p.mu.Lock()
	p.HardwareAdmitted = admitted
	p.mu.Unlock()
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

func (p *Provider) PersistenceEnabled() bool {
	if p == nil {
		return false
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.persistenceEnabled
}

func (r *Registry) ActivateProviderPersistence(p *Provider) {
	if p == nil {
		return
	}
	p.mu.Lock()
	if p.persistenceEnabled {
		p.mu.Unlock()
		return
	}
	p.persistenceEnabled = true
	sessionID := p.ID
	p.mu.Unlock()

	if r.store != nil {
		saferun.Go(r.logger, "registry.openAdmittedSession", func() {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			if err := r.store.OpenProviderSession(ctx, sessionID, "", ""); err != nil {
				r.logger.Warn("failed to open admitted provider session",
					"provider_id", sessionID, "error", err)
			}
		})
	}
	r.persistProviderNow(p)
}
