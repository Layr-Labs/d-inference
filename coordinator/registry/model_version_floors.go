package registry

import "strings"

// Per-model provider-version routing floors — the second half of the
// mixed-fleet migration defense (beside the version-keyed heartbeat clamp in
// v2_capacity_clamp.go).
//
// During the v0.7.5 rollout a model that NEEDS the re-slice-capable v2 engine
// (e.g. gemma-4: multi-model co-residency, honest per-engine KV grants) must
// never route to an older binary, no matter what that binary advertises — an
// old mixed box would silently legacy-serve it at collapsed batch throughput.
// EIGENINFERENCE_MODEL_VERSION_FLOORS maps model patterns to minimum provider
// binary versions ("pattern=version" CSV, e.g. "gemma-4=0.7.5"). A pattern is
// matched as a case-insensitive substring of the resolved build id — the same
// matching semantics as EIGENINFERENCE_DEDICATED_MODELS
// (dedicatedPatternForLocked) — and the version comparison is CompareVersions,
// the same tolerant dotted-numeric compare the capability version floors use.
//
// Enforcement points (both, so we never pre-warm a box we won't route to):
//   - the single routing gate providerPassesRoutingGatesLockedEx (shared by the
//     dispatch hot path, the capacity preflight, and the final admit re-check),
//     beside the trait version floors;
//   - the warm-pool candidate gate warmPoolCandidateReasonLocked (reason
//     warmColdBelowVersionFloor).
//
// Providers with an EMPTY version fail every floor (same rule as the trait
// floors: a binary too old to report a version is below any floor). An empty
// env — the default — disables the feature entirely: zero behavior change.
// The env is expected to RETIRE (empty again) after fleet convergence.

// ModelVersionFloor pairs a build-id substring pattern with the minimum
// provider binary version able to serve matching models.
type ModelVersionFloor struct {
	Pattern string // lowercased, non-empty substring of the resolved build id
	Version string // minimum provider binary version (CompareVersions semantics)
}

// ParseModelVersionFloors parses a "pattern=version" CSV into normalized
// floors. Patterns are trimmed + lowercased; versions are trimmed. Entries
// with an empty pattern or empty version (or no '=') are skipped — a malformed
// entry must degrade to "no floor for that pattern", never to a floor that
// blocks or admits the wrong providers. An empty or all-invalid input yields
// nil (feature disabled). Entry order is preserved: like the dedicated-model
// patterns, the FIRST matching pattern wins.
func ParseModelVersionFloors(csv string) []ModelVersionFloor {
	var out []ModelVersionFloor
	for _, entry := range strings.Split(csv, ",") {
		entry = strings.TrimSpace(entry)
		if entry == "" {
			continue
		}
		pattern, version, ok := strings.Cut(entry, "=")
		if !ok {
			continue
		}
		pattern = strings.ToLower(strings.TrimSpace(pattern))
		version = strings.TrimSpace(version)
		if pattern == "" || version == "" {
			continue
		}
		out = append(out, ModelVersionFloor{Pattern: pattern, Version: version})
	}
	return out
}

// FormatModelVersionFloors renders floors back to the "pattern=version" CSV
// form for startup logging.
func FormatModelVersionFloors(floors []ModelVersionFloor) string {
	parts := make([]string, 0, len(floors))
	for _, f := range floors {
		parts = append(parts, f.Pattern+"="+f.Version)
	}
	return strings.Join(parts, ",")
}

// SetModelVersionFloors configures the per-model provider-version routing
// floors. Entries are re-normalized defensively (SetDedicatedModels does the
// same); invalid entries are dropped. An empty (or all-invalid) list disables
// the feature. Called once at startup before the coordinator begins serving.
func (r *Registry) SetModelVersionFloors(floors []ModelVersionFloor) {
	normalized := make([]ModelVersionFloor, 0, len(floors))
	for _, f := range floors {
		pattern := strings.ToLower(strings.TrimSpace(f.Pattern))
		version := strings.TrimSpace(f.Version)
		if pattern == "" || version == "" {
			continue
		}
		normalized = append(normalized, ModelVersionFloor{Pattern: pattern, Version: version})
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if len(normalized) == 0 {
		r.modelVersionFloors = nil
		return
	}
	r.modelVersionFloors = normalized
}

// modelVersionFloorForLocked returns the minimum provider version for the
// resolved build id, or "", false when no configured pattern matches (or the
// feature is disabled). First matching pattern wins, mirroring
// dedicatedPatternForLocked. Caller holds r.mu.
func (r *Registry) modelVersionFloorForLocked(model string) (string, bool) {
	if len(r.modelVersionFloors) == 0 {
		return "", false
	}
	m := strings.ToLower(model)
	for _, f := range r.modelVersionFloors {
		if strings.Contains(m, f.Pattern) {
			return f.Version, true
		}
	}
	return "", false
}

// providerBelowModelVersionFloorLocked reports whether the per-model version
// floor EXCLUDES this provider for the model: a floor is configured for the
// model AND the provider's binary version is below it (an empty version is
// below any floor). false when no floor matches the model — the common case
// and the whole-feature-disabled case. Applied to self-route too: unlike the
// dedicated-box rule (a routing-policy partition owners may opt out of), the
// floor exists because a below-floor binary would MIS-SERVE the model, which
// is just as true on the owner's own machine. Caller holds r.mu and p.mu
// (p.Version is guarded by p.mu — same discipline as
// providerMeetsTraitFloorsLocked).
func (r *Registry) providerBelowModelVersionFloorLocked(p *Provider, model string) bool {
	floor, ok := r.modelVersionFloorForLocked(model)
	if !ok {
		return false
	}
	return p.Version == "" || CompareVersions(p.Version, floor) < 0
}
