package access

import (
	"net/http"
	"strings"
)

type SelfRoutePolicy struct {
	Enabled        bool
	Prefer         bool
	OwnerAccountID string
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
func ResolveSelfRoutePolicy(r *http.Request) SelfRoutePolicy {
	route := strings.ToLower(strings.TrimSpace(r.Header.Get("X-Darkbloom-Route")))
	keyForces := false
	if k := APIKeyFromContext(r.Context()); k != nil {
		keyForces = k.SelfRouteOnly
	}
	exclusive := keyForces || route == "self"
	prefer := !exclusive && route == "prefer"
	if !exclusive && !prefer {
		return SelfRoutePolicy{}
	}
	owner := ConsumerKeyFromContext(r.Context())
	if owner == "" {
		return SelfRoutePolicy{}
	}
	return SelfRoutePolicy{Enabled: exclusive, Prefer: prefer, OwnerAccountID: owner}
}
