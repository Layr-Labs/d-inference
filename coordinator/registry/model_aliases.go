package registry

import (
	"time"
)

// AliasTarget is the declarative resolution target for a public alias: a single
// Desired build the fleet converges to, with an optional still-acceptable
// Previous build during a staggered rollout. No weights, no ramp. Retired holds
// former members (rotated out by later upserts) — never routed, but used to
// recognize a returning provider that was offline through a retirement as part
// of this alias's fleet so it still receives desired_models. OpenRouterOnly
// targets resolve requests but never drive provider convergence or canonical
// build-to-public-name mapping.
type AliasTarget struct {
	Desired        string
	Previous       string
	Retired        []string
	OpenRouterOnly bool
}

// SetModelAliases installs the public-alias → {desired, previous} mapping. Pass
// nil (or an empty map) to clear all aliases. Callers pass only ACTIVE aliases
// (the store/sync layer filters inactive ones out). An alias whose Desired is
// empty contributes nothing routable.
func (r *Registry) SetModelAliases(aliases map[string]AliasTarget) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if len(aliases) == 0 {
		r.modelAliases = nil
		return
	}
	m := make(map[string]AliasTarget, len(aliases))
	for alias, t := range aliases {
		m[alias] = t
	}
	r.modelAliases = m
}

// PublicNameForBuild returns the public alias a concrete build is exposed under
// (the consumer-facing name), or the build id unchanged if it isn't the desired
// or previous build of any alias. This lets consumer-facing surfaces (e.g. usage
// history) show the alias while billing/stats/earnings keep storing the concrete
// build. If several aliases map to the build, the lexicographically-first is
// returned for stability.
func (r *Registry) PublicNameForBuild(buildID string) string {
	if buildID == "" {
		return buildID
	}
	r.mu.RLock()
	defer r.mu.RUnlock()
	best := ""
	for alias, t := range r.modelAliases {
		if t.OpenRouterOnly {
			continue
		}
		if t.Desired == buildID || t.Previous == buildID {

			if best == "" || alias < best {
				best = alias
			}
		}
	}
	if best == "" {
		return buildID
	}
	return best
}

// IsAlias reports whether requested is a configured public alias.
func (r *Registry) IsAlias(requested string) bool {
	r.mu.RLock()
	defer r.mu.RUnlock()
	_, ok := r.modelAliases[requested]
	return ok
}

// AliasTarget returns the configured desired/previous build pointers for alias.
func (r *Registry) AliasTarget(alias string) (AliasTarget, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	t, ok := r.modelAliases[alias]
	return t, ok
}

// ResolveModel maps a requested model id to a concrete build id for routing.
//
//   - If requested is NOT an alias, it is returned unchanged (isAlias=false,
//     ok=true) — raw build ids keep working for backward compatibility.
//   - If requested IS an alias, it resolves to the Desired build when at least
//     one provider can route it; otherwise to the Previous build when that is
//     routable; otherwise it returns Desired so the request queues against a
//     real build instead of black-holing. ok=false only when Desired is empty.
func (r *Registry) ResolveModel(requested string) (buildID string, isAlias bool, ok bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()

	t, found := r.modelAliases[requested]
	if !found {
		return requested, false, true
	}
	if t.Desired == "" {
		return "", true, false
	}
	if r.anyProviderCanRouteBuildLocked(t.Desired) {
		return t.Desired, true, true
	}
	if t.Previous != "" && r.anyProviderCanRouteBuildLocked(t.Previous) {
		return t.Previous, true, true
	}
	// Neither build is routable yet — resolve to Desired so the request queues
	// against a real build instead of failing outright.
	return t.Desired, true, true
}

// ResolveModelConstrained is ResolveModel, but when a request is restricted to
// specific providers — a serial allowlist or self-route to the owner's own
// machines — it only treats a build as servable if an ELIGIBLE provider (one
// that both matches the constraint and can route the build) can serve it. This
// stops an alias from resolving to a build that's routable somewhere globally
// but absent from the request's allowed provider set (which would then fail at
// dispatch). With no constraints it is identical to ResolveModel.
func (r *Registry) ResolveModelConstrained(requested string, allowedSerials []string, ownerAccountID string, selfRouteOnly, preferOwner bool) (buildID string, isAlias bool, ok bool) {
	return r.ResolveModelConstrainedWithTraits(
		requested, allowedSerials, ownerAccountID, selfRouteOnly, preferOwner,
		RequestTraits{})
}

// ResolveModelConstrainedWithTraits extends ResolveModelConstrained with the
// same request-shape gates used at dispatch. During a mixed-version rollout an
// alias must not resolve to Desired merely because an old provider can serve
// ordinary text when Previous has a provider capable of the requested shape.
func (r *Registry) ResolveModelConstrainedWithTraits(
	requested string,
	allowedSerials []string,
	ownerAccountID string,
	selfRouteOnly, preferOwner bool,
	traits RequestTraits,
) (buildID string, isAlias bool, ok bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()

	t, found := r.modelAliases[requested]
	if !found {
		return requested, false, true
	}
	if t.Desired == "" {
		return "", true, false
	}
	allowed := make(map[string]struct{}, len(allowedSerials))
	for _, s := range allowedSerials {
		if s != "" {
			allowed[s] = struct{}{}
		}
	}
	now := time.Now()
	hardConstrained := len(allowed) > 0 || selfRouteOnly
	if preferOwner && ownerAccountID != "" {
		if r.anyProviderCanServeAliasWithTraitsLocked(
			t.Desired, nil, ownerAccountID, true, true, now, traits, false,
		) {
			return t.Desired, true, true
		}
		if t.Previous != "" && r.anyProviderCanServeAliasWithTraitsLocked(
			t.Previous, nil, ownerAccountID, true, true, now, traits, false,
		) {
			return t.Previous, true, true
		}
	}
	if !hardConstrained {
		if r.anyProviderCanServeAliasWithTraitsLocked(
			t.Desired, nil, "", false, false, now, traits, false,
		) {
			return t.Desired, true, true
		}
		if t.Previous != "" && r.anyProviderCanServeAliasWithTraitsLocked(
			t.Previous, nil, "", false, false, now, traits, false,
		) {
			return t.Previous, true, true
		}
		if r.anyProviderCanServeAliasWithTraitsLocked(
			t.Desired, nil, "", false, false, now, traits, true,
		) {
			return t.Desired, true, true
		}
		if t.Previous != "" && r.anyProviderCanServeAliasWithTraitsLocked(
			t.Previous, nil, "", false, false, now, traits, true,
		) {
			return t.Previous, true, true
		}
		return t.Desired, true, true
	}
	if t.Desired != "" && r.anyProviderCanServeAliasWithTraitsLocked(
		t.Desired, allowed, ownerAccountID, selfRouteOnly, preferOwner, now, traits, false,
	) {
		return t.Desired, true, true
	}
	if t.Previous != "" && r.anyProviderCanServeAliasWithTraitsLocked(
		t.Previous, allowed, ownerAccountID, selfRouteOnly, preferOwner, now, traits, false,
	) {
		return t.Previous, true, true
	}
	if t.Desired != "" && r.anyProviderCanServeAliasWithTraitsLocked(
		t.Desired, allowed, ownerAccountID, selfRouteOnly, preferOwner, now, traits, true,
	) {
		return t.Desired, true, true
	}
	if t.Previous != "" && r.anyProviderCanServeAliasWithTraitsLocked(
		t.Previous, allowed, ownerAccountID, selfRouteOnly, preferOwner, now, traits, true,
	) {
		return t.Previous, true, true
	}
	// Only HARD-constrained requests (serial pin / self-route-only) reach here —
	// the unconstrained path returned ResolveModel above. So if no allowed+
	// eligible provider can serve either build, do NOT fall back to Desired: that
	// would resolve to a build the allowed providers can't serve (the exact thing
	// this function exists to prevent) and then queue/fail against the wrong
	// build, or for self-route leak toward the fleet. Return unavailable.
	return "", true, false
}

// anyProviderCanServeAliasWithTraitsLocked reports whether some provider
// matches the request's routing constraints and exact capability traits.
// structural=true ignores transient slot/cooldown state so alias resolution can
// queue against a capable build instead of falling back to an incapable one.
// Self-route to an owned machine relaxes trust and allows private-only
// providers, mirroring snapshotProviderIntoLockedEx. Caller holds r.mu.
func (r *Registry) anyProviderCanServeAliasWithTraitsLocked(
	buildID string,
	allowedSerials map[string]struct{},
	ownerAccountID string,
	selfRouteOnly, preferOwner bool,
	now time.Time,
	traits RequestTraits,
	structural bool,
) bool {
	// Only providers advertising the build can route it; the per-model index
	// prunes the rest (gates unchanged). Copied before any p.mu is taken.
	for _, p := range r.providersForModelLocked(buildID) {
		p.mu.Lock()
		ok := func() bool {
			if len(allowedSerials) > 0 {
				// A provider with no attestation result can't be serial-matched
				// (and dereferencing it would panic) — treat as not eligible.
				serial := ""
				if p.AttestationResult != nil {
					serial = p.AttestationResult.SerialNumber
				}
				if _, in := allowedSerials[serial]; !in || serial == "" {
					return false
				}
			}
			owned := p.AccountID != "" && p.AccountID == ownerAccountID
			if selfRouteOnly && !owned {
				return false
			}
			minTrust := r.MinTrustLevel
			allowPrivate := false
			if owned && (selfRouteOnly || preferOwner) {
				minTrust = TrustNone
				allowPrivate = true
			}
			canRoute := r.providerCanRouteBuildLocked(
				p, buildID, minTrust, now, allowPrivate)
			if structural {
				canRoute = r.providerStructurallyCanRouteBuildLocked(
					p, buildID, minTrust, now, allowPrivate)
			}
			return canRoute && r.providerEligibleForTraitsLocked(p, buildID, traits)
		}()
		p.mu.Unlock()
		if ok {
			return true
		}
	}
	return false
}

// providerStructurallyCanRouteBuildLocked reports whether a provider has every
// non-capacity prerequisite for serving a build. Transient load cooldowns and
// slot states are intentionally excluded so queued requests can wait for a
// reloading capable provider instead of being misreported as capability-
// unavailable. Caller holds r.mu (RLock) and p.mu.
func (r *Registry) providerStructurallyCanRouteBuildLocked(
	p *Provider,
	buildID string,
	minTrust TrustLevel,
	now time.Time,
	allowPrivate bool,
) bool {
	// Catalog membership + dedicated-box isolation, mirroring
	// providerPassesRoutingGatesLockedEx so alias routability (and rollout/drop
	// measurement) matches actual dispatch routability: a dedicated-family build
	// is only routable on a provider dedicated to that family. Without this, an
	// alias whose Desired build is advertised only by a mixed box would resolve
	// to Desired (then 429 at dispatch) instead of failing over to a Previous
	// build on a dedicated box. allowPrivate marks the owner self-route context,
	// exempt like selfRouteOwner.
	if !r.providerServesRoutableModelLocked(p, buildID, allowPrivate) {
		return false
	}
	// Liveness/trust/privacy core. allowPrivate marks the owner self-route
	// context (relax private-only admission); the trust-floor relaxation is
	// folded into the minTrust the caller passes (TrustNone for owner routes).
	if !r.providerLivenessGateLocked(p, minTrust, allowPrivate, now) {
		return false
	}
	// Hardware fit: don't count a provider whose RAM can't hold the build (e.g.
	// migrating to a larger build than the source). totalMemory prefers the
	// backend-reported figure, matching snapshotProviderIntoLockedEx. A resident
	// running/idle slot has already demonstrated fit and must bypass the
	// heuristic. Owner-only off-catalog models use their advertised size.
	totalMemoryGB := float64(p.Hardware.MemoryGB)
	slotState := "unknown"
	if p.BackendCapacity != nil && p.BackendCapacity.TotalMemoryGB > 0 {
		totalMemoryGB = p.BackendCapacity.TotalMemoryGB
	}
	if p.BackendCapacity != nil {
		for _, slot := range p.BackendCapacity.Slots {
			if slot.Model == buildID {
				slotState = slot.State
				break
			}
		}
	}
	return slotStateModelLoaded(slotState) ||
		modelFitsHardware(
			r.catalogMinRAMGbLocked(buildID),
			r.modelSizeGBForFitLocked(p, buildID),
			totalMemoryGB)
}

// providerCanRouteBuildLocked is the single source of truth for "could this
// provider actually serve this build right now". It adds transient cooldown and
// slot-state gates to providerStructurallyCanRouteBuildLocked, while still
// omitting per-request capacity/headroom checks. Cold-but-healthy providers
// pass (no warm slot required — they load on first demand). Caller holds r.mu
// (RLock) and p.mu.
func (r *Registry) providerCanRouteBuildLocked(p *Provider, buildID string, minTrust TrustLevel, now time.Time, allowPrivate bool) bool {
	if !r.providerStructurallyCanRouteBuildLocked(
		p, buildID, minTrust, now, allowPrivate,
	) {
		return false
	}
	// The session's current gate, read under p.mu — which the identity bind
	// also holds (bindStableFaultKey) — so a rebind cannot repoint p.gate, or
	// migrate the cooldown away from the gate read here, mid-check. Without
	// that, a read of a shared source gate emptied by this session's own
	// rebind would say "not cooled" and let an alias resolve to a Desired
	// build whose only provider is cooled (the request then queues or 429s
	// instead of taking the routable Previous build). No gateView
	// confirmation is needed under p.mu.
	if r.gateOf(p).dispatchLoadCooled(buildID, now) {
		return false
	}
	if p.BackendCapacity != nil {
		for _, slot := range p.BackendCapacity.Slots {
			if slot.Model != buildID {
				continue
			}
			if _, eligible := slotStatePenalty(slot.State); !eligible {
				return false
			}
			break
		}
	}
	return true
}

// anyProviderCanRouteBuildLocked reports whether at least one provider could
// route the build right now. Caller holds r.mu.
func (r *Registry) anyProviderCanRouteBuildLocked(buildID string) bool {
	now := time.Now()
	minTrust := r.MinTrustLevel
	// Per-model index: only advertisers can route the build (model_index.go).
	for _, p := range r.providersForModelLocked(buildID) {
		p.mu.Lock()
		ok := r.providerCanRouteBuildLocked(p, buildID, minTrust, now, false)
		p.mu.Unlock()
		if ok {
			return true
		}
	}
	return false
}

// RoutableProviderIDsForBuild returns the ids of providers that would actually
// pass the routing gate for the build right now — the SAME checks
// snapshotProviderIntoLockedEx applies (advertises the build, not offline/untrusted,
// public, trust ≥ floor, runtime verified, private-text capable, fresh
// challenge), minus per-request capacity/headroom. Cold-but-healthy providers
// count (no warm slot required — they load on first demand). Used to measure how
// much of the fleet can truly serve a build (e.g. rollout progress / hard-swap
// drop verification in tests) without counting capacity it can't actually route.
func (r *Registry) RoutableProviderIDsForBuild(buildID string) []string {
	r.mu.RLock()
	defer r.mu.RUnlock()
	now := time.Now()
	minTrust := r.MinTrustLevel
	var ids []string
	for id, p := range r.providers {
		p.mu.Lock()
		ok := r.providerCanRouteBuildLocked(p, buildID, minTrust, now, false)
		p.mu.Unlock()
		if ok {
			ids = append(ids, id)
		}
	}
	return ids
}
