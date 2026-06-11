package registry

import (
	"strconv"
	"strings"
)

// RequestTraits captures request-shape attributes that affect provider
// eligibility beyond the model id. Stamped onto PendingRequest by the consumer
// handler and enforced in the scheduler's candidate filter and final admit.
type RequestTraits struct {
	// HasTools is true when the request carries an OpenAI tools/functions
	// schema. Tool schemas are rendered through the model's chat template on
	// the provider, and old binaries crash on schema shapes they don't
	// normalize (e.g. nullable/missing parameter types crashing Gemma's
	// template with "upper filter requires string"). Tool-bearing requests are
	// therefore gated by capabilityVersionFloors and by the per-model
	// template_render_ok advertisement.
	HasTools bool
	// AvoidVersion is the SOFT version-diversity hint for retries: when set,
	// candidate selection first excludes providers running exactly this binary
	// version (the one a previous attempt just failed on) so a deterministic
	// per-version bug cannot burn every retry on identical binaries. Diversity
	// never fails closed — when no other version can serve, selection falls
	// back to the full pool.
	AvoidVersion string
}

// capabilityVersionFloors maps a request trait to the minimum provider binary
// version able to serve it. Providers BELOW a floor — including providers that
// report no version at all — are excluded from requests carrying that trait.
//
// "tools": 0.6.3 is the first version with provider-side tool-schema
// normalization (#310); older binaries crash Gemma's chat template on OpenAI
// tool schemas with nullable/missing types.
var capabilityVersionFloors = map[string]string{
	"tools": "0.6.3",
}

// CompareVersions compares two dotted numeric versions, returning -1 when
// a < b, 0 when equal, +1 when a > b. It is deliberately tolerant: a leading
// "v"/"V" is stripped, segments compare numerically ("0.6.10" > "0.6.3"),
// missing segments compare as 0 ("0.6" == "0.6.0"), and unparseable segments
// compare as 0 ("garbage" == "0", "0.6.3-rc1" == "0.6.0"). An empty string
// parses as no segments (all zeros), so it sits below any real floor;
// providerMeetsTraitFloorsLocked additionally special-cases empty so a
// non-reporting provider fails every floor even if one were ever set to 0.
func CompareVersions(a, b string) int {
	as := versionSegments(a)
	bs := versionSegments(b)
	n := len(as)
	if len(bs) > n {
		n = len(bs)
	}
	for i := 0; i < n; i++ {
		var av, bv int
		if i < len(as) {
			av = as[i]
		}
		if i < len(bs) {
			bv = bs[i]
		}
		switch {
		case av < bv:
			return -1
		case av > bv:
			return 1
		}
	}
	return 0
}

// versionSegments parses "v0.6.3" into [0 6 3]. Unparseable or negative
// segments parse as 0.
func versionSegments(v string) []int {
	v = strings.TrimSpace(v)
	if len(v) > 0 && (v[0] == 'v' || v[0] == 'V') {
		v = v[1:]
	}
	if v == "" {
		return nil
	}
	parts := strings.Split(v, ".")
	segs := make([]int, len(parts))
	for i, part := range parts {
		n, err := strconv.Atoi(strings.TrimSpace(part))
		if err != nil || n < 0 {
			n = 0
		}
		segs[i] = n
	}
	return segs
}

// providerMeetsTraitFloorsLocked reports whether the provider's binary version
// meets every capability version floor required by the request's traits. A
// provider with an EMPTY version (old binaries that never report one) is below
// any floor. Caller holds r.mu and p.mu — same discipline as
// providerServesVisionModelLocked; p.Version is guarded by p.mu.
func (r *Registry) providerMeetsTraitFloorsLocked(p *Provider, t RequestTraits) bool {
	if t.HasTools {
		if floor := capabilityVersionFloors["tools"]; floor != "" {
			if p.Version == "" || CompareVersions(p.Version, floor) < 0 {
				return false
			}
		}
	}
	return true
}

// providerTemplateRenderBrokenLocked reports whether the provider's advertised
// ModelInfo for model carries an EXPLICIT template_render_ok=false — the
// 0.6.5+ provider self-checked the model's chat template against the canonical
// tool/multimodal fixtures and the render crashed. nil means a pre-0.6.5
// provider with no opinion (allowed; the version floor is the backstop there).
// Caller holds p.mu (p.Models is guarded by p.mu).
func providerTemplateRenderBrokenLocked(p *Provider, model string) bool {
	for _, m := range p.Models {
		if m.ID == model && m.TemplateRenderOK != nil && !*m.TemplateRenderOK {
			return true
		}
	}
	return false
}

// providerEligibleForTraitsLocked combines the capability version floors with
// the per-model template_render_ok gate: a tool-bearing request must not route
// to a provider below the tools floor, nor to one whose advertised build
// declares a broken chat-template render for this model. Caller holds r.mu and
// p.mu (same discipline as providerServesVisionModelLocked).
func (r *Registry) providerEligibleForTraitsLocked(p *Provider, model string, t RequestTraits) bool {
	if !r.providerMeetsTraitFloorsLocked(p, t) {
		return false
	}
	if t.HasTools && providerTemplateRenderBrokenLocked(p, model) {
		return false
	}
	return true
}

// hasFloorGatedTrait reports whether any trait on t is subject to provider
// eligibility gating (capability version floors / template_render_ok), i.e.
// whether the scheduler must take p.mu and consult
// providerEligibleForTraitsLocked at all. Extend together with
// capabilityVersionFloors. AvoidVersion is deliberately NOT included — it is a
// soft pool preference, not an eligibility gate.
func (t RequestTraits) hasFloorGatedTrait() bool {
	return t.HasTools
}

// HasToolCapableProviderForModel reports whether any online, non-untrusted
// provider could serve a tool-bearing request for the resolved model id:
// it advertises a catalog-allowed build of the model AND passes the tools
// trait gate (>= the tools version floor with no explicit
// template_render_ok=false for the model). The consumer uses it to fail a
// tools request fast with the real cause when the model's whole pool is
// trait-gated (e.g. a fleet still updating past 0.6.3) — without it the
// request passes the trait-blind capacity preflight, queues for up to 120s,
// and dies with a misleading capacity 429. Mirrors HasVisionProviderForModel,
// including its r.mu/p.mu discipline.
func (r *Registry) HasToolCapableProviderForModel(model string) bool {
	traits := RequestTraits{HasTools: true}
	r.mu.RLock()
	defer r.mu.RUnlock()
	for _, p := range r.providers {
		// p.Status, p.Version, and p.Models are guarded by p.mu (writers hold
		// it), so the whole eligibility read must happen under the provider lock.
		p.mu.Lock()
		eligible := p.Status != StatusOffline && p.Status != StatusUntrusted &&
			r.providerServesCatalogModelLocked(p, model) &&
			r.providerEligibleForTraitsLocked(p, model, traits)
		p.mu.Unlock()
		if eligible {
			return true
		}
	}
	return false
}
