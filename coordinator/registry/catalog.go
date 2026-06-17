package registry

import (
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// TruncHash returns the first 16 chars of a hash string for logging.
func TruncHash(h string) string {
	if len(h) > 16 {
		return h[:16] + "..."
	}
	return h
}

// CatalogEntry holds metadata about an active model in the catalog.
type CatalogEntry struct {
	ID         string
	WeightHash string  // expected SHA-256 weight fingerprint (empty = not enforced)
	SizeGB     float64 // disk/GPU footprint of the model weights (zero = unknown, gate disabled)
	// MinRAMGB is the catalog's authoritative minimum unified memory (GB) to run
	// this model — the operator-published requirement. The hardware-fit gate
	// prefers this over any heuristic multiple of SizeGB. Zero = unknown.
	MinRAMGB int
}

// SetModelCatalog updates the set of active models. Only models in this
// set will be accepted from providers during registration and routable to
// consumers. Pass nil to disable catalog filtering for tests/dev flows. Passing
// an empty non-nil slice configures a deny-all catalog, which is what a fresh
// DB-backed registry should do until an operator registers and promotes models.
func (r *Registry) SetModelCatalog(entries []CatalogEntry) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if entries == nil {
		r.modelCatalog = nil
		return
	}
	catalog := make(map[string]CatalogEntry, len(entries))
	for _, e := range entries {
		catalog[e.ID] = e
	}
	r.modelCatalog = catalog
}

// AliasTarget is the declarative resolution target for a public alias: a single
// Desired build the fleet converges to, with an optional still-acceptable
// Previous build during a staggered rollout. No weights, no ramp. Retired holds
// former members (rotated out by later upserts) — never routed, but used to
// recognize a returning provider that was offline through a retirement as part
// of this alias's fleet so it still receives desired_models.
type AliasTarget struct {
	Desired  string
	Previous string
	Retired  []string
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
	if len(allowedSerials) == 0 && !selfRouteOnly && !preferOwner {
		return r.ResolveModel(requested)
	}
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
		if r.anyEligibleProviderCanRouteLocked(t.Desired, nil, ownerAccountID, true, true, now) {
			return t.Desired, true, true
		}
		if t.Previous != "" && r.anyEligibleProviderCanRouteLocked(t.Previous, nil, ownerAccountID, true, true, now) {
			return t.Previous, true, true
		}
	}
	if !hardConstrained {
		if r.anyProviderCanRouteBuildLocked(t.Desired) {
			return t.Desired, true, true
		}
		if t.Previous != "" && r.anyProviderCanRouteBuildLocked(t.Previous) {
			return t.Previous, true, true
		}
		return t.Desired, true, true
	}
	if t.Desired != "" && r.anyEligibleProviderCanRouteLocked(t.Desired, allowed, ownerAccountID, selfRouteOnly, preferOwner, now) {
		return t.Desired, true, true
	}
	if t.Previous != "" && r.anyEligibleProviderCanRouteLocked(t.Previous, allowed, ownerAccountID, selfRouteOnly, preferOwner, now) {
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

// anyEligibleProviderCanRouteLocked reports whether some provider both matches
// the request's constraint (serial allowlist and/or self-route ownership) and
// can route the build. Self-route to an OWNED machine relaxes trust and allows
// private-only providers, mirroring snapshotProviderLocked. Caller holds r.mu.
func (r *Registry) anyEligibleProviderCanRouteLocked(buildID string, allowedSerials map[string]struct{}, ownerAccountID string, selfRouteOnly, preferOwner bool, now time.Time) bool {
	for _, p := range r.providers {
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
			return r.providerCanRouteBuildLocked(p, buildID, minTrust, now, allowPrivate)
		}()
		p.mu.Unlock()
		if ok {
			return true
		}
	}
	return false
}

// providerCanRouteBuildLocked is the single source of truth for "could this
// provider actually serve this build right now" — the same gates
// snapshotProviderLocked applies (advertises the build + in catalog, not
// offline/untrusted, public, trust ≥ floor, runtime verified, private-text
// capable, fresh challenge, AND the model fits the provider's RAM), minus the
// per-request capacity/headroom checks. Cold-but-healthy providers pass (no warm
// slot required — they load on first demand). Caller holds r.mu (RLock) and p.mu.
func (r *Registry) providerCanRouteBuildLocked(p *Provider, buildID string, minTrust TrustLevel, now time.Time, allowPrivate bool) bool {
	if !r.providerServesCatalogModelLocked(p, buildID) {
		return false
	}
	if r.dispatchLoadCooldownActiveLocked(p.ID, buildID, now) {
		return false
	}
	if p.Status == StatusOffline || p.Status == StatusUntrusted {
		return false
	}
	if p.PrivateOnly && !allowPrivate {
		return false
	}
	if trustRank(p.TrustLevel) < trustRank(minTrust) {
		return false
	}
	if !p.RuntimeVerified || !r.providerSupportsPrivateTextLocked(p) {
		return false
	}
	if p.LastChallengeVerified.IsZero() || now.Sub(p.LastChallengeVerified) > challengeFreshnessMaxAge {
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
	// Hardware fit: don't count a provider whose RAM can't hold the build (e.g.
	// migrating to a larger build than the source). totalMemory prefers the
	// backend-reported figure, matching snapshotProviderLocked.
	totalMemoryGB := float64(p.Hardware.MemoryGB)
	if p.BackendCapacity != nil && p.BackendCapacity.TotalMemoryGB > 0 {
		totalMemoryGB = p.BackendCapacity.TotalMemoryGB
	}
	return modelFitsHardware(r.catalogMinRAMGbLocked(buildID), r.catalogSizeGBLocked(buildID), totalMemoryGB)
}

// anyProviderCanRouteBuildLocked reports whether at least one provider could
// route the build right now. Caller holds r.mu.
func (r *Registry) anyProviderCanRouteBuildLocked(buildID string) bool {
	now := time.Now()
	minTrust := r.MinTrustLevel
	for _, p := range r.providers {
		p.mu.Lock()
		ok := r.providerCanRouteBuildLocked(p, buildID, minTrust, now, false)
		p.mu.Unlock()
		if ok {
			return true
		}
	}
	return false
}

// MergeProviderModels applies a provider's authoritative models_update to its
// advertised Models in place — used for the message a provider sends after it
// converges on a desired build (background prefetch verified, then hard-swap),
// so a new build becomes routable WITHOUT a reconnect and WITHOUT resetting
// trust/reputation/challenge state. It is authoritative for each alias whose
// desired build appears in the validated update: that alias's previous build is
// dropped if omitted. Seeing a build only as another alias's previous build is
// not enough to drop that other alias's desired build, which keeps aliases that
// share a concrete build independent.
//
// Each model's WeightHash is cross-checked against the catalog's expected hash;
// a mismatch is REJECTED (the build is not made routable) so a bad or buggy
// prefetch/swap can never take traffic. Returns build ids that were merged and
// build ids that were dropped from this provider.
func (r *Registry) MergeProviderModels(providerID string, models []protocol.ModelInfo) (merged, dropped []string) {
	if len(models) == 0 {
		return nil, nil
	}
	r.mu.RLock()
	p, ok := r.providers[providerID]
	// hasCatalog mirrors modelAllowedByCatalogLocked: a nil catalog (dev/test
	// setups) imposes no membership gate; a present catalog makes membership
	// mandatory for merging.
	hasCatalog := r.modelCatalog != nil
	expected := make(map[string]string, len(models))
	for _, m := range models {
		if e, has := r.modelCatalog[m.ID]; has {
			expected[m.ID] = e.WeightHash
		}
	}
	// Snapshot the alias targets under the read lock so the drop set can be
	// computed later (under p.mu) without nesting r.mu — and, crucially, from
	// the builds that actually PASS validation below, not from the raw message.
	aliasTargets := make([]AliasTarget, 0, len(r.modelAliases))
	for _, t := range r.modelAliases {
		aliasTargets = append(aliasTargets, t)
	}
	r.mu.RUnlock()
	if !ok {
		return nil, nil
	}

	p.mu.Lock()
	defer p.mu.Unlock()
	// present tracks only builds that passed validation and were merged — the
	// hard-swap drop is derived from THIS set, never from the raw message. A
	// desired build rejected for a bad weight hash therefore does NOT cause its
	// previous sibling to be dropped (which would strand the provider on neither
	// build — the exact failure the hash check exists to prevent).
	present := make(map[string]struct{}, len(models))
	for _, m := range models {
		if m.ID == "" {
			continue
		}
		// A build the catalog has never heard of is rejected outright (when a
		// catalog exists). It could never be routed anyway
		// (modelAllowedByCatalogLocked), and merging it would let a provider
		// grow its own p.Models without bound via repeated models_update
		// messages carrying fabricated ids.
		if _, inCatalog := expected[m.ID]; hasCatalog && !inCatalog {
			r.logger.Warn("models_update for build not in catalog; rejecting",
				"provider_id", providerID, "model_id", m.ID)
			continue
		}
		// When the catalog pins an expected hash, a models_update MUST carry a
		// non-empty MATCHING hash. A missing hash is rejected just like a
		// mismatched one — otherwise a buggy/malicious update that omits
		// weight_hash (or a nil WeightHasher.computeHash on the provider) would be
		// merged as "validated" and could cut the provider over to an unverified
		// desired build while dropping the last known-good previous sibling.
		if exp := expected[m.ID]; exp != "" && !strings.EqualFold(m.WeightHash, exp) {
			r.logger.Warn("models_update weight-hash missing or mismatched; rejecting build",
				"provider_id", providerID, "model_id", m.ID, "expected", exp, "got", m.WeightHash)
			continue
		}
		replaced := false
		for i := range p.Models {
			if p.Models[i].ID == m.ID {
				p.Models[i] = m
				replaced = true
				break
			}
		}
		if !replaced {
			p.Models = append(p.Models, m)
		}
		merged = append(merged, m.ID)
		present[m.ID] = struct{}{}
	}
	// Compute the hard-swap drop set: a VALIDATED desired build authorizes
	// dropping only that alias's previous build. This is intentionally
	// directional; if two aliases share a build, updating one alias to that shared
	// desired build must not drop the desired build of another alias where the
	// shared build is merely "previous".
	drop := make(map[string]struct{})
	for _, t := range aliasTargets {
		if t.Desired == "" || t.Previous == "" || t.Desired == t.Previous {
			continue
		}
		if _, desiredPresent := present[t.Desired]; !desiredPresent {
			continue
		}
		if _, previousStillPresent := present[t.Previous]; !previousStillPresent {
			drop[t.Previous] = struct{}{}
		}
	}
	// Apply the hard-swap drop: remove any alias-sibling build the provider no
	// longer advertises.
	if len(drop) > 0 {
		kept := p.Models[:0]
		for _, m := range p.Models {
			if _, gone := drop[m.ID]; gone {
				r.logger.Info("models_update hard-swap: dropping retired build",
					"provider_id", providerID, "model_id", m.ID)
				dropped = append(dropped, m.ID)
				continue
			}
			kept = append(kept, m)
		}
		p.Models = kept
	}
	return merged, dropped
}

// RoutableProviderIDsForBuild returns the ids of providers that would actually
// pass the routing gate for the build right now — the SAME checks
// snapshotProviderLocked applies (advertises the build, not offline/untrusted,
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

// ModelType returns the model type string for the given model ID, or
// "unknown" if no provider is currently serving it.
func (r *Registry) ModelType(model string) string {
	r.mu.RLock()
	defer r.mu.RUnlock()
	for _, p := range r.providers {
		p.mu.Lock()
		for _, m := range p.Models {
			if m.ID == model && m.ModelType != "" {
				p.mu.Unlock()
				return m.ModelType
			}
		}
		p.mu.Unlock()
	}
	return "unknown"
}

// IsModelInCatalog returns true if the model is in the active catalog, or if
// catalog filtering has been explicitly disabled by setting a nil catalog.
func (r *Registry) IsModelInCatalog(model string) bool {
	r.mu.RLock()
	defer r.mu.RUnlock()
	if r.modelCatalog == nil {
		return true
	}
	_, ok := r.modelCatalog[model]
	return ok
}

// UpdateModelWeightHashes refreshes the stored per-model weight hashes for a
// provider from a verified attestation challenge response. Providers recompute
// weight hashes when a model is (re)loaded from disk — e.g. after a model was
// re-published and re-downloaded while the daemon kept running. Without this,
// the registry would keep the registration-time snapshot and the per-model
// catalog filter (modelAllowedByCatalogLocked) would silently stop routing the
// model to this provider until its next reconnect.
//
// Concurrency: the p.Models slice header is replaced (copy-on-write, never
// mutated in place) under p.mu — NOT under the registry-wide r.mu, which is held
// only as a read lock to look the provider up in the map. p.mu is therefore the
// sole lock guarding p.Models, so every reader that ranges p.Models must hold
// p.mu (see providerModelIDs and the *Locked helpers). Do not rely on r.mu to
// serialize reads against this write: it does not.
func (r *Registry) UpdateModelWeightHashes(providerID string, hashes map[string]string) {
	if len(hashes) == 0 {
		return
	}
	r.mu.RLock()
	p, ok := r.providers[providerID]
	r.mu.RUnlock()
	if !ok {
		return
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	changed := false
	models := make([]protocol.ModelInfo, len(p.Models))
	copy(models, p.Models)
	for i := range models {
		if h, ok := hashes[models[i].ID]; ok && h != "" && models[i].WeightHash != h {
			models[i].WeightHash = h
			changed = true
		}
	}
	if changed {
		p.Models = models
	}
}

// CatalogWeightHash returns the expected weight hash for a model, or empty
// string if not set or not in catalog.
func (r *Registry) CatalogWeightHash(model string) string {
	r.mu.RLock()
	defer r.mu.RUnlock()
	if e, ok := r.modelCatalog[model]; ok {
		return e.WeightHash
	}
	return ""
}

// IsAliasLineageBuild reports whether buildID is a PREVIOUS or RETIRED member of
// any active alias — i.e. an old build that a hot-swap migration legitimately
// leaves GPU-resident on providers after it drops from the advertised set. Used
// to scope the attestation active-hash alibi to exactly that migration case, so
// a provider can't use the alibi to claim an arbitrary unrelated catalog model
// as active. (Desired members are still advertised, so they never need it.)
func (r *Registry) IsAliasLineageBuild(buildID string) bool {
	if buildID == "" {
		return false
	}
	r.mu.RLock()
	defer r.mu.RUnlock()
	for _, t := range r.modelAliases {
		if t.Previous == buildID {
			return true
		}
		for _, retired := range t.Retired {
			if retired == buildID {
				return true
			}
		}
	}
	return false
}

// modelAllowedByCatalogLocked returns whether a provider-reported model is
// allowed by the current catalog. Caller must hold r.mu (read or write). A nil
// catalog disables filtering; an empty non-nil catalog denies all models.
func (r *Registry) modelAllowedByCatalogLocked(model protocol.ModelInfo) bool {
	if r.modelCatalog == nil {
		return true
	}
	entry, ok := r.modelCatalog[model.ID]
	if !ok {
		return false
	}
	return entry.WeightHash == "" || model.WeightHash == "" || model.WeightHash == entry.WeightHash
}

// providerServesCatalogModelLocked returns true if the provider advertises the
// model and that model is currently allowed by the catalog. Caller must hold
// r.mu and p.mu.
func (r *Registry) providerServesCatalogModelLocked(p *Provider, model string) bool {
	for _, m := range p.Models {
		if m.ID == model && r.modelAllowedByCatalogLocked(m) {
			return true
		}
	}
	return false
}

// providerServesVisionModelLocked reports whether the provider advertises the
// model as a vision-capable (VLM) build — required to route image/video requests
// so the media is actually perceived rather than silently dropped. Caller must
// hold r.mu AND p.mu (mirrors providerServesCatalogModelLocked): p.Models is
// guarded by p.mu and mutated by MergeProviderModels/UpdateModelWeightHashes.
// Pre-0.6.0 providers never set IsVision, so they are correctly excluded.
func (r *Registry) providerServesVisionModelLocked(p *Provider, model string) bool {
	for _, m := range p.Models {
		if m.ID == model && m.IsVision && r.modelAllowedByCatalogLocked(m) {
			return true
		}
	}
	return false
}

// HasVisionProviderForModel reports whether any online, non-untrusted provider
// advertises a vision-capable build for the resolved model id. The consumer uses
// it to fail a media request fast with a clear error when the fleet has no
// VLM-capable provider for the model (e.g. before the gemma fleet finishes
// updating to 0.6.0), instead of queueing the request to a timeout.
//
// When allowedSerials is non-empty the check is restricted to providers whose
// attested serial is in the set, exactly as the routing path constrains the
// candidate pool. Without this filter a constrained media request would be
// falsely reported as serviceable by an unrelated public provider (the same
// latent gap as HasToolCapableProviderForModel).
func (r *Registry) HasVisionProviderForModel(model string, allowedSerials ...string) bool {
	allowedSet := make(map[string]struct{}, len(allowedSerials))
	for _, s := range allowedSerials {
		allowedSet[s] = struct{}{}
	}
	r.mu.RLock()
	defer r.mu.RUnlock()
	for _, p := range r.providers {
		// Allowed-serial filter first (providerMatchesAllowedSerial takes p.mu
		// internally), mirroring the routing candidate filter and QuickCapacityCheck.
		if len(allowedSet) > 0 && !providerMatchesAllowedSerial(p, allowedSet) {
			continue
		}
		// p.Status and p.Models are guarded by p.mu (writers hold it), so the
		// whole eligibility read must happen under the provider lock.
		p.mu.Lock()
		eligible := p.Status != StatusOffline && p.Status != StatusUntrusted &&
			r.providerServesVisionModelLocked(p, model)
		p.mu.Unlock()
		if eligible {
			return true
		}
	}
	return false
}

// catalogSizeGBLocked returns the model's reported weight footprint in GB,
// or 0 when unknown. Caller must hold r.mu (read or write). Zero means the
// memory-admission gate should not enforce for this model — typically a
// catalog entry that pre-dates the SizeGB field, or a model the operator
// hasn't sized yet.
func (r *Registry) catalogSizeGBLocked(model string) float64 {
	if e, ok := r.modelCatalog[model]; ok {
		return e.SizeGB
	}
	return 0
}

// catalogMinRAMGbLocked returns the model's authoritative minimum-RAM
// requirement (GB) from the catalog, or 0 when unknown. Caller must hold r.mu.
func (r *Registry) catalogMinRAMGbLocked(model string) int {
	if e, ok := r.modelCatalog[model]; ok {
		return e.MinRAMGB
	}
	return 0
}

// trustMeetsMinimum returns true if the given trust level meets the minimum.
func (r *Registry) trustMeetsMinimum(level TrustLevel) bool {
	return trustRank(level) >= trustRank(r.MinTrustLevel)
}

// Queue returns the registry's request queue.
func (r *Registry) Queue() *RequestQueue {
	return r.queue
}

// SetQueue replaces the registry's request queue. This is useful for tests
// that need a larger queue capacity than the default.
func (r *Registry) SetQueue(q *RequestQueue) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.queue = q
}
