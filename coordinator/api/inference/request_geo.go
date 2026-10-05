package inference

import (
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *Owner) requestLocation(r *http.Request) *store.ProviderLocation {
	if s == nil || s.geoResolver == nil || r == nil {
		return nil
	}
	loc := s.geoResolver.Lookup(r)
	if loc == nil {
		return nil
	}
	cp := *loc
	if cp.Source != "" {
		cp.Source = "request_" + cp.Source
	}
	return &cp
}
