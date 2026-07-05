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

// selfRouteUnavailable reports whether a self-route request cannot proceed and,
// when so, writes the precise terminal error. Self-route never falls back to
// the paid fleet, so "can't serve" is an explicit failure rather than a
// silent reroute. Distinguishes: no machine linked (409), machine offline
// (503), model absent (503), and model-present-but-request-shape-unsupported
// (503) — e.g. a tool call to a node below the tools capability floor, or a
// media request to a text-only build. traits/requiresVision mirror the
// dispatch-time gates; without them such requests pass this preflight, queue
// for up to 120s, and die as machine_busy instead of failing fast with the
// real cause. Returns false (no write) when at least one owned, online
// machine can serve this request.
func (s *Server) selfRouteUnavailable(w http.ResponseWriter, r *http.Request, owner, model string, traits registry.RequestTraits, requiresVision bool) bool {
	online, servesRequest := s.registry.OwnedProviderSummary(owner, model, traits, requiresVision)
	if servesRequest > 0 {
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
	// Online and the model is served for plain requests, but not for THIS
	// request's shape: the machine is below a capability floor (tools) or the
	// build isn't vision-capable (media). Deterministic for this machine, so
	// say the real cause rather than "not loaded".
	if _, servesBase := s.registry.OwnedProviderSummary(owner, model, registry.RequestTraits{}, false); servesBase > 0 {
		var reason string
		switch {
		case requiresVision && !traits.HasTools:
			reason = "image/video input needs a vision-capable build of the model"
		case traits.HasTools && !requiresVision:
			reason = "tool calls need a newer node version with a healthy chat template"
		default:
			reason = "this request needs capabilities your node build doesn't advertise (vision-capable model / tool support)"
		}
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("model_unavailable",
			fmt.Sprintf("your machine serves model %q but cannot take this request: %s — update your Darkbloom node or load a capable build", model, reason),
			withCode("model_capability_unsupported")))
		return true
	}
	// Online, but no owned machine currently serves this model.
	w.Header().Set("Retry-After", "15")
	writeJSON(w, http.StatusServiceUnavailable, errorResponse("model_not_loaded",
		fmt.Sprintf("model %q is not available on your machine — load it on your node and retry", model),
		withCode("model_not_loaded")))
	return true
}
