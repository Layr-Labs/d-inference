package registry

import (
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachepolicy"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/kvbudget"
)

type coldKVKey struct {
	model, artifact, version, metallib string
}

// coldKVEstimates is operation-local prediction data, never a capacity report.
// Different backend/precision/MTP choices can still produce different native
// rates. The maximum current observation is a forecast, not a memory guarantee;
// the destination's real load and request gates remain authoritative.
type coldKVEstimates map[coldKVKey]int64

func coldKVKeyLocked(p *Provider, model string) (coldKVKey, bool) {
	if p.Backend != BackendMLXSwift || p.Version == "" || !p.RuntimeVerified ||
		!p.RuntimeManifestChecked || !p.MetallibVerified {
		return coldKVKey{}, false
	}
	metallib := strings.ToLower(p.TemplateHashes["mlx_metallib"])
	if !cachepolicy.LowerHex256(metallib) {
		return coldKVKey{}, false
	}
	for _, info := range p.Models {
		if info.ID == model {
			artifact := strings.ToLower(info.WeightHash)
			if cachepolicy.LowerHex256(artifact) {
				return coldKVKey{model: model, artifact: artifact, version: p.Version, metallib: metallib}, true
			}
			break
		}
	}
	return coldKVKey{}, false
}

// Rate returns a prediction only for an absent/cold model. A resident's missing
// rate remains legacy/unknown; a positive own rate is never replaced by a peer.
// Caller holds p.mu and the registry read lease used to collect the estimates.
func (estimates coldKVEstimates) Rate(p *Provider, model string) int64 {
	if len(estimates) == 0 {
		return 0
	}
	if p.BackendCapacity != nil {
		for _, slot := range p.BackendCapacity.Slots {
			if slot.Model == model && (slot.KVBytesPerToken > 0 || slotStateModelLoaded(slot.State)) {
				return 0
			}
		}
	}
	key, ok := coldKVKeyLocked(p, model)
	if !ok {
		return 0
	}
	return estimates[key]
}

// coldKVEstimatesLocked collects only the models needed by this operation's
// candidates and their pending work. It visits each needed model index once,
// before taking any destination lock. No rate history
// survives the operation: removal, distrust, artifact replacement and accepted
// heartbeat clearing take effect on the next scan, including reservation commit.
// Caller holds r.mu and no provider lock.
func (r *Registry) coldKVEstimatesLocked(providers []*Provider, model string, now time.Time) coldKVEstimates {
	var wanted map[string]map[coldKVKey]struct{}
	for _, p := range providers {
		p.mu.Lock()
		require := func(model string) {
			if p.BackendCapacity != nil {
				for _, slot := range p.BackendCapacity.Slots {
					if slot.Model == model && (slot.KVBytesPerToken > 0 || slotStateModelLoaded(slot.State)) {
						return
					}
				}
			}
			key, ok := coldKVKeyLocked(p, model)
			if !ok {
				return
			}
			if wanted == nil {
				wanted = make(map[string]map[coldKVKey]struct{})
			}
			if wanted[model] == nil {
				wanted[model] = make(map[coldKVKey]struct{})
			}
			wanted[model][key] = struct{}{}
		}
		if model != "" {
			require(model)
		} else {
			for _, info := range p.Models {
				require(info.ID)
			}
		}
		for _, pending := range p.pendingReqs {
			require(pending.Model)
		}
		p.mu.Unlock()
	}
	var estimates coldKVEstimates
	for model, identities := range wanted {
		for _, p := range r.providersForModelLocked(model) {
			p.mu.Lock()
			key, rate := r.observedColdKVRateLocked(p, model, now)
			p.mu.Unlock()
			if _, needed := identities[key]; rate > 0 && needed {
				if estimates == nil {
					estimates = make(coldKVEstimates)
				}
				estimates[key] = max(estimates[key], rate)
			}
		}
	}
	return estimates
}

func (r *Registry) observedColdKVRateLocked(p *Provider, model string, now time.Time) (coldKVKey, int64) {
	if p.BackendCapacity == nil || len(p.BackendCapacity.Slots) == 0 || p.CapacityAcceptedAt.IsZero() || p.CapacityAcceptedAt.After(now) ||
		now.Sub(p.CapacityAcceptedAt) > DefaultProviderHeartbeatTimeout ||
		!r.providerPassesRoutingGatesLocked(p, model, RequestTraits{}, false, now) {
		return coldKVKey{}, 0
	}
	key, ok := coldKVKeyLocked(p, model)
	if !ok {
		return coldKVKey{}, 0
	}
	var rate int64
	for _, slot := range p.BackendCapacity.Slots {
		if slot.Model != model || !slotStateModelLoaded(slot.State) || slot.WedgeSuspected ||
			slot.KVBytesPerToken <= 0 || slot.KVBytesPerToken > kvbudget.MaxBytesPerToken ||
			slot.KVBackend == nil || (*slot.KVBackend != "contiguous" && *slot.KVBackend != "paged") ||
			!slot.PromptWorkIdentity.IsValid() || slot.PromptWorkIdentity.ModelArtifactHash != key.artifact {
			continue
		}
		rate = max(rate, slot.KVBytesPerToken)
	}
	return key, rate
}
