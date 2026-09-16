package ingress

import (
	"fmt"
	"net/http"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
	"github.com/eigeninference/d-inference/coordinator/api/requestcontext"
	"github.com/eigeninference/d-inference/coordinator/inference/dispatch"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// ResolveSelfRoutePolicy derives the self-route decision from the request's
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
func ResolveSelfRoutePolicy(r *http.Request) dispatch.RoutePolicy {
	route := strings.ToLower(strings.TrimSpace(r.Header.Get("X-Darkbloom-Route")))
	keyForces := false
	if k := requestcontext.APIKey(r.Context()); k != nil {
		keyForces = k.SelfRouteOnly
	}
	exclusive := keyForces || route == "self"
	prefer := !exclusive && route == "prefer"
	if !exclusive && !prefer {
		return dispatch.RoutePolicy{}
	}
	owner := requestcontext.AccountID(r.Context())
	if owner == "" {
		return dispatch.RoutePolicy{}
	}
	return dispatch.RoutePolicy{Enabled: exclusive, Prefer: prefer, OwnerAccountID: owner}
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
func (s *Controller) selfRouteUnavailable(w http.ResponseWriter, r *http.Request, owner, model string, traits registry.RequestTraits, requiresVision bool) bool {
	online, servesRequest := s.deps.Registry().OwnedProviderSummary(owner, model, traits, requiresVision)
	if servesRequest > 0 {
		return false
	}
	if online == 0 {
		linked := 0
		if recs, err := s.deps.Store().ListProvidersByAccount(r.Context(), owner); err == nil {
			linked = len(recs)
		}
		if linked == 0 {
			httpresponse.WriteJSON(w, http.StatusConflict, httpresponse.ErrorBody("no_linked_machine",
				"self-route requested but no machine is linked to your account — run `darkbloom login` on your Mac to link it",
				httpresponse.WithCode("no_linked_machine")))
			return true
		}
		w.Header().Set("Retry-After", "30")
		httpresponse.WriteJSON(w, http.StatusServiceUnavailable, httpresponse.ErrorBody("machine_offline",
			"your machine is offline — self-route will not fall back to paid providers; start your Darkbloom node and retry",
			httpresponse.WithCode("machine_offline")))
		return true
	}
	// Online and the model is served for plain requests, but not for THIS
	// request's shape: the machine is below a capability floor (tools) or the
	// build isn't vision-capable (media). Deterministic for this machine, so
	// say the real cause rather than "not loaded".
	if _, servesBase := s.deps.Registry().OwnedProviderSummary(owner, model, registry.RequestTraits{}, false); servesBase > 0 {
		var reason string
		switch {
		case requiresVision && !traits.HasTools:
			reason = "image/video input needs a vision-capable build of the model"
		case traits.HasTools && !requiresVision:
			reason = "tool calls need a newer node version with a healthy chat template"
		default:
			reason = "this request needs capabilities your node build doesn't advertise (vision-capable model / tool support)"
		}
		httpresponse.WriteJSON(w, http.StatusServiceUnavailable, httpresponse.ErrorBody("model_unavailable",
			fmt.Sprintf("your machine serves model %q but cannot take this request: %s — update your Darkbloom node or load a capable build", model, reason),
			httpresponse.WithCode("model_capability_unsupported")))
		return true
	}
	// Online, but no owned machine currently serves this model.
	w.Header().Set("Retry-After", "15")
	httpresponse.WriteJSON(w, http.StatusServiceUnavailable, httpresponse.ErrorBody("model_not_loaded",
		fmt.Sprintf("model %q is not available on your machine — load it on your node and retry", model),
		httpresponse.WithCode("model_not_loaded")))
	return true
}
