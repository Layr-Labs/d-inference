package registry

import (
	"sort"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// AttestationSummary provides aggregate attestation status for a model's providers.
type AttestationSummary struct {
	SecureEnclave bool `json:"secure_enclave"`
	SIPEnabled    bool `json:"sip_enabled"`
	SecureBoot    bool `json:"secure_boot"`
}

// AggregateModel is a deduplicated model entry for the /v1/models endpoint.
type AggregateModel struct {
	ID                string              `json:"id"`
	ModelType         string              `json:"model_type"`
	Quantization      string              `json:"quantization"`
	Providers         int                 `json:"providers"`          // number of providers offering this model
	AttestedProviders int                 `json:"attested_providers"` // number of attested providers
	TrustLevel        TrustLevel          `json:"trust_level"`        // highest trust level among providers
	Attestation       *AttestationSummary `json:"attestation,omitempty"`
}

// ListModels returns deduplicated models from all online providers.
func (r *Registry) ListModels() []AggregateModel {
	r.mu.RLock()
	defer r.mu.RUnlock()

	type modelAgg struct {
		modelType     string
		quantization  string
		count         int
		attestedCount int
		highestTrust  TrustLevel
		secureEnclave bool
		sipEnabled    bool
		secureBoot    bool
	}

	// Aggregate by model ID only — consumers request by ID, so providers
	// offering the same model ID should be counted together regardless of
	// minor metadata differences.
	//
	// The whole per-provider step runs under p.mu: it reads only strings and
	// booleans, retains nothing from the provider, and costs a few map lookups.
	// There is deliberately NO per-provider snapshot slice — at fleet scale
	// (~1,260 providers) that was one heap allocation per provider per call,
	// and /v1/models (uncached, two ListModels calls per request) paid for it
	// mostly as GC pressure rather than as the walk itself.
	agg := make(map[string]*modelAgg, len(r.modelCatalog))
	for _, p := range r.providers {
		p.mu.Lock()
		// Provider-level gates first, so an ineligible provider costs one lock
		// and a handful of field reads — never a walk of its inventory.
		// Private-only providers serve only their owner's self-route traffic, so
		// they must not appear in or inflate the public /v1/models aggregation.
		if p.Status == StatusOffline || p.Status == StatusUntrusted ||
			p.PrivateOnly ||
			!r.trustMeetsMinimum(p.TrustLevel) ||
			!r.providerSupportsPrivateTextLocked(p) {
			p.mu.Unlock()
			continue
		}
		trust := p.TrustLevel
		attestResult := p.AttestationResult
		attested := p.Attested && attestResult != nil
		for _, m := range p.Models {
			// Count only provider-model pairs that satisfy the live catalog and
			// connection-scoped capability requirements.
			if !r.providerModelAllowedByCatalogLocked(p, m) {
				continue
			}
			a, ok := agg[m.ID]
			if !ok {
				a = &modelAgg{
					modelType:    m.ModelType,
					quantization: m.Quantization,
					highestTrust: TrustNone,
				}
				agg[m.ID] = a
			}
			a.count++

			// Update highest trust level
			if trustRank(trust) > trustRank(a.highestTrust) {
				a.highestTrust = trust
			}

			if attested {
				a.attestedCount++
				a.secureEnclave = a.secureEnclave || attestResult.SecureEnclaveAvailable
				a.sipEnabled = a.sipEnabled || attestResult.SIPEnabled
				a.secureBoot = a.secureBoot || attestResult.SecureBootEnabled
			}
		}
		p.mu.Unlock()
	}

	models := make([]AggregateModel, 0, len(agg))
	for k, a := range agg {
		am := AggregateModel{
			ID:                k,
			ModelType:         a.modelType,
			Quantization:      a.quantization,
			Providers:         a.count,
			AttestedProviders: a.attestedCount,
			TrustLevel:        a.highestTrust,
		}
		if a.attestedCount > 0 {
			am.Attestation = &AttestationSummary{
				SecureEnclave: a.secureEnclave,
				SIPEnabled:    a.sipEnabled,
				SecureBoot:    a.secureBoot,
			}
		}
		models = append(models, am)
	}

	return models
}

// OwnedModels returns deduplicated live models advertised by providers owned by
// accountID. Unlike ListModels, it intentionally does not apply the public
// catalog filter; self-route keys may target off-catalog local models.
func (r *Registry) OwnedModels(accountID string) []AggregateModel {
	if accountID == "" {
		return nil
	}
	now := time.Now()
	agg := make(map[string]*AggregateModel)

	r.mu.RLock()
	defer r.mu.RUnlock()
	for _, p := range r.providers {
		p.mu.Lock()
		eligible := p.AccountID == accountID &&
			p.Status != StatusOffline &&
			p.Status != StatusUntrusted &&
			p.RuntimeVerified &&
			r.providerSupportsPrivateTextLocked(p) &&
			!p.LastChallengeVerified.IsZero() &&
			now.Sub(p.LastChallengeVerified) <= challengeFreshnessMaxAge
		if !eligible {
			p.mu.Unlock()
			continue
		}
		trust := p.TrustLevel
		attested := p.Attested
		attestResult := p.AttestationResult
		models := make([]protocol.ModelInfo, 0, len(p.Models))
		for _, model := range p.Models {
			if r.modelServableForOwnerLocked(p, model) {
				models = append(models, model)
			}
		}
		p.mu.Unlock()

		for _, m := range models {
			if m.ID == "" {
				continue
			}
			// Same principle for the template-render gate: an explicit
			// template_render_ok=false fences EVERY request shape at dispatch
			// (see providerTemplateRenderBrokenLocked / the trait gate), so a
			// render-broken build must not be listed either. nil (pre-0.6.5, no
			// opinion) stays listed, matching dispatch.
			if m.TemplateRenderOK != nil && !*m.TemplateRenderOK {
				continue
			}
			a, ok := agg[m.ID]
			if !ok {
				a = &AggregateModel{
					ID:         m.ID,
					TrustLevel: TrustNone,
				}
				agg[m.ID] = a
			}
			// Metadata backfill rather than first-writer-wins: two owned boxes
			// can advertise the same id with one omitting metadata, and map
			// iteration order must not decide which copy the owner sees.
			if a.ModelType == "" {
				a.ModelType = m.ModelType
			}
			if a.Quantization == "" {
				a.Quantization = m.Quantization
			}
			a.Providers++
			if trustRank(trust) > trustRank(a.TrustLevel) {
				a.TrustLevel = trust
			}
			if attested && attestResult != nil {
				a.AttestedProviders++
				if a.Attestation == nil {
					a.Attestation = &AttestationSummary{}
				}
				a.Attestation.SecureEnclave = a.Attestation.SecureEnclave || attestResult.SecureEnclaveAvailable
				a.Attestation.SIPEnabled = a.Attestation.SIPEnabled || attestResult.SIPEnabled
				a.Attestation.SecureBoot = a.Attestation.SecureBoot || attestResult.SecureBootEnabled
			}
		}
	}

	models := make([]AggregateModel, 0, len(agg))
	for _, a := range agg {
		models = append(models, *a)
	}
	sort.Slice(models, func(i, j int) bool { return models[i].ID < models[j].ID })
	return models
}

// ModelCountryCodes returns the sorted, de-duplicated ISO 3166-1 alpha-2
// country codes of online providers serving the given model. Used to populate
// the OpenRouter "datacenters" field. Only routing-eligible providers count —
// the same gates as ListModels (online, meets the minimum trust level, and
// private-text ready) — so a country whose providers can't actually serve the
// model is not advertised. Providers without a known location are skipped.
func (r *Registry) ModelCountryCodes(modelID string) []string {
	r.mu.RLock()
	defer r.mu.RUnlock()

	seen := make(map[string]bool)
	for _, p := range r.providers {
		p.mu.Lock()
		status := p.Status
		trust := p.TrustLevel
		privateReady := r.providerSupportsPrivateTextLocked(p)
		var cc string
		if p.Location != nil {
			cc = strings.ToUpper(strings.TrimSpace(p.Location.CountryCode))
		}
		serves := cc != "" && r.providerServesCatalogModelLocked(p, modelID)
		p.mu.Unlock()
		if !serves {
			continue
		}
		// Apply the same routing-eligibility gates as ListModels.
		if status == StatusOffline || status == StatusUntrusted {
			continue
		}
		if !r.trustMeetsMinimum(trust) || !privateReady {
			continue
		}
		seen[cc] = true
	}
	if len(seen) == 0 {
		return nil
	}
	out := make([]string, 0, len(seen))
	for c := range seen {
		out = append(out, c)
	}
	sort.Strings(out)
	return out
}

// ModelProviderSnapshot returns live catalog-eligible provider-model counts.
// Raw inventory counters remain forensic bookkeeping; this public snapshot is
// derived so catalog requirement changes take effect immediately.
func (r *Registry) ModelProviderSnapshot() map[string]int64 {
	r.mu.RLock()
	defer r.mu.RUnlock()
	snap := make(map[string]int64)
	for _, p := range r.providers {
		p.mu.Lock()
		if p.Status == StatusOffline || p.Status == StatusUntrusted {
			p.mu.Unlock()
			continue
		}
		seen := make(map[string]struct{}, len(p.Models))
		for _, model := range p.Models {
			if model.ID == "" || !r.providerModelAllowedByCatalogLocked(p, model) {
				continue
			}
			if _, duplicate := seen[model.ID]; duplicate {
				continue
			}
			seen[model.ID] = struct{}{}
			snap[model.ID]++
		}
		p.mu.Unlock()
	}
	return snap
}
