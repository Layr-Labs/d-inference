package registry

import (
	"time"
	"unicode/utf8"

	"github.com/eigeninference/d-inference/coordinator/internal/payments/rewardeligibility"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store/earningsfloor"
)

// AutopilotRewardConsentSnapshot reads only the last accepted registration or
// heartbeat. Control readiness, pauses, leases and rollout modes are not saved
// consent. Unsupported or malformed declarations fail closed, including older
// providers that report enabled without the separate consent_enabled field.
// supported distinguishes a valid opt-out from missing consent history.
func (p *Provider) AutopilotRewardConsentSnapshot() (optedIn, supported bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.autopilotRewardConsentLocked()
}

func (p *Provider) autopilotRewardConsentLocked() (optedIn, supported bool) {
	state := p.ModelAutopilot
	if state == nil || state.Protocol != protocol.ModelAutopilotProtocol || state.ConsentEnabled == nil {
		return false, false
	}
	if !*state.ConsentEnabled {
		return false, true
	}
	if !state.CachedOnly || state.Revision == "" || len(state.Revision) > 64 ||
		len(state.SelectedModels) == 0 || len(state.SelectedModels) > 256 {
		return false, false
	}
	for _, id := range state.SelectedModels {
		if id == "" || len(id) > 256 {
			return false, false
		}
	}
	return true, true
}

// AutopilotRewardSnapshot separates saved opt-in from qualification to earn the
// daily floor. A temporary OS, authorization or inventory failure cannot erase
// the first opt-in or establish a new baseline. Downloaded models need not be
// resident or covered by an active residency-control lease.
func (r *Registry) AutopilotRewardSnapshot(p *Provider) (optedIn, supported, qualified bool) {
	declaration := r.AutopilotRewardDeclaration(p)
	return declaration.OptedIn, declaration.Supported, declaration.Qualified
}

// AutopilotRewardDeclaration captures hardware together with saved consent and
// current qualification. The first registration receipt precedes asynchronous
// machine inventory, so later identity binding must use this original hardware
// when selecting its baseline cohort. The socket owner supplies the authenticated
// account and session after releasing these locks.
func (r *Registry) AutopilotRewardDeclaration(p *Provider) (declaration earningsfloor.Consent) {
	return r.autopilotRewardDeclaration(p, time.Now(), true)
}

// AutopilotRewardDeclarationAt evaluates the current accepted declaration and
// evidence at the socket's receive instant. A lease granted while this frame
// waits for processing cannot retroactively qualify the earlier receipt.
func (r *Registry) AutopilotRewardDeclarationAt(p *Provider, receivedAt time.Time) earningsfloor.Consent {
	return r.autopilotRewardDeclaration(p, receivedAt, false)
}

func (r *Registry) autopilotRewardDeclaration(p *Provider, receivedAt time.Time, inspection bool) (declaration earningsfloor.Consent) {
	if p == nil {
		return declaration
	}
	r.mu.RLock()
	defer r.mu.RUnlock()
	if r.providers[p.ID] != p {
		return declaration
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if inspection {
		receivedAt = r.appAttestNow(receivedAt)
	}
	declaration.At = receivedAt
	declaration.OptedIn, declaration.Supported = p.autopilotRewardConsentLocked()
	chip := p.Hardware.ChipName
	if utf8.ValidString(chip) {
		if len(chip) > 128 {
			chip = chip[:128]
			for !utf8.ValidString(chip) {
				chip = chip[:len(chip)-1]
			}
		}
		declaration.Chip = chip
	}
	if p.Hardware.MemoryGB > 0 {
		declaration.MemoryGB = float64(p.Hardware.MemoryGB)
	}
	declaration.Qualified = r.autopilotRewardQualifiedLocked(p, declaration.OptedIn, declaration.Supported, receivedAt)
	return declaration
}

func (r *Registry) autopilotRewardQualifiedLocked(p *Provider, optedIn, supported bool, receivedAt time.Time) bool {
	if !optedIn || !supported || !p.ModelAutopilot.Enabled || p.PrivateOnly ||
		!r.providerAppAttestServingAuthorizedAtLocked(p, receivedAt) ||
		!rewardeligibility.OSVersionEligible(p.appAttestAuthorization.OSVersion) {
		return false
	}

	selected := make(map[string]bool, len(p.ModelAutopilot.SelectedModels))
	for _, id := range p.ModelAutopilot.SelectedModels {
		if selected[id] {
			return false
		}
		selected[id] = true
	}
	downloaded := make(map[string]bool)
	eligible := 0
	for _, model := range p.Models {
		if !selected[model.ID] {
			continue
		}
		if downloaded[model.ID] {
			return false
		}
		downloaded[model.ID] = true
		// Unlike dev routing, missing catalog policy never grants reward
		// eligibility. Exact promoted artifacts and current runtime gates are
		// required even for cached observation-only inventory.
		entry, exists := r.modelCatalog[model.ID]
		if !exists || entry.WeightHash == "" || model.WeightHash == "" ||
			!entry.acceptsWeightHash(model.WeightHash) ||
			!r.providerMeetsModelRequirementsWithAppAttestLocked(p, model.ID, true) ||
			!r.providerEligibleForTraitsLocked(p, model.ID, RequestTraits{}) ||
			!modelFitsHardware(entry.MinRAMGB, entry.SizeGB, float64(p.Hardware.MemoryGB)) {
			continue
		}
		eligible++
	}
	return eligible >= 2
}
