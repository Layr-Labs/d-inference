package registry

import "strings"

// Dedicated-model routing isolates a model family (e.g. Gemma 4) to providers
// that run ONLY that family. A "dedicated" provider is one whose entire
// advertised catalog matches the family pattern; nothing else can ever load on
// that machine, so the isolated model never contends for memory or compute with
// other models on the same box. The patterns are configured at startup
// (EIGENINFERENCE_DEDICATED_MODELS, default "gemma-4") and applied in the single
// routing/preflight gate providerPassesRoutingGatesLockedEx, which both the
// dispatch hot path and the OpenRouter capacity preflight funnel through.

// ParseDedicatedModels parses a comma-separated list of model-family patterns
// into normalized (trimmed, lowercased, non-empty) substring patterns. Used by
// the coordinator entrypoint to read EIGENINFERENCE_DEDICATED_MODELS. An empty
// or all-blank input yields a nil slice (feature disabled).
func ParseDedicatedModels(csv string) []string {
	var out []string
	for _, p := range strings.Split(csv, ",") {
		p = strings.ToLower(strings.TrimSpace(p))
		if p == "" {
			continue
		}
		out = append(out, p)
	}
	return out
}

// SetDedicatedModels configures the dedicated-model routing patterns. Patterns
// are matched case-insensitively as substrings of the resolved build id. An
// empty (or all-blank) list disables the feature. Called once at startup before
// the coordinator begins serving.
func (r *Registry) SetDedicatedModels(patterns []string) {
	normalized := make([]string, 0, len(patterns))
	for _, p := range patterns {
		p = strings.ToLower(strings.TrimSpace(p))
		if p == "" {
			continue
		}
		normalized = append(normalized, p)
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if len(normalized) == 0 {
		r.dedicatedModels = nil
		return
	}
	r.dedicatedModels = normalized
}

// dedicatedPatternForLocked returns the first configured pattern that the given
// resolved build id contains, or "", false when the model is not a dedicated
// model (or the feature is disabled). Caller holds r.mu.
func (r *Registry) dedicatedPatternForLocked(model string) (string, bool) {
	if len(r.dedicatedModels) == 0 {
		return "", false
	}
	m := strings.ToLower(model)
	for _, p := range r.dedicatedModels {
		if strings.Contains(m, p) {
			return p, true
		}
	}
	return "", false
}

// providerDedicatedToPatternLocked reports whether EVERY catalog-allowed model
// the provider advertises matches pattern — i.e. the box is dedicated to that
// model family. A provider that advertises no catalog-allowed model is not
// dedicated (returns false). Non-catalog-allowed advertised builds (stale or
// unknown) are ignored so they cannot spuriously disqualify a dedicated box.
// Caller holds r.mu AND p.mu (mirrors providerServesCatalogModelLocked).
func (r *Registry) providerDedicatedToPatternLocked(p *Provider, pattern string) bool {
	advertised := 0
	for _, m := range p.Models {
		if !r.modelAllowedByCatalogLocked(m) {
			continue
		}
		advertised++
		if !strings.Contains(strings.ToLower(m.ID), pattern) {
			return false
		}
	}
	return advertised > 0
}

// providerExcludedByDedicatedRuleLocked reports whether the dedicated-box rule
// excludes this provider from PUBLIC routing/warming for the model: true when
// the model is a dedicated family AND the provider is not dedicated to it. It is
// the single predicate shared by the routing gate, the capacity preflight, the
// cold-spill check, the warm-pool target picker, and the model-swap planner, so
// every place that selects or pre-warms a provider for a public request applies
// the same constraint and cannot drift. (Self-route exemption is the caller's
// concern — only the routing gate honors it.) Caller holds r.mu AND p.mu.
func (r *Registry) providerExcludedByDedicatedRuleLocked(p *Provider, model string) bool {
	pat, ok := r.dedicatedPatternForLocked(model)
	if !ok {
		return false
	}
	return !r.providerDedicatedToPatternLocked(p, pat)
}

// IsDedicatedModel reports whether the resolved build id is governed by the
// dedicated-model routing rule. The consumer layer uses it to classify a
// "no eligible provider" shed for such a model as a transient 429 (rather than
// a 503): with no dedicated box available, the request must fail over cleanly.
func (r *Registry) IsDedicatedModel(model string) bool {
	r.mu.RLock()
	defer r.mu.RUnlock()
	_, ok := r.dedicatedPatternForLocked(model)
	return ok
}

// HasProviderForModel reports whether any online, non-untrusted provider
// advertises a catalog-allowed build of the resolved model id (ignoring
// dedicated-box and capacity gates). It distinguishes "the fleet serves this
// model but no dedicated/available box can take it right now" (transient — a
// 429 shed) from "the model is absent from the fleet entirely" (a 503). When
// allowedSerials is non-empty the check is restricted to providers whose
// attested serial is in the set, mirroring the routing candidate filter.
func (r *Registry) HasProviderForModel(model string, allowedSerials ...string) bool {
	allowedSet := make(map[string]struct{}, len(allowedSerials))
	for _, s := range allowedSerials {
		allowedSet[s] = struct{}{}
	}
	r.mu.RLock()
	defer r.mu.RUnlock()
	for _, p := range r.providers {
		if len(allowedSet) > 0 && !providerMatchesAllowedSerial(p, allowedSet) {
			continue
		}
		p.mu.Lock()
		eligible := p.Status != StatusOffline && p.Status != StatusUntrusted &&
			r.providerServesCatalogModelLocked(p, model)
		p.mu.Unlock()
		if eligible {
			return true
		}
	}
	return false
}
