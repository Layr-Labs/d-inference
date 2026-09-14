package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry/routingcost"
)

// selectBestCandidateLockedFull is the full-fidelity selection that
// also reports how many providers were rejected by capacity-style
// gates (memory). Capacity rejection count lets ReserveProviderEx
// distinguish "no provider serves this model" from "every fitting
// provider is over-subscribed", which is the difference between the
// no_provider and over_capacity outcome counters.
// Returns the winner plus the candidateScan of the pass that produced it, so
// the caller can read the rejection tallies AND (for plan retention) the
// ranked pool itself without a second scan.
//
// FAIL-OPEN SAFETY VALVE: selection runs in two passes. Pass 1 honors the
// per-provider node-health breaker. If pass 1 finds ZERO candidates AND the
// breaker is the SOLE reason — it rejected at least one provider AND no healthy
// provider was merely busy or too slow — pass 2 re-runs the whole scan with the
// breaker BYPASSED (ignoreProviderBreaker=true), so a bad fleet-wide rollout
// that fault-503s every node can never deroute the entire fleet. When healthy
// providers are simply over capacity or above the TTFT ceiling, pass 1's signal
// is returned instead, so the request queues / 429s and waits for a healthy node
// rather than being routed to a known-bad provider. Pass 2's result is used only
// when it yields a candidate, and its counters (not pass 1's) are returned so
// metrics are never double-counted. This mirrors servability.go's fail-open
// philosophy: when in doubt, keep serving.
func (r *Registry) selectBestCandidateLockedFull(model string, pr *PendingRequest, excludeIDs ...string) (*routingCandidate, candidateScan) {
	winner, scan := r.selectBestCandidateScanLocked(model, pr, false, excludeIDs...)
	if !shouldBypassBreakerFailOpen(winner, scan.breakerRejected, scan.capacityRejections, scan.ttftRejections) {
		return winner, scan
	}
	// The node-health breaker is the SOLE reason this request has no route: re-scan
	// with the breaker bypassed. Use pass 2 only when it actually finds a candidate,
	// so a genuinely empty fleet still reports pass 1's (accurate) counters.
	if w2, scan2 := r.selectBestCandidateScanLocked(model, pr, true, excludeIDs...); w2 != nil {
		return w2, scan2
	}
	return winner, scan
}

// shouldBypassBreakerFailOpen decides whether selection should retry with the
// node-health breaker bypassed (the fail-open safety valve). It fails open ONLY
// when the breaker is the SOLE reason no route was found:
//   - pass 1 produced no winner, AND
//   - the breaker rejected at least one provider, AND
//   - no healthy provider was merely busy (capacityRejections) or too slow
//     (ttftRejections).
//
// If a healthy provider was just over capacity or above the TTFT ceiling, we
// surface that signal (so the request queues / 429s and waits for a healthy
// node) rather than routing to a known-bad, breaker-open provider. Model-too-
// large and vision-unsupported rejections are deliberately NOT counted: those
// providers cannot serve this request at all, so they are not a healthy
// alternative to a fail-open probe.
func shouldBypassBreakerFailOpen(winner *routingCandidate, breakerRejected, capacityRejections, ttftRejections int) bool {
	return winner == nil && breakerRejected > 0 && capacityRejections == 0 && ttftRejections == 0
}

// scanCandidatesLocked builds the eligible candidate pool for a request — every
// per-provider gate (self-route, allowlist, exclude, structural/trait/trust via
// snapshotProviderLockedEx, vision, capacity via buildCandidateWithReason, plus
// the per-request TTFT ceiling) followed by the post-candidate pool narrowing
// (prefer-owner / AvoidVersion / MinDecodeTPS) — i.e. exactly the set the
// selector ranks by cost. When ignoreProviderBreaker is true the node-health
// breaker gate is skipped (every other gate still applies); breakerRejected is
// always 0 in that mode. Caller holds r.mu and no provider lock.
func (r *Registry) scanCandidatesLocked(model string, pr *PendingRequest, ignoreProviderBreaker bool, excludeIDs ...string) candidateScan {
	// Nil maps read as empty; only allocate when there is something to hold.
	var excludeSet map[string]struct{}
	if len(excludeIDs)+len(pr.ExcludedProviderIDs) > 0 {
		excludeSet = make(map[string]struct{}, len(excludeIDs)+len(pr.ExcludedProviderIDs))
		for _, id := range excludeIDs {
			excludeSet[id] = struct{}{}
		}
		for _, id := range pr.ExcludedProviderIDs {
			excludeSet[id] = struct{}{}
		}
	}
	var allowedSerials map[string]struct{}
	if len(pr.AllowedProviderSerials) > 0 {
		allowedSerials = make(map[string]struct{}, len(pr.AllowedProviderSerials))
		for _, serial := range pr.AllowedProviderSerials {
			allowedSerials[serial] = struct{}{}
		}
	}

	// Two-pass selection: collect all eligible candidates first, then
	// compute best + tie pool. The single-pass approach was order-
	// dependent — when a new best replaced an older one within the tie
	// window, candidates near the OLD best (and still near the NEW
	// best) were dropped from the pool, making the queue-depth tie-
	// break flaky under map iteration randomness.
	// Only providers advertising the model can pass the first gate; the
	// per-model index (model_index.go) prunes the rest without touching any
	// gate. Copied before any p.mu is taken (index lock discipline).
	providers := r.providersForModelLocked(model)
	candidates := make([]*routingCandidate, 0, len(providers))
	// Candidates live in arena chunks: one allocation per candidateArenaChunk
	// candidates instead of one per candidate, and each snapshot is written
	// straight into its slot (candidate_arena.go).
	var arena candidateArena
	var scan candidateScan
	now := time.Now()
	// Vision preparation is absent from the token-prefill projection, so media
	// estimates are advisory even if a caller accidentally supplies a ceiling.
	// The request-absolute first-content deadline remains authoritative.
	enforceTTFT := pr.MaxTTFTMs > 0 && !pr.RequiresVision
	for _, p := range providers {
		scan.scanned++
		owned := providerOwnedBy(p, pr.OwnerAccountID)
		// Exclusive self-route: restrict to the caller's own machines and never
		// fall back to the public fleet. Tallied as an allowlist drop: the caller
		// restricted routing to a set of providers this one is not in.
		if pr.SelfRouteOnly && !owned {
			scan.tallyGate(GateAllowlist)
			continue
		}
		if len(allowedSerials) > 0 {
			if !providerMatchesAllowedSerial(p, allowedSerials) {
				scan.tallyGate(GateAllowlist)
				continue
			}
		}
		if _, excluded := excludeSet[p.ID]; excluded {
			scan.tallyGate(GateExcluded)
			continue
		}
		// Relax the hardware-trust floor ONLY for the caller's own (possibly
		// un-enrolled) machine — whether exclusive self-route or prefer — never
		// for public providers.
		relaxTrust := owned && (pr.SelfRouteOnly || pr.PreferOwner)
		// snapshotProviderIntoLockedEx applies every per-provider gate via the shared
		// providerPassesRoutingGatesLocked, INCLUDING the shape-keyed
		// inference-error cooldown and the trait gates (render-broken fences all
		// shapes; the tools version floor fences tool requests). A failing
		// provider is simply dropped here — the returned gate reason names WHICH
		// gate dropped it for the profiler tally without changing the verdict.
		// The snapshot is written straight into an arena slot (candidate_arena.go).
		c := arena.next()
		ok, gateReason := r.snapshotProviderIntoLockedEx(&c.snapshot, p, model, pr.Traits, relaxTrust, ignoreProviderBreaker, now)
		if !ok {
			arena.release(c)
			scan.tallyGate(gateReason)
			breaker, capacity := r.classifyRejectedProvider(
				r.gateViewOf(p), model, pr.Traits, relaxTrust, ignoreProviderBreaker, now)
			if breaker {
				scan.breakerRejected++
			}
			if capacity {
				scan.capacityRejections++
			}
			continue
		}
		// Vision gate: a media request must only go to a provider advertising a
		// vision-capable build of this model. Providers reach here only if they
		// already serve the model (snapshot ok), so a miss here means "serves it,
		// but text-only" — counted separately so the caller can return a precise
		// "no vision-capable provider" error rather than a busy/429. snapshot
		// released p.mu, so re-take it for the p.Models read.
		if pr.RequiresVision {
			p.mu.Lock()
			servesVision := r.providerServesVisionModelLocked(p, model, relaxTrust)
			p.mu.Unlock()
			if !servesVision {
				arena.release(c)
				scan.visionRejections++
				scan.tallyGate(GateVision)
				continue
			}
		}
		reason, gateReason, ok := r.buildCandidateInto(c, pr, now)
		if !ok {
			arena.release(c)
			switch reason {
			case rejectCapacity:
				scan.capacityRejections++
			case rejectModelTooLarge:
				scan.tooLargeRejections++
			case rejectVisionUnsupported:
				scan.visionRejections++
			}
			scan.tallyGate(gateReason)
			continue
		}

		// Track the best reliable TTFT seen among providers that passed all
		// structural and capacity gates. Even if this candidate is over the
		// ceiling, the value is used for Retry-After on the TTFT 429 path.
		// Providers without BackendCapacity do not contribute a reliable TTFT
		// estimate, so they are skipped here.
		if c.snapshot.HasBackendCapacity && (c.breakdown.TTFTMs < scan.bestTTFTMs || scan.bestTTFTMs == 0) {
			scan.bestTTFTMs = c.breakdown.TTFTMs
		}

		// Enforce the per-request TTFT ceiling for public inference routes.
		// Providers above the threshold are counted as TTFT rejections and
		// excluded from cost-based selection so the router cannot pick a
		// provider that misses the OpenRouter SLA target. Providers without
		// BackendCapacity have no reliable TTFT estimate, so the ceiling is
		// not enforced on them (matching the preflight behavior).
		if enforceTTFT && c.snapshot.HasBackendCapacity && c.breakdown.TTFTMs > pr.MaxTTFTMs {
			arena.release(c)
			scan.ttftRejections++
			scan.tallyGate(GateTTFTCeiling)
			continue
		}

		r.applyCacheRoutingCost(p, model, pr, c)
		// Best-idle is computed UNCONDITIONALLY over every routable candidate
		// (before pool narrowing) so the record can answer "was an idle warm box
		// available?" whether or not the shadow evaluator is on.
		scan.noteBestIdle(c)
		candidates = append(candidates, c)
		scan.candidateCount++
	}
	// With the per-model index scan.scanned counts the providers advertising
	// the model (the index members), not the whole fleet, and the
	// GateNotServingModel tally is normally 0 — the relation below still holds
	// (see RoutingDecision.Scanned).
	scan.candidateSetSize = scan.scanned - int(scan.gateRejections[GateNotServingModel])

	// Prefer-with-fallback: if the caller asked to prefer their own machine and
	// at least one owned candidate can serve, choose among owned candidates
	// only; otherwise fall back to the full pool (a public provider, charged
	// normally). Exclusive self-route already filtered to owned above.
	pool := candidates
	if pr.PreferOwner {
		pool = preferRoutingCandidates(pool, func(c *routingCandidate) bool {
			return providerOwnedBy(c.provider, pr.OwnerAccountID)
		})
	}

	// Version-diverse retry (SOFT): when a previous attempt failed on a given
	// binary version, prefer candidates running any OTHER version so a
	// deterministic per-version bug (e.g. a chat-template render crash) cannot
	// consume every retry on identical binaries. Diversity never fails closed:
	// when every candidate runs the avoided version, keep the full pool rather
	// than failing the request.
	if pr.Traits.AvoidVersion != "" {
		pool = preferRoutingCandidates(pool, func(c *routingCandidate) bool {
			return providerVersion(c.provider) != pr.Traits.AvoidVersion
		})
	}

	// Decode-floor quality preference (SOFT, Routing v2 W2): when a per-request
	// decode floor is set, prefer candidates that would still deliver
	// >= MinDecodeTPS to a newly admitted request, so the router does not overpack
	// a provider into a degraded (low tok/s) stream. Never fails closed — if no
	// candidate clears the floor, keep the full pool so the request is still
	// served (growing warm capacity / queueing to protect quality is handled
	// upstream, not by dropping the request here).
	if pr.MinDecodeTPS > 0 {
		pool = preferRoutingCandidates(pool, func(c *routingCandidate) bool {
			return routingcost.ProjectedPerRequestDecodeTPS(&c.snapshot) >= pr.MinDecodeTPS
		})
	}

	// Top-4 by cost over the NARROWED pool (the set the selector ranks); the
	// winner is promoted to top[0] after selection. ≤ 4 compares per candidate,
	// fixed array, no allocation.
	for _, c := range pool {
		scan.insertTop(c)
	}

	scan.pool = pool
	scan.ignoreProviderBreaker = ignoreProviderBreaker
	return scan
}

// selectBestCandidateScanLocked is one pass of candidate selection: it builds the
// eligible pool (scanCandidatesLocked — the single source of eligibility) and
// ranks it by cost, returning the winner plus the whole scan (rejection tallies
// and the ranked pool). When ignoreProviderBreaker is true the node-health
// breaker gate is skipped; scan.breakerRejected (providers dropped while their
// breaker was OPEN) is the signal selectBestCandidateLockedFull uses to decide
// whether a breaker-bypassed fail-open re-scan could help, and is always 0 in
// that mode.
func (r *Registry) selectBestCandidateScanLocked(model string, pr *PendingRequest, ignoreProviderBreaker bool, excludeIDs ...string) (*routingCandidate, candidateScan) {
	scan := r.scanCandidatesLocked(model, pr, ignoreProviderBreaker, excludeIDs...)
	if len(scan.pool) == 0 {
		return nil, scan
	}

	affinity := ""
	if pr.CacheSelectionMode == "active" && r.cacheRouting != nil &&
		pr.CachePlan.generation == r.cacheRouting.generation && !r.cacheRouting.generation.Revoked() {
		affinity = pr.CachePlan.affinityKey
	}
	pr.CacheOpportunity.UsableCandidates = 0
	pr.CacheOpportunity.CreditedCandidates = 0
	for _, candidate := range scan.pool {
		if candidate.cacheTier != "" {
			pr.CacheOpportunity.UsableCandidates++
			if candidate.breakdown.CacheDiscountMs > 0 {
				pr.CacheOpportunity.CreditedCandidates++
			}
		}
	}
	winner, runnerUp, nearTieSize, path := selectRoutingCandidateWithAffinity(scan.pool, affinity)
	pr.CacheOpportunity.AffinityApplied = path == SelectionPrefixAffinity
	scan.runnerUp = candidateSummaryOf(runnerUp)
	scan.nearTieSize = clampInt32(nearTieSize)
	scan.path = path
	scan.promoteWinnerTop(winner)
	r.logRoutingDecision(model, pr, winner, scan.candidateCount)
	return winner, scan
}
