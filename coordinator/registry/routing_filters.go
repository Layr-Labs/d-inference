package registry

import (
	"time"
)

func providerMatchesAllowedSerial(p *Provider, allowed map[string]struct{}) bool {
	if p == nil || len(allowed) == 0 {
		return true
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.AttestationResult != nil {
		if _, ok := allowed[p.AttestationResult.SerialNumber]; ok && p.AttestationResult.SerialNumber != "" {
			return true
		}
	}
	if p.MDAResult != nil {
		if _, ok := allowed[p.MDAResult.DeviceSerial]; ok && p.MDAResult.DeviceSerial != "" {
			return true
		}
	}
	return false
}

// providerOwnedBy reports whether p is owned by accountID. Ownership is the
// coordinator-stamped Provider.AccountID (set at registration from the device
// auth token), never a client-supplied value — so it cannot be forged by a
// caller. An empty accountID never matches.
func providerOwnedBy(p *Provider, accountID string) bool {
	if p == nil || accountID == "" {
		return false
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.AccountID != "" && p.AccountID == accountID
}

// providerVersion reads the provider's binary version under p.mu (set by the
// API layer after registration; p.mu guards provider field access — mirrors
// providerOwnedBy). Used by the version-diverse retry pool filter.
func providerVersion(p *Provider) string {
	if p == nil {
		return ""
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.Version
}

// OwnedProviderSummary reports, for the given account, how many of its
// currently-connected providers are online and how many can serve `model` for
// a request with the given traits/media shape. It powers self-route pre-flight
// error messaging: distinguishing "your machine is offline" from "your machine
// can't serve this request". The model-serving check applies the same
// privacy/runtime/challenge gates as routing but deliberately ignores the
// hardware-trust gate, which self-route relaxes for a caller's own machine.
// traits/requiresVision mirror the dispatch-time gates
// (providerEligibleForTraitsLocked, the vision gate): without them a tool call
// to an owned box below the tools floor — or a media request to a text-only
// build — would pass this preflight, queue for up to 120s, and die as
// machine_busy instead of failing fast with the real cause. Callers asking the
// base-shape question ("any owned box serves this model at all?") pass zero
// traits and requiresVision=false. "Linked but offline" providers are not
// counted here (they are not in the registry); callers detect zero linked
// machines via store.ListProvidersByAccount.
func (r *Registry) OwnedProviderSummary(accountID, model string, traits RequestTraits, requiresVision bool) (online, servesModel int) {
	if accountID == "" {
		return 0, 0
	}
	now := time.Now()
	r.mu.RLock()
	defer r.mu.RUnlock()
	for _, p := range r.providers {
		p.mu.Lock()
		if p.AccountID == "" || p.AccountID != accountID {
			p.mu.Unlock()
			continue
		}
		if p.Status == StatusOffline || p.Status == StatusUntrusted {
			p.mu.Unlock()
			continue
		}
		online++
		// Owner-servability (not bare advertisement) so the self-route error
		// messaging matches what routing would actually admit: an owned box
		// advertising a stale-hash catalog build reports "model not loaded"
		// instead of proceeding into a dispatch that can only be rejected.
		serves := r.providerServesOwnedRoutableModelLocked(p, model) &&
			r.providerEligibleForTraitsLocked(p, model, traits) &&
			(!requiresVision || r.providerServesVisionModelLocked(p, model, true)) &&
			r.providerLivenessGateLocked(p, TrustNone, true, now)
		p.mu.Unlock()
		if serves {
			servesModel++
		}
	}
	return online, servesModel
}
