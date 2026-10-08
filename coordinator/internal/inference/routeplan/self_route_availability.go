package routeplan

import (
	"fmt"
	"net/http"

	httpx "github.com/eigeninference/d-inference/coordinator/api/httpx"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type Availability struct {
	Registry *registry.Registry
	Store    store.Store
}

// selfRouteUnavailable reports whether a self-route request cannot proceed and,
// when so, writes the precise terminal error. Self-route never falls back to
// the paid fleet, so "can't serve" is an explicit failure rather than a
// silent reroute. Distinguishes: no machine linked (409), machine offline
// (503), model absent (503), and model-present-but-request-shape-unsupported
// (503) — e.g. a tool call to a node whose chat template fails to render, or a
// media request to a text-only build. traits/requiresVision mirror the
// dispatch-time gates; without them such requests pass this preflight, queue
// for up to 120s, and die as machine_busy instead of failing fast with the
// real cause. Returns false (no write) when at least one owned, online
// machine can serve this request.
func (s Availability) Unavailable(w http.ResponseWriter, r *http.Request, owner, model string, traits registry.RequestTraits, requiresVision bool) bool {
	if reject := s.Rejection(w, r, owner, model, traits, requiresVision); reject != nil {
		reject()
		return true
	}
	return false
}

// Rejection completes every owned-provider walk before returning the
// terminal store lookup or HTTP write. Callers can release their scan permit
// before applying it; nil means that an owned provider can serve the request.
func (s Availability) Rejection(w http.ResponseWriter, r *http.Request, owner, model string, traits registry.RequestTraits, requiresVision bool) func() {
	online, servesRequest := s.Registry.OwnedProviderSummary(owner, model, traits, requiresVision)
	if servesRequest > 0 {
		return nil
	}
	if online == 0 {
		return func() {
			linked := 0
			if recs, err := s.Store.ListProvidersByAccount(r.Context(), owner); err == nil {
				linked = len(recs)
			}
			if linked == 0 {
				httpx.WriteJSON(w, http.StatusConflict, httpx.ErrorResponse("no_linked_machine",
					"self-route requested but no machine is linked to your account — run `darkbloom login` on your Mac to link it", httpx.WithCode("no_linked_machine")))
				return
			}
			w.Header().Set("Retry-After", "30")
			httpx.WriteJSON(w, http.StatusServiceUnavailable, httpx.ErrorResponse("machine_offline",
				"your machine is offline — self-route will not fall back to paid providers; start your Darkbloom node and retry", httpx.WithCode("machine_offline")))
		}
	}
	// Online and the model is served for plain requests, but not for THIS
	// request's shape: the machine lacks a request-shape capability (tools,
	// tool constraints) or the build isn't vision-capable (media). Deterministic for this machine, so
	// say the real cause rather than "not loaded".
	if _, servesBase := s.Registry.OwnedProviderSummary(owner, model, registry.RequestTraits{}, false); servesBase > 0 {
		return func() {
			var reason string
			switch {
			case requiresVision && !traits.HasTools:
				reason = "image/video input needs a vision-capable build of the model"
			case traits.HasTools && !requiresVision:
				reason = "tool calls need a node whose chat template renders cleanly"
			default:
				reason = "this request needs capabilities your node build doesn't advertise (vision-capable model / tool support)"
			}
			httpx.WriteJSON(w, http.StatusServiceUnavailable, httpx.ErrorResponse("model_unavailable",
				fmt.Sprintf("your machine serves model %q but cannot take this request: %s — update your Darkbloom node or load a capable build", model, reason), httpx.WithCode("model_capability_unsupported")))
		}
	}
	// Online, but no owned machine currently serves this model.
	return func() {
		w.Header().Set("Retry-After", "15")
		httpx.WriteJSON(w, http.StatusServiceUnavailable, httpx.ErrorResponse("model_not_loaded",
			fmt.Sprintf("model %q is not available on your machine — load it on your node and retry", model), httpx.WithCode("model_not_loaded")))
	}
}
