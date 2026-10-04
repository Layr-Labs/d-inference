package inference

import (
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	inroute "github.com/eigeninference/d-inference/coordinator/internal/inference/routeplan"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

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

func (s *Owner) resolveSelfRoutePolicy(r *http.Request) selfRoutePolicy {
	p := access.ResolveSelfRoutePolicy(r)
	return selfRoutePolicy{enabled: p.Enabled, prefer: p.Prefer, ownerAccountID: p.OwnerAccountID}
}

func (s *Owner) selfRouteUnavailable(w http.ResponseWriter, r *http.Request, owner, model string, traits registry.RequestTraits, vision bool) bool {
	return (inroute.Availability{Registry: s.registry, Store: s.store}).Unavailable(w, r, owner, model, traits, vision)
}

func (s *Owner) selfRouteRejection(w http.ResponseWriter, r *http.Request, owner, model string, traits registry.RequestTraits, vision bool) func() {
	return (inroute.Availability{Registry: s.registry, Store: s.store}).Rejection(w, r, owner, model, traits, vision)
}
