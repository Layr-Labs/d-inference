package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/connectiontime"
)

func (r *Registry) newConnectionOrigin(id string, at time.Time) *connectiontime.Origin {
	if r.connectionOriginFactory != nil {
		if origin := r.connectionOriginFactory(id, at); origin != nil {
			return origin
		}
	}
	return connectiontime.New(at)
}

// RegisteredAt returns the connection's immutable creation time, not a persistence time.
func (p *Provider) RegisteredAt() time.Time {
	if p == nil {
		return time.Time{}
	}
	return p.connectionOrigin.Time()
}
