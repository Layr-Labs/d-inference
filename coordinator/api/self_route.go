package api

import (
	"fmt"
	"net/http"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// This file holds the consumer-side "use my own machine, for free" (self-route)
// helpers: how the opt-in is resolved from the authenticated request, and how
// pre-flight eligibility maps to precise, no-fallback error responses. The
// routing/billing wiring that consumes these lives in consumer.go (dispatch)
// and provider.go (settlement); the owner filter and trust relaxation live in
// the registry scheduler.

// selfRoutePolicy carries the authenticated "use my own machine, for free"
// decision through dispatch so that primary, sequential-retry, and
// speculative-backup PendingRequests all inherit the same owner filter and
// free-billing flag. It is resolved entirely server-side (from the request's
// authenticated identity plus the X-Darkbloom-Route header / per-key flag);
// no field originates from the request body.
type selfRoutePolicy struct {
	// enabled is EXCLUSIVE self-route: restrict routing to providers owned by
	// ownerAccountID, mark the request free, and never fall back to the paid
	// fleet. The zero value is a normal paid request to any provider.
	enabled bool
	// prefer is "prefer my own machine, fall back to the paid fleet": route to
	// an owned provider whenever one can serve (free), otherwise use the public
	// fleet (charged). Mutually exclusive with `enabled`; it takes a normal
	// reservation up front so the paid fallback can settle, and billing is
	// decided at settlement by whether an owned machine actually served it.
	prefer bool
	// ownerAccountID is the account that must own the serving provider.
	ownerAccountID string
}

// resolveSelfRoutePolicy derives the self-route decision from the request's
// authenticated identity and opt-in signals:
//
//   - A per-key SelfRouteOnly flag is a hard ceiling — every request on that key
//     is EXCLUSIVE self-route (owned-only, free, no fallback), regardless of header.
//   - X-Darkbloom-Route: self  → EXCLUSIVE for this one request.
//   - X-Darkbloom-Route: prefer → PREFER (owned-first, paid fallback) for this request.
//
// The owner is the authenticated consumer key, the same namespace as
// Provider.AccountID (both derive from the account that linked the device). An
// unresolved identity (empty consumer key) disables self-route entirely so it
// can never match a machine.
func (s *Server) resolveSelfRoutePolicy(r *http.Request) selfRoutePolicy {
	route := strings.ToLower(strings.TrimSpace(r.Header.Get("X-Darkbloom-Route")))
	keyForces := false
	if k := apiKeyFromContext(r.Context()); k != nil {
		keyForces = k.SelfRouteOnly
	}
	exclusive := keyForces || route == "self"
	prefer := !exclusive && route == "prefer"
	if !exclusive && !prefer {
		return selfRoutePolicy{}
	}
	owner := consumerKeyFromContext(r.Context())
	if owner == "" {
		return selfRoutePolicy{}
	}
	return selfRoutePolicy{enabled: exclusive, prefer: prefer, ownerAccountID: owner}
}

// downgradePreferToSelfRoute converts a PREFER request into an EXCLUSIVE
// self-route when the owner can't afford the paid fallback but their own
// machine can serve THIS request right now. This is what lets a zero-balance
// provider-owner keep using their own Mac for free: instead of a 402, the
// request is pinned to the owner's online machine (free, no paid fallback).
//
// Eligibility is the full request shape (model + serial allowlist + vision +
// tools), not just "owns a provider for the model": if the owned machine can't
// actually satisfy the request, we must NOT downgrade — doing so would strand an
// exclusive self-route with no candidate (and no paid fallback) instead of
// preserving the precise 402/error.
//
// It mutates policy in place and reports whether the downgrade happened. The
// downgrade only fires for PREFER requests (never a normal paid request) — so
// billing integrity holds: the request can no longer settle on the paid fleet,
// and if the machine drops between here and dispatch, the exclusive self-route
// pre-flight returns a precise 503 rather than handing out free public inference.
func (s *Server) downgradePreferToSelfRoute(policy *selfRoutePolicy, model string, traits registry.RequestTraits, requiresVision bool, allowedSerials []string) bool {
	if policy == nil || !policy.prefer || policy.ownerAccountID == "" {
		return false
	}
	if !s.registry.OwnedProviderEligible(policy.ownerAccountID, model, traits, requiresVision, allowedSerials) {
		return false
	}
	policy.enabled = true
	policy.prefer = false
	return true
}

// pinPreferToSelfRouteOnShed converts a PREFER request into an EXCLUSIVE
// self-route when its model is being shed from the public fleet but the owner
// has a structurally-eligible machine. Model-shed is a PUBLIC-fleet load lever,
// so a prefer request must never be allowed to skip the shed and then fall back
// to the paid public fleet (which would defeat the shed for exactly the fleet it
// protects). Pinning it owned-only — exclusive, no fallback — keeps the shed
// effective while never blocking an owner from their own Mac: it runs free on
// the owner's machine (queuing there if busy) instead of touching the shed
// public fleet. Owners with no eligible machine are left as prefer and shed
// normally by shedIfModelRejected. Mutates policy in place.
func (s *Server) pinPreferToSelfRouteOnShed(policy *selfRoutePolicy, model string, traits registry.RequestTraits, requiresVision bool, allowedSerials []string) {
	if policy == nil || !policy.prefer || policy.ownerAccountID == "" {
		return
	}
	if !s.registry.OwnedProviderEligible(policy.ownerAccountID, model, traits, requiresVision, allowedSerials) {
		return
	}
	policy.enabled = true
	policy.prefer = false
}

// selfRouteUnavailable reports whether a self-route request cannot proceed and,
// when so, writes the precise terminal error. Self-route never falls back to
// the paid fleet, so "can't serve" is an explicit failure rather than a
// silent reroute. Distinguishes: no machine linked (409), machine offline
// (503), and online-but-can't-serve-this-model (503). Returns false (no write)
// when at least one owned, online machine can serve the model.
func (s *Server) selfRouteUnavailable(w http.ResponseWriter, r *http.Request, owner, model string) bool {
	online, servesModel := s.registry.OwnedProviderSummary(owner, model)
	if servesModel > 0 {
		return false
	}
	if online == 0 {
		linked := 0
		if recs, err := s.store.ListProvidersByAccount(r.Context(), owner); err == nil {
			linked = len(recs)
		}
		if linked == 0 {
			writeJSON(w, http.StatusConflict, errorResponse("no_linked_machine",
				"self-route requested but no machine is linked to your account — run `darkbloom login` on your Mac to link it",
				withCode("no_linked_machine")))
			return true
		}
		w.Header().Set("Retry-After", "30")
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("machine_offline",
			"your machine is offline — self-route will not fall back to paid providers; start your Darkbloom node and retry",
			withCode("machine_offline")))
		return true
	}
	// Online, but no owned machine currently serves this model.
	w.Header().Set("Retry-After", "15")
	writeJSON(w, http.StatusServiceUnavailable, errorResponse("model_not_loaded",
		fmt.Sprintf("model %q is not available on your machine — load it on your node and retry", model),
		withCode("model_not_loaded")))
	return true
}
